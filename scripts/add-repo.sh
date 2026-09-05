#!/usr/bin/env bash
# add-repo.sh — añade el repositorio de este proyecto a /etc/pacman.conf,
# en el sitio correcto, sin duplicarlo.
#
#   sudo ./scripts/add-repo.sh              # edita /etc/pacman.conf
#   ./scripts/add-repo.sh --dry-run         # muestra lo que haria
#   ./scripts/add-repo.sh --file otro.conf  # edita otro fichero (pruebas)
#
# POR QUE EL ORDEN IMPORTA: gnome-online-accounts existe en [extra], y pacman
# elige el PRIMER repositorio de pacman.conf que tenga un paquete con ese
# nombre, sin mirar versiones. Si este repo va despues de [extra], pacman
# instalara siempre el GOA de Arch (sin permiso de Drive) y no dira nada.
# Por eso el bloque se inserta justo ANTES de [core].

set -euo pipefail

REPO_NAME="drive-gekko-gnome"
OWNER="The-Gekko"
PROJECT="Drive-Gekko-Gnome"
CONF=/etc/pacman.conf
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --file) CONF="${2:?}"; shift 2 ;;
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done

BLOCK="# Drive-Gekko-Gnome: Google Drive en GNOME. Va ANTES de [core]/[extra] a
# proposito: gnome-online-accounts sombrea al de Arch y pacman elige por orden.
[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = https://github.com/${OWNER}/${PROJECT}/releases/download/repo
"

[[ -r "$CONF" ]] || { echo "no puedo leer $CONF" >&2; exit 1; }

if grep -qE "^\[${REPO_NAME}\]" "$CONF"; then
  echo "[$REPO_NAME] ya esta en $CONF; nada que hacer."
  # aviso si esta en mal sitio
  l_repo=$(grep -nE "^\[${REPO_NAME}\]" "$CONF" | cut -d: -f1 | head -1)
  l_core=$(grep -nE '^\[core\]' "$CONF" | cut -d: -f1 | head -1)
  if [[ -n "$l_core" && "$l_repo" -gt "$l_core" ]]; then
    echo "AVISO: esta DESPUES de [core] (linea $l_repo > $l_core). Muevelo antes, o pacman preferira el GOA de Arch." >&2
    exit 2
  fi
  exit 0
fi

grep -qE '^\[core\]' "$CONF" || { echo "no encuentro [core] en $CONF" >&2; exit 1; }

new="$(awk -v block="$BLOCK" '/^\[core\]/ && !done { print block; done=1 } { print }' "$CONF")"

if (( DRY )); then
  echo "--- se insertaria antes de [core] en $CONF: ---"; printf '%s\n' "$BLOCK"
  exit 0
fi

[[ -w "$CONF" ]] || { echo "sin permiso de escritura en $CONF: usa sudo" >&2; exit 1; }
cp -a "$CONF" "${CONF}.bak-drive-gekko-$(date +%Y%m%d%H%M%S)"
printf '%s\n' "$new" > "$CONF"
echo "[$REPO_NAME] añadido a $CONF (copia de seguridad al lado). Ahora:  sudo pacman -Syu"
