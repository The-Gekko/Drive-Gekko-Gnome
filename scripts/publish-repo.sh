#!/usr/bin/env bash
# publish-repo.sh — convierte los .pkg.tar.zst de out/ en un repositorio de
# pacman LOCAL (out/drive-gekko-gnome.db) y comprueba que pacman lo lee.
#
#   ./scripts/publish-repo.sh            # genera la .db
#   ./scripts/publish-repo.sh --check    # ademas la prueba como lo haria pacman
#
# Este repositorio se consume por file:// desde la misma maquina: los binarios
# no se publican en GitHub, cada maquina construye los suyos a partir de las
# recetas. Lo usan install.sh, local-repo.sh y el CI.
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
  # `|| true`: sin el, un .pkg.tar.zst truncado hace fallar a tar, pipefail
  # propaga el estado a la asignacion y set -e mata el script sin decir nada,
  # justo antes del die que si nombra el fichero.
  name="$(tar --zstd -xOf "$p" .PKGINFO 2>/dev/null | awk -F' = ' '/^pkgname/{print $2; exit}' || true)"
  printf '%s\n' "${ALLOWED[@]}" | grep -qxF -- "$name" \
    || die "'$name' ($p) NO esta en la lista blanca (o no se pudo leer su .PKGINFO): no se genera nada. Sacalo de ${OUT} (rm '${OUT}/$p') y repite: mientras ese fichero siga ahi mueren aqui el temporizador, el paso 3 de install.sh y 'gekko drive u'"
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
# Mismo escapado que url_ruta() de scripts/add-repo.sh: quien abre un file://
# es curl, que descodifica los %XX, corta la ruta donde empiezan el fragmento
# (#) o la consulta (?) y rechaza el espacio de plano. Escapando solo el
# espacio, un clon en "a#b" tumbaba ESTA prueba -y con ella el temporizador
# cada 6 h, el paso 3 de install.sh y `gekko drive u`, porque local-repo.sh la
# llama con || die- sobre un repo impecable que add-repo.sh si sabia poner en
# /etc/pacman.conf. El % va el primero o recodificaria los que ponemos aqui.
_srv="${OUT//%/%25}"; _srv="${_srv//\\/%5C}"; _srv="${_srv// /%20}"
_srv="${_srv//\#/%23}"; _srv="${_srv//\?/%3F}"
cat > "$tmp/pacman.conf" <<CONF
[options]
Architecture = auto
SigLevel = Never
[${REPO_NAME}]
Server = file://${_srv}
CONF
pac=(pacman --config "$tmp/pacman.conf" --dbpath "$tmp/db" --cachedir "$tmp/cache" --logfile "$tmp/log" --gpgdir "$tmp/gnupg")
[[ $EUID -eq 0 ]] || pac=(fakeroot -- "${pac[@]}")
"${pac[@]}" -Sy >"$tmp/sy.log" 2>&1 || { cat "$tmp/sy.log" >&2; die "pacman no pudo leer la .db recien generada"; }
for n in "${ALLOWED[@]}"; do
  url="$("${pac[@]}" -Spdd "${REPO_NAME}/$n" 2>/dev/null | grep '^file://' | head -1 || true)"
  # Los cuatro tienen que estar: una .db a la que le falte uno dejaria al
  # sistema sin actualizaciones de ese paquete (o sin el pin de gvfs).
  [[ -n "$url" ]] || die "$n no esta en la .db (¿fallo su build?)"
  # Deshacer el escapado de arriba, con %25 el ULTIMO: al reves, un directorio
  # llamado "lit%20eral" se leeria como "lit eral" y el -f de abajo fallaria.
  f="${url#file://}"; f="${f//%20/ }"; f="${f//%23/#}"; f="${f//%3F/\?}"
  f="${f//%5C/\\}"; f="${f//%25/%}"
  [[ -f "$f" ]] || die "$n: la .db apunta a $(basename "$f") pero no existe en out/"
  # y la version de la .db tiene que ser la del PKGBUILD actual: una .db con
  # una version vieja dejaria al sistema pineado a un gvfs/libgoa que ya no existe
  # Se lee el PKGBUILD en crudo y NO se usa `makepkg --printsrcinfo`: makepkg
  # comprueba EUID==0 y sale con 10 antes de atender esa opcion, asi que en
  # cuanto esto corre como root (un sudo a mano, o el CI el dia que se olvide
  # de degradar a builder) pipefail mataba el script aqui mismo, mudo y sin
  # llegar a ningun die. Vale leerlo a pelo porque ninguno de los cuatro
  # PKGBUILD tiene epoch= ni funcion pkgver().
  want="$(awk -F= '/^pkgver=/{v=$2} /^pkgrel=/{r=$2} END{if (v != "") print v"-"r}' "$ROOT/packages/$n/PKGBUILD" 2>/dev/null || true)"
  have="$(bsdtar -xOf "${REPO_NAME}.db" "$n-*/desc" 2>/dev/null | awk '/^%VERSION%/{getline; print; exit}' || true)"
  [[ -z "$want" || "$have" == "$want" ]] || die "$n: la .db tiene $have pero el PKGBUILD dice $want (¿quedo una version vieja en out/?)"
  ok "$n -> $(basename "$f")$( [[ -n "$want" ]] && echo " ($want)" )"
