#!/usr/bin/env bash
# publish-repo.sh — convierte los .pkg.tar.zst de out/ en un repositorio de
# pacman LOCAL (out/drive-gekko-gnome.db) y comprueba que pacman lo lee.
#
#   ./scripts/publish-repo.sh            # genera la .db
#   ./scripts/publish-repo.sh --check    # ademas la prueba como lo haria pacman
#
# Este repositorio se consume por file:// desde la misma maquina (el repo git
# es privado: pacman no puede bajar assets de un Release privado, asi que los
# binarios no se publican en GitHub). Lo usan install.sh, local-repo.sh y el CI.
#
# Reglas:
#   - Lista blanca CERRADA de 4 paquetes. Con el repo delante de [extra],
#     cualquier otro sombrearia al oficial.
#   - Sin `repo-add --new`: con el, un paquete reconstruido con la misma
#     version no se actualizaria en la db.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-${ROOT}/out}"
REPO_NAME="${REPO_NAME:-drive-gekko-gnome}"
ALLOWED=(libsoup2 libgdata gvfs-google gnome-online-accounts)
CHECK=0
for a in "$@"; do case "$a" in --check) CHECK=1 ;; *) echo "opcion desconocida: $a" >&2; exit 1 ;; esac; done

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$Y" "$O" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$O" "$*" >&2; exit 1; }

cd "$OUT" 2>/dev/null || die "no existe ${OUT}: construye primero"
rm -f ./*-debug-*.pkg.tar.zst
pkgs=()
for p in *.pkg.tar.zst; do [[ -f "$p" ]] && pkgs+=("$p"); done
(( ${#pkgs[@]} )) || die "no hay .pkg.tar.zst en ${OUT}"

for p in "${pkgs[@]}"; do
  name="$(tar --zstd -xOf "$p" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}')"
  printf '%s\n' "${ALLOWED[@]}" | grep -qx "$name" || die "'$name' ($p) NO esta en la lista blanca: no se genera nada"
done

info "generando la base de datos ${REPO_NAME}"
# --prevent-downgrade: si en out/ hubiera dos versiones, la vieja no pisa a la nueva.
repo-add --remove --prevent-downgrade "${REPO_NAME}.db.tar.zst" "${pkgs[@]}" >/dev/null
# repo-add deja .db y .files como symlinks; se copian como ficheros reales.
for f in db files; do rm -f "${REPO_NAME}.${f}"; cp -L "${REPO_NAME}.${f}.tar.zst" "${REPO_NAME}.${f}"; done
ok "${REPO_NAME}.db con ${#pkgs[@]} paquete(s)"; printf '     %s\n' "${pkgs[@]}"

(( CHECK )) || exit 0

# ---------------------------------------------------------------------------
# Prueba de consumidor: ¿resuelve pacman cada paquete desde esta .db?
# pacman exige root para -Sy aunque el dbpath sea temporal: fuera del CI se
# engaña con fakeroot (base-devel). Todo apunta a $tmp: no toca el sistema.
# -Spdd: solo nombre -> fichero, SIN resolver dependencias (en una db temporal
# vacia, glib2 o gvfs=X no existen y -Sp normal abortaria).
# ---------------------------------------------------------------------------
info "prueba de consumidor (pacman -Sy contra file://${OUT})"
command -v fakeroot >/dev/null || [[ $EUID -eq 0 ]] || die "falta fakeroot (base-devel) para la prueba de consumidor"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/db" "$tmp/cache" "$tmp/gnupg"
cat > "$tmp/pacman.conf" <<CONF
[options]
Architecture = auto
SigLevel = Never
[${REPO_NAME}]
Server = file://${OUT// /%20}
CONF
pac=(pacman --config "$tmp/pacman.conf" --dbpath "$tmp/db" --cachedir "$tmp/cache" --logfile "$tmp/log" --gpgdir "$tmp/gnupg")
[[ $EUID -eq 0 ]] || pac=(fakeroot -- "${pac[@]}")
"${pac[@]}" -Sy >"$tmp/sy.log" 2>&1 || { cat "$tmp/sy.log" >&2; die "pacman no pudo leer la .db recien generada"; }
for n in "${ALLOWED[@]}"; do
  url="$("${pac[@]}" -Spdd "${REPO_NAME}/$n" 2>/dev/null | grep '^file://' | head -1 || true)"
  # Los cuatro tienen que estar: una .db a la que le falte uno dejaria al
  # sistema sin actualizaciones de ese paquete (o sin el pin de gvfs).
  [[ -n "$url" ]] || die "$n no esta en la .db (¿fallo su build?)"
  f="${url#file://}"; f="${f//%20/ }"
  [[ -f "$f" ]] || die "$n: la .db apunta a $(basename "$f") pero no existe en out/"
  # y la version de la .db tiene que ser la del PKGBUILD actual: una .db con
  # una version vieja dejaria al sistema pineado a un gvfs/libgoa que ya no existe
  want="$( (cd "$ROOT/packages/$n" && makepkg --printsrcinfo 2>/dev/null) | awk -F' = ' '/^\tpkgver/{v=$2} /^\tpkgrel/{r=$2} END{print v"-"r}')"
  have="$(bsdtar -xOf "${REPO_NAME}.db" "$n-*/desc" 2>/dev/null | awk '/^%VERSION%/{getline; print; exit}')"
  [[ -z "$want" || "$have" == "$want" ]] || die "$n: la .db tiene $have pero el PKGBUILD dice $want (¿quedo una version vieja en out/?)"
  ok "$n -> $(basename "$f")$( [[ -n "$want" ]] && echo " ($want)" )"
done
echo "repositorio local verificado"
