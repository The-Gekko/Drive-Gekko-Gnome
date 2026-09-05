# Mantenimiento

Guía de lo que hay que hacer cada vez que se toca un paquete. Antes de nada,
lee [estado-upstream.md](estado-upstream.md): aquí mantenemos software que
nadie mantiene, y eso cambia las reglas.

## Herramientas

```bash
sudo pacman -S --needed base-devel git meson ninja namcap pacman-contrib devtools
```

- `namcap` — analiza PKGBUILDs y paquetes construidos.
- `updpkgsums` (pacman-contrib) — recalcula los `sha256sums`.
- `devtools` — `extra-x86_64-build` construye en un chroot limpio.

## Regla nº 1: el origen del código

**Todo tarball sale de `download.gnome.org`, nunca del AUR ni de un espejo de
terceros.** Y el checksum se verifica contra el fichero de sumas que publica
GNOME junto al tarball:

```bash
cd packages/libgdata
updpkgsums                                   # calcula el sha256 de lo bajado
curl -s https://download.gnome.org/sources/libgdata/0.18/libgdata-0.18.1.sha256sum
# los dos valores deben coincidir; si no, PARA y averigua por qué
```

> [!CAUTION]
> **Trampa real:** el fichero `.sha256sum` de GNOME tiene **varias líneas** —
> una por artefacto publicado, incluido un `.news` que va **antes** que el
> tarball. Un `head -1` o un `awk '{print $1}'` sin filtrar te da el hash del
> fichero equivocado y te hace creer que el PKGBUILD está mal cuando está bien.
> Filtra siempre por el nombre del tarball:
>
> ```bash
> curl -s .../libgdata-0.18.1.sha256sum | awk '$2=="libgdata-0.18.1.tar.xz"{print $1}'
> ```

`libsoup2` y `gnome-online-accounts` no usan tarball: clonan el tag de GNOME y
se verifican con `b2sums` del checkout, igual que hace Arch. `updpkgsums` (y
`makepkg -g`) también recalculan ese `b2sum` para fuentes `git+…#tag=`, así que
el flujo es el mismo. Si cambias de tag, el valor debe coincidir con el del
PKGBUILD oficial de Arch para ese mismo tag: es una segunda comprobación
gratis.

## Regla nº 2: `gvfs-google` va atado a `gvfs`

`gvfsd-google` enlaza contra `/usr/lib/gvfs/libgvfscommon.so`, que **no tiene
soname versionado**. Si Arch sube `gvfs` y tú no reconstruyes, el backend deja
de arrancar (o peor, arranca contra símbolos que cambiaron).

Por eso el `depends` lleva `gvfs=$pkgver` exacto. Cuando Arch publique una
versión nueva:

```bash
LC_ALL=C pacman -Si gvfs | grep '^Version'   # p.ej. 1.60.3-1 (en cualquier idioma)
cd packages/gvfs-google
$EDITOR PKGBUILD                        # pkgver=1.60.3, pkgrel=1
updpkgsums
makepkg --syncdeps --cleanbuild --install
```

Un `pacman -Syu` que actualice `gvfs` y deje tu `gvfs-google` viejo **fallará
con un conflicto de dependencias**, y eso es lo que queremos: mejor que pare
pacman a que se rompa el montaje en silencio.

## Regla nº 3: `libsoup2` no se sube de versión

Este paquete está clavado a la serie **2.74** a propósito. libsoup 3.x existe y
está viva, pero `libgdata` no está portada a ella; ese es justamente el motivo
de todo este lío. `check-updates.sh` ya filtra por la serie 2.74, así que no
verás avisos de 3.x.

Los **parches de CVE** vienen del paquete oficial de Arch: el `prepare()` hace
`git cherry-pick -n 2.74.3..<commit>` sobre la rama de mantenimiento. Cuando
Arch amplíe ese rango, actualiza `_cvecommit` en el PKGBUILD contrastándolo con
`https://aur.archlinux.org/libsoup.git`.

Lo que sí hay que vigilar de libsoup2 son los **avisos de seguridad**. Ya no
hay *releases* de la serie 2.x, pero sí commits en su rama de mantenimiento
(los que Arch recoge con el cherry-pick); el rango se actualiza a mano:

```bash
# el tracker de Arch sigue listando los CVEs históricos del paquete
xdg-open https://security.archlinux.org/package/libsoup
```

Si aparece algo grave y explotable en el camino que usa libgdata, la respuesta
correcta probablemente no sea parchear a mano: es pasarse a rclone (Opción B
de estado-upstream.md).

