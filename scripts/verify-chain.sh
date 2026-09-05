#!/usr/bin/env bash
# verify-chain.sh — las comprobaciones que dicen si la cadena instalada SIRVE.
#
#   ./scripts/verify-chain.sh
#
# Las usan install.sh, el CI y el sincronizador. Cada una corresponde a un
# fallo real visto en esta cadena. Sale con 1 al primer fallo.

set -euo pipefail

R=$'\033[1;31m'; G=$'\033[1;32m'; O=$'\033[0m'
fail() { printf '%sFALLO%s %s\n' "$R" "$O" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }

[[ -x /usr/lib/gvfsd-google ]] || fail "no existe /usr/lib/gvfsd-google (gvfs-google no esta instalado)"

# 1. gvfsd-google enlaza contra el gvfs del sistema (libgvfscommon/libgvfsdaemon sin soname)
if ldd /usr/lib/gvfsd-google | grep -q 'not found'; then
  ldd /usr/lib/gvfsd-google | grep 'not found' >&2
  fail "gvfsd-google tiene librerias sin resolver (¿gvfs cambio de version?)"
fi
ok "gvfsd-google enlaza contra el gvfs del sistema"

# 2. el pin de gvfs-google coincide con el gvfs instalado
_pin="$(LC_ALL=C pacman -Qi gvfs-google 2>/dev/null | sed -n 's/^Depends On.*gvfs=\([0-9.]*\).*/\1/p' | head -1 || true)"
_gvfs="$(pacman -Q gvfs 2>/dev/null | awk '{print $2}' | cut -d- -f1 || true)"
[[ -n "$_pin" && "$_pin" == "$_gvfs" ]] || fail "gvfs-google fija gvfs=${_pin:-?} pero hay gvfs ${_gvfs:-?}"
ok "pin de gvfs (${_pin}) coincide con el instalado"

# 3. GOA pide el permiso de Drive (grep -a: sin depender de binutils; patron
#    estricto: 'drive' seguido de espacio o fin, no drive.file/drive.readonly)
# (find -exec ... + devolveria 0 si no hubiera ningun fichero: se exige que exista)
_goa="$(find /usr/lib -maxdepth 1 -name 'libgoa-backend-1.0.so*' -type f | head -1)"
[[ -n "$_goa" ]] || fail "no existe /usr/lib/libgoa-backend-1.0.so* (¿gnome-online-accounts no esta instalado?)"
grep -aqE 'googleapis\.com/auth/drive( |$)' "$_goa" \
  || fail "el gnome-online-accounts instalado NO pide el scope de Drive (¿es el de Arch?)"
ok "gnome-online-accounts pide el permiso de Drive"

# 4. libgdata enlaza contra libsoup 2.4 (no contra la 3)
ldd /usr/lib/libgdata.so 2>/dev/null | grep -q 'libsoup-2.4' || fail "libgdata no enlaza contra libsoup-2.4"
ok "libgdata enlaza contra libsoup-2.4"

echo "cadena verificada"
