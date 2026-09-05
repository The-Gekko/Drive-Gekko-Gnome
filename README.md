<div align="center">

<img src="assets/gekko-drive.jpg" alt="Gekko's Drive — GNOME Integration" width="880">

<sub><i>(Imagen generada con Gemini — modelo Nano Banana)</i></sub>

# Drive-Gekko-Gnome

**Google Drive en Nautilus, sobre Arch Linux, después de que Arch lo retirara**

<sub>`libsoup2` · `libgdata` · `gvfs-google` · `gnome-online-accounts` — construidos desde el código oficial de GNOME</sub>

<br>

![Arch Linux](https://img.shields.io/badge/Arch_Linux-1793D1?style=for-the-badge&logo=archlinux&logoColor=white)
![GNOME](https://img.shields.io/badge/GNOME-4A86CF?style=for-the-badge&logo=gnome&logoColor=white)
![PKGBUILD](https://img.shields.io/badge/PKGBUILD-x86__64-2C3E50?style=for-the-badge&logo=gnubash&logoColor=white)

![libsoup2](https://img.shields.io/badge/libsoup2-2.74.3-1793D1?style=flat-square)
![libgdata](https://img.shields.io/badge/libgdata-0.18.1-1793D1?style=flat-square)
![gvfs--google](https://img.shields.io/badge/gvfs--google-1.60.2-1793D1?style=flat-square)
![GOA](https://img.shields.io/badge/gnome--online--accounts-3.58.1-1793D1?style=flat-square)
![probado](https://img.shields.io/badge/probado-montaje%20real%20verificado-2ea043?style=flat-square)

</div>

---

> [!WARNING]
> **Lee esto antes de instalar.** Google Drive en GNOME está muerto upstream:
> GNOME archivó `libgdata`, gvfs marcó su backend de Google como *deprecated* y
> Arch lo eliminó de sus repos en 2026. Este repo lo revive, pero implica
> cargar con **libsoup 2.4, una librería HTTP sin releases upstream**.
> Si lo único que quieres son tus archivos o un backup, **[rclone](https://rclone.org/)
> está en `[extra]`, tiene upstream vivo y lo hace sin esa deuda.**
> La comparación honesta está en **[docs/estado-upstream.md](docs/estado-upstream.md)**.

## Instalación

**Necesitas:** Arch Linux con GNOME, `base-devel` y `git` instalados, un usuario
con `sudo`, conexión a internet y unos 10 minutos de compilación. Si tienes
instalado el paquete `libsoup` (2.4) del AUR, el script te pedirá quitarlo
antes: `libsoup2` lo sustituye.

```bash
sudo pacman -S --needed base-devel git
git clone https://github.com/The-Gekko/Drive-Gekko-Gnome.git
cd Drive-Gekko-Gnome
./install.sh
```

Eso instala las herramientas de compilación (una sola contraseña), construye e
instala los cuatro paquetes en orden, **verifica que el resultado sirve** (que
`gvfsd-google` enlaza y que GOA pide el permiso de Drive), y deja puestos el
hook de pacman y el servicio de inicio de sesión que avisan si una
actualización de Arch rompe el montaje.

### El paso que no puede hacer el script

Cuando termine, **tienes que volver a autorizar tu cuenta de Google a mano**:

1. Abre `gnome-control-center online-accounts`
2. Si ya tenías una cuenta de Google, **quítala** y vuelve a añadirla
3. Acepta el permiso de Drive en la pantalla de consentimiento de Google
4. Comprueba que en la cuenta aparece el servicio **Archivos** activado

Este paso **no es opcional y no se puede saltar**. El token que Google te dio
antes se firmó sin el permiso de Drive, y Google no lo amplía de forma
retroactiva. Sin reautorizar, Nautilus dará *«Permiso denegado»* aunque todo lo
demás esté perfecto.

### Comprobar que funciona

```bash
ls /run/user/$(id -u)/gvfs/
```

Deberías ver un directorio `google-drive:host=gmail.com,user=TU_USUARIO`, y tu
unidad en la barra lateral de Nautilus. Al añadir la cuenta, GOA la monta solo;
si además ejecutas `gio mount "google-drive://TU_CORREO@gmail.com/"` y te dice
*«La ubicación ya está montada»*, eso es la confirmación, no un error.

Y las dos comprobaciones de fondo, por si algo falla:

```bash
ldd /usr/lib/gvfsd-google | grep 'not found'                 # debe salir vacío
strings /usr/lib/libgoa-backend-1.0.so | grep auth/drive     # debe salir algo
```

## Qué instala y por qué

Cuatro piezas. Las tres primeras son la cadena de archivos; la cuarta es la que
pide el permiso, y **sin ella las otras tres no sirven de nada**.

| Paquete | Estado en Arch | Qué aporta |
| --- | --- | --- |
| [`libsoup2`](packages/libsoup2/PKGBUILD) | retirado de `[extra]` en mayo 2026 | La librería HTTP 2.4 que necesita `libgdata`. **Con los 17 commits de la rama de mantenimiento que Arch recoge, 9 de ellos de seguridad** |
| [`libgdata`](packages/libgdata/PKGBUILD) | retirado de `[extra]` en mayo 2026 | El protocolo GData de Google. Archivado upstream |
| [`gvfs-google`](packages/gvfs-google/PKGBUILD) | **no existe en ningún sitio** | `gvfsd-google`: el backend que monta la unidad |
| [`gnome-online-accounts`](packages/gnome-online-accounts/PKGBUILD) | está en `[extra]`, pero **compilado sin Drive** | El mismo paquete de Arch recompilado con `-D google_files=true` |

### La pieza que casi nadie ve

Instalar `gvfsd-google` no basta. En febrero de 2026 GNOME movió el soporte de
Drive de GOA detrás de una opción de compilación, apagada por defecto:

```meson
option('google_files', type: 'boolean', value: false,
       description: 'Enable Google provider Files feature')
```

Arch compila con el valor por defecto. Resultado: el `goa-daemon` de `[extra]`
nunca pide `https://www.googleapis.com/auth/drive`, la cuenta no expone la
interfaz `org.gnome.OnlineAccounts.Files`, y `gvfsd-google` recibe *«Permiso
denegado»* aunque esté perfectamente instalado. Se puede verificar:

```bash
strings /usr/lib/libgoa-backend-1.0.so | grep googleapis.com/auth/
```

Por eso este repo recompila GOA. La idea no es nuestra: es lo que hace Solus
desde el 21 de marzo de 2026 (ver [Créditos](#créditos)). Es la única de las
cuatro que **sustituye a un paquete oficial de Arch**, y eso tiene
consecuencias — ver abajo.

## Mantenimiento: qué se rompe y cuándo

| Qué pasa | Cómo te enteras | Qué hacer |
| --- | --- | --- |
| Arch actualiza `gnome-online-accounts` | El hook de pacman lo grita al terminar la transacción, y te llega una notificación | Subir `pkgver` al de Arch, `pkgrel` por encima del de Arch, `b2sum` del PKGBUILD oficial, y `makepkg -si`. Paso a paso en [docs/mantenimiento.md](docs/mantenimiento.md), Regla nº 4 |
| Arch actualiza `gvfs` | `pacman -Syu` **se planta** con un conflicto de dependencias | Subir `pkgver` en `gvfs-google`, `updpkgsums`, reconstruir |
| GNOME borra la opción `google` de gvfs | `./scripts/check-updates.sh` lo avisa | Fin del camino: quedarte en la versión actual o migrar a rclone |

El caso peligroso es el primero, porque **no da ningún error**: Drive
simplemente deja de montar. Por eso `install.sh` deja dos avisos puestos:

| Dónde | Cuándo salta |
| --- | --- |
| `/etc/pacman.d/hooks/99-drive-gekko-gnome.hook` | Justo al terminar cualquier `pacman` que toque `gnome-online-accounts` o `gvfs`. Escribe en la terminal **y lanza una notificación de escritorio** |
| `~/.config/systemd/user/drive-gekko-check.service` | En cada inicio de sesión, por si la actualización pasó cuando no estabas mirando |

Los dos ejecutan la misma comprobación: que el binario instalado sigue pidiendo
el permiso, que `gvfsd-google` sigue enlazando, y que el pin de `gvfs` sigue
coincidiendo con lo instalado. La primera, a mano:

```bash
strings /usr/lib/libgoa-backend-1.0.so | grep googleapis.com/auth/drive
```

No arreglan nada solos — construir paquetes no se hace dentro de una
transacción de pacman — pero hacen imposible no enterarse.

También puedes preguntarlo tú en cualquier momento:

```bash
./scripts/check-updates.sh
```

> [!NOTE]
> **¿Y no se puede fijar para que no se quite nunca?** Se puede (`IgnorePkg`, o
> un `epoch` en el PKGBUILD), pero es mala idea: dejarías de recibir
> actualizaciones de seguridad de un paquete que guarda tus credenciales de
> Google, y sin enterarte. Es preferible que Arch gane y que la rotura sea
> ruidosa. Detalles en [docs/mantenimiento.md](docs/mantenimiento.md).

## Herramientas

| Script | Para qué |
| --- | --- |
| `./install.sh` | Todo lo anterior de una vez |
| `./scripts/check-updates.sh` | Versiones, el pin de gvfs, el estado de la opción `google` y si GOA sigue pidiendo el permiso de Drive |
| `./scripts/check-sources.sh` | De qué repo puede salir hoy cada paquete: oficiales, AUR o Chaotic |
| `./scripts/build-all.sh` | Construir la cadena por partes, o generar un repo local de pacman |
| `./scripts/lint.sh` | `bash -n` + `namcap` sobre los PKGBUILD |

## De dónde sale el código

Siempre del tarball o el tag oficial de GNOME, con checksum fijado. Los
tarballs se contrastan contra el `.sha256sum` que publica `download.gnome.org`;
los checkouts git, contra el `b2sum` que verifica el PKGBUILD oficial de Arch
para el mismo tag.

| Paquete | Fuente | Verificación |
| --- | --- | --- |
| `libsoup2` | `git+gitlab.gnome.org/GNOME/libsoup.git#tag=2.74.3` | `b2sums` del checkout, el mismo valor que verifica Arch |
| `libgdata` | `download.gnome.org/.../libgdata-0.18.1.tar.xz` | `sha256sums` |
| `gvfs-google` | `download.gnome.org/.../gvfs-1.60.2.tar.xz` | `sha256sums` |
| `gnome-online-accounts` | `git+gitlab.gnome.org/GNOME/gnome-online-accounts.git#tag=3.58.1` | `b2sums` |

Los parches de `libsoup2` se toman del paquete oficial de Arch
(`git cherry-pick` sobre la rama de mantenimiento, como hace
[heftig](https://gitlab.archlinux.org/archlinux/packaging/packages/libsoup/-/issues/1)):
17 commits, 9 de ellos de seguridad. El tarball pelado de 2.74.3 **no** los
lleva.

### Sobre el AUR

`libsoup` y `libgdata` siguen existiendo en el AUR, y sus `PKGBUILD` son hoy los
de Arch, con historial firmado por su equipo. **No hay nada malo en usarlos.**
Este repo existe por otras razones: `gvfs-google` no existe en ninguna parte, y
la recompilación de GOA tampoco. Ya puestos, la cadena entera se construye igual.

Dicho esto, `libgdata` figura en la lista consolidada de paquetes adoptados
durante la campaña **«Atomic Arch»** de junio de 2026 — aunque su git del AUR no
tiene ningún commit dentro de la ventana del ataque. Si te importa el detalle,
está en [docs/estado-upstream.md](docs/estado-upstream.md).

## Estructura

```
Drive-Gekko-Gnome/
├── install.sh                     # instalación completa
├── packages/
│   ├── libsoup2/                  # HTTP 2.4 + parches de CVE de Arch
│   ├── libgdata/                  # protocolo GData (archivado upstream)
│   ├── gvfs-google/               # gvfsd-google: solo los 2 ficheros que faltan
│   ├── gnome-online-accounts/     # GOA con -D google_files=true
│   └── deja-dup/                  # opcional: sigue en [extra], aquí como referencia
├── pacman-hooks/                  # aviso post-actualización (terminal + notificación)
├── systemd/                       # comprobación en cada inicio de sesión
├── .github/workflows/build.yml    # CI: lint + construye la cadena entera en un Arch limpio
├── CREDITS.md                     # quién hizo qué: Solus, Arch, GNOME
├── scripts/
├── docs/
│   ├── estado-upstream.md         # el porqué, y la comparación con rclone
│   ├── mantenimiento.md           # qué hacer cuando algo se rompe
│   ├── solus-vs-arch.md           # traducción package.yml -> PKGBUILD
│   └── google-drive.md            # uso diario
└── assets/gekko-drive.jpg
```

## Créditos

Este repositorio existe porque otras dos distribuciones hicieron antes el
trabajo difícil.

- **[Solus](https://getsol.us/)** es la distribución que mantiene viva la cadena
  de Google Drive en GNOME cuando casi todas la han retirado, y la estabilidad
  con la que lo hace es el motivo de este repo. Las opciones de compilación
  salen de sus recetas (`package.yml` del monorepo
  [getsolus/packages](https://github.com/getsolus/packages), MPL-2.0). La pieza
  decisiva —compilar GNOME Online Accounts con `-Dgoogle_files=true` para que
  vuelva a pedir el permiso de Drive— la aplicó **Joey Riches** el 21 de marzo
  de 2026 ([commit a4be647](https://github.com/getsolus/packages/commit/a4be6479d5e3fcc97151a5451a588efd27a04779)),
  el mismo día que reactivó `-Dgoogle=true` en gvfs 1.60
  ([commit d78e428](https://github.com/getsolus/packages/commit/d78e428c5e4a1efb7591a98a48ebf1ec188aa775)).
  Sin haber visto eso, este repo se habría quedado en un `gvfsd-google` que
  responde «Permiso denegado». Gracias también a Muhammad Alfi Syahrin, Troy
  Harvey, Evan Maddock, Jakob Gezelius, Zach Bacon, Joshua Strobl y Thomas
  Staudinger, autores de los `package.yml` de gvfs, libgdata, libsoup,
  gnome-online-accounts y deja-dup.
- **[Arch Linux](https://archlinux.org/)**: el PKGBUILD de
  `gnome-online-accounts` es el oficial de Arch (heftig, fabiscafe; 0BSD) con
  una opción cambiada, y los parches de `libsoup2` se aplican exactamente como
  lo hace el paquete `libsoup` de Arch. Ese trabajo es de Arch, no de Solus: la
  receta de Solus compila el tarball 2.74.3 sin parches.
- **[GNOME](https://www.gnome.org/)**: todo el código que se compila es suyo,
  sin modificar, desde `download.gnome.org` o `gitlab.gnome.org`.

Ningún fichero de este repo es copia de un fichero de Solus: los PKGBUILD están
escritos para Arch y reproducen decisiones (opciones de meson, checksums que
publica GNOME), no texto. Qué se tomó de cada sitio, paquete a paquete, está en
[CREDITS.md](CREDITS.md) y en [docs/solus-vs-arch.md](docs/solus-vs-arch.md).

## Licencia

MIT para los PKGBUILD, scripts y documentación escritos para este repositorio.
Las opciones de compilación se tomaron de las recetas de Solus (MPL-2.0) y el
PKGBUILD de `gnome-online-accounts` se basa en el de Arch (0BSD); ningún fichero
de esos proyectos se copia aquí. Cada paquete conserva la licencia de su código
fuente: LGPL-2.0 (`libsoup`), LGPL-2.1 (`libgdata`), LGPL-2.0 (`gvfs`,
`gnome-online-accounts`), GPL-3.0 (`deja-dup`).
