#!/usr/bin/env bash
# publish-repo.sh — convierte los .pkg.tar.zst de out/ en un repositorio de
# pacman y, si se pide, lo sube al Release fijo `repo` de GitHub.
#
#   ./scripts/publish-repo.sh                 # solo genera out/<repo>.db y .files
#   ./scripts/publish-repo.sh --check         # ademas prueba la .db como lo haria pacman
#   ./scripts/publish-repo.sh --upload        # ademas sube a GitHub (necesita gh + token)
#
# Firma: si GPG_KEY_ID esta definido (lo exporta ci-prepare.sh cuando existe el
# secreto REPO_GPG_KEY), firma cada paquete nuevo y la base de datos. Si no,
# publica sin firma y lo dice.
#
# Reglas que importan:
#   - Un .pkg.tar.zst ya publicado NUNCA se sobrescribe. Si un usuario lo tiene
#     en cache y el contenido cambia, pacman falla con "invalid or corrupt".
#     Para volver a publicar un paquete, sube pkgrel. Aqui, si el nombre ya
#     existe como asset, se omite (y se avisa).
#   - La base de datos (.db, .files) SI se sobrescribe siempre: es lo que
#     apunta a la version vigente de cada paquete.
#   - Los assets que ya no esten en out/ se borran: el Release refleja main.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/out"
REPO_NAME="${REPO_NAME:-drive-gekko-gnome}"
TAG="${RELEASE_TAG:-repo}"
UPLOAD=0; CHECK=0
for a in "$@"; do case "$a" in --upload) UPLOAD=1 ;; --check) CHECK=1 ;; *) echo "opcion desconocida: $a" >&2; exit 1 ;; esac; done

# Lista blanca CERRADA. Con el repo delante de [extra], cualquier paquete que
# se publique aqui sombrea al oficial en todas las maquinas: solo estos cuatro.
ALLOWED=(libsoup2 libgdata gvfs-google gnome-online-accounts)

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$Y" "$O" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$O" "$*" >&2; exit 1; }

