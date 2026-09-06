# Automatización: de upstream a `pacman -Syu`

Este documento explica qué hace el bot, qué hace tu máquina, cuándo, y qué te
toca a ti. Está escrito para que puedas entenderlo y arreglarlo dentro de un
año sin acordarte de nada.

## La idea en una frase

**El bot de GitHub mantiene las recetas (PKGBUILD) al día y las verifica
construyéndolas en un Arch limpio; el temporizador de tu máquina las trae y las
construye en un repositorio de pacman local; tú instalas con `sudo pacman
-Syu`.** Por GitHub pasan las recetas; los binarios nunca.

## Quién manda la versión de cada paquete (y por qué no es Solus)

| Paquete | Sigue a | Por qué |
| --- | --- | --- |
| `gvfs-google` | el **gvfs de Arch `[extra]`** | `gvfsd-google` enlaza contra `libgvfscommon.so` y `libgvfsdaemon.so` del gvfs del sistema, sin soname versionado. Seguir a Solus o a GNOME daría un paquete ininstalable o roto |
| `gnome-online-accounts` | el **GOA de Arch `[extra]`**, `pkgver` y `pkgrel` | Sombrea ese paquete y depende de `libgoa=<misma versión>`. Nuestro `pkgrel` es siempre el de Arch + `.1` (3.58.1-1 → 3.58.1-1.1): gana en versión, no colisiona en la caché |
| `libsoup2` | **GNOME** (solo la serie 2.74) para la versión; **Arch** (el `libsoup` del AUR) para el rango de parches | La 3.x no vale: libgdata necesita la 2.4. Solus compila el tarball sin parches. El commit nuevo tiene que existir en GNOME **y** estar en la rama `libsoup-2-74` |
| `libgdata` | **GNOME** | Upstream archivado: no se moverá. Se vigila igual |
| Solus | **nada**: es un canario | Solo se vigila el bloque `setup:` de sus `package.yml`. Si Solus cambia `-Dgoogle=true` o `-Dgoogle_files=true`, issue. Ver [upstream/solus/README.md](../upstream/solus/README.md) |

Todo lo que el bot lee de fuera se **valida** antes de escribirlo (versiones con
el alfabeto de pacman, hashes de longitud exacta) y una versión nueva tiene que
ser **mayor** (`vercmp`): un retroceso nunca se aplica solo.

## Las piezas

| Dónde | Fichero | Qué hace |
| --- | --- | --- |
| GitHub | `scripts/sync-upstream.sh` | El cerebro. Compara cada PKGBUILD con su fuente; con `--apply` edita `pkgver`, `pkgrel` y el checksum. Ejecutable en tu máquina: sin `--apply` solo informa |
| GitHub | `.github/workflows/sync-upstream.yml` | El vigilante. Cada 8 h (o con *Run workflow*) ejecuta el anterior y decide: nada / push a main / PR / issue |
| GitHub | `.github/workflows/build.yml` | Con cada push o PR (y cada lunes): lint; la cadena entera con `build-all.sh`; y, en un job aparte sobre un contenedor **sin preparar**, el camino de una máquina real (`local-repo.sh`: solo `makedepends` y `makepkg -d`), que es el único que caza una dependencia de compilación sin declarar |
| ambos | `scripts/build-all.sh --install` | Construye e instala la cadena en orden. Lo usa el CI |
| ambos | `scripts/verify-chain.sh` | Dice si la cadena instalada sirve (ldd, pin de gvfs, scope de Drive, libsoup 2.4). La quinta, que haya llavero, solo avisa: no es parte de lo que construimos |
| ambos | `scripts/publish-repo.sh --check` | `repo-add` con lista blanca de 4, prueba de que pacman lee la `.db` y de que el `DownloadUser` de pacman llega hasta ella |
| tu máquina | `scripts/local-repo.sh` + `systemd/drive-gekko-repo.{service,timer}` | Cada 6 h: `git pull`; si cambió un PKGBUILD **o falta algo en `out/`**, instala los `makedepends` de las recetas, construye como tu usuario, instala `libsoup2`/`libgdata`, y deja `gvfs-google`/`gnome-online-accounts` en el repo local para tu próximo `pacman -Syu` |
| tu máquina | `scripts/add-repo.sh --local` | Mete el repositorio local en `/etc/pacman.conf` antes de `[core]`, lo recoloca si está mal, y da acceso de lectura por ACL al `DownloadUser` de pacman (si no puede, no escribe el bloque) |
| tu máquina | `pacman-hooks/`, `systemd/drive-gekko-check.service` | La última red: avisan si algo pisa el GOA, el pin, el orden de los repos, la ruta del repositorio local o el llavero. Siempre salen con 0 (`ESTRICTO=1` es lo que el CI usa para que fallen de verdad) |

## Qué pasa en cada caso

**Arch sube gvfs 1.60.2 → 1.60.3.** El bot lo ve en el `pacman -Si` del propio
contenedor. Confirma que la opción `google` sigue en el `meson_options.txt` de
ese tag, toma el sha256 del `.sha256sum` de GNOME (filtrando por nombre de
fichero), comprueba con `vercmp` que es mayor, edita el PKGBUILD, construye la
cadena entera, la verifica, y hace push a `main`. En tu máquina: el
temporizador hace `git pull`, ve el PKGBUILD cambiado, construye `gvfs-google`
1.60.3 y lo deja en `out/`. Tu siguiente `sudo pacman -Syu` instala `gvfs`
1.60.3 (de Arch) y `gvfs-google` 1.60.3 (del repo local) **juntos**.