## Regla nº 4: `gnome-online-accounts` sombrea un paquete oficial

Es el único paquete del repo que **sustituye** a uno de `[extra]`. Lleva la
misma `pkgver-pkgrel` que el de Arch, así que `pacman -Syu` no lo toca... hasta
que Arch publique una versión nueva. Entonces instala la suya, el permiso de
Drive desaparece y **Nautilus empieza a dar «Permiso denegado» sin más aviso**.

No falla el arranque. No hay error en el log. Simplemente deja de funcionar.

### Cómo te enteras

Tres redes, de la más inmediata a la más tardía:

1. **Hook de pacman** — `/etc/pacman.d/hooks/99-drive-gekko-gnome.hook`, que
   ejecuta `/usr/local/lib/drive-gekko-gnome/post-upgrade-check.sh`. Salta al
   terminar cualquier transacción sobre `gnome-online-accounts` o `gvfs`.
   Escribe en la terminal **y lanza una notificación de escritorio**, porque la
   salida de un hook se pierde entre las 200 líneas de un `-Syu` grande.
2. **Servicio de inicio de sesión** — `drive-gekko-check.service` (unidad de
   usuario). Repite la comprobación en cada arranque, por si la actualización
   ocurrió desde una TTY o con el escritorio caído.
3. **A mano** — `./scripts/check-updates.sh`, cuando quieras.

Los tres ejecutan el mismo script. La comprobación de fondo es:

```bash
strings /usr/lib/libgoa-backend-1.0.so | grep googleapis.com/auth/drive
```

Si no devuelve nada, Drive está roto. **No basta con `makepkg -si` tal cual**,
porque el PKGBUILD lleva `depends=("libgoa=${pkgver}")` y Arch acaba de subir
`libgoa`. El arreglo son tres pasos:

```bash
# 1. ¿qué versión tiene Arch ahora?
LC_ALL=C pacman -Si gnome-online-accounts | grep '^Version'     # p.ej. 3.58.2-1

# 2. edita packages/gnome-online-accounts/PKGBUILD:
#      pkgver = el de Arch (3.58.2)
#      pkgrel = MAYOR que el de Arch (si Arch tiene -1, pon 2), para que pacman
#               no vuelva a preferir el oficial
#      b2sums = el del PKGBUILD oficial de Arch para ese tag:
#        https://gitlab.archlinux.org/archlinux/packaging/packages/gnome-online-accounts/-/raw/main/PKGBUILD
#      (o regenéralo con updpkgsums y compáralo con ese)

# 3. reconstruye e instala
cd packages/gnome-online-accounts && makepkg -si
```

Si Arch solo subió `pkgrel` (3.58.1-2), basta con el paso 2 (pkgrel=3) y el 3.

### ¿Por qué no fijarlo con `IgnorePkg` o `epoch`?

Se puede, y es tentador, pero es peor:

- `IgnorePkg = gnome-online-accounts` deja `libgoa` (mismo `pkgbase`) libre para
  actualizarse, y acabas con una actualización parcial: dos mitades de la misma
  fuente en versiones distintas.
- `epoch=1` en el PKGBUILD haría que el nuestro gane siempre, para siempre, y
  **dejarías de recibir actualizaciones de seguridad sin enterarte** — de un
  paquete que custodia tus credenciales de Google.

Es preferible que Arch gane y que la rotura sea ruidosa. Un paquete de OAuth
desactualizado en silencio es peor que un montaje que deja de funcionar.

## Subir de versión (caso general)

```bash
./scripts/check-sources.sh          # ¿sigue haciendo falta que lo mantengamos?
./scripts/check-updates.sh          # ¿hay algo nuevo upstream?
cd packages/libgdata
$EDITOR PKGBUILD                    # pkgver=NUEVA, pkgrel=1
updpkgsums
makepkg --syncdeps --cleanbuild
namcap ./*.pkg.tar.zst
```

Reglas:

- `pkgver` nuevo → `pkgrel=1`.
- Mismo `pkgver` pero cambia el PKGBUILD (flags, deps, parches) → `pkgrel+1`.
- Nunca uses `epoch` salvo que upstream retroceda el número de versión.

## Construcción limpia (recomendado antes de publicar)

`makepkg` usa tu sistema como entorno de build, así que puede "funcionar aquí"
por dependencias que tienes instaladas y no están declaradas. El chroot lo
detecta:

```bash
cd packages/libsoup2
extra-x86_64-build           # requiere devtools
```

