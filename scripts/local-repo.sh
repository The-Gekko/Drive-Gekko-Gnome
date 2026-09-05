#!/usr/bin/env bash
# local-repo.sh — mantiene el repositorio de pacman de ESTA maquina al dia con
# las recetas de git. Los binarios no se publican en GitHub: el bot mantiene
# las RECETAS y cada maquina construye las suyas aqui.
#
#   sudo ./scripts/local-repo.sh                # lo que hace el temporizador
#   sudo ./scripts/local-repo.sh --force        # reconstruir aunque no haya cambios
#   ./scripts/local-repo.sh --dry-run           # solo dice que haria (sin root)
#
# Lo ejecuta drive-gekko-repo.timer (unidad de SISTEMA, como root) cada 6 h:
#   1. git pull como el usuario duenio del clon (usa SU credencial de git)
#   2. si ningun PKGBUILD cambio desde la ultima vez: fin (segundos)
#   3. construye los 4 paquetes como ese usuario (makepkg nunca corre como root)
#   4. libsoup2 y libgdata se instalan ya (no pisan nada de [extra])
#   5. gvfs-google y gnome-online-accounts NO se instalan aqui: van al repo
#      local out/, y el `pacman -Syu` del usuario los instala en la MISMA
#      transaccion que el gvfs/libgoa nuevo de Arch. Asi el pin nunca se
#      salta, y nunca se hace una actualizacion parcial a escondidas.
#   6. avisa en el escritorio de que hay algo que instalar
#
# El usuario y la ruta del clon se leen de /etc/drive-gekko-gnome.conf
# (lo escribe install.sh) o de --user/--repo.
#
# El repo es PUBLICO: el `git pull` no necesita credencial, que es justo lo que
# hace falta aqui (el temporizador corre sin sesion grafica, asi que el llavero
# de GNOME no esta disponible). Si git llegara a pedir usuario, no es que falte
# un token: es que el repo dejo de ser publico o el remoto del clon es ssh.

set -euo pipefail
export LC_ALL=C   # los mensajes de git/pacman se comparan en ingles

CONF=/etc/drive-gekko-gnome.conf
REPO=""; USER_=""; FORCE=0; PULL=1; DRY=0
[[ -r "$CONF" ]] && . "$CONF"    # define REPO y USER_
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --user) USER_="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-pull) PULL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" ]] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "$USER_" ]] || USER_="$(stat -c %U "$REPO")"
[[ -d "$REPO/packages" ]] || { echo "no parece el repo: $REPO" >&2; exit 1; }
if (( ! DRY )) && [[ $EUID -ne 0 ]]; then echo "ejecutalo con sudo (lo hace el temporizador), o con --dry-run" >&2; exit 1; fi

# La copia instalada en /usr/local/lib puede quedarse vieja: si el clon tiene
# una version distinta de este script, se ejecuta la del clon (lo que el bot
# mantiene es el clon).
if [[ -f "$REPO/scripts/local-repo.sh" && "$(readlink -f "$0")" != "$(readlink -f "$REPO/scripts/local-repo.sh")" ]] \
   && ! cmp -s "$0" "$REPO/scripts/local-repo.sh"; then
  args=(--repo "$REPO" --user "$USER_"); (( FORCE )) && args+=(--force); (( PULL )) || args+=(--no-pull); (( DRY )) && args+=(--dry-run)
  exec bash "$REPO/scripts/local-repo.sh" "${args[@]}"
fi

# Una sola ejecucion a la vez (temporizador + manual + install.sh).
if (( ! DRY )); then
  exec 9>/run/lock/drive-gekko-repo.lock
  flock -n 9 || { echo "ya hay una ejecucion de local-repo.sh en curso" >&2; exit 0; }
fi

ORDER=(libsoup2 libgdata gvfs-google gnome-online-accounts)
INSTALL_NOW=(libsoup2 libgdata)          # no existen en [extra]: instalarlos no pisa nada
REPO_ONLY=(gvfs-google gnome-online-accounts)  # pinean gvfs/libgoa: los instala el -Syu del usuario
OUT="$REPO/out"; STAMP="$OUT/.built-from"   # el nombre del repo lo pone publish-repo.sh

log()  { printf '[drive-gekko] %s\n' "$*"; }
# Ningun fallo en silencio: con set -e, un error sin mensaje seria invisible
# en el journal. Y que se entere el usuario, no solo el journal.
trap 'log "abortado en la linea $LINENO (ultimo comando: $BASH_COMMAND)"; notificar "Drive-Gekko-Gnome: fallo al actualizar" "local-repo.sh abortado (journalctl -u drive-gekko-repo)"' ERR
die()  { log "ERROR: $*"; notificar "Drive-Gekko-Gnome: fallo al actualizar" "$*"; exit 1; }
as_user() { if [[ $EUID -eq 0 ]]; then runuser -u "$USER_" -- "$@"; else "$@"; fi; }
run() { if (( DRY )); then log "(dry-run) $*"; else "$@"; fi; }

notificar() {
  local uid; uid="$(id -u "$USER_")"
  [[ -S "/run/user/$uid/bus" ]] || return 0
  runuser -u "$USER_" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    notify-send -u normal -i drive-harddisk -a "Drive-Gekko-Gnome" "$1" "$2" 2>/dev/null || true
}

