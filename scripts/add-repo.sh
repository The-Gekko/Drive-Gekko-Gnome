#!/usr/bin/env bash
# add-repo.sh — pone el repositorio de este proyecto en /etc/pacman.conf, en
# el sitio correcto, sin duplicarlo, y lo recoloca si esta en mal sitio.
#
#   sudo ./scripts/add-repo.sh --local /ruta/al/repo/out   # repo local (lo normal)
#   ./scripts/add-repo.sh --local DIR --dry-run             # muestra lo que haria
#   ./scripts/add-repo.sh --local DIR --file otro.conf      # edita otro fichero (pruebas)
#
# POR QUE EL ORDEN IMPORTA: gnome-online-accounts existe en [extra], y pacman
# elige el PRIMER repositorio de pacman.conf que tenga un paquete con ese
# nombre, sin mirar versiones. Si este repo va despues de [extra], pacman
# instalara siempre el GOA de Arch (sin permiso de Drive) y no dira nada.
# Por eso el bloque se inserta antes de [core]; si [core] viene por Include o
# esta comentado, antes de la primera seccion que no sea [options].

set -uo pipefail

REPO_NAME="drive-gekko-gnome"
CONF=/etc/pacman.conf; DRY=0; SERVER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) SERVER="file://${2:?}"; SERVER="${SERVER// /%20}"; shift 2 ;;
    --server) SERVER="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --file) CONF="${2:?}"; shift 2 ;;
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$SERVER" ]] || { echo "falta --local DIR (o --server URL)" >&2; exit 1; }
[[ -r "$CONF" ]] || { echo "no puedo leer $CONF" >&2; exit 1; }

BLOCK="# Drive-Gekko-Gnome: Google Drive en GNOME. Va ANTES de [core]/[extra] a
# proposito: gnome-online-accounts sombrea al de Arch y pacman elige por orden.
[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = ${SERVER}
"

# Quita un bloque nuestro anterior (desde el comentario o la cabecera hasta la
# siguiente seccion o el final), para reinsertarlo en el sitio correcto.
strip_block() {
  awk -v name="[${REPO_NAME}]" '
    /^# Drive-Gekko-Gnome:/ { skip=1; next }
    skip && /^# proposito:/ { next }
    $0==name { skip=1; next }
    skip && /^\[/ { skip=0 }
    skip && /^(SigLevel|Server|Include)[[:space:]]*=/ { next }
    skip && /^[[:space:]]*$/ { next }
    { skip=0; print }'
}
# Inserta el bloque antes de la primera seccion real (no comentada) distinta
# de [options]; [core] es la habitual.
insert_block() {
  awk -v block="$BLOCK" '
    !done && /^\[/ && $0 != "[options]" { print block; done=1 }
    { print }
    END { if (!done) print block }'
}

had=0; grep -qE "^\[${REPO_NAME}\]" "$CONF" && had=1
new="$(strip_block < "$CONF" | insert_block)"

# ¿queda antes de [extra] (y de [core] si existe literal)? Se comprueba sobre
# el resultado, que es lo que importa.
pos_repo="$(grep -nE "^\[${REPO_NAME}\]" <<<"$new" | cut -d: -f1 | head -1)"
pos_extra="$(grep -nE '^\[extra\]' <<<"$new" | cut -d: -f1 | head -1)"
if [[ -n "$pos_extra" && "$pos_repo" -gt "$pos_extra" ]]; then
  echo "no he conseguido colocar [$REPO_NAME] antes de [extra] en $CONF; hazlo a mano" >&2; exit 1
fi

if [[ "$new" == "$(cat "$CONF")" ]]; then
  echo "[$REPO_NAME] ya esta en $CONF y en el sitio correcto; nada que hacer."; exit 0
fi
if (( DRY )); then
  echo "--- $CONF quedaria asi (diff): ---"; diff <(cat "$CONF") <(printf '%s\n' "$new") || true; exit 0
fi
[[ -w "$CONF" ]] || { echo "sin permiso de escritura en $CONF: usa sudo" >&2; exit 1; }
cp -a "$CONF" "${CONF}.bak-drive-gekko-$(date +%Y%m%d%H%M%S)"
printf '%s\n' "$new" > "$CONF"
if (( had )); then echo "[$REPO_NAME] recolocado en $CONF (copia de seguridad al lado)."
else echo "[$REPO_NAME] anadido a $CONF antes de [core] (copia de seguridad al lado). Ahora:  sudo pacman -Syu"; fi