Ojo: funciona para `libsoup2` y `gnome-online-accounts` (todas sus dependencias
están en repos), pero **no** para `libgdata` ni `gvfs-google` tal cual: el
chroot limpio no tiene `libsoup2` ni `libgdata`. Para esos dos hay que pasarle
los paquetes ya construidos con `-I`:

```bash
extra-x86_64-build -- -I ../libsoup2/libsoup2-*.pkg.tar.zst
```

## Checklist por paquete

- [ ] `pkgver` / `pkgrel` correctos.
- [ ] `updpkgsums` ejecutado **y** contrastado con el `.sha256sum` de GNOME.
- [ ] `namcap PKGBUILD` sin errores.
- [ ] `namcap *.pkg.tar.zst` sin dependencias faltantes ni sobrantes.
- [ ] En `gvfs-google`: el build no abortó con "el build no generó ...".
- [ ] En `gnome-online-accounts`: el build no abortó con "no pide el scope de Drive".
- [ ] `ldd /usr/lib/gvfsd-google | grep -i "not found"` vacío tras instalar.
- [ ] `strings /usr/lib/libgoa-backend-1.0.so | grep googleapis.com/auth/drive` devuelve algo.
- [ ] `gdbus introspect --session --dest org.gnome.OnlineAccounts --object-path /org/gnome/OnlineAccounts/Accounts/<cuenta>` muestra `org.gnome.OnlineAccounts.Files`.
- [ ] Probado con la sesión real: montar Drive y abrir un fichero.

## Publicar el repo

```bash
./scripts/build-all.sh --repo gekko
```

Genera `out/gekko.db.tar.zst`:

```ini
[gekko]
SigLevel = Optional TrustAll
Server = file:///ruta/a/Drive-Gekko-Gnome/out
```

**El orden importa.** `libsoup2`, `libgdata` y `gvfs-google` no existen en
`[extra]`, pero `gnome-online-accounts` sí. pacman elige el **primer**
repositorio de `pacman.conf` que tenga un paquete con ese nombre, sin mirar
versiones. Si `[gekko]` va después de `[extra]`, `pacman -Syu` instalará
siempre el GOA de Arch — el que no pide el permiso de Drive — y no dirá nada.
Ponlo **antes** de `[core]` y `[extra]`.

Para firmar (recomendado si lo sirves por HTTP, y más aún tratándose de
paquetes sin upstream):

```bash
gpg --full-gen-key                       # una sola vez
cd out && for p in *.pkg.tar.zst; do gpg --detach-sign --use-agent "$p"; done
repo-add --sign --key <TU_KEYID> gekko.db.tar.zst ./*.pkg.tar.zst
```

y cambia `SigLevel` a `Required DatabaseOptional`.

## Riesgos conocidos

| Riesgo | Detalle | Qué hacer |
| --- | --- | --- |
| libsoup 2.4 sin releases | Los CVEs de 2025 fueron el motivo de que las distros la echaran. Quedan commits en la rama de mantenimiento, que Arch recoge; nadie publica releases. | Vigilar el tracker y el rango de cherry-pick de Arch; si algo grave toca el camino de libgdata sin arreglo en la rama, migrar a rclone. |
| `libgdata` archivada | Sin mantenedor ~4 años. GNOME archivó el repo. | Nada que hacer salvo congelar 0.18.1 y vigilar si aparece un sustituto sobre libsoup3. |
| Confusión sobre el AUR | `libgdata` figura en la lista de Atomic Arch (jun 2026), pero su git del AUR no tiene commits dentro de la ventana y su PKGBUILD es el de Arch. | No hay que temer al AUR aquí. Este repo existe porque `gvfs-google` y el GOA recompilado no están en ninguna parte. |
| `gvfs` sube en `[extra]` | Rompe `gvfs-google` por el soname sin versionar. | Reconstruir según la Regla nº 2. |
| Arch actualiza `gnome-online-accounts` | Pacman instala el suyo, sin `google_files`. Drive deja de montar **en silencio**. | El hook de pacman lo avisa. Reconstruir (Regla nº 4). |
| GNOME quita la opción `google` de gvfs | Ya está marcada `deprecated: true` en 1.60.2. Cuando la borren, `gvfs-google` no se podrá construir. | `check-updates.sh` lo detecta. Es el fin del proyecto: quedarse en la versión actual o migrar a rclone. |
| GNOME quita `google_files` de GOA | El soporte de Drive lleva ahí desde feb-2026 apagado por defecto; podrían eliminarlo. | El `package()` del PKGBUILD aborta si el scope no acaba en el binario. |
