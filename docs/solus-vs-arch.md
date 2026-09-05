# De `package.yml` (Solus) a `PKGBUILD` (Arch)

Las **opciones de compilación** de este repo nacen de los `package.yml` del
monorepo de Solus ([getsolus/packages](https://github.com/getsolus/packages),
MPL-2.0). No todo: `libsoup2` sigue la receta de Arch, y la estructura del
PKGBUILD de `gnome-online-accounts` también es la de Arch. Aquí queda
documentado qué se tomó de dónde, qué se cambió y por qué, para que un bump de
versión futuro no tenga que redescubrirlo. Los créditos con nombres y commits
están en [CREDITS.md](../CREDITS.md).

Ojo con una diferencia de fondo: **Solus todavia mantiene la cadena de Google
Drive viva** (compila gvfs con `google=true` y empaqueta libgdata), mientras
que Arch la elimino entera. Sus `package.yml` siguen siendo la mejor referencia
de como se construia esto, pero no son un indicador de que siga siendo buena
idea. Ver [estado-upstream.md](estado-upstream.md).

## Equivalencias generales

| ypkg (Solus)        | PKGBUILD (Arch)                        | Notas |
| ------------------- | -------------------------------------- | ----- |
| `name`              | `pkgname` / `pkgbase`                  | — |
| `version`           | `pkgver`                               | — |
| `release`           | `pkgrel`                               | Solus incrementa el release en cada rebuild; en Arch se vuelve a `1` en cada `pkgver` nuevo. |
| `source: url : sha` | `source=()` + `sha256sums=()`          | — |
| `homepage`          | `url`                                  | — |
| `license`           | `license=()`                           | Arch usa identificadores SPDX. |
| `component`         | `groups=()` (aproximado)               | No hay equivalente real; `gnome` es lo mas cercano. |
| `builddeps`         | `makedepends=()`                       | Solus usa `pkgconfig(foo)`, Arch usa el nombre del paquete. |
| `rundeps`           | `depends=()` / `optdepends=()`         | Arch resuelve muchas por soname automaticamente. |
| `patterns`          | funciones `package_*()` + `_pick`      | Solus divide por globs; Arch mueve ficheros explicitamente. |
| `setup:`            | `build()` con `meson setup`            | `%meson_configure` ≈ `meson setup --prefix=/usr ...`. |
| `build:`            | `meson compile -C build`               | `%ninja_build`. |
| `install:`          | `package()` con `meson install`        | `%ninja_install` + `--destdir "$pkgdir"`. |
| `%install_license`  | `install -Dm644 COPYING ...`           | Ruta: `/usr/share/licenses/$pkgname/`. |

## Traduccion de `pkgconfig(...)`

| Solus                        | Arch                  |
| ---------------------------- | --------------------- |
| `pkgconfig(gtk4)`            | `gtk4`                |
| `pkgconfig(libadwaita-1)`    | `libadwaita`          |
| `pkgconfig(libsoup-3.0)`     | `libsoup3`            |
| `pkgconfig(libsoup-2.4)`     | `libsoup2` (de este repo; ya no existe `libsoup` en Arch) |
| `pkgconfig(goa-1.0)`         | `libgoa`              |
| `pkgconfig(gcr-4)`           | `gcr-4`               |
| `pkgconfig(gcr-base-3)`      | `gcr`                 |
| `pkgconfig(gudev-1.0)`       | `libgudev`            |
| `pkgconfig(libcdio_paranoia)`| `libcdio-paranoia`    |
| `pkgconfig(msgraph-1)`       | `msgraph`             |
| `pkgconfig(smbclient)`       | `smbclient`           |
| `pkgconfig(fuse3)`           | `fuse3`               |
| `cifs-utils-devel`           | `cifs-utils`          |

> En Arch no existen paquetes `-devel` separados: las cabeceras van dentro del
> paquete normal.

## Diferencias deliberadas por paquete

### libgdata

- Solus compila con `-Doauth1=enabled`. Aqui va **`disabled`**: requiere
  `liboauth`, que esta muerto upstream y fuera de los repos de Arch, y el
  camino GOA → Google Drive usa OAuth2, no OAuth1.
- Se anade `-Dgtk_doc=false`: la documentacion no aporta nada en un paquete
  binario y arrastra dependencias de build.

### gvfs -> gvfs-google

Aqui esta la mayor divergencia con Solus, y no es cosmetica.

- Solus **sigue compilando gvfs con `-Dgoogle=true`** y separando un subpaquete
  `goa`. Arch fue por el camino contrario: elimino el backend de Google por
  completo (ver [estado-upstream.md](estado-upstream.md)).
- Por eso NO replicamos el paquete dividido entero de Solus ni el de Arch.
  Compilamos el mismo tarball oficial con `-D google=true` y empaquetamos
  **solo** `gvfsd-google` y `google.mount`, dejando que el `gvfs` de `[extra]`
  siga aportando todo lo demas. Menos superficie que mantener y no sombreamos
  un paquete del sistema.
- El resto de backends se apagan explicitamente en el `meson setup`: el build
  es mucho mas rapido y no arrastra samba, libmtp ni libimobiledevice.
- `patterns:` de Solus usa rutas `/usr/lib64/...`; Arch usa `/usr/lib`, y por
  eso el `meson setup` fija `--libexecdir=/usr/lib`.
- Se conserva `-D privileged_group=wheel` (Arch tambien usa `wheel`).

### libsoup2

En Solus se llama simplemente `libsoup` (2.74.3, release 39) y compila el
tarball **sin parches**. Aqui NO se sigue esa receta, a proposito.

El `libsoup` de Arch hace `git cherry-pick -n 2.74.3..5739a090` sobre la rama de
mantenimiento: **17 commits** con arreglos de seguridad reales (desbordamientos
de heap en el content sniffer, bytes NUL en cabeceras, un `int` que deberia ser
`gsize`). El tarball de 2.74.3 no los lleva.

Asi que este paquete toma el **codigo de GNOME** y los **parches de Arch**.
Es el unico sitio del repo donde Arch va por delante de Solus, y es justo en la
libreria mas expuesta de toda la cadena.

### gnome-online-accounts

La aportación más valiosa de Solus a este repo, y la que más costó encontrar.

Solus compila:

```
%meson_configure -Ddocumentation=false -Dgoogle_files=true
```

Arch usa el valor por defecto de esa opción, que upstream puso en `false` en
febrero de 2026 (*«build: Disable google provider Files feature»*). Es la única
diferencia entre que Drive funcione y que no, y no se ve por ninguna parte:
ambos compilan el mismo tag 3.58.1 de GNOME, sin parches.

El flag lo añadió **Joey Riches** en Solus el 21 de marzo de 2026 (commit
[a4be647](https://github.com/getsolus/packages/commit/a4be6479d5e3fcc97151a5451a588efd27a04779),
GOA 3.58.0), junto a un parche `reenable-google-support.patch` que en 3.58.1
dejó de hacer falta ([7bcc7fd](https://github.com/getsolus/packages/commit/7bcc7fdc585351b360a197d164673dadd6248f29)).
Por eso este repo, en 3.58.1, solo necesita el flag.

Aquí se replica la decisión de Solus, pero **solo se reemplaza el paquete
`gnome-online-accounts`**: `libgoa` y `libgoa-docs` siguen siendo los oficiales
de `[extra]`, porque esa opción no los afecta y así se sombrea lo mínimo.

### deja-dup (opcional)

`deja-dup` sigue en `[extra]`, mantenido y con restic activado. Esta receta se
conserva como documentacion y fallback, no como paquete a instalar.

- Solus hace `mv $installdir/etc/xdg $installdir/usr/share/xdg` por su diseno
  *stateless*. En Arch **no se replica**: `/etc/xdg` es la ruta correcta y
  mover eso rompe la configuracion por defecto.
- Solus lista `duplicity`, `gvfs`, `rclone`, `restic` como `rundeps`. Aqui
  `rclone` pasa a `optdepends` (solo hace falta para destinos remotos tipo
  Drive/OneDrive) siguiendo el criterio de Arch.
- El tarball viene del *archive* autogenerado de GitLab: si el checksum falla
  tras un bump, regeneralo con `updpkgsums` en vez de asumir que hay
  manipulacion.
