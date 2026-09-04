#!/usr/bin/env bash
# lint.sh — revisa sintaxis y buenas practicas de los PKGBUILD.
#
#   ./scripts/lint.sh
#
# Usa `bash -n` siempre y `namcap` si esta instalado (pacman -S namcap).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

for pkgbuild in "${REPO_ROOT}"/packages/*/PKGBUILD; do
  pkg="$(basename "$(dirname "$pkgbuild")")"
  echo "==> ${pkg}"

  if bash -n "$pkgbuild"; then
    echo "    sintaxis: ok"
  else
    echo "    sintaxis: FALLA"
    STATUS=1
  fi

  if command -v namcap >/dev/null; then
    namcap "$pkgbuild" || STATUS=1
  else
    echo "    namcap no instalado, se omite (pacman -S namcap)"
  fi
done

exit "$STATUS"
