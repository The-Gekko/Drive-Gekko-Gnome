#!/usr/bin/env bash
# post-upgrade-check.sh — lo ejecuta pacman despues de cada transaccion que
# toque gnome-online-accounts o gvfs. Ver 99-drive-gekko-gnome.hook.
#
# NO arregla nada por su cuenta: construir paquetes requiere red, tiempo y no
# se hace dentro de una transaccion de pacman. Lo que hace es que la rotura
# sea IMPOSIBLE de no ver, que es justo el problema de este montaje.

set -uo pipefail

R=$'\033[1;31m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; O=$'\033[0m'
ROTO=0

# Si el usuario no tiene gvfs-google, esto no le incumbe.
pacman -Qq gvfs-google >/dev/null 2>&1 || exit 0

# ---------------------------------------------------------------------------
# 1. El permiso de Drive en GNOME Online Accounts
#
# Arch compila GOA sin -Dgoogle_files=true. Si pacman acaba de reinstalar el
# GOA oficial encima del nuestro, el scope de Drive desaparece y Drive deja de
# montar SIN ningun mensaje de error en el arranque.
# ---------------------------------------------------------------------------
# Ojo: `grep -q` cierra la tuberia en cuanto encuentra algo, `strings` recibe
# SIGPIPE y con `pipefail` eso cuenta como fallo. Por eso se vuelca primero a
# una variable en vez de encadenar directamente.
_scopes="$(find /usr/lib -maxdepth 1 -name 'libgoa-backend-1.0.so*' -type f \
           -exec strings {} + 2>/dev/null || true)"

if ! grep -q 'googleapis.com/auth/drive' <<<"$_scopes"; then
  printf '%s  Drive-Gekko-Gnome: SE PERDIO EL PERMISO DE GOOGLE DRIVE%s\n\n' "${R}" "${O}"
  printf '  El gnome-online-accounts oficial de Arch acaba de sustituir al\n'
  printf '  nuestro. Ya no pide el scope .../auth/drive, asi que Nautilus va a\n'
  printf '  dar "Permiso denegado" al abrir tu unidad.\n\n'
  printf '  Para arreglarlo:%s\n' "${Y}"
  printf '    cd <repo>/packages/gnome-online-accounts && makepkg -si\n'
  printf '%s\n' "${O}"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 2. El pin estricto de gvfs
#
# gvfsd-google enlaza contra libgvfscommon.so, que no tiene soname versionado.
# Por eso gvfs-google fija gvfs a una pkgver exacta.
# ---------------------------------------------------------------------------
_pin="$(pacman -Qi gvfs-google 2>/dev/null | sed -n 's/^[^:]*:.*gvfs=\([0-9.]*\).*/\1/p' | head -1)"
_gvfs="$(pacman -Q gvfs 2>/dev/null | awk '{print $2}' | cut -d- -f1)"

if [[ -n "$_pin" && -n "$_gvfs" && "$_pin" != "$_gvfs" ]]; then
  printf '%s\n' "${Y}"
  printf '  Drive-Gekko-Gnome: gvfs cambio de version${O}\n\n'
  printf '    gvfs instalado : %s\n' "$_gvfs"
  printf '    pin del paquete: %s\n\n' "$_pin"
  printf '  Reconstruye gvfs-google con pkgver=%s antes de usar Drive.\n' "$_gvfs"
  printf '\n'
  ROTO=1
fi

if (( ROTO == 0 )); then
  printf '%s  Drive-Gekko-Gnome: Google Drive sigue operativo.%s\n' "${G}" "${O}"
fi

exit 0
