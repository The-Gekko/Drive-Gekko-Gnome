#!/usr/bin/env bash
# ci-prepare.sh — deja un contenedor archlinux:base-devel listo para construir.
# Lo usan build.yml y sync-upstream.yml, para que los dos preparen el entorno
# EXACTAMENTE igual. Ejecutar como root, dentro del contenedor.
#
# Si existe la variable REPO_GPG_KEY (clave privada armored, desde un secreto
# de GitHub), la importa y exporta GPG_KEY_ID para que publish-repo.sh firme.

set -euo pipefail

# El keyring de la imagen puede llevar semanas: se refresca antes de nada.
pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm git github-cli pacman-contrib sudo namcap \
  meson ninja vala glib2-devel gobject-introspection

# makepkg se niega a correr como root.
if ! id builder >/dev/null 2>&1; then
  useradd -m builder
  install -m 0440 /dev/stdin /etc/sudoers.d/builder <<< 'builder ALL=(ALL) NOPASSWD: ALL'
fi
chown -R builder:builder "${GITHUB_WORKSPACE:-.}"

# git dentro del contenedor, sobre un checkout de otro usuario.
git config --global --add safe.directory "${GITHUB_WORKSPACE:-$(pwd)}"
git config --global user.name  "drive-gekko-bot"
git config --global user.email "drive-gekko-bot@users.noreply.github.com"
sudo -u builder git config --global --add safe.directory "${GITHUB_WORKSPACE:-$(pwd)}"

# Sin paquetes -debug: no se publican y solo ocupan.
sed -i 's/^OPTIONS=(\(.*\)debug\(.*\))/OPTIONS=(\1!debug\2)/' /etc/makepkg.conf
printf 'PACKAGER="Drive-Gekko-Gnome CI <drive-gekko-bot@users.noreply.github.com>"\n' >> /etc/makepkg.conf

# Firma opcional.
if [[ -n "${REPO_GPG_KEY:-}" ]]; then
  printf '%s\n' "$REPO_GPG_KEY" | gpg --batch --import
  GPG_KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec/{print $5; exit}')"
  echo "GPG_KEY_ID=$GPG_KEY_ID" >> "${GITHUB_ENV:-/dev/null}"
  echo "firma activada con la clave $GPG_KEY_ID"
else
  echo "sin REPO_GPG_KEY: el repo se publicara SIN firma"
fi