cd "$OUT" 2>/dev/null || die "no existe ${OUT}: construye primero (scripts/build-all.sh)"
shopt -s nullglob
pkgs=( *.pkg.tar.zst )
pkgs=( "${pkgs[@]/*-debug-*/}" )   # fuera los -debug
pkgs=( "${pkgs[@]}" )              # compacta huecos
(( ${#pkgs[@]} )) || die "no hay .pkg.tar.zst en ${OUT}"
rm -f ./*-debug-*.pkg.tar.zst

for p in "${pkgs[@]}"; do
  name="$(tar --zstd -xOf "$p" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}')"
  printf '%s\n' "${ALLOWED[@]}" | grep -qx "$name" || die "'$name' ($p) NO esta en la lista blanca: no se publica nada"
done

# Firma opcional de los paquetes (la db se firma en repo-add).
SIGN=()
if [[ -n "${GPG_KEY_ID:-}" ]]; then
  SIGN=(--sign --key "$GPG_KEY_ID")
  for p in "${pkgs[@]}"; do
    [[ -f "$p.sig" ]] || gpg --batch --yes --detach-sign --use-agent -u "$GPG_KEY_ID" "$p"
  done
  ok "paquetes firmados con $GPG_KEY_ID"
else
  warn "GPG_KEY_ID no definido: se publica SIN firma (ver keys/README.md para activarla)"
fi

info "generando la base de datos ${REPO_NAME}"
# Sin --new: con el, un paquete reconstruido con la misma version no se
# actualizaria en la db. --remove quita las versiones viejas de la db.
repo-add --remove "${SIGN[@]}" "${REPO_NAME}.db.tar.zst" "${pkgs[@]}" >/dev/null
# repo-add deja .db y .files como symlinks; GitHub necesita ficheros reales.
for f in db files; do
  rm -f "${REPO_NAME}.${f}" "${REPO_NAME}.${f}.sig"
  cp -L "${REPO_NAME}.${f}.tar.zst" "${REPO_NAME}.${f}"
  [[ -f "${REPO_NAME}.${f}.tar.zst.sig" ]] && cp -L "${REPO_NAME}.${f}.tar.zst.sig" "${REPO_NAME}.${f}.sig"
done
ok "${REPO_NAME}.db y ${REPO_NAME}.files listos con ${#pkgs[@]} paquetes"
ls -1 "${pkgs[@]}" | sed 's/^/     /'

# ---------------------------------------------------------------------------
# Prueba de consumidor: antes de subir nada, ¿resuelve pacman cada paquete
# desde esta .db, exactamente como lo hara en la maquina de un usuario?
# Se usa una pacman.conf y un dbpath temporales: no toca el sistema.
# ---------------------------------------------------------------------------
if (( CHECK )); then
  info "prueba de consumidor (pacman -Sy contra file://${OUT})"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/db"
  cat > "$tmp/pacman.conf" <<CONF
[options]
Architecture = x86_64
SigLevel = Optional TrustAll
[${REPO_NAME}]
Server = file://${OUT// /%20}
CONF
  # pacman exige root para -Sy aunque el dbpath sea temporal; fuera del CI se
  # engaña con fakeroot (base-devel). Todo apunta a $tmp: no toca el sistema.
  pac=(pacman --config "$tmp/pacman.conf" --dbpath "$tmp/db" --cachedir "$tmp/cache" \
       --logfile "$tmp/log" --gpgdir "$tmp/gnupg")
  [[ $EUID -eq 0 ]] || pac=(fakeroot -- "${pac[@]}")
  mkdir -p "$tmp/cache" "$tmp/gnupg"
  "${pac[@]}" -Sy >"$tmp/sy.log" 2>&1 || { cat "$tmp/sy.log" >&2; die "pacman no pudo leer la .db recien generada"; }
  for n in "${ALLOWED[@]}"; do
    url="$("${pac[@]}" -Sp "${REPO_NAME}/$n" 2>/dev/null || true)"
    # Los cuatro tienen que estar: una .db a la que le falte uno dejaria a los
    # consumidores sin actualizaciones de ese paquete (o sin el pin de gvfs).
    [[ -n "$url" ]] || die "$n no esta en la .db: no se publica nada (¿fallo su build?)"
    f="${url#file://}"; f="${f//%20/ }"
    [[ -f "$f" ]] || die "$n: la .db apunta a $(basename "$f") pero no existe en out/"
    ok "$n -> $(basename "$f")"
  done
fi

(( UPLOAD )) || { echo; echo "Sin --upload: nada se ha subido."; exit 0; }

command -v gh >/dev/null || die "falta gh (github-cli)"
[[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] || gh auth status >/dev/null 2>&1 || die "gh no esta autenticado"

info "asegurando que existe el Release '${TAG}'"
if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --latest=false --title "Repositorio de pacman" --notes \
"Repositorio de pacman de Drive-Gekko-Gnome. Se actualiza solo desde el CI.

Añade a /etc/pacman.conf, ANTES de [core] y [extra]:

    [${REPO_NAME}]
    SigLevel = Optional TrustAll
    Server = https://github.com/\${OWNER}/\${REPO}/releases/download/${TAG}

y luego: sudo pacman -Syu" >/dev/null
  ok "Release creado"
fi

mapfile -t existing < <(gh release view "$TAG" --json assets --jq '.assets[].name')

info "subiendo paquetes nuevos (los ya publicados no se tocan)"
subidos=0
for p in "${pkgs[@]}"; do
  if printf '%s\n' "${existing[@]}" | grep -qx "$p"; then
    echo "     ya publicado: $p"
    continue
  fi
  gh release upload "$TAG" "$p" >/dev/null
  [[ -f "$p.sig" ]] && gh release upload "$TAG" "$p.sig" >/dev/null
  ok "$p"; subidos=$((subidos+1))
done

info "actualizando la base de datos"
dbfiles=("${REPO_NAME}.db" "${REPO_NAME}.files")
for f in "${REPO_NAME}.db.sig" "${REPO_NAME}.files.sig"; do [[ -f "$f" ]] && dbfiles+=("$f"); done
gh release upload "$TAG" "${dbfiles[@]}" --clobber >/dev/null
ok "db y files"

info "borrando assets que ya no estan en out/"
for a in "${existing[@]}"; do
  case "$a" in "${REPO_NAME}".db|"${REPO_NAME}".files|"${REPO_NAME}".db.sig|"${REPO_NAME}".files.sig) continue ;; esac
  [[ -e "$a" ]] && continue
  gh release delete-asset "$TAG" "$a" --yes >/dev/null 2>&1 && echo "     borrado: $a" || warn "no se pudo borrar $a"
done

echo; ok "publicado: ${subidos} paquete(s) nuevo(s); db actualizada"
