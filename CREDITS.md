# Créditos

Este repositorio empaqueta software de GNOME para Arch siguiendo decisiones de
configuración que tomaron otras distribuciones. Aquí queda constancia de quién
hizo qué, con enlaces, para que el crédito no dependa de la memoria de nadie.

## Solus — https://github.com/getsolus/packages

**Solus es la distribución que mantiene viva la cadena de Google Drive en GNOME
cuando casi todas las demás la han retirado.** La estabilidad y el cuidado con
que empaquetan es el motivo de que este repo exista: se quería eso mismo, en
Arch.

Licencia del monorepo: MPL-2.0 para las contribuciones (según su `LICENSE.md`).
Los `package.yml` citados no llevan cabecera SPDX. Ningún fichero de este repo
es copia ni modificación de un fichero de Solus: se tomaron **opciones de
compilación** y se **contrastaron checksums** (que son los que publica GNOME).
Por eso las recetas de aquí van bajo MIT.

**Regla para el futuro:** si algún día se copia un fichero de Solus tal cual
(por ejemplo un parche de `files/`, como el `reenable-google-support.patch` que
Solus necesitó en GOA 3.58.0), ese fichero conserva la MPL-2.0 y su cabecera, y
se anota en esta tabla.

| Paquete aquí | `package.yml` de Solus | Qué se tomó | Autores del `package.yml` |
| --- | --- | --- | --- |
| `gnome-online-accounts` | [packages/g/gnome-online-accounts](https://github.com/getsolus/packages/blob/main/packages/g/gnome-online-accounts/package.yml) | `-Dgoogle_files=true` y `-Ddocumentation=false`. El flag lo añadió Joey Riches el 2026-03-21 en [a4be647](https://github.com/getsolus/packages/commit/a4be6479d5e3fcc97151a5451a588efd27a04779) (GOA 3.58.0, junto a un parche que dejó de hacer falta en 3.58.1, [7bcc7fd](https://github.com/getsolus/packages/commit/7bcc7fdc585351b360a197d164673dadd6248f29)). **Es la aportación decisiva: sin ella nada de este repo funciona.** | Joey Riches, Evan Maddock |
| `gvfs-google` | [packages/g/gvfs](https://github.com/getsolus/packages/blob/main/packages/g/gvfs/package.yml) | `-Dgoogle=true` (reactivado a propósito por Joey Riches el 2026-03-21 en [d78e428](https://github.com/getsolus/packages/commit/d78e428c5e4a1efb7591a98a48ebf1ec188aa775), gvfs 1.60.0) y `-Dprivileged_group=wheel`. El diseño del paquete (solo `gvfsd-google` y `google.mount`, sin sustituir `gvfs`) es propio. | Muhammad Alfi Syahrin, Joey Riches, Troy Harvey |
| `libgdata` | [packages/l/libgdata](https://github.com/getsolus/packages/blob/main/packages/l/libgdata/package.yml) | `-Dalways_build_tests=false` y contraste del sha256 del tarball. `oauth1` va en `disabled` aquí (Solus: `enabled`). | Joey Riches, Jakob Gezelius, Zach Bacon, Joshua Strobl |
| `libsoup2` | [packages/l/libsoup](https://github.com/getsolus/packages/blob/main/packages/l/libsoup/package.yml) | **Nada.** Solus compila el tarball 2.74.3 sin parches; esta receta sigue a Arch. Se cita solo como referencia de que la serie 2.74 sigue empaquetada en otra distribución. | Joey Riches, Thomas Staudinger, Zach Bacon |
| `deja-dup` (opcional) | [packages/d/deja-dup](https://github.com/getsolus/packages/blob/main/packages/d/deja-dup/package.yml) | La lista de dependencias en ejecución (`rclone` pasa a opcional). No se replica el `mv /etc/xdg`; las opciones de meson siguen a Arch. | Muhammad Alfi Syahrin, Joey Riches (mantenedores: Evan Maddock, Muhammad Alfi Syahrin) |

Qué se cambió respecto a cada receta y por qué: [docs/solus-vs-arch.md](docs/solus-vs-arch.md).

## Arch Linux — https://gitlab.archlinux.org/archlinux/packaging/packages

Licencia de los PKGBUILD de Arch: 0BSD (`REUSE.toml`, «Arch Linux
contributors»). No exige atribución; se da igualmente.

- `gnome-online-accounts`: el PKGBUILD es el oficial de Arch (Jan Alexander
  Steffens «heftig», Fabian Bornschein «fabiscafe»; contribuidor Ionut Biru)
  con `-D google_files=true`, `-D documentation=false` y sin los subpaquetes
  `libgoa` / `libgoa-docs`.
- `libsoup2`: mismo método que el `libsoup` de Arch (heftig): checkout del tag
  2.74.3 y `git cherry-pick -n 2.74.3..5739a090` (17 commits de la rama de
  mantenimiento, 9 de ellos de seguridad). Esos parches son commits de GNOME
  recogidos por Arch; no vienen de Solus.

## GNOME

Todo el código compilado es de GNOME, sin parches de terceros (los cherry-picks
de libsoup son commits del propio GNOME): libsoup (LGPL-2.0-or-later), libgdata
(LGPL-2.1-or-later, archivada), gvfs (LGPL-2.0), gnome-online-accounts
(LGPL-2.0-or-later), deja-dup (GPL-3.0-or-later).