**Arch publica gnome-online-accounts 3.58.1-2 o 3.58.2-1.** Igual: b2sum del
PKGBUILD oficial de Arch para ese tag, confirma `google_files`, `pkgrel` pasa a
`2.1` (o `1.1` con el pkgver nuevo), construye, el `package()` aborta si el
binario no pide el scope de Drive, push. El temporizador construye; tu `-Syu`
instala `libgoa` (de Arch) y GOA (del repo local) juntos.

**Arch sube gvfs 1.60 → 1.62, o GOA 3.58 → 3.60.** Cambio de serie: la opción
`google` está `deprecated` y puede desaparecer, y el PKGBUILD de Arch puede
cambiar de forma. El bot construye igual (para demostrar que compila) y abre
un **PR** con el run enlazado en el cuerpo (un PR abierto por el bot no tiene
checks propios; el enlace es la prueba). Tú lo revisas y pulsas Merge.

**Arch amplía los parches de libsoup.** PR. El bot comprueba que el commit
existe en `gitlab.gnome.org/GNOME/libsoup` y que está en la rama `libsoup-2-74`;
si no, aviso y no se aplica.

**Solus cambia el `setup:` de gvfs o de GOA.** Issue. No se toca ningún
PKGBUILD, y **no bloquea** los bumps rutinarios de los demás; tú decides si
nos afecta.

**Algo no cuadra** (un checksum ilegible, la opción `google` desapareció, la
versión de [extra] es menor que la nuestra, un epoch): aviso en un issue, ese
paquete no se bumpea, los demás sí. Nunca se «arregla» con `updpkgsums` a
ciegas: eso ocultaría una manipulación.

**El bump no construye.** Issue con el log; `main` no se toca. Tu `pacman -Syu`
se plantará por el pin de gvfs o libgoa (ruidoso, esperado) hasta que lo mires.

**El propio bot falla** (red, formato inesperado): descarta lo editado, issue,
run en rojo.

## Lo que te toca a ti

1. **Una vez**, en GitHub → *Settings → Actions → General*: marcar **Allow
   GitHub Actions to create and approve pull requests**. Sin eso, abrir el PR
   falla con 403 (el resto de permisos los declara el propio workflow).
2. **Cuando llegue un PR** (cada varios meses): abrir el run enlazado y ver
   que está en verde, comprobar que el diff toca solo lo anunciado. Si quieres
   probarlo antes: `gh pr checkout <n>`, `sudo systemctl start
   drive-gekko-repo.service`, y al terminar `git checkout main`. Merge.
3. **Cuando llegue un issue**: leerlo. El bot lo cierra solo si en un run
   posterior el problema ya no está.
4. **Antes de hacer push desde tu IDE**: `git pull`, porque el bot también
   hace commits en `main`.
5. **Cuando `pacman -Syu` se plante por `gvfs=` o `libgoa=`**: es el pin, a
   propósito. `sudo systemctl start drive-gekko-repo.service` y repetir.

## Lo que puede fallar, y cómo se nota

| Situación | Qué ves | Qué hacer |
| --- | --- | --- |
| Arch sube gvfs/GOA y el bot aún no ha corrido (≤ 8 h) o el temporizador no ha construido (≤ 6 h) | `pacman -Syu` se planta: *«instalar gvfs (X) rompe la dependencia gvfs=Y requerida por gvfs-google»* | `sudo systemctl start drive-gekko-repo.service`; si la receta aún no está en git, *Actions → sync-upstream → Run workflow* |
| El temporizador no puede hacer `git pull` | Notificación «fallo al actualizar» y `journalctl -u drive-gekko-repo` | El repo es público: no hay credencial que arreglar. Mirar la red y que el remoto del clon sea el `https` (`git -C <clon> remote -v`) |
| El temporizador se cuelga, o lo mata el sistema (OOM, SIGKILL) | La unidad corta a las 2 h (`TimeoutStartSec`) y su `ExecStopPost` notifica con el motivo que da systemd | `journalctl -u drive-gekko-repo -b`. Sin ese límite la unidad se quedaría en *activating* para siempre y el temporizador no volvería a dispararse |
| GitHub Actions caído o con la cola parada | Nada nuevo en `main` | `./scripts/sync-upstream.sh --apply` en tu máquina, revisar el diff, commit, y `sudo systemctl start drive-gekko-repo.service` |
| Alguien pone el repo después de `[extra]` | Hook y notificación | `sudo scripts/add-repo.sh --local <repo>/out` |
| Mueves o renombras el clon | Todo `pacman -Sy` falla, y el temporizador muere diciendo que el clon ya no está en la ruta de `/etc/drive-gekko-gnome.conf` | Corregir los **dos** sitios: `sudo <clon>/scripts/add-repo.sh --local <clon>/out` y `REPO=` en `/etc/drive-gekko-gnome.conf` |
| GNOME borra la opción `google` de gvfs | Issue: *«fin del camino»* | Quedarse en la versión actual o migrar a rclone ([estado-upstream.md](estado-upstream.md)) |