# 1. pull ---------------------------------------------------------------------
if (( PULL )); then
  log "git pull como $USER_ en $REPO"
  # Resto de una instalacion anterior, cuando el repo era privado. No estorba,
  # pero es un token en disco que ya no pinta nada: mejor decirlo.
  if [[ -e /etc/drive-gekko-gnome.token ]]; then
    log "aviso: /etc/drive-gekko-gnome.token ya no hace falta (el repo es publico); puedes borrarlo"
  fi
  # credential.helper= vacio: desactiva cualquier helper heredado. Uno roto (o
  # el llavero, que aqui no existe) haria fallar un pull que deberia ir solo.
  if ! out="$(as_user env GIT_TERMINAL_PROMPT=0 LC_ALL=C git -c credential.helper= -C "$REPO" pull --ff-only 2>&1)"; then
    if grep -qE 'could not read Username|Authentication failed|terminal prompts disabled|Repository not found' <<<"$out"; then
      die "GitHub pide credencial para un repo que deberia ser publico: comprueba que el repo sigue siendo publico y que 'git -C $REPO remote -v' apunta al https, no al ssh"
    fi
    die "git pull fallo: $(tail -1 <<<"$out")"
  fi
  log "$(tail -1 <<<"$out")"
fi

# 2. ¿cambio algo? ------------------------------------------------------------
fp="$(for p in "${ORDER[@]}"; do cat "$REPO/packages/$p/PKGBUILD"; done | sha256sum | cut -c1-16)"
if (( ! FORCE )) && [[ -r "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$fp" ]]; then
  log "sin cambios en los PKGBUILD desde la ultima construccion ($fp): nada que hacer"
  exit 0
fi
log "los PKGBUILD cambiaron (o --force): construyendo la cadena"

# 3. makedepends (como root, --needed: si ya estan, no toca nada) -------------
# SOLO makedepends, nunca depends: gvfs, gvfs-goa y libgoa son dependencias en
# tiempo de ejecucion pineadas a [extra]; un `pacman -S gvfs` aqui haria una
# actualizacion parcial a escondidas. Esas las instala el -Syu del usuario.
srcinfo() { ( cd "$REPO/packages/$1" && as_user makepkg --printsrcinfo 2>/dev/null ); }
deps=()
for p in "${ORDER[@]}"; do
  while read -r d; do [[ -n "$d" ]] && deps+=("$d"); done < <(
    srcinfo "$p" | awk -F' = ' '/^\tmakedepends = /{print $2}' | sed -E 's/[<>=].*//' \
    | grep -v '\.so' | grep -vxE 'gvfs|gvfs-goa|libgoa|gnome-online-accounts|libsoup2|libgdata|gvfs-google' || true)
done
mapfile -t deps < <(printf '%s\n' "${deps[@]}" | grep -v '^$' | sort -u || true)
if (( ${#deps[@]} )); then
  log "makedepends: ${deps[*]}"
  run pacman -S --needed --noconfirm "${deps[@]}"
fi

# 4/5. construir en orden ------------------------------------------------------
run mkdir -p "$OUT"; run chown "$USER_" "$OUT" 2>/dev/null || true
built=()
for p in "${ORDER[@]}"; do
  log "construyendo $p"
  # -d: las dependencias en tiempo de ejecucion (gvfs=X, libgoa=X) pueden no
  # estar aun instaladas A PROPOSITO; las makedepends ya se han instalado arriba.
  if (( DRY )); then log "(dry-run) makepkg -d --cleanbuild --noconfirm en packages/$p"; continue; fi
  ( cd "$REPO/packages/$p" && as_user makepkg -d --cleanbuild --noconfirm ) \
    || die "no se pudo construir $p (mira el journal: journalctl -u drive-gekko-repo)"
  mapfile -t files < <(cd "$REPO/packages/$p" && as_user makepkg --packagelist | grep -v -- '-debug-')
  (( ${#files[@]} )) || die "$p: makepkg no genero paquete"
  # Fuera las versiones anteriores de ESTE paquete en out/: si quedaran dos,
  # repo-add podria quedarse con la vieja (ordena por nombre, no por version:
  # 1.60.10 va antes que 1.60.9) y borrar la nueva.
  as_user find "$OUT" -maxdepth 1 -regextype posix-extended -regex ".*/${p}-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst" -delete
  for f in "${files[@]}"; do as_user cp -f "$f" "$OUT/"; built+=("$OUT/$(basename "$f")"); done
  if printf '%s\n' "${INSTALL_NOW[@]}" | grep -qx "$p"; then
    log "instalando $p (no existe en [extra]; hace falta para construir el siguiente)"
    pacman -U --noconfirm "${files[@]}" >/dev/null
  fi
done
(( DRY )) && { log "(dry-run) repo-add en $OUT y aviso"; exit 0; }

# 6. repo local + sello ---------------------------------------------------------
# publish-repo.sh: lista blanca, repo-add, y prueba de que pacman lee la .db
OUT="$OUT" as_user "$REPO/scripts/publish-repo.sh" --check >/dev/null || die "el repo local no verifica (scripts/publish-repo.sh --check)"
as_user bash -c "printf '%s\n' '$fp' > '$STAMP'"
log "repo local actualizado en $OUT"

pend=()
for p in "${REPO_ONLY[@]}"; do
  v="$(srcinfo "$p" | awk -F' = ' '/^\tpkgver/{v=$2} /^\tpkgrel/{r=$2} END{print v"-"r}')"
  [[ "$(pacman -Q "$p" 2>/dev/null | awk '{print $2}')" == "$v" ]] || pend+=("$p $v")
done
if (( ${#pend[@]} )); then
  log "pendiente de instalar con 'sudo pacman -Syu': ${pend[*]}"
  notificar "Google Drive: hay una actualizacion lista" "Ejecuta  sudo pacman -Syu  para instalar: ${pend[*]}"
else
  log "todo instalado y al dia"
fi
