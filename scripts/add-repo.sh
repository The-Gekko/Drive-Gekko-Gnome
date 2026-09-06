#!/usr/bin/env bash
# add-repo.sh — pone el repositorio de este proyecto en /etc/pacman.conf, en
# el sitio correcto, sin duplicarlo, y lo recoloca si esta en mal sitio. De
# paso se asegura de que el usuario con el que pacman descarga pueda leerlo.
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
CONF=/etc/pacman.conf; DRY=0; SERVER=""; DIR=""

# Codifica la ruta para meterla en una URL file://. Quien abre el fichero es
# curl, tambien con file://, y descodifica los %XX antes: el espacio lo rechaza
# de plano ("Malformed input to a URL function") y # y ? le cortan la ruta por
# donde empiezan el fragmento y la consulta. El % va el primero o volveria a
# codificar los que ponemos aqui, y una carpeta llamada "a%20b" acabaria
# apuntando a "a b". La barra invertida no la codifica curl, sino insert_block:
# awk interpreta las secuencias de escape en un "-v var=valor", asi que una
# carpeta llamada "nota\nueva" partiria el "Server =" en dos lineas dentro de
# pacman.conf. Lo demas -acentos, +, &, comas, corchetes- llega literal y
# funciona, asi que se deja legible.
url_ruta() {
  local p="$1"
  p="${p//%/%25}"; p="${p//\\/%5C}"; p="${p// /%20}"
  p="${p//\#/%23}"; p="${p//\?/%3F}"
  p="${p//$'\t'/%09}"; p="${p//$'\r'/%0D}"; p="${p//$'\n'/%0A}"
  printf '%s' "$p"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    # DIR guarda la ruta sin codificar, que es la que hace falta mas abajo para
    # los permisos. Se vuelve absoluta: pacman no resuelve relativas en file://.
    --local) DIR="${2:?}"; [[ "$DIR" == /* ]] || DIR="$PWD/$DIR"
             SERVER="file://$(url_ruta "$DIR")"; shift 2 ;;
    --server) SERVER="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --file) CONF="${2:?}"; shift 2 ;;
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$SERVER" ]] || { echo "falta --local DIR (o --server URL)" >&2; exit 1; }
[[ -r "$CONF" ]] || { echo "no puedo leer $CONF" >&2; exit 1; }

# PERMISOS: pacman NO lee los repositorios como root. Baja privilegios al
# usuario de DownloadUser (de fabrica "alpm", uid 970) y lo hace TAMBIEN con
# los repos file://. Si el clon cuelga de un HOME con el 0700 de fabrica de
# /etc/login.defs, ese usuario no puede ni atravesarlo: el "pacman -Sy" falla
# entero y, como el bloque ya quedo escrito, la maquina se queda sin poder
# instalar ni actualizar nada hasta que alguien lo quita a mano. Por eso se
# mira ANTES de tocar pacman.conf, y se mira de verdad, ejecutando como ese
# usuario: los bits del modo no cuentan toda la historia (puede haber ACL ya
# puestas, o un montaje que no las respete).
acceso_repo_local() {
  local dl d otro="" rc=0 i
  local -a subida=() prueba=()

  # pacman-conf devuelve 0 y nada cuando la directiva no esta, y 1 cuando no
  # sabe leer la conf. Sin distinguirlos, un fichero que pacman no parsea
  # apagaria esta comprobacion en silencio.
  dl="$(pacman-conf --config "$CONF" DownloadUser 2>/dev/null)" || {
    echo "aviso: pacman-conf no sabe leer $CONF, asi que no puedo averiguar con que usuario descarga pacman" >&2
    return 0; }
  [[ -n "$dl" ]] || return 0          # sin DownloadUser pacman lee como root: nada que conceder
  id -u "$dl" >/dev/null 2>&1 || {
    echo "aviso: $CONF pone DownloadUser = $dl, que no existe como usuario; no toco permisos" >&2
    return 0; }
  [[ -d "$DIR" ]] || {
    echo "aviso: $DIR no existe todavia; vuelve a lanzar esto cuando lo construyas, para dar acceso a '$dl'" >&2
    return 0; }

  # Si la .db aun no esta (esto puede ejecutarse antes del primer build) basta
  # con poder atravesar el directorio: repo-add la crea legible (umask 022).
  prueba=(test -r "${DIR}/${REPO_NAME}.db")
  [[ -e "${DIR}/${REPO_NAME}.db" ]] || prueba=(test -x "$DIR")

  # Sin root no hay ni runuser ni setfacl: se dice, en vez de dar por bueno
  # algo que no se ha comprobado. Es el caso de --dry-run sin sudo.
  if (( EUID != 0 )); then
    # El mandato que se sugiere repite el --file: sin el mandaria a tocar
    # /etc/pacman.conf a quien solo estaba probando sobre una copia.
    [[ "$CONF" == /etc/pacman.conf ]] || otro=" --file '$CONF'"
    echo "aviso: sin root no puedo comprobar si '$dl' (el usuario con el que descarga pacman) llega a $DIR." >&2
    echo "       Si luego pacman no encuentra la base de datos del repo:  sudo $0 --local '$DIR'$otro" >&2
    return 0
  fi
  runuser -u "$dl" -- "${prueba[@]}" 2>/dev/null && return 0   # ya llega: no se toca ni un permiso
  if (( DRY )); then
    echo "--- '$dl' no puede leer $DIR: de verdad le daria paso (u:$dl:--x) en cada directorio"
    echo "    del camino y lectura (u:$dl:r-X) sobre $DIR ---"
    return 0
  fi
  command -v setfacl >/dev/null || {
    echo "'$dl' no puede leer $DIR y no tengo setfacl (del paquete acl) para arreglarlo" >&2
    return 1; }

  # Esto cambia permisos dentro de tu HOME, asi que se dice en voz alta. Se da
  # el minimo que sirve: paso en los directorios del camino, lectura solo en el
  # repositorio, y ACL por defecto para los paquetes que se copien ahi despues.
  echo "pacman descarga como el usuario '$dl' y ese usuario no puede leer $DIR."
  echo "Le doy acceso de solo lectura con ACL (tu usuario no pierde nada):"
  d="$(dirname "$DIR")"
  while [[ "$d" == /?* ]]; do subida+=("$d"); d="$(dirname "$d")"; done
  # De arriba abajo: mientras el padre no deje pasar, probar el hijo miente y
  # acabariamos poniendo ACL en directorios que ya estaban bien.
  for (( i=${#subida[@]}-1; i>=0; i-- )); do
    d="${subida[i]}"
    runuser -u "$dl" -- test -x "$d" 2>/dev/null && continue
    setfacl -m "u:${dl}:--x" "$d" || { rc=1; continue; }
    echo "  paso    (--x) en $d"
  done
  setfacl -R -m "u:${dl}:r-X" "$DIR" && setfacl -d -m "u:${dl}:r-X" "$DIR" \
    && echo "  lectura (r-X) en $DIR y lo que contenga" || rc=1
  (( rc == 0 )) || { echo "algun setfacl ha fallado sobre $DIR" >&2; return 1; }

  # Lo que decide no es que setfacl no proteste, sino que el usuario lea.
  runuser -u "$dl" -- "${prueba[@]}" 2>/dev/null && return 0
  echo "'$dl' sigue sin leer $DIR con las ACL puestas: mira si el montaje admite ACL" >&2
  return 1
}
if [[ -n "$DIR" ]] && ! acceso_repo_local; then
  echo "no escribo en $CONF: un repositorio que pacman no puede leer tumba TODOS los pacman -Sy" >&2
  exit 1
fi

BLOCK="# Drive-Gekko-Gnome: Google Drive en GNOME. Va ANTES de [core]/[extra] a
# proposito: gnome-online-accounts sombrea al de Arch y pacman elige por orden.
[${REPO_NAME}]
SigLevel = Optional TrustAll
Server = ${SERVER}
"

# Quita un bloque nuestro anterior (desde el comentario o la cabecera hasta la
# siguiente seccion o el final), para reinsertarlo en el sitio correcto.
# Lo que se quita es TODA directiva de dentro del bloque, no solo la lista
# blanca SigLevel/Server/Include de antes: la que se dejaba pasar apagaba el
# skip, asi que ella y el resto del bloque -SigLevel y Server incluidos- se
# imprimian aqui, donde ya no hay cabecera de seccion, y acababan dentro de
# [options]. Con un SigLevel eso es serio, porque en [options] es directiva
# valida -pacman no avisa- y la politica de firmas de TODA la maquina pasa a
# ser Optional TrustAll. Los comentarios ajenos si se conservan: son inocuos
# caiga donde caiga y muchas veces son los del propio pacman.conf de Arch, que
# quedan detras del bloque cuando este esta mal colocado. De lo que se tira se
# avisa por stderr para no perderlo en silencio.
# El bloque solo lo cierra una cabecera de seccion DE VERDAD, con sangria o
# sin ella: para pacman un "#[loquesea]" es un comentario y lo que va detras
# sigue siendo de nuestra seccion, asi que darlo por cierre volveria a soltar
# el SigLevel en [options] -es lo que pasa si alguien desactiva el repo
# comentando su cabecera-.
strip_block() {
  awk -v name="[${REPO_NAME}]" '
    /^# Drive-Gekko-Gnome:/ { skip=1; next }
    $0==name { skip=1; next }
    skip && /^[[:space:]]*\[/ { skip=0; print; next }
    skip && (/^[[:space:]]*$/ || /^# proposito:/ || /^(SigLevel|Server)[[:space:]]*=/) { next }
    skip && /^[[:space:]]*#/ { print; next }
    skip {
      print "aviso: quito de " name " esta linea, que no vuelvo a escribir: " $0 > "/dev/stderr"
      next }
    { print }'
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
else
  # El mensaje dice donde ha quedado de verdad: [core] puede no existir como
  # seccion literal (Include) y entonces va antes de la primera que haya.
  ante="$(grep -E "^\[" <<<"$new" | grep -A1 -xF "[${REPO_NAME}]" | tail -1)"
  if [[ -n "$ante" && "$ante" != "[${REPO_NAME}]" ]]; then donde="antes de ${ante}"; else donde="al final del fichero"; fi
  echo "[$REPO_NAME] anadido a $CONF ${donde} (copia de seguridad al lado). Ahora:  sudo pacman -Syu"
fi
