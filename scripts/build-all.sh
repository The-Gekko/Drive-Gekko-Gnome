#!/usr/bin/env bash
# build-all.sh — construye la cadena de Drive-Gekko-Gnome en orden de dependencia.
#
#   ./scripts/build-all.sh                    # solo construir la cadena obligatoria
#   ./scripts/build-all.sh --install          # construir e instalar con pacman
#   ./scripts/build-all.sh --repo gekko       # construir y generar repo local "gekko"
#   ./scripts/build-all.sh --with-optional    # incluir deja-dup (ya esta en [extra])
#   ./scripts/build-all.sh --only libgdata    # construir un paquete concreto
#   ./scripts/build-all.sh --clean            # borrar src/ pkg/ antes de construir
#
# NO ejecutar como root: makepkg lo rechaza a proposito.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"

# Orden obligatorio. libgdata enlaza contra libsoup 2.4, y gvfsd-google contra
# libgdata. gvfs y gvfs-goa vienen de [extra]: aqui no se tocan.
#
# gnome-online-accounts no depende de los otros tres, pero SIN EL no sirven de
# nada: es quien pide a Google el permiso de Drive. Va el ultimo porque es el
# unico que sombrea un paquete oficial de Arch.
ORDER=(libsoup2 libgdata gvfs-google gnome-online-accounts)

# Opcionales: siguen en los repos oficiales, se construyen solo si los pides.
OPTIONAL=(deja-dup)

DO_INSTALL=0
DO_CLEAN=0
WITH_OPTIONAL=0
REPO_NAME=""
ONLY=""

C_OK=$'\033[1;32m'; C_INFO=$'\033[1;36m'; C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)       DO_INSTALL=1; shift ;;
    --clean)         DO_CLEAN=1; shift ;;
    --with-optional) WITH_OPTIONAL=1; shift ;;
    --repo)          REPO_NAME="${2:?--repo necesita un nombre}"; shift 2 ;;
    --only)          ONLY="${2:?--only necesita un paquete}"; shift 2 ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *)               die "opcion desconocida: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] && die "no ejecutes esto como root"
command -v makepkg >/dev/null || die "falta base-devel (makepkg no encontrado)"

if [[ -n "$ONLY" ]]; then
  [[ -d "${REPO_ROOT}/packages/${ONLY}" ]] || die "no existe packages/${ONLY}"
  ORDER=("$ONLY")
elif (( WITH_OPTIONAL )); then
  ORDER+=("${OPTIONAL[@]}")
fi

# Aviso: construir e instalar por separado no funciona para esta cadena. Cada
# paquete necesita las CABECERAS del anterior ya instaladas, no solo su .pkg.
if (( DO_INSTALL == 0 )) && [[ -z "$ONLY" ]]; then
  warn "sin --install los paquetes se construyen pero NO se instalan."
  warn "libgdata necesita las cabeceras de libsoup2 ya instaladas, y"
  warn "gvfs-google las de libgdata: sin --install la cadena fallara."
fi

mkdir -p "$OUT_DIR"

for pkg in "${ORDER[@]}"; do
  dir="${REPO_ROOT}/packages/${pkg}"
  info "construyendo ${pkg}"
  pushd "$dir" >/dev/null

  (( DO_CLEAN )) && rm -rf src pkg

  makepkg_args=(--syncdeps --cleanbuild --noconfirm --needed)
  (( DO_INSTALL )) && makepkg_args+=(--install)

  if ! makepkg "${makepkg_args[@]}"; then
    popd >/dev/null
    die "fallo la construccion de ${pkg}"
  fi

  # Los .pkg.tar.zst se centralizan en out/ para poder firmarlos o servirlos.
  shopt -s nullglob
  built=(*.pkg.tar.zst)
  shopt -u nullglob
  (( ${#built[@]} )) || warn "${pkg}: no se genero ningun .pkg.tar.zst"
  for f in "${built[@]}"; do
    mv -f "$f" "$OUT_DIR/"
    ok "${f}"
  done

  popd >/dev/null
done

if [[ -n "$REPO_NAME" ]]; then
  info "generando repo local '${REPO_NAME}' en ${OUT_DIR}"
  ( cd "$OUT_DIR" && repo-add --new --remove "${REPO_NAME}.db.tar.zst" ./*.pkg.tar.zst )
  cat <<EOFMSG

Repo listo. Anade esto a /etc/pacman.conf. Como ninguno de estos paquetes
existe ya en los repos oficiales, el orden respecto a [extra] da igual: ponlo
al final para no sombrear nada por accidente.

[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = file://${OUT_DIR}

Luego: sudo pacman -Syu
EOFMSG
fi

ok "listo"
