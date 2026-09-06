#!/usr/bin/env bash
# ci-prepare.sh — deja un contenedor archlinux:base-devel listo para construir.
# Lo usan build.yml y sync-upstream.yml, para que los dos preparen el entorno
# EXACTAMENTE igual. Ejecutar como root, dentro del contenedor.
#

set -euo pipefail

# El keyring de la imagen puede llevar semanas: se refresca antes de nada.
pacman -Sy --noconfirm archlinux-keyring
# base-devel y gcr van nombrados aunque hoy lleguen solos (la imagen trae el
# primero, y --syncdeps arrastraria el segundo al construir libgdata): son
# EXACTAMENTE los dos que le faltaban a la maquina del usuario. base-devel
# aporta fakeroot y debugedit, sin los cuales makepkg aborta en check_software
# antes de compilar; gcr aporta gcr-base-3, que el meson de libgdata exige y
# que en una instalacion GNOME hecha a mano no lo arrastra nadie salvo
# gnome-keyring. Nombrarlos es lo que hace que este contenedor se parezca a
# una maquina real en vez de depender de que la imagen siga tapando el agujero.
#
# gnome-keyring no construye nada: es el proveedor de org.freedesktop.secrets
# contra el que GOA guarda el token, al que en Arch no arrastra nadie (ni
# gnome-session). Es la unica cosa que la comprobacion 4 de
# post-upgrade-check.sh echaria de menos en un contenedor con la cadena entera
# y perfecta, y sin ella el ESTRICTO=1 de build.yml pondria el job en rojo por
# algo que no es un fallo de la cadena.
pacman -Syu --noconfirm base-devel git github-cli pacman-contrib sudo namcap fakeroot \
  meson ninja vala glib2-devel gobject-introspection gcr gnome-keyring

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

# Sin paquetes -debug: solo ocupan. Idempotente (una segunda pasada no toca nada).
grep -qE '^OPTIONS=.*!debug' /etc/makepkg.conf || sed -i -E 's/^(OPTIONS=\(.*[[:space:](])debug([[:space:])])/\1!debug\2/' /etc/makepkg.conf
grep -q '^PACKAGER=' /etc/makepkg.conf || printf 'PACKAGER="Drive-Gekko-Gnome CI <drive-gekko-bot@users.noreply.github.com>"\n' >> /etc/makepkg.conf
