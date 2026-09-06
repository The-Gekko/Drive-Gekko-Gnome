#!/usr/bin/env bash
# post-upgrade-check.sh — lo ejecuta pacman despues de cada transaccion que
# toque gnome-online-accounts, gvfs o gvfs-google. Ver 99-drive-gekko-gnome.hook.
# Tambien lo ejecuta drive-gekko-check.service en cada inicio de sesion grafico.
#
# NO arregla nada por su cuenta: construir paquetes requiere red, tiempo y no
# se hace dentro de una transaccion de pacman. Lo que hace es que la rotura
# sea IMPOSIBLE de no ver, que es justo el problema de este montaje.
#
# Sin dependencias fuera de coreutils + pacman: la comprobacion del scope usa
# `grep -a` sobre el binario, no `strings` (binutils podria no estar).

set -uo pipefail

R=$'\033[1;31m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; O=$'\033[0m'
ROTO=0

# ---------------------------------------------------------------------------
# Contrato de salida: por defecto 0, detecte lo que detecte.
#
# Esto lo lanza un hook PostTransaction, y un codigo distinto de cero solo
# consigue que pacman remate cada actualizacion con "command failed to execute
# correctly" sin decir por que; el aviso ya sale por stdout y por notificacion.
# Con ESTRICTO=1 si devuelve 1 cuando algo esta roto: es lo que hace falta para
# que el CI (build.yml) lo use como una comprobacion de verdad y no de adorno.
# Las DOS salidas del script pasan por aqui.
#
# Antes de poner ese ESTRICTO=1 en build.yml: el contenedor del CI no tiene
# llavero, asi que la comprobacion 4 lo dejaria en rojo hasta que
# scripts/ci-prepare.sh instale gnome-keyring.
# ---------------------------------------------------------------------------
salir() {
  (( ROTO )) && [[ "${ESTRICTO:-0}" == 1 ]] && exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# Aviso en el escritorio.
#
# La salida de un hook de pacman se pierde entre las 200 lineas de un -Syu
# grande. Una notificacion no. Funciona en los dos contextos donde corre este
# script: como root desde el hook, y como usuario desde el servicio de login.
# ---------------------------------------------------------------------------
notificar() {
  local titulo="$1" cuerpo="$2"
  command -v notify-send >/dev/null 2>&1 || return 0

  if [[ $EUID -ne 0 ]]; then
    notify-send -u critical -i drive-harddisk -a "Drive-Gekko-Gnome" \
      "$titulo" "$cuerpo" 2>/dev/null || true
    return 0
  fi

  # Como root: hay que entrar en la sesion grafica de cada usuario. Se detectan
  # por su bus de sesion en /run/user/<uid>/bus, sin depender de parsear
  # la salida de loginctl.
  local d uid nombre
  for d in /run/user/*/; do
    [[ -S "${d}bus" ]] || continue
    uid="$(basename "$d")"
    nombre="$(id -nu "$uid" 2>/dev/null)" || continue
    runuser -u "$nombre" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${d}bus" \
      notify-send -u critical -i drive-harddisk -a "Drive-Gekko-Gnome" \
      "$titulo" "$cuerpo" 2>/dev/null || true
  done
}

# Que hacer, en una linea, para meterlo en la notificacion.
#
# Si gekko esta instalado en el sistema, un comando corto vale mas que dos
# largos. Solo se miran rutas del sistema a proposito: esto tambien corre como
# root desde el hook de pacman, donde el ~/.local/bin del usuario no existe en
# el PATH (si lo tienes ahi: sudo install -m755 gekko /usr/local/bin/gekko).
comando_arreglo() {
  if [[ -x /usr/local/bin/gekko || -x /usr/bin/gekko ]]; then
    printf 'Abre una terminal y ejecuta:  gekko drive'
  else
    printf '%s' "$1"
  fi
}

# ¿Pide GOA el scope de Drive? Se busca 'auth/drive' seguido de espacio o fin
# de linea, para no dar por bueno un scope parcial (drive.file, drive.readonly).
#
# El find se guarda en una variable en vez de encadenar '-exec ... {} +': con
# esa forma, si el -name no casa con nada grep no llega a ejecutarse y find sale
# con 0, o sea que "no hay libreria" se leeria como "si pide Drive", justo al
# reves. Y no es un caso de laboratorio: gvfs-google depende de libgoa, no de
# gnome-online-accounts, asi que quitar GOA dejando el resto es un estado que
# pacman permite -- el mismo que este hook vigila con su Operation = Remove.
# Mismo patron que scripts/verify-chain.sh.
goa_pide_drive() {
  local _goa
  _goa="$(find /usr/lib -maxdepth 1 -name 'libgoa-backend-1.0.so*' -type f 2>/dev/null | head -1)"
  [[ -n "$_goa" ]] || return 1
  grep -aqE 'googleapis\.com/auth/drive( |$)' "$_goa" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 0a. Si el repositorio esta en pacman.conf, tiene que ir ANTES de [extra]
#     (se comprueba antes de nada: aplica aunque gvfs-google no este instalado)
# ---------------------------------------------------------------------------
_pos_repo="$(pacman-conf --repo-list 2>/dev/null | awk '$0=="drive-gekko-gnome"{print NR; exit}')"
_pos_extra="$(pacman-conf --repo-list 2>/dev/null | awk '$0=="extra"{print NR; exit}')"
if [[ -n "$_pos_repo" && -n "$_pos_extra" && "$_pos_repo" -gt "$_pos_extra" ]]; then
  printf '%s  Drive-Gekko-Gnome: el repositorio esta DESPUES de [extra] en pacman.conf%s\n' "$Y" "$O"
  printf '  pacman elige el primer repo que tenga el nombre: instalara el GOA de Arch\n'
  printf '  (sin permiso de Drive) en la proxima actualizacion. Arreglo:\n'
  printf '    sudo <repo>/scripts/add-repo.sh --local <repo>/out   (lo recoloca)\n\n'
  notificar "El repositorio de Drive esta en mal sitio" \
    "En /etc/pacman.conf, [drive-gekko-gnome] debe ir ANTES de [core] y [extra]. $(comando_arreglo 'Ejecuta: sudo <clon>/scripts/add-repo.sh --local <clon>/out')"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 0b. Y tiene que apuntar a un sitio que exista
#
# El Server es la ruta ABSOLUTA del clon, grabada una sola vez por add-repo.sh.
# Si mueves o renombras el clon, ese file:// deja de resolver y falla TODO
# 'pacman -Sy' de la maquina, no solo lo de Drive. Nadie mas lo caza: sin
# transaccion no hay hook, asi que el unico que llega aqui es
# drive-gekko-check.service en el siguiente inicio de sesion.
# ---------------------------------------------------------------------------
_srv="$(pacman-conf --repo=drive-gekko-gnome Server 2>/dev/null | head -1)"
# url_ruta() de add-repo.sh no escapa solo el espacio: tambien %, la barra
# invertida, # y ?. Hay que deshacer LOS CINCO porque este aviso es ROJO y sale
# con notificacion: quedandose en %20, un clon en "50%", en "a#b" o en
# "nota\ueva" disparaba la alarma con el repositorio perfectamente puesto. El
# %25 va el ultimo: si no, una carpeta llamada "a%20b" se leeria como "a b".
_dir="${_srv#file://}"
_dir="${_dir//%20/ }"; _dir="${_dir//%23/#}"; _dir="${_dir//%3F/\?}"
_dir="${_dir//%5C/\\}"; _dir="${_dir//%25/%}"
if [[ -n "$_srv" && "$_srv" == file://* && ! -r "${_dir}/drive-gekko-gnome.db" ]]; then
  printf '%s  Drive-Gekko-Gnome: el repositorio de pacman apunta a la nada%s\n\n' "$R" "$O"
  printf '    Server = %s\n\n' "$_srv"
  printf '  Ahi no hay drive-gekko-gnome.db, asi que cualquier "pacman -Sy" de esta\n'
  printf '  maquina falla entero. Si has movido el clon hay que corregir DOS sitios:\n'
  printf '    sudo <clon>/scripts/add-repo.sh --local <clon>/out   (/etc/pacman.conf)\n'
  printf '    REPO= en /etc/drive-gekko-gnome.conf                 (el temporizador)\n\n'
  notificar "El repositorio de Drive no existe" \
    "pacman busca la base de datos en ${_dir} y ahi no hay nada: hasta que se arregle no se puede actualizar la maquina. Si has movido el clon, ejecuta sudo <clon>/scripts/add-repo.sh --local <clon>/out y corrige REPO= en /etc/drive-gekko-gnome.conf"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 0. Si gvfs-google no esta instalado, esto no incumbe al usuario... salvo que
#    acabe de quitarlo dejando nuestro GOA puesto: entonces un recordatorio.
# ---------------------------------------------------------------------------
if ! pacman -Qq gvfs-google >/dev/null 2>&1; then
  if goa_pide_drive; then
    printf '%s  Drive-Gekko-Gnome: gvfs-google no esta instalado, pero el gnome-online-accounts\n' "$Y"
    printf '  de este repo sigue puesto. Si has quitado gvfs-google para desbloquear una\n'
    printf '  actualizacion de gvfs, reconstruyelo con el pkgver nuevo cuando termines.%s\n' "$O"
  fi
  salir
fi

# ---------------------------------------------------------------------------
# 1. El permiso de Drive en GNOME Online Accounts
#
# Arch compila GOA sin -Dgoogle_files=true. Si pacman acaba de reinstalar el
# GOA oficial encima del nuestro, el scope de Drive desaparece y Drive deja de
# montar SIN ningun mensaje de error en el arranque.
# ---------------------------------------------------------------------------
if ! goa_pide_drive; then
  printf '%s  Drive-Gekko-Gnome: SE PERDIO EL PERMISO DE GOOGLE DRIVE%s\n\n' "$R" "$O"
  printf '  El gnome-online-accounts oficial de Arch acaba de sustituir al\n'
  printf '  nuestro. Ya no pide el scope .../auth/drive, asi que Nautilus va a\n'
  printf '  dar "Permiso denegado" al abrir tu unidad.\n\n'
  printf '  Para arreglarlo:%s\n' "$Y"
  printf '    sudo systemctl start drive-gekko-repo.service   (trae y construye las recetas)\n'
  printf '    sudo pacman -Syu                                (instala desde el repo local)\n'
  printf '    Si aun no hay receta nueva, el bot no ha corrido: docs/automatizacion.md%s\n\n' "$O"
  notificar "Google Drive ha dejado de funcionar" \
    "Arch ha reinstalado gnome-online-accounts y se perdio el permiso de Drive. $(comando_arreglo 'Ejecuta: sudo systemctl start drive-gekko-repo.service && sudo pacman -Syu')"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 2. El pin estricto de gvfs
#
# gvfsd-google enlaza contra libgvfscommon.so y libgvfsdaemon.so, sin soname
# versionado. Por eso gvfs-google fija gvfs a una pkgver exacta.
# ---------------------------------------------------------------------------
_pin="$(LC_ALL=C pacman -Qi gvfs-google 2>/dev/null | sed -n 's/^Depends On.*gvfs=\([0-9.]*\).*/\1/p' | head -1)"
_gvfs="$(pacman -Q gvfs 2>/dev/null | awk '{print $2}' | cut -d- -f1)"

if [[ -n "$_pin" && -n "$_gvfs" && "$_pin" != "$_gvfs" ]]; then
  printf '%s  Drive-Gekko-Gnome: gvfs cambio de version%s\n\n' "$Y" "$O"
  printf '    gvfs instalado : %s\n' "$_gvfs"
  printf '    pin del paquete: %s\n\n' "$_pin"
  printf '  Arreglo: sudo systemctl start drive-gekko-repo.service && sudo pacman -Syu\n'
  printf '  (si el bot aun no ha subido la receta para gvfs %s, espera o lanzalo en Actions)\n\n' "$_gvfs"
  notificar "Google Drive necesita reconstruirse" \
    "gvfs paso a la version ${_gvfs} y gvfs-google esta fijado a ${_pin}. $(comando_arreglo 'Ejecuta: sudo systemctl start drive-gekko-repo.service && sudo pacman -Syu')"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 3. El binario sigue enlazando (por si acaso pacman dejo pasar algo)
# ---------------------------------------------------------------------------
if [[ -x /usr/lib/gvfsd-google ]] && ldd /usr/lib/gvfsd-google 2>/dev/null | grep -q 'not found'; then
  printf '%s  Drive-Gekko-Gnome: gvfsd-google tiene librerias sin resolver:%s\n' "$R" "$O"
  ldd /usr/lib/gvfsd-google | grep 'not found' | sed 's/^/    /'
  printf '\n'
  notificar "Google Drive esta roto" \
    "gvfsd-google ya no encuentra sus librerias. $(comando_arreglo 'Ejecuta: sudo systemctl start drive-gekko-repo.service && sudo pacman -Syu')"
  ROTO=1
fi

# ---------------------------------------------------------------------------
# 4. Hay donde guardar el token de la cuenta
#
# GOA guarda las credenciales con libsecret contra org.freedesktop.secrets, y en
# Arch ese servicio lo aporta gnome-keyring, al que NADIE arrastra como
# dependencia (ni gnome-session). Sin el, las tres comprobaciones de arriba pasan
# y aun asi la cuenta de Google no se puede dar de alta: GOA responde "Failed to
# store credentials in the keyring" y Drive no monta jamas. Se mira el .service
# de D-Bus y no el bus de sesion porque esto corre como root desde el hook.
#
# Se pasa el DIRECTORIO con -r --include y no un glob 'dir/*.service': si el
# glob no casa, bash deja el patron literal y grep se pone a leer la ENTRADA
# ESTANDAR, o sea que el hook colgaria la transaccion de pacman entera. El
# --include ademas descarta un org.freedesktop.secrets.service.pacsave olvidado,
# que declara el Name pero no lo sirve.
# ---------------------------------------------------------------------------
if ! grep -rqsE '^Name[[:space:]]*=[[:space:]]*org\.freedesktop\.secrets' \
       --include='*.service' /usr/share/dbus-1/services/; then
  printf '%s  Drive-Gekko-Gnome: no hay donde guardar el token de la cuenta%s\n\n' "$Y" "$O"
  printf '  Falta un proveedor de org.freedesktop.secrets (el llavero). La cadena esta\n'
  printf '  entera, pero al anadir la cuenta de Google, GOA respondera "Failed to store\n'
  printf '  credentials in the keyring" y la unidad no llegara a montarse. Arreglo:\n'
  printf '    sudo pacman -S --needed gnome-keyring\n\n'
  notificar "Google Drive no puede guardar la sesion" \
    "Falta el llavero (org.freedesktop.secrets): sin el no se puede anadir la cuenta de Google. Ejecuta: sudo pacman -S --needed gnome-keyring"
  ROTO=1
fi

if (( ROTO == 0 )); then
  printf '%s  Drive-Gekko-Gnome: Google Drive sigue operativo.%s\n' "$G" "$O"
fi

salir
