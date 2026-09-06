#!/usr/bin/env bash
# build-all.sh — construye la cadena de Drive-Gekko-Gnome en orden de dependencia.
#
#   ./scripts/build-all.sh                    # solo construir la cadena obligatoria
#   ./scripts/build-all.sh --install          # construir e instalar con pacman
#   ./scripts/build-all.sh --with-optional    # incluir deja-dup (ya esta en [extra])
#   ./scripts/build-all.sh --only libgdata    # construir un paquete concreto
#   ./scripts/build-all.sh --clean            # borrar src/ pkg/ antes de construir
#
# Lo que no es de la cadena (deja-dup) va a out-opcional/, no a out/: out/ es
# el repositorio local y publish-repo.sh solo admite los cuatro de la cadena.
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
# La misma lista blanca que publish-repo.sh. --only la pisa en ORDER, asi que
# se guarda aparte: es lo unico que puede acabar en out/.
CHAIN=("${ORDER[@]}")

# Opcionales: siguen en los repos oficiales, se construyen solo si los pides.
OPTIONAL=(deja-dup)

DO_INSTALL=0
DO_CLEAN=0
WITH_OPTIONAL=0
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
    --only)          ONLY="${2:?--only necesita un paquete}"; shift 2 ;;
    -h|--help)       sed -n '2,13p' "$0"; exit 0 ;;
    *)               die "opcion desconocida: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] && die "no ejecutes esto como root"

if [[ -n "$ONLY" ]]; then
  [[ -d "${REPO_ROOT}/packages/${ONLY}" ]] || die "no existe packages/${ONLY}"
  ORDER=("$ONLY")
elif (( WITH_OPTIONAL )); then
  ORDER+=("${OPTIONAL[@]}")
fi

# `command -v makepkg` no discriminaba nada: /usr/bin/makepkg lo trae el
# paquete `pacman` (pacman -Qo /usr/bin/makepkg), no base-devel, asi que esa
# guarda pasaba siempre. Lo que falta de verdad en un Arch sin base-devel es
# fakeroot, y debugedit cuando makepkg.conf deja activa la opcion `debug` y el
# PKGBUILD no la apaga: makepkg aborta en check_software con rc=15 antes de
# compilar nada. Aqui, al reves que en install.sh, no hay ningun paso que los
# instale, asi que la guarda tiene que ser de verdad.
falta=()
command -v fakeroot >/dev/null || falta+=(fakeroot)
if ! command -v debugedit >/dev/null && grep -qE '^OPTIONS=\(([^)]*[[:space:]])?debug[[:space:])]' /etc/makepkg.conf 2>/dev/null; then
  for p in "${ORDER[@]}"; do
    grep -qE '^options=\(.*!debug' "${REPO_ROOT}/packages/${p}/PKGBUILD" || { falta+=(debugedit); break; }
  done
fi
(( ${#falta[@]} )) && die "falta ${falta[*]} (makepkg aborta en check_software): sudo pacman -S --needed base-devel"

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

  # Sin --needed a proposito: con el, pacman OMITE nuestro gnome-online-accounts
  # cuando el de Arch ya esta instalado con la misma version (caso normal).
  # --force: makepkg deja el .pkg.tar.zst en el directorio de la receta y se
  # niega a rehacerlo ("A package has already been built") mientras siga ahi,
  # asi que sin esto la segunda pasada sobre la misma version falla siempre.
  makepkg_args=(--syncdeps --cleanbuild --noconfirm --force)
  (( DO_INSTALL )) && makepkg_args+=(--install)

  if ! makepkg "${makepkg_args[@]}"; then
    popd >/dev/null
    die "fallo la construccion de ${pkg}"
  fi

  # Los .pkg.tar.zst se centralizan en out/ para poder firmarlos o servirlos.
  # --packagelist respeta PKGDEST si el usuario lo tiene en makepkg.conf.
  mapfile -t built < <(makepkg --packagelist 2>/dev/null)
  (( ${#built[@]} )) || warn "${pkg}: no se genero ningun .pkg.tar.zst"
  # Solo la cadena entra en out/. publish-repo.sh tiene una lista blanca
  # cerrada y hace die con cualquier otro paquete, asi que un deja-dup ahi
  # dejaria el repo local sin regenerar -y al temporizador recompilando y
  # muriendo cada 6 h- hasta que alguien borrase el fichero a mano.
  dest="$OUT_DIR"
  printf '%s\n' "${CHAIN[@]}" | grep -qx "$pkg" || dest="${REPO_ROOT}/out-opcional"
  mkdir -p "$dest"
  for f in "${built[@]}"; do
    [[ -f "$f" ]] || continue
    mv -f "$f" "$dest/"
    ok "$(basename "$f")"
  done
  [[ "$dest" == "$OUT_DIR" ]] || info "${pkg} no es de la cadena: queda en out-opcional/, fuera del repo local"

  popd >/dev/null
done

# El repositorio de pacman (out/<nombre>.db) lo genera scripts/publish-repo.sh:
# lista blanca de 4 paquetes y prueba de que pacman lo lee.
ok "listo"
