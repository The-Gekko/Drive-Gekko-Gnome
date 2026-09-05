#!/usr/bin/env bash
# post-upgrade-check.sh — lo ejecuta pacman despues de cada transaccion que
# toque gnome-online-accounts, gvfs o gvfs-google. Ver 99-drive-gekko-gnome.hook.
# Tambien lo ejecuta drive-gekko-check.service en cada inicio de sesion grafico.
#
# NO arregla nada por su cuenta: construir paquetes requiere red, tiempo y no
# se hace dentro de una transaccion de pacman. Lo que hace es que la rotura
# sea IMPOSIBLE de no ver, que es justo el problema de este montaje.
#
# Sin dependencias fuera de coreutils + pacman: la comprobacion del scope usa
# `grep -a` sobre el binario, no `strings` (binutils podria no estar).

set -uo pipefail

R=$'\033[1;31m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; O=$'\033[0m'
ROTO=0

# ---------------------------------------------------------------------------
# Aviso en el escritorio.
#
# La salida de un hook de pacman se pierde entre las 200 lineas de un -Syu
# grande. Una notificacion no. Funciona en los dos contextos donde corre este
# script: como root desde el hook, y como usuario desde el servicio de login.
# ---------------------------------------------------------------------------
notificar() {
  local titulo="$1" cuerpo="$2"
  command -v notify-send >/dev/null 2>&1 || return 0

  if [[ $EUID -ne 0 ]]; then
    notify-send -u critical -i drive-harddisk -a "Drive-Gekko-Gnome" \
      "$titulo" "$cuerpo" 2>/dev/null || true
    return 0
  fi

  # Como root: hay que entrar en la sesion grafica de cada usuario. Se detectan
  # por su bus de sesion en /run/user/<uid>/bus, sin depender de parsear
  # la salida de loginctl.
  local d uid nombre
  for d in /run/user/*/; do
    [[ -S "${d}bus" ]] || continue
    uid="$(basename "$d")"
    nombre="$(id -nu "$uid" 2>/dev/null)" || continue
    runuser -u "$nombre" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${d}bus" \
      notify-send -u critical -i drive-harddisk -a "Drive-Gekko-Gnome" \
      "$titulo" "$cuerpo" 2>/dev/null || true
  done
}

# ¿Pide GOA el scope de Drive? Se busca 'auth/drive' seguido de espacio o fin
# de linea, para no dar por bueno un scope parcial (drive.file, drive.readonly).
goa_pide_drive() {
  find /usr/lib -maxdepth 1 -name 'libgoa-backend-1.0.so*' -type f \
    -exec grep -aqE 'googleapis\.com/auth/drive( |$)' {} + 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0. Si gvfs-google no esta instalado, esto no incumbe al usuario... salvo que
#    acabe de quitarlo dejando nuestro GOA puesto: entonces un recordatorio.
# ---------------------------------------------------------------------------
if ! pacman -Qq gvfs-google >/dev/null 2>&1; then
  if goa_pide_drive; then
    printf '%s  Drive-Gekko-Gnome: gvfs-google no esta instalado, pero el gnome-online-accounts\n' "$Y"
    printf '  de este repo sigue puesto. Si has quitado gvfs-google para desbloquear una\n'
    printf '  actualizacion de gvfs, reconstruyelo con el pkgver nuevo cuando termines.%s\n' "$O"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. El permiso de Drive en GNOME Online Accounts
#
# Arch compila GOA sin -Dgoogle_files=true. Si pacman acaba de reinstalar el
# GOA oficial encima del nuestro, el scope de Drive desaparece y Drive deja de
# montar SIN ningun mensaje de error en el arranque.
# ---------------------------------------------------------------------------
if ! goa_pide_drive; then
  printf '%s  Drive-Gekko-Gnome: SE PERDIO EL PERMISO DE GOOGLE DRIVE%s\n\n' "$R" "$O"
  printf '  El gnome-online-accounts oficial de Arch acaba de sustituir al\n'
  printf '  nuestro. Ya no pide el scope .../auth/drive, asi que Nautilus va a\n'
  printf '  dar "Permiso denegado" al abrir tu unidad.\n\n'
  printf '  Para arreglarlo:%s\n' "$Y"
  printf '    Si tienes el repositorio [drive-gekko-gnome] en pacman.conf: comprueba que\n'
  printf '    va ANTES de [core] (pacman-conf --repo-list) y ejecuta  sudo pacman -Syu\n'
  printf '    Si compilas tu: docs/mantenimiento.md, Regla n.4 (pkgver de Arch,\n'
  printf '    pkgrel <Arch>.1, b2sum del PKGBUILD oficial, makepkg -si)%s\n\n' "$O"
  notificar "Google Drive ha dejado de funcionar" \
    "Arch ha reinstalado gnome-online-accounts y se perdio el permiso de Drive. Reconstruye el paquete del repo Drive-Gekko-Gnome (docs/mantenimiento.md, Regla 4)."
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 2. El pin estricto de gvfs
#
# gvfsd-google enlaza contra libgvfscommon.so y libgvfsdaemon.so, sin soname
# versionado. Por eso gvfs-google fija gvfs a una pkgver exacta.
# ---------------------------------------------------------------------------
_pin="$(LC_ALL=C pacman -Qi gvfs-google 2>/dev/null | sed -n 's/^Depends On.*gvfs=\([0-9.]*\).*/\1/p' | head -1)"
_gvfs="$(pacman -Q gvfs 2>/dev/null | awk '{print $2}' | cut -d- -f1)"

if [[ -n "$_pin" && -n "$_gvfs" && "$_pin" != "$_gvfs" ]]; then
  printf '%s  Drive-Gekko-Gnome: gvfs cambio de version%s\n\n' "$Y" "$O"
  printf '    gvfs instalado : %s\n' "$_gvfs"
  printf '    pin del paquete: %s\n\n' "$_pin"
  printf '  Con el repositorio: sudo pacman -Syu (si aun no trae el paquete nuevo, el\n'
  printf '  sincronizador no ha corrido; espera o lanza Actions -> sync-upstream).\n'
  printf '  Compilando tu: reconstruye gvfs-google con pkgver=%s.\n\n' "$_gvfs"
  notificar "Google Drive necesita reconstruirse" \
    "gvfs paso a la version ${_gvfs} y gvfs-google esta fijado a ${_pin}. Reconstruyelo antes de usar Drive."
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 3. El binario sigue enlazando (por si acaso pacman dejo pasar algo)
# ---------------------------------------------------------------------------
if [[ -x /usr/lib/gvfsd-google ]] && ldd /usr/lib/gvfsd-google 2>/dev/null | grep -q 'not found'; then
  printf '%s  Drive-Gekko-Gnome: gvfsd-google tiene librerias sin resolver:%s\n' "$R" "$O"
  ldd /usr/lib/gvfsd-google | grep 'not found' | sed 's/^/    /'
  printf '\n'
  notificar "Google Drive esta roto" "gvfsd-google ya no encuentra sus librerias. Reconstruye gvfs-google."
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 4. Si el repositorio esta en pacman.conf, tiene que ir ANTES de [extra]
# ---------------------------------------------------------------------------
if pacman-conf --repo-list 2>/dev/null | grep -qx drive-gekko-gnome; then
  _order="$(pacman-conf --repo-list 2>/dev/null | tr '\n' ' ')"
  if [[ "$_order" == *extra*drive-gekko-gnome* ]]; then
    printf '%s  Drive-Gekko-Gnome: el repositorio esta DESPUES de [extra] en pacman.conf%s\n' "$Y" "$O"
    printf '  pacman elige el primer repo que tenga el nombre: instalara el GOA de Arch\n'
    printf '  (sin permiso de Drive) en la proxima actualizacion. Muevelo antes de [core].\n\n'
    notificar "El repositorio de Drive esta en mal sitio" "En /etc/pacman.conf, [drive-gekko-gnome] debe ir ANTES de [core] y [extra]."
    ROTO=1
  fi
fi

if (( ROTO == 0 )); then
  printf '%s  Drive-Gekko-Gnome: Google Drive sigue operativo.%s\n' "$G" "$O"
fi

exit 0
