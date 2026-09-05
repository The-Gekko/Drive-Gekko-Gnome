#!/usr/bin/env bash
# install.sh — instala Google Drive en GNOME sobre Arch, de principio a fin.
#
#   ./install.sh               # modo repo (por defecto): anade el repositorio de
#                              # pacman de este proyecto y instala los paquetes
#                              # ya construidos. Rapido, y `pacman -Syu` los
#                              # mantiene al dia.
#   ./install.sh --compilar    # construye los cuatro paquetes aqui, en orden.
#                              # Para quien no quiera depender del repo
#                              # publicado, o para probar un PR.
#
# En los dos casos verifica que el resultado sirve de verdad, y deja puestos el
# hook de pacman y el servicio de inicio de sesion que avisan si una
# actualizacion de Arch rompe el montaje.
#
# NO ejecutar como root: makepkg lo rechaza. Pide sudo una vez al principio.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR=/etc/pacman.d/hooks
LIB_DIR=/usr/local/lib/drive-gekko-gnome
MODE=repo
case "${1:-}" in
  ""|--repo) MODE=repo ;;
  --compilar|--build) MODE=compilar ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "opcion desconocida: $1 (usa --repo o --compilar)" >&2; exit 1 ;;
esac

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }
warn() { printf '%s /!\\%s %s\n' "$Y" "$O" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$O" "$*" >&2; exit 1; }

# El orden importa: libgdata enlaza contra libsoup 2.4, y gvfsd-google contra
# libgdata. Cada uno tiene que estar INSTALADO antes de compilar el siguiente,
# porque hacen falta sus cabeceras. gnome-online-accounts va el ultimo porque
# es el unico que sustituye a un paquete oficial de Arch.
ORDER=(libsoup2 libgdata gvfs-google gnome-online-accounts)

# Todo lo que los cuatro PKGBUILD declaran en makedepends. Se instala de una
# vez, al principio, por dos motivos: una sola contrasena de sudo (makepkg
# usa `sudo -k`, que pediria la contrasena en cada paquete), y que un fallo
# de red aparezca aqui y no a mitad de una compilacion.
MAKEDEPS=(git glib2-devel gobject-introspection meson ninja vala)

# ---------------------------------------------------------------------------
# Comprobaciones previas: mejor parar aqui que a los veinte minutos.
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] && die "no ejecutes esto como root; se pedira sudo cuando haga falta"
command -v sudo    >/dev/null || die "falta sudo"
if [[ $MODE == compilar ]]; then
  command -v makepkg >/dev/null || die "falta el grupo base-devel:  sudo pacman -S base-devel"
  command -v git     >/dev/null || warn "git no esta instalado; se instalara con las herramientas de compilacion"
fi

# libsoup 2.4 del AUR (o de cuando estaba en [extra]) conflicta con libsoup2.
if pacman -Qq libsoup >/dev/null 2>&1; then
  die "tienes instalado el paquete 'libsoup' (2.4). libsoup2 lo sustituye y pacman
      no puede resolver ese conflicto sin preguntar. Quitalo primero:
        sudo pacman -Rns libsoup
      (si algo depende de el, pacman te lo dira; esa dependencia la cubrira libsoup2)"
fi

# gvfs-google fija gvfs a una version exacta. Si [extra] ya la cambio, la
# compilacion del tercer paquete fallaria por dependencias. Aviso claro antes.
_pin="$(grep -m1 '^pkgver=' "${ROOT}/packages/gvfs-google/PKGBUILD" | cut -d= -f2)"
_extra="$(LC_ALL=C pacman -Si gvfs 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' | cut -d- -f1 || true)"
if [[ -n "$_extra" && "$_pin" != "$_extra" ]]; then
  die "gvfs-google esta fijado a gvfs ${_pin}, pero [extra] tiene gvfs ${_extra}.
      Antes de instalar hay que subir el pkgver de packages/gvfs-google/PKGBUILD
      a ${_extra} y regenerar el checksum (updpkgsums). Ver docs/mantenimiento.md, Regla 2."
fi

# ---------------------------------------------------------------------------
info "pidiendo sudo (una sola vez)"
sudo -v || die "sin sudo no se puede instalar nada"

