#!/usr/bin/env bash
# install.sh — instala Google Drive en GNOME sobre Arch, de principio a fin.
#
#   ./install.sh
#
# Que hace:
#   1. instala las herramientas de compilacion (con `pacman -Syu`: en Arch no
#      se instalan paquetes sin actualizar el sistema)
#   2. construye los cuatro paquetes en orden con scripts/local-repo.sh y los
#      deja en un repositorio de pacman LOCAL (out/)
#   3. pone ese repositorio en /etc/pacman.conf, ANTES de [core]
#   4. `pacman -Syu gvfs-google gnome-online-accounts` desde ahi (tu confirmas)
#   5. deja puestos: el temporizador que reconstruye cuando cambien las recetas
#      (drive-gekko-repo.timer), el hook de pacman y el servicio de inicio de
#      sesion que avisan si algo rompe el montaje
#   6. verifica que el resultado sirve de verdad
#
# Los binarios no se publican en GitHub: cada maquina los construye. El bot de
# GitHub Actions mantiene las RECETAS; el temporizador de esta maquina las trae
# (el repo es publico: `git pull` sin credencial) y las construye.
#
# NO ejecutar como root: makepkg lo rechaza. Pide sudo al principio y mantiene
# viva la credencial mientras compila, para no interrumpirte a mitad.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR=/usr/local/lib/drive-gekko-gnome
HOOK_DIR=/etc/pacman.d/hooks
UNIT_DIR=/etc/systemd/system
ME="$(id -un)"

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$Y" "$O" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$O" "$*" >&2; exit 1; }

# base-devel esta aqui por fakeroot y debugedit: makepkg los exige y no los
# arrastra nadie mas (/usr/bin/makepkg lo pone el paquete 'pacman', no
# base-devel), asi que sin el la construccion muere en seco con "Cannot find
# the fakeroot binary." antes de compilar una sola linea. Y gcr es la serie 3,
# la que pide libgdata (meson.build:119, gcr-base-3): en la pila de GNOME solo
# lo arrastra gnome-keyring, asi que un GNOME montado a mano no lo tiene y
# meson corta con 'Dependency "gcr-base-3" not found'.
MAKEDEPS=(base-devel git glib2-devel gobject-introspection meson ninja vala gcr)