done

# ---------------------------------------------------------------------------
# Lo unico que la prueba de arriba NO ejerce: pacman de verdad baja privilegios
# al usuario de DownloadUser (alpm, sin comentar en el pacman.conf que instala
# el propio paquete pacman) y abre la .db con ESE uid, tambien en un repo
# file://. Aqui no se puede reproducir tal cual —bajo fakeroot pacman no puede
# ni aplicar Landlock ni cambiar de usuario, y fallaria igual en una maquina
# sana—, asi que se miran los permisos a mano. Importa: el HOME se crea a 0700
# (HOME_MODE de /etc/login.defs) y ahi ese uid no llega ni a atravesar hasta
# out/; pacman no sincroniza la .db y se cae la transaccion ENTERA, no solo la
# de este repo. Sin esta comprobacion la prueba de consumidor daba verde en una
# maquina en la que pacman ya no funcionaba.
# ---------------------------------------------------------------------------
alcanza() { # $1 usuario, $2 ruta, $3 bit (r|x); sin privilegios: solo permisos
  local u=$1 f=$2 bit=$3 m g tri acl
  m="$(stat -Lc '%A %G' -- "$f" 2>/dev/null)" || return 1
  g="${m#* }"; m="${m%% *}"; tri="${m:7:3}"
  [[ " $(id -nG "$u" 2>/dev/null) " == *" $g "* ]] && tri="${m:4:3}"   # o la del grupo
  tri="${tri//[ts]/x}"; tri="${tri//[TS]/-}"   # el sticky de /tmp no es permiso
  acl="$(getfacl -pE -- "$f" 2>/dev/null | awk -F: -v u="$u" '$1=="user" && $2==u {print $3}')"
  [[ "${tri}${acl}" == *"$bit"* ]]
}
DL="$(pacman-conf DownloadUser 2>/dev/null || true)"
# Bajo fakeroot esta comprobacion no se puede hacer: libfakeroot finge el dueno
# (stat dice root) y getfacl ya no devuelve las entradas de usuario, asi que un
# HOME perfectamente accesible por ACL se leeria como inalcanzable y este script
# moriria con una alarma falsa. No se pierde nada: por la ruta real —
# local-repo.sh lo llama con as_user, y el CI como root de verdad — aqui no hay
# ningun FAKEROOTKEY.
if [[ -n "${FAKEROOTKEY:-}" ]]; then
  warn "bajo fakeroot no se puede comprobar el acceso de DownloadUser (getfacl no ve las ACL); se omite"
elif [[ -n "$DL" ]] && id -u "$DL" >/dev/null 2>&1; then
  # `pwd -P` y no $OUT: el cwd es OUT desde :33, y lo que atraviesa el kernel
  # son los directorios reales, no los symlinks del camino escrito.
  sin=(); dir="$(pwd -P)"; d="$dir"
  while :; do                                  # travesia de TODA la ruta
    alcanza "$DL" "$d" x || sin+=("$d")
    [[ "$d" == / ]] && break
    d="$(dirname "$d")"
  done
  alcanza "$DL" "${dir}/${REPO_NAME}.db" r || sin+=("${dir}/${REPO_NAME}.db")
  (( ${#sin[@]} == 0 )) || die "la .db esta bien, pero pacman descarga como el usuario '$DL' y no puede llegar a ella: le falta permiso en ${sin[*]}.
      Tal cual, cualquier 'pacman -Sy' de esta maquina falla y arrastra a toda la transaccion.
      Lo arregla: sudo ${ROOT}/scripts/add-repo.sh --local ${dir}"
  ok "legible para '$DL', que es con quien pacman descarga (DownloadUser)"
fi
echo "repositorio local verificado"