if [[ $MODE == repo ]]; then
  # -------------------------------------------------------------------------
  # MODO REPO: el bloque de pacman.conf (ANTES de [core]: gnome-online-accounts
  # sombrea al de Arch y pacman elige por orden de repos) y los paquetes ya
  # construidos por el CI. libsoup2 y libgdata entran como dependencias.
  # -------------------------------------------------------------------------
  info "anadiendo el repositorio a /etc/pacman.conf"
  sudo "${ROOT}/scripts/add-repo.sh" || die "no se pudo anadir el repositorio (¿esta despues de [core]?)"
  info "instalando desde el repositorio"
  sudo pacman -Syu --noconfirm gvfs-google gnome-online-accounts \
    || die "pacman no pudo instalar. Si dice que gvfs-google requiere un gvfs que
      no esta, es que Arch acaba de subir gvfs y el repo aun no ha publicado el
      paquete nuevo: espera al siguiente run de sync-upstream (cada 4 h) o usa
      ./install.sh --compilar"
else
  # -------------------------------------------------------------------------
  # MODO COMPILAR: construir e instalar, uno a uno.
  #
  # NO se usa `makepkg -si --needed`: con --needed, pacman OMITE nuestro
  # gnome-online-accounts cuando el de Arch ya esta instalado con la misma
  # version. Se construye con makepkg y se instala con `pacman -U` a secas.
  # -------------------------------------------------------------------------
  info "sincronizando repos e instalando herramientas de compilacion"
  sudo pacman -Sy --needed --noconfirm "${MAKEDEPS[@]}"
  ok "listas"
  for pkg in "${ORDER[@]}"; do
    info "construyendo ${pkg}"
    pushd "${ROOT}/packages/${pkg}" >/dev/null
    makepkg -s --noconfirm --cleanbuild
    # --packagelist respeta PKGDEST si el usuario lo tiene en makepkg.conf.
    mapfile -t _built < <(makepkg --packagelist | grep -v -- '-debug-')
    popd >/dev/null
    (( ${#_built[@]} )) || die "${pkg}: makepkg no genero ningun paquete"
    info "instalando ${pkg}"
    sudo pacman -U --noconfirm "${_built[@]}"
    ok "${pkg}"
  done
fi

# ---------------------------------------------------------------------------
# Verificar que lo instalado sirve (mismo script que el CI).
# ---------------------------------------------------------------------------
info "verificando"
"${ROOT}/scripts/verify-chain.sh" || die "la cadena instalada no verifica; mira los mensajes de arriba"

# ---------------------------------------------------------------------------
info "instalando el hook de pacman"
sudo install -Dm755 "${ROOT}/pacman-hooks/post-upgrade-check.sh" \
  "${LIB_DIR}/post-upgrade-check.sh"
sudo install -Dm644 "${ROOT}/pacman-hooks/99-drive-gekko-gnome.hook" \
  "${HOOK_DIR}/99-drive-gekko-gnome.hook"
ok "hook puesto en ${HOOK_DIR}"

# Segunda red de seguridad: el hook avisa en el momento, pero solo si estabas
# mirando la terminal. Esto lo vuelve a comprobar en cada inicio de sesion.
# Se habilita sin --now: la unidad espera 20 s a que arranque el escritorio, y
# aqui no hay motivo para bloquear; la comprobacion se ejecuta directa abajo.
info "instalando la comprobacion de inicio de sesion"
install -Dm644 "${ROOT}/systemd/drive-gekko-check.service" \
  "${HOME}/.config/systemd/user/drive-gekko-check.service"
systemctl --user daemon-reload 2>/dev/null || true
if systemctl --user enable drive-gekko-check.service >/dev/null 2>&1; then
  ok "servicio de usuario habilitado"
else
  warn "no se pudo habilitar el servicio de usuario (¿sesion sin systemd --user?); el hook de pacman sigue activo"
fi
"${LIB_DIR}/post-upgrade-check.sh" || true

cat <<FIN

${G}Paquetes instalados y verificados.${O} Queda un paso que solo puedes dar tu, en la interfaz:

  1. Abre:  gnome-control-center online-accounts
  2. Si ya tenias una cuenta de Google, ${Y}QUITALA${O} y vuelve a anadirla.
     Es imprescindible: el token que tienes guardado se pidio sin el permiso
     de Drive, y Google no lo amplia de forma retroactiva.
  3. Acepta el permiso de Drive en la pantalla de consentimiento.
  4. Comprueba que en la cuenta aparece el servicio ${C}Archivos${O} activado.

Despues, tu unidad sale en la barra lateral de Nautilus. Para verificarlo:

  ls /run/user/\$(id -u)/gvfs/

$( [[ $MODE == repo ]] && printf 'A partir de ahora, %ssudo pacman -Syu%s trae las actualizaciones de estos paquetes.\n' "$C" "$O" )
FIN
