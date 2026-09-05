#!/usr/bin/env bash
# check-updates.sh — compara el pkgver de cada PKGBUILD con la ultima version upstream.
#
#   ./scripts/check-updates.sh
#
# Fuentes:
#   libsoup, libgdata, gvfs -> https://download.gnome.org/sources/<modulo>/cache.json
#   deja-dup                -> API de tags de GNOME GitLab (World/deja-dup)
#
# Solo informa. No toca ningun PKGBUILD.
#
# OJO con dos casos particulares:
#   - libsoup se compara solo dentro de la serie 2.74 (la 3.x no vale: libgdata
#     necesita la 2.4).
#   - gvfs-google se compara contra el gvfs de [extra], no contra GNOME.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

command -v curl    >/dev/null || { echo "falta curl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "falta python3" >&2; exit 1; }

local_ver() {
  # pkgver del PKGBUILD sin ejecutarlo entero
  grep -m1 '^pkgver=' "${REPO_ROOT}/packages/$1/PKGBUILD" | cut -d= -f2
}

gnome_latest() {
  # Sin red o con la URL cambiada: imprime '?' en vez de un traceback.
  curl -fsSL --max-time 30 "https://download.gnome.org/sources/$1/cache.json" 2>/dev/null | python3 -c '
import json, sys

mod = sys.argv[1]
data = json.load(sys.stdin)

# El formato de cache.json ha cambiado entre versiones: el modulo puede estar
# en distintos indices y las versiones venir como lista o como dict. Se busca
# en todos los elementos que sean dict.
versions = None
for entry in data:
    if isinstance(entry, dict) and mod in entry:
        value = entry[mod]
        if isinstance(value, dict):
            versions = list(value.keys())
        elif isinstance(value, list):
            versions = [v for v in value if isinstance(v, str)]
        if versions:
            break

if not versions:
    print("?")
    sys.exit(0)

def key(v):
    out = []
    for part in v.split("."):
        out.append((0, int(part)) if part.isdigit() else (1, 0))
    return out

print(sorted(versions, key=key)[-1])
' "$1" 2>/dev/null || echo "?"
}

gitlab_latest() {
  # $1 = proyecto url-encoded, p.ej. World%2Fdeja-dup
  curl -fsSL --max-time 30 "https://gitlab.gnome.org/api/v4/projects/$1/repository/tags?per_page=20" 2>/dev/null \
    | python3 -c '
import json, sys, re
tags = json.load(sys.stdin)
def key(name):
    return [int(x) for x in re.findall(r"\d+", name)] or [0]
names = [t["name"].lstrip("v") for t in tags if re.match(r"^v?\d", t["name"])]
print(sorted(names, key=key)[-1] if names else "?")
' 2>/dev/null || echo "?"
}

report() {
  local pkg="$1" local_v="$2" up_v="$3"
  if [[ "$local_v" == "$up_v" ]]; then
    printf '%-12s %-10s %sal dia%s\n' "$pkg" "$local_v" "$C_OK" "$C_OFF"
  else
    printf '%-12s %-10s %shay %s upstream%s\n' "$pkg" "$local_v" "$C_WARN" "$up_v" "$C_OFF"
  fi
}

# libsoup: upstream publica la serie 3.x, que NO sirve aqui (libgdata necesita
# la 2.4). Solo cuenta como novedad un 2.74.x nuevo.
gnome_latest_series() {
  curl -fsSL --max-time 30 "https://download.gnome.org/sources/$1/cache.json" 2>/dev/null | python3 -c '
import json, sys, re
mod, pref = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
versions = None
for entry in data:
    if isinstance(entry, dict) and mod in entry:
        value = entry[mod]
        versions = list(value.keys()) if isinstance(value, dict) else [v for v in value if isinstance(v, str)]
        if versions:
            break
versions = [v for v in (versions or []) if v.startswith(pref)]
if not versions:
    print("?"); sys.exit(0)
key = lambda v: [int(x) if x.isdigit() else 0 for x in v.split(".")]
print(sorted(versions, key=key)[-1])
' "$1" "$2" 2>/dev/null || echo "?"
}

# gvfs-google NO sigue a GNOME: sigue al gvfs de [extra], porque enlaza contra
# su libgvfscommon.so. Comparar con la ultima de GNOME solo genera ruido.
arch_repo_ver() {
  LC_ALL=C pacman -Si "$1" 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' | cut -d- -f1 || echo "?"
}

printf '%-12s %-10s %s\n' "PAQUETE" "LOCAL" "ESTADO"
report libsoup2    "$(local_ver libsoup2)"    "$(gnome_latest_series libsoup 2.74)"
report libgdata    "$(local_ver libgdata)"    "$(gnome_latest libgdata)"
report gvfs-google "$(local_ver gvfs-google)" "$(arch_repo_ver gvfs)"
report deja-dup    "$(local_ver deja-dup)"    "$(gitlab_latest 'World%2Fdeja-dup')"


# ############################################################################
# EL AVISO QUE DE VERDAD IMPORTA
#
# gvfs-google fija `depends=(gvfs=<pkgver>)` porque enlaza contra la
# libgvfscommon.so del gvfs del sistema, que NO tiene soname versionado.
# El dia que Arch suba gvfs, `pacman -Syu` se planta con un conflicto de
# dependencias hasta que reconstruyas. Esto lo detecta ANTES.
# ############################################################################

gvfs_pin_check() {
  local pin repo_v inst_v
  pin="$(local_ver gvfs-google)"
  # LC_ALL=C: la etiqueta es 'Version' en cualquier idioma. `|| true`: con
  # set -e y pipefail, un pacman que falle mataria el script en silencio.
  repo_v="$(LC_ALL=C pacman -Si gvfs 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' | cut -d- -f1 || true)"
  inst_v="$(pacman -Q gvfs 2>/dev/null | awk '{print $2}' | cut -d- -f1 || true)"

  echo
  printf '%-22s %s\n' "pin en gvfs-google:" "${pin:-?}"
  printf '%-22s %s\n' "gvfs instalado:"     "${inst_v:-no instalado}"
  printf '%-22s %s\n' "gvfs en [extra]:"    "${repo_v:-?}"

  if [[ -z "$repo_v" || -z "$pin" ]]; then
    printf '%s!! no se pudo comparar%s\n' "$C_WARN" "$C_OFF"
    return
  fi

  if [[ "$pin" == "$repo_v" ]]; then
    printf '%s== el pin coincide con [extra]: nada que hacer%s\n' "$C_OK" "$C_OFF"
  else
    printf '%s!! ACCION REQUERIDA: Arch tiene gvfs %s y tu pin es %s%s\n' \
      "$C_ERR" "$repo_v" "$pin" "$C_OFF"
    cat <<AVISO
   Un \`pacman -Syu\` va a FALLAR con un conflicto de dependencias.
   Antes de actualizar el sistema:
     1) edita packages/gvfs-google/PKGBUILD -> pkgver=$repo_v, pkgrel=1
     2) cd packages/gvfs-google && updpkgsums && makepkg -si
   Detalles en docs/mantenimiento.md
AVISO
  fi
}

# ############################################################################
# LA FECHA DE CADUCIDAD DEL PROYECTO
#
# En gvfs 1.60.2 la opcion de meson es:
#   option('google', type: 'boolean', value: false, deprecated: true)
# Esta marcada como deprecated. El dia que la borren, gvfs-google deja de poder
# construirse y este repo se acaba. Mejor enterarse aqui que en un build roto.
# ############################################################################

google_option_check() {
  local v opts
  v="$(LC_ALL=C pacman -Si gvfs 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' | cut -d- -f1 || true)"
  [[ -z "$v" ]] && return

  opts="$(curl -fsSL --max-time 20 \
    "https://gitlab.gnome.org/GNOME/gvfs/-/raw/${v}/meson_options.txt" 2>/dev/null || true)"

  echo
  if [[ -z "$opts" ]]; then
    printf '%s?? no se pudo leer meson_options.txt de gvfs %s%s\n' "$C_WARN" "$v" "$C_OFF"
  elif ! grep -q "^option('google'" <<<"$opts"; then
    printf '%s!! la opcion `google` YA NO EXISTE en gvfs %s%s\n' "$C_ERR" "$v" "$C_OFF"
    echo "   Fin del camino: gvfsd-google no se puede construir contra esa version."
    echo "   Opciones: quedarte en la version actual, o migrar a rclone."
    echo "   Ver docs/estado-upstream.md"
  elif grep -q "^option('google'.*deprecated" <<<"$opts"; then
    printf '%s~~ la opcion `google` sigue en gvfs %s, pero marcada DEPRECATED%s\n' "$C_WARN" "$v" "$C_OFF"
    echo "   Funciona, pero upstream ya avisa. Vigila esto en cada bump."
  else
    printf '%s== la opcion `google` sigue viva en gvfs %s%s\n' "$C_OK" "$v" "$C_OFF"
  fi
}

echo
echo "--- gvfs: pin y opcion google -------------------------------------------"
gvfs_pin_check
google_option_check


# ############################################################################
# EL FALLO SILENCIOSO
#
# gnome-online-accounts de este repo sombrea al oficial de Arch. Cuando Arch
# publica una version nueva, pacman instala la suya, el scope de Drive
# desaparece y Nautilus empieza a dar "Permiso denegado" SIN mas explicacion.
#
# Esto no compara versiones: comprueba si el binario instalado pide de verdad
# el permiso, que es lo unico que importa.
# ############################################################################

goa_drive_check() {
  echo
  if ! pacman -Qq gvfs-google >/dev/null 2>&1; then
    printf '%s-- gvfs-google no instalado, se omite%s\n' "$C_DIM" "$C_OFF"
    return
  fi

  # `grep -q` cierra la tuberia y con `pipefail` eso cuenta como fallo:
  # por eso se vuelca a una variable antes de buscar.
  # grep -a lee el binario sin depender de binutils; el patron exige 'drive'
  # seguido de espacio o fin de linea (no vale drive.file ni drive.readonly).
  if find /usr/lib -maxdepth 1 -name 'libgoa-backend-1.0.so*' -type f \
       -exec grep -aqE 'googleapis\.com/auth/drive( |$)' {} + 2>/dev/null; then
    printf '%s== GOA pide el scope de Drive: Nautilus puede montar%s\n' "$C_OK" "$C_OFF"
  else
    printf '%s!! GOA YA NO PIDE EL SCOPE DE DRIVE%s\n' "$C_ERR" "$C_OFF"
    cat <<'AVISO'
   Arch ha reinstalado su gnome-online-accounts encima del nuestro.
   Google Drive va a fallar con "Permiso denegado".

   Arreglo (docs/mantenimiento.md, Regla n.4):
     1) pacman -Si gnome-online-accounts        # version que tiene Arch
     2) packages/gnome-online-accounts/PKGBUILD: mismo pkgver, pkgrel MAYOR
        que el de Arch, y el b2sum del PKGBUILD oficial de Arch
     3) cd packages/gnome-online-accounts && makepkg -si

   Si tras reinstalar sigue fallando, la cuenta necesita reautorizarse:
   Configuracion -> Cuentas en linea -> quitar y volver a anadir Google.
AVISO
  fi
}

echo
echo "--- gnome-online-accounts: permiso de Drive -----------------------------"
goa_drive_check

cat <<'EOF'

Si hay novedades: edita pkgver, pon pkgrel=1, ejecuta `updpkgsums` dentro de
la carpeta del paquete y reconstruye. Detalles en docs/mantenimiento.md

Para saber de que repo puede salir hoy cada paquete: ./scripts/check-sources.sh
EOF
