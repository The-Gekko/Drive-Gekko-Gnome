# Automatización: de upstream a `pacman -Syu`

Este documento explica qué hace el bot, cuándo, y qué te toca a ti. Está
escrito para que puedas entenderlo y arreglarlo dentro de un año sin acordarte
de nada.

## La idea en una frase

**Si Arch sube el último número de gvfs o cualquier cosa de
gnome-online-accounts, o amplía los parches de libsoup, el bot lo hace solo y
lo publica. Si cambia otro número, si Solus toca sus flags, o si se mueve
libgdata, te abre un PR y tú pulsas Merge.** En ambos casos, los usuarios lo
reciben con `sudo pacman -Syu`.

## Quién manda la versión de cada paquete (y por qué no es Solus)

| Paquete | Sigue a | Por qué |
| --- | --- | --- |
| `gvfs-google` | el **gvfs de Arch `[extra]`** | `gvfsd-google` enlaza contra `libgvfscommon.so` y `libgvfsdaemon.so` del gvfs del sistema, sin soname versionado. Seguir a Solus o a GNOME daría un paquete ininstalable o roto |
| `gnome-online-accounts` | el **GOA de Arch `[extra]`**, `pkgver` y `pkgrel` | Sombrea ese paquete y depende de `libgoa=<misma versión>`. Nuestro `pkgrel` es siempre el de Arch + `.1` (3.58.1-1 → 3.58.1-1.1): gana en versión, no colisiona en la caché |
| `libsoup2` | **GNOME** (solo la serie 2.74) para la versión; **Arch** (el `libsoup` del AUR) para el rango de parches | La 3.x no vale: libgdata necesita la 2.4. Solus compila el tarball sin parches |
| `libgdata` | **GNOME** | Upstream archivado: no se moverá. Se vigila igual, cuesta tres líneas |
| Solus | **nada**: es un canario | Solo se vigila el bloque `setup:` de sus `package.yml`. Si Solus cambia `-Dgoogle=true` o `-Dgoogle_files=true`, una persona tiene que mirarlo. Ver [upstream/solus/README.md](../upstream/solus/README.md) |

## Las piezas

| Fichero | Qué hace |
| --- | --- |
| `scripts/sync-upstream.sh` | El cerebro. Compara cada PKGBUILD con su fuente, y con `--apply` edita `pkgver`, `pkgrel` y el checksum. Ejecutable en tu máquina: sin `--apply` solo informa |
| `.github/workflows/sync-upstream.yml` | El vigilante. Cada 4 h (o con *Run workflow*) ejecuta el anterior y decide: nada / publicar / PR / issue |
| `scripts/build-all.sh --install` | Construye e instala la cadena en orden. Lo usan el CI, el bot y tú |
| `scripts/verify-chain.sh` | Dice si la cadena instalada sirve (ldd, pin de gvfs, scope de Drive, libsoup 2.4). Lo usan install.sh, el CI y el bot |
| `scripts/publish-repo.sh` | `repo-add` + prueba de consumidor + subida al Release `repo`. Los paquetes ya publicados no se tocan nunca |
| `.github/workflows/build.yml` | Con cada push a `main` (tuyo o un Merge): lint, cadena entera en un Arch limpio, y publicación |
| `scripts/add-repo.sh` | Mete el bloque en `/etc/pacman.conf` en el sitio correcto (antes de `[core]`) |
| `pacman-hooks/` y `systemd/` | La última red en la máquina del usuario: avisan si algo pisa el GOA o el pin |

## Qué pasa en cada caso

**Arch sube gvfs 1.60.2 → 1.60.3.** El bot lo ve en el `pacman -Si` del propio
contenedor (el mismo espejo con el que luego construye, así no hay falsos
positivos). Confirma que la opción `google` sigue en el `meson_options.txt` de
ese tag, toma el sha256 del `.sha256sum` de GNOME (filtrando por nombre de
fichero), edita el PKGBUILD, construye la cadena entera, la verifica, hace
push a `main` y publica. Tú no haces nada. Tus usuarios: `pacman -Syu`.

**Arch publica gnome-online-accounts 3.58.1-2 o 3.58.2-1.** Igual: b2sum del
PKGBUILD oficial de Arch para ese tag, confirma `google_files`, `pkgrel` pasa a
`2.1` (o `1.1` con el pkgver nuevo), construye, el `package()` aborta si el
binario no pide el scope de Drive, y publica.

**Arch sube gvfs 1.60 → 1.62, o GOA 3.58 → 3.60.** Cambio de serie: la opción
`google` está `deprecated` y puede desaparecer, y el PKGBUILD de Arch puede
cambiar de forma. El bot construye igual (para demostrar que compila) y abre
un **PR** con el run enlazado. Tú lo revisas en tres líneas y pulsas Merge.

**Solus cambia el `setup:` de gvfs o de GOA.** Issue. No se toca ningún
PKGBUILD; tú decides si nos afecta.

**Algo no cuadra** (un checksum, la opción `google` desapareció, el commit de
parches del AUR no existe en GNOME): issue, y nada se aplica. Nunca se
"arregla" con `updpkgsums` a ciegas: eso ocultaría una manipulación.

**El bump no construye.** Issue con el log. Nada se publica. Tus usuarios se
quedan con la versión anterior hasta que lo mires; su `pacman -Syu` se
plantará por el pin de gvfs o libgoa (ruidoso, esperado).

## Lo que te toca a ti

1. **Una vez**, en GitHub → *Settings → Actions → General*: *Workflow
   permissions* en **Read and write**, y marcar **Allow GitHub Actions to
   create and approve pull requests**. Sin eso el bot falla con 403.
2. **Una vez**, hacer el repositorio **público**. Los assets de un Release
   privado exigen token y pacman no puede pasarlo.
3. **Opcional, recomendado**: activar la firma ([keys/README.md](../keys/README.md)).
4. **Cuando llegue un PR** (cada varios meses): mirar que el check está en
   verde y que el diff toca solo lo anunciado. Si quieres probarlo antes:
   `gh pr checkout <n> && ./install.sh --compilar` y monta Drive. Merge.
5. **Cuando llegue un issue**: leerlo. El bot lo cierra solo si en un run
   posterior el problema ya no está.
6. **Antes de hacer push desde tu IDE**: `git pull`, porque el bot también
   hace commits en `main`.

## Lo que puede fallar, y cómo se nota

| Situación | Qué ven los usuarios | Qué hacer |
| --- | --- | --- |
| Arch sube gvfs/GOA y el bot aún no ha corrido (hasta 4 h) | `pacman -Syu` se planta: *«instalar gvfs (X) rompe la dependencia gvfs=Y requerida por gvfs-google»* | Esperar, o *Actions → sync-upstream → Run workflow*. Escape: `pacman -Syu --ignore gvfs,libgoa` |
| GitHub Actions caído | Lo mismo, más tiempo | Plan B: `./install.sh --compilar` en tu máquina; o `scripts/build-all.sh --install && scripts/publish-repo.sh --upload` con `gh auth login` |
| El cron se desactiva (60 días sin commits) | Nada se publica | El bot hace un commit *keepalive* cada ~50 días. Si aun así se para, *Run workflow* lo reactiva |
| Alguien pone el repo después de `[extra]` | Al siguiente bump de Arch, GOA oficial y «Permiso denegado» | El hook lo detecta y avisa. `sudo scripts/add-repo.sh` lo comprueba |
| GNOME borra la opción `google` de gvfs | Issue: *«fin del camino»* | Quedarse en la versión actual o migrar a rclone ([estado-upstream.md](estado-upstream.md)) |
