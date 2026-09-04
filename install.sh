#!/usr/bin/env bash
# install.sh — instala Google Drive en GNOME sobre Arch, de principio a fin.
#
#   ./install.sh
#
# Construye los cuatro paquetes en orden, los instala, y deja puesto el hook de
# pacman que avisa si una actualizacion de Arch rompe el montaje.
#
# NO ejecutar como root: makepkg lo rechaza. Pedira sudo cuando toque.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR=/etc/pacman.d/hooks
LIB_DIR=/usr/local/lib/drive-gekko-gnome

G=$'\033[1;32m'; C=$'\033[1;36m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$O" "$*"; }
die()  { printf '%serror%s %s\n' "$R" "$O" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "no ejecutes esto como root; se pedira sudo cuando haga falta"
command -v makepkg >/dev/null || die "falta el grupo base-devel: sudo pacman -S base-devel"

# El orden importa: libgdata enlaza contra libsoup 2.4, y gvfsd-google contra
# libgdata. Cada uno tiene que estar INSTALADO antes de compilar el siguiente,
# porque hacen falta sus cabeceras.
ORDER=(libsoup2 libgdata gvfs-google gnome-online-accounts)

info "herramientas de compilacion"
sudo pacman -S --needed --noconfirm \
  meson ninja vala glib2-devel gobject-introspection gtk-doc
ok "listas"

for pkg in "${ORDER[@]}"; do
  info "construyendo e instalando ${pkg}"
  ( cd "${ROOT}/packages/${pkg}" && makepkg -si --noconfirm --needed --cleanbuild )
  ok "${pkg}"
done

info "instalando el hook de pacman"
sudo install -Dm755 "${ROOT}/pacman-hooks/post-upgrade-check.sh" \
  "${LIB_DIR}/post-upgrade-check.sh"
sudo install -Dm644 "${ROOT}/pacman-hooks/99-drive-gekko-gnome.hook" \
  "${HOOK_DIR}/99-drive-gekko-gnome.hook"
ok "hook puesto en ${HOOK_DIR}"

# Segunda red de seguridad: el hook avisa en el momento, pero solo si estabas
# mirando la terminal. Esto lo vuelve a comprobar en cada inicio de sesion.
info "instalando la comprobacion de inicio de sesion"
install -Dm644 "${ROOT}/systemd/drive-gekko-check.service" \
  "${HOME}/.config/systemd/user/drive-gekko-check.service"
systemctl --user daemon-reload
systemctl --user enable --now drive-gekko-check.service >/dev/null 2>&1 || true
ok "servicio de usuario activado"

cat <<FIN

${G}Paquetes instalados.${O} Queda un paso que solo puedes dar tu, en la interfaz:

  1. Abre:  gnome-control-center online-accounts
  2. Si ya tenias una cuenta de Google, ${Y}QUITALA${O} y vuelve a anadirla.
     Es imprescindible: el token que tienes guardado se pidio sin el permiso
     de Drive, y Google no lo amplia de forma retroactiva.
  3. Acepta el permiso de Drive en la pantalla de consentimiento.
  4. Comprueba que en la cuenta aparece el servicio ${C}Archivos${O} activado.

Despues, tu unidad sale en la barra lateral de Nautilus. Para verificarlo:

  gio mount "google-drive://TU_CORREO@gmail.com/"
  ls /run/user/\$(id -u)/gvfs/

FIN