# ---------------------------------------------------------------------------
# Comprobaciones previas: mejor parar aqui que a los veinte minutos.
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] && die "no ejecutes esto como root; se pedira sudo cuando haga falta"
command -v sudo    >/dev/null || die "falta sudo"
# Comprobar makepkg no vale de nada: lo instala el paquete 'pacman', asi que la
# condicion se cumple en cualquier Arch. Lo que de verdad falta sin base-devel
# (que hoy es metapaquete, no grupo) es fakeroot; y como el paso 1 lo instala,
# esto es un aviso, no un motivo para parar.
command -v fakeroot >/dev/null || warn "no tienes base-devel (falta fakeroot); el paso 1 lo instalara"
command -v git     >/dev/null || die "falta git:  sudo pacman -S git"
[[ "$ROOT" == "$HOME"/* ]] || warn "el repo no esta en tu HOME; el temporizador construira como '$ME' en $ROOT"

# El paquete 'libsoup' (2.4, del AUR o de cuando estaba en [extra]) conflicta
# con libsoup2. Se mira por NOMBRE: `pacman -Qq libsoup` resolveria el provides
# de libsoup2 y daria falso positivo.
if pacman -Qq 2>/dev/null | grep -qx libsoup; then
  die "tienes instalado el paquete 'libsoup' (2.4). libsoup2 lo sustituye; quitalo primero:
        sudo pacman -Rns libsoup"
fi

info "pidiendo sudo"
sudo -v || die "sin sudo no se puede instalar nada"

# El paso 3 tarda mas que el timeout de sudo, y sin esto el paso 4 vuelve a
# pedir la contrasena a media instalacion. `sudo -n -v` renueva la credencial
# sin ejecutar ningun mandato y sin preguntar jamas; si no puede (sudoers sin
# cache) el bucle muere solo, y no arrastra al script porque va en la condicion
# del while. Todo va a /dev/null por dos motivos: sudo se queja por stderr
# cuando no puede renovar, y sobre todo porque el `sleep` sobrevive huerfano
# hasta 50 s al kill del trap -si conservara la stdout del script, un
# `./install.sh | tee registro.txt` se quedaria colgado ese rato despues de
# haber terminado-.
( while sudo -n -v && kill -0 "$$"; do sleep 50; done ) >/dev/null 2>&1 &
SUDO_KEEP=$!
trap 'kill "$SUDO_KEEP" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# 1. Herramientas. -Syu y no -Sy: en Arch instalar sin actualizar es una
#    actualizacion parcial. Se pide confirmacion: es TU sistema.
# ---------------------------------------------------------------------------
info "actualizando el sistema e instalando herramientas de compilacion"
sudo pacman -Syu --needed "${MAKEDEPS[@]}"
ok "listas"

# ---------------------------------------------------------------------------
# 2. Ficheros del sistema: el actualizador local y las unidades. El paso 3
#    ejecuta local-repo.sh desde LIB_DIR, asi que tiene que estar puesto
#    antes. El hook de pacman no: se arma al final (paso 6), cuando ya hay
#    cadena que vigilar.
# ---------------------------------------------------------------------------
info "instalando el actualizador local y las unidades"
sudo install -Dm755 "${ROOT}/scripts/local-repo.sh"          "${LIB_DIR}/local-repo.sh"
sudo install -Dm755 "${ROOT}/pacman-hooks/post-upgrade-check.sh" "${LIB_DIR}/post-upgrade-check.sh"
sudo install -Dm644 "${ROOT}/systemd/drive-gekko-repo.service" "${UNIT_DIR}/drive-gekko-repo.service"
sudo install -Dm644 "${ROOT}/systemd/drive-gekko-repo.timer"   "${UNIT_DIR}/drive-gekko-repo.timer"
printf 'REPO=%q\nUSER_=%q\n' "$ROOT" "$ME" | sudo tee /etc/drive-gekko-gnome.conf >/dev/null
sudo systemctl daemon-reload
ok "en ${LIB_DIR}, ${UNIT_DIR} y /etc/drive-gekko-gnome.conf"

# ---------------------------------------------------------------------------
# 3. Construir la cadena y dejarla en el repo local out/. local-repo.sh
#    construye como tu usuario, instala libsoup2 y libgdata (no existen en
#    [extra]) y deja gvfs-google y gnome-online-accounts SOLO en el repo:
#    esos los instala pacman en el paso 5, junto con el gvfs/libgoa de Arch.
# ---------------------------------------------------------------------------
info "construyendo la cadena (tarda unos minutos)"
sudo "${LIB_DIR}/local-repo.sh" --repo "$ROOT" --user "$ME" --no-pull --force
ok "repositorio local en ${ROOT}/out"

# ---------------------------------------------------------------------------
# 4. El repo local en pacman.conf, antes de [core].
# ---------------------------------------------------------------------------
info "anadiendo el repositorio local a /etc/pacman.conf"
sudo "${ROOT}/scripts/add-repo.sh" --local "${ROOT}/out"

# ---------------------------------------------------------------------------
# 5. Instalar desde el repo. Sin --noconfirm: veras la transaccion. Y sin
#    --needed: gnome-online-accounts 3.58.x-N.1 sustituye al de Arch.
# ---------------------------------------------------------------------------
info "instalando gvfs-google y gnome-online-accounts desde el repositorio local"
sudo pacman -Syu gvfs-google gnome-online-accounts \
  || die "pacman no pudo instalar. Hay dos causas frecuentes y su propio error las distingue:
      - habla de 'gvfs=X': Arch acaba de subir gvfs y la receta aun no la ha
        seguido el bot. Espera al siguiente run (cada 8 h) o lanzalo en GitHub
        (Actions -> sync-upstream -> Run workflow); luego 'git pull' en este
        clon y repite ./install.sh
      - habla de no poder abrir o leer la base de datos o un fichero del repo
        ('could not open file', 'no se pudo obtener el archivo'): pacman
        descarga como el usuario alpm y tu HOME es 0700, asi que no puede
        entrar a leer ${ROOT}/out. Lo repara volver a ejecutar:
          sudo ${ROOT}/scripts/add-repo.sh --local ${ROOT}/out
      Hasta que se arregle, el bloque [drive-gekko-gnome] que ya esta en
      /etc/pacman.conf hace fallar cualquier 'pacman -Sy' (tambien el paso 1 de
      este script si lo relanzas). Son cinco lineas seguidas; se quitan con:
        sudo sed -i '/^# Drive-Gekko-Gnome:/,+4d' /etc/pacman.conf
      y add-repo.sh dejo al lado una copia previa: /etc/pacman.conf.bak-drive-gekko-*"

info "verificando"
"${ROOT}/scripts/verify-chain.sh" || die "la cadena instalada no verifica; mira los mensajes de arriba"

# ---------------------------------------------------------------------------
# 6. Automatismos: hook de pacman, temporizador (sistema) y comprobacion de
#    login (usuario). El hook se arma AQUI y no en el paso 2: si algo aborta
#    antes de llegar hasta aqui, un hook ya puesto dispara post-upgrade-check.sh
#    en cada 'pacman -S' que toque gvfs o GOA, con notificaciones critical sobre
#    una cadena que nunca se llego a instalar.
# ---------------------------------------------------------------------------
info "armando el hook de pacman y el temporizador de reconstruccion"
sudo install -Dm644 "${ROOT}/pacman-hooks/99-drive-gekko-gnome.hook" "${HOOK_DIR}/99-drive-gekko-gnome.hook"
ok "${HOOK_DIR}/99-drive-gekko-gnome.hook (avisa cuando Arch pise el GOA de este repo)"
sudo systemctl enable --now drive-gekko-repo.timer >/dev/null
ok "drive-gekko-repo.timer (cada 6 h: git pull y, si cambio algo, construir)"

install -Dm644 "${ROOT}/systemd/drive-gekko-check.service" "${HOME}/.config/systemd/user/drive-gekko-check.service"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable drive-gekko-check.service >/dev/null 2>&1 && ok "drive-gekko-check.service (aviso en cada inicio de sesion)" \
  || warn "no se pudo habilitar el servicio de usuario: systemctl --user necesita el bus de tu
      sesion, y por ssh o en una tty pelada no lo hay. El hook de pacman sigue activo; para
      ponerlo, desde tu sesion grafica:  systemctl --user enable drive-gekko-check.service"
"${LIB_DIR}/post-upgrade-check.sh" || true

cat <<FIN

${G}Instalado y verificado.${O} Queda un paso que solo puedes dar tu, en la interfaz:

  1. Abre:  gnome-control-center online-accounts
  2. Si ya tenias una cuenta de Google, ${Y}QUITALA${O} y vuelve a anadirla.
     Es imprescindible: el token que tienes guardado se pidio sin el permiso
     de Drive, y Google no lo amplia de forma retroactiva.
  3. Acepta el permiso de Drive en la pantalla de consentimiento.
  4. Comprueba que en la cuenta aparece el servicio ${C}Archivos${O} activado.

Despues, tu unidad sale en la barra lateral de Nautilus:  ls /run/user/\$(id -u)/gvfs/

El temporizador (${C}drive-gekko-repo.timer${O}, cada 6 h) trae las recetas nuevas por su
cuenta: el repo es publico y su ${C}git pull${O} no necesita ninguna credencial.

FIN
