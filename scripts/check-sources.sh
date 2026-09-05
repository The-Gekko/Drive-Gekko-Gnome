#!/usr/bin/env bash
# check-sources.sh — ¿de donde puede salir hoy cada paquete de esta cadena?
#
#   ./scripts/check-sources.sh
#
# Consulta, para cada paquete:
#   [oficial]  API de archlinux.org (core/extra/multilib/testing/gnome-unstable)
#   [aur]      RPC v5 del AUR
#   [chaotic]  el repo chaotic-aur, si lo tienes configurado en pacman
#
# La regla de este proyecto: si esta en los repos OFICIALES, se usa el oficial
# y no lo empaquetamos. Si solo esta en AUR/Chaotic, lo construimos nosotros
# desde el tarball upstream. UNA excepcion: gnome-online-accounts esta en
# [extra] pero compilado sin el permiso de Drive, asi que se recompila igual.
# Ver docs/estado-upstream.md para el porque.

set -uo pipefail

PAQUETES=(libsoup libsoup2 libgdata gvfs gvfs-goa gvfs-google gnome-online-accounts deja-dup rclone)

C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

command -v curl    >/dev/null || { echo "falta curl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "falta python3" >&2; exit 1; }

oficial() {
  curl -fsSL "https://archlinux.org/packages/search/json/?name=$1" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    results = json.load(sys.stdin).get("results", [])
except Exception:
    print("?"); raise SystemExit
if not results:
    print("-"); raise SystemExit
# se prefiere el repo estable si aparece en varios
orden = {"core": 0, "extra": 1, "multilib": 2}
results.sort(key=lambda r: orden.get(r["repo"].lower(), 9))
r = results[0]
print(f'"'"'{r["repo"].lower()}:{r["pkgver"]}-{r["pkgrel"]}'"'"')
'
}

aur() {
  curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
results = data.get("results", [])
if not results:
    print("-"); raise SystemExit
r = results[0]
huerfano = " HUERFANO" if not r.get("Maintainer") else ""
print(f'"'"'{r["Version"]}{huerfano}'"'"')
'
}

chaotic() {
  if ! command -v pacman >/dev/null; then
    echo "?"
    return
  fi
  if ! pacman-conf --repo-list 2>/dev/null | grep -qx 'chaotic-aur'; then
    echo "no-conf"
    return
  fi
  local out
  out="$(pacman -Sl chaotic-aur 2>/dev/null | awk -v p="$1" '$2 == p {print $3}')"
  [[ -n "$out" ]] && echo "$out" || echo "-"
}

echo
printf '%-14s %-24s %-24s %s\n' "PAQUETE" "OFICIAL" "AUR" "CHAOTIC"
printf '%s\n' "--------------------------------------------------------------------------------"

for p in "${PAQUETES[@]}"; do
  o="$(oficial "$p")"
  a="$(aur "$p")"
  c="$(chaotic "$p")"

  if [[ "$o" != "-" && "$o" != "?" ]]; then
    co="$C_OK"      # esta en oficiales: usar ese
  else
    co="$C_WARN"    # no esta: candidato a mantenerlo nosotros
  fi

  [[ "$a" == *HUERFANO* ]] && ca="$C_ERR" || ca="$C_DIM"

  printf '%-14s %s%-24s%s %s%-24s%s %s\n' \
    "$p" "$co" "$o" "$C_OFF" "$ca" "$a" "$C_OFF" "$c"
done

cat <<'EOF'

Lectura:
  verde en OFICIAL  -> usa el paquete oficial, no lo empaquetes aqui
                       (excepcion: gnome-online-accounts, que se recompila
                       con -D google_files=true aunque este en [extra])
  amarillo          -> ya no esta en Arch: nos toca a nosotros
  rojo en AUR       -> paquete huerfano; un huerfano es justo lo que se adopto
                       masivamente en el incidente Atomic Arch de junio 2026

"chaotic: no-conf" solo significa que no tienes el repo anadido en pacman.conf.
Aun asi, para esta cadena concreta NO se recomienda Chaotic: reconstruye AUR
de forma automatica, y el eslabon debil (libgdata) es un paquete archivado.
EOF
