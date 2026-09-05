# Google Drive en el escritorio

Cómo queda el flujo con los paquetes de este repo instalados.

> Antes de seguir: [estado-upstream.md](estado-upstream.md) explica por qué
> esto ya no viene de serie y qué alternativa (rclone) evita tener que
> mantener libsoup 2.4. Si solo quieres tus archivos o un backup, esa
> alternativa probablemente te conviene más.

## Cadena completa

```
Cuenta de Google
      │  OAuth2
GNOME Online Accounts (goa-daemon)      ← RECOMPILADO por ESTE repo
      │                                     (-D google_files=true)
      │  D-Bus
gvfs-goa  →  gvfs-google (gvfsd-google) ← lo aporta ESTE repo
      │            │
      │            └→ libgdata → libsoup 2.4   ← los aporta ESTE repo
GIO  →  /run/user/$UID/gvfs/google-drive:host=gmail.com,user=<usuario>
      │
Nautilus / cualquier app GTK
```

`gvfs` y `gvfs-goa` salen de `[extra]`. Los otros cuatro eslabones los aporta
este repo. Ojo con el primero: `gnome-online-accounts` **sí está** en `[extra]`,
pero compilado sin el soporte de Drive, así que no vale.

## 1. Instalar

```bash
sudo pacman -S --needed gvfs gvfs-goa gnome-control-center gnome-keyring
./install.sh
```

Dos comprobaciones rápidas:

```bash
ldd /usr/lib/gvfsd-google | grep -i "not found"           # debe salir vacío
strings /usr/lib/libgoa-backend-1.0.so | grep auth/drive  # debe salir algo
```

La segunda es la que casi nadie hace y la que más falla.

Si la **primera** muestra algo (`not found`), casi siempre es que `gvfs` de
`[extra]` subió de versión y hay que reconstruir `gvfs-google` (Regla nº 2 de
docs/mantenimiento.md). Si la **segunda** no muestra nada, es GOA (Regla nº 4).

## 2. Añadir la cuenta

```bash
gnome-control-center online-accounts
```

Google → iniciar sesión → dejar activado **Archivos**.

> [!IMPORTANT]
> **Si ya tenías la cuenta añadida antes de instalar esto, quítala y vuelve a
> añadirla.** No es opcional. El permiso de Drive se concede en el momento del
> consentimiento OAuth; un token emitido antes no lo tiene y Google **no lo
> amplía de forma retroactiva**. Verás `FilesEnabled=true` en
> `~/.config/goa-1.0/accounts.conf` y aun así el montaje dará *«Permiso
> denegado»*, porque el flag local no cambia lo que Google firmó.

Que el interruptor **Archivos** aparezca depende de que GOA se haya compilado
con `-D google_files=true` — no de que `gvfsd-google` esté instalado. Si no
sale, el problema está en GOA, no en gvfs.

En un escritorio que no sea GNOME (Sway, Hyprland, Niri) también funciona,
pero hace falta el llavero desbloqueado y el bus de sesión levantado:

```bash
systemctl --user status gnome-keyring-daemon
systemctl --user status gvfs-goa-volume-monitor
echo "$DBUS_SESSION_BUS_ADDRESS"      # no debe estar vacío
```

## 3. Comprobar el montaje

```bash
gio mount -li | grep -i google        # ¿lo ve GIO?
ls /run/user/$(id -u)/gvfs/           # ruta real del montaje
```

Y que la cuenta expone de verdad la interfaz de archivos:

```bash
acc=$(grep -oE 'account_[0-9_]+' ~/.config/goa-1.0/accounts.conf | head -1)
gdbus introspect --session --dest org.gnome.OnlineAccounts \
  --object-path "/org/gnome/OnlineAccounts/Accounts/$acc" | grep Files
```

Montar / desmontar a mano:

```bash
gio mount google-drive://tu.correo@gmail.com/
gio mount -u google-drive://tu.correo@gmail.com/
```

Copiar por CLI usando el backend (sin pasar por la ruta FUSE):

```bash
gio copy informe.pdf google-drive://tu.correo@gmail.com/
gio list google-drive://tu.correo@gmail.com/
```

## 4. Copias de seguridad con Déjà Dup

Usa el `deja-dup` de `[extra]`, no hace falta compilarlo:

```bash
sudo pacman -S --needed deja-dup rclone
deja-dup --prefs
```

Déjà Dup 50 guarda con restic (o duplicity) y ofrece Drive y OneDrive como
destino apoyándose en `rclone` — es decir, **no necesita nada de este repo**.

Recomendaciones:

- Activa el cifrado con contraseña. El backup viaja a un tercero.
- Excluye `~/.cache`, `~/.local/share/Trash` y directorios de juegos/Steam.
- Haz una **restauración de prueba** de un fichero suelto antes de confiar en
  el backup. Un backup no verificado no es un backup.

## Problemas frecuentes

| Síntoma | Causa habitual | Comprobación |
| --- | --- | --- |
| No aparece el interruptor *Archivos* | GOA compilado sin `google_files` (el de Arch lo está) | `strings /usr/lib/libgoa-backend-1.0.so \| grep auth/drive` |
| *«Permiso denegado»* al montar, con todo instalado | el token OAuth es anterior y no tiene el permiso de Drive | quitar y volver a añadir la cuenta |
| Funcionaba y de pronto dejó de ir | Arch actualizó `gnome-online-accounts` encima del nuestro | Regla nº 4 de [mantenimiento.md](mantenimiento.md): subir `pkgver`/`pkgrel` y reconstruir |
| La cuenta aparece pero no hay carpeta | `gvfs-goa` ausente o su monitor no arranca | `systemctl --user status gvfs-goa-volume-monitor` |
| `gvfsd-google` muere al arrancar | `gvfs` subió de versión y el soname sin versionar ya no cuadra | `ldd /usr/lib/gvfsd-google \| grep -i "not found"` |
| Pide login en cada arranque | llavero bloqueado | `systemctl --user status gnome-keyring-daemon` |
| Nada aparece en `/run/user/$UID/gvfs` | `gvfsd-fuse` no está corriendo | `pgrep -a gvfsd-fuse` |

Para ver qué está pasando por dentro:

```bash
GVFS_DEBUG=all /usr/lib/gvfsd -r
```
