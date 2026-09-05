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
    # namcap sale siempre con 0: hay que mirar si imprime errores (lineas "E:").
    _out="$(namcap "$pkgbuild" 2>&1 || true)"
    [[ -n "$_out" ]] && printf '%s\n' "$_out" | sed 's/^/    /'
    if grep -qE '^[^ ]+ E: ' <<<"$_out"; then
      echo "    namcap: ERRORES"
      STATUS=1
    fi
  else
    echo "    namcap no instalado, se omite (pacman -S namcap)"
  fi
done

exit "$STATUS"
