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

set -eEuo pipefail
export LC_ALL=C   # los mensajes de git/pacman se comparan en ingles

CONF=/etc/drive-gekko-gnome.conf
REPO=""; USER_=""; FORCE=0; PULL=1; DRY=0; AVISO=0
[[ -r "$CONF" ]] && . "$CONF"    # define REPO y USER_
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --user) USER_="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-pull) PULL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --aviso-de-fallo) AVISO=1; shift ;;   # lo llama ExecStopPost de la unidad
    *) echo "opcion desconocida: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$REPO" ]] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "$USER_" ]] || USER_="$(stat -c %U "$REPO")"

# Los helpers van AQUI, antes de la primera comprobacion: el fallo mas probable
# de todos (el clon movido) ocurre unas lineas mas abajo, y con die() definido
# despues aquello salia con "die: orden no encontrada" y rc=127.
log()  { printf '[drive-gekko] %s\n' "$*"; }
# Ningun fallo en silencio: con set -e, un error sin mensaje seria invisible
# en el journal. Y que se entere el usuario, no solo el journal. Hace falta el
# -E de la linea 29 para que el trap salte tambien DENTRO de run() y as_user(),
# que es donde fallan pacman, mkdir, cp y el sello; alli $BASH_COMMAND vale
# literalmente "$@", asi que sin la linea de la llamada y el nombre de la
# funcion el mensaje no diria nada de nada.
on_err() {
  local f="${FUNCNAME[1]:-main}" donde="la linea $1"
  [[ "$f" == main ]] || donde="la linea $2 (dentro de $f(), linea $1)"
  log "abortado en $donde (ultimo comando: $3)"
  notificar "Drive-Gekko-Gnome: fallo al actualizar" "local-repo.sh abortado en $donde (journalctl -u drive-gekko-repo)"
}
trap 'on_err "$LINENO" "${BASH_LINENO[0]}" "$BASH_COMMAND"' ERR
die()  { log "ERROR: $*"; notificar "Drive-Gekko-Gnome: fallo al actualizar" "$*"; exit 1; }
as_user() { if [[ $EUID -eq 0 ]]; then runuser -u "$USER_" -- "$@"; else "$@"; fi; }
run() { if (( DRY )); then log "(dry-run) $*"; else "$@"; fi; }

notificar() {
  # Avisar es lo accesorio: si el USER_ de la conf ya no existe, esto no puede
  # tumbar ni el mensaje de error que lo llama ni una pasada que fue bien.
  local uid; uid="$(id -u "$USER_" 2>/dev/null)" || return 0
  [[ -S "/run/user/$uid/bus" ]] || return 0
  runuser -u "$USER_" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    notify-send -u normal -i drive-harddisk -a "Drive-Gekko-Gnome" "$1" "$2" 2>/dev/null || true
}

# Lo invoca ExecStopPost de drive-gekko-repo.service, y es el unico aviso
# posible cuando el script no llega a contarlo el mismo: un OOM, un SIGKILL o
# el TimeoutStartSec de la unidad lo matan sin que el trap ERR llegue a correr.
if (( AVISO )); then
  res="${SERVICE_RESULT:-success}"
  if [[ "$res" != success ]]; then
    log "la unidad termino con resultado $res (codigo ${EXIT_CODE:-?}/${EXIT_STATUS:-?})"
    notificar "Drive-Gekko-Gnome: fallo al actualizar" "El servicio termino con '$res'. Mira: journalctl -u drive-gekko-repo -b"
  fi
  exit 0
fi

[[ -d "$REPO/packages" ]] || die "el clon ya no esta en $REPO. Si lo has movido, pacman sigue apuntando ahi" \
  "y no puede sincronizar NADA: corrige REPO en $CONF y vuelve a ejecutar" \
  "'sudo <clon>/scripts/add-repo.sh --local <clon>/out'"
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
# La huella son las recetas, pero con ellas no basta: si a out/ le falta un
# paquete o la .db (un borrado a mano, un disco lleno, una pasada que aborto a
# medias) y ningun PKGBUILD ha cambiado, saltarse el trabajo deja la .db
# prometiendo ficheros que ya no estan, y eso aborta el `pacman -Syu` de TODA
# la maquina, cuatro veces al dia y para siempre. Lo publicado tambien decide.
publicado() {
  local p m
  for p in "${ORDER[@]}"; do m=("$OUT/$p"-*.pkg.tar.zst); [[ -f "${m[0]}" ]] || return 1; done
  m=("$OUT"/*.db); [[ -f "${m[0]}" ]]
}
fp="$(for p in "${ORDER[@]}"; do cat "$REPO/packages/$p/PKGBUILD"; done | sha256sum | cut -c1-16)"
if (( ! FORCE )) && [[ -r "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$fp" ]]; then
  if publicado; then
    log "sin cambios en los PKGBUILD desde la ultima construccion ($fp): nada que hacer"
    exit 0
  fi
  log "los PKGBUILD no cambiaron, pero en $OUT falta algo de lo ya publicado: reconstruyendo"
else
  log "los PKGBUILD cambiaron (o --force): construyendo la cadena"
fi

# 3. makedepends (como root, --needed: si ya estan, no toca nada) -------------
# SOLO makedepends, nunca depends: gvfs y gvfs-goa son dependencias en tiempo
# de ejecucion pineadas a [extra]; un `pacman -S gvfs` aqui haria una
# actualizacion parcial a escondidas. Esas las instala el -Syu del usuario.
# libgoa NO entra en esa lista negra: viene de [extra], no lleva pin y hace
# falta para COMPILAR (goa-1.0), asi que si un PKGBUILD lo declara en
# makedepends tiene que instalarse o el build muere en meson.
srcinfo() { ( cd "$REPO/packages/$1" && as_user makepkg --printsrcinfo 2>/dev/null ); }
# Semilla: fakeroot y debugedit no estan en ningun makedepends y makepkg aborta
# sin ellos, asi que el temporizador tiene que garantizarlos el tambien.
deps=(base-devel)
for p in "${ORDER[@]}"; do
  while read -r d; do [[ -n "$d" ]] && deps+=("$d"); done < <(
    srcinfo "$p" | awk -F' = ' '/^\tmakedepends = /{print $2}' | sed -E 's/[<>=].*//' \
    | grep -v '\.so' | grep -vxE 'gvfs|gvfs-goa|gnome-online-accounts|libsoup2|libgdata|gvfs-google' || true)
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
  # -f: si el .pkg.tar.zst de esa misma version sigue en packages/$p —y sigue
  # siempre, porque makepkg lo deja ahi y solo se COPIA a out/— makepkg se niega
  # con "A package has already been built". Sin esto, reconstruir una version
  # que ya se construyo una vez es imposible: revienta --force, revienta la
  # reconstruccion tras vaciar out/, y revienta el reintento del temporizador
  # cuando una pasada anterior murio despues del primer paquete.
  if (( DRY )); then log "(dry-run) makepkg -df --cleanbuild --noconfirm en packages/$p"; continue; fi
  ( cd "$REPO/packages/$p" && as_user makepkg -df --cleanbuild --noconfirm ) \
    || die "no se pudo construir $p: lo mas comun con diferencia es que falte una dependencia de compilacion." \
           "Busca el 'not found' de meson en la salida de arriba, o en 'journalctl -u drive-gekko-repo -b' si" \
           "esto lo lanzo el temporizador"
  mapfile -t files < <(cd "$REPO/packages/$p" && as_user makepkg --packagelist | grep -v -- '-debug-')
  (( ${#files[@]} )) || die "$p: makepkg no genero paquete"
  # Aqui SOLO se copia. Las versiones anteriores se borran despues del bucle,
  # pegadas al repo-add: la .db solo se regenera al final, asi que borrar aqui
  # y morir en un build posterior deja la .db ofreciendo un fichero que ya no
  # existe, y entonces cualquier `pacman -Syu` de la maquina aborta entero con
  # "no se pudo obtener el archivo ... desde disco". Y no se repara solo: el
  # sello tampoco se escribe, asi que el temporizador repite el estado cada 6 h.
  for f in "${files[@]}"; do as_user cp -f "$f" "$OUT/"; built+=("$OUT/$(basename "$f")"); done
  if printf '%s\n' "${INSTALL_NOW[@]}" | grep -qx "$p"; then
    log "instalando $p (no existe en [extra]; hace falta para construir el siguiente)"
    pacman -U --noconfirm "${files[@]}" >/dev/null
  fi
done
(( DRY )) && { log "(dry-run) repo-add en $OUT y aviso"; exit 0; }

# 6. repo local + sello ---------------------------------------------------------
# Los cuatro han salido bien: ahora si, fuera las versiones anteriores. Tiene
# que ser aqui, ANTES de publish-repo.sh: con dos versiones del mismo paquete
# en out/, repo-add las toma en el orden del glob, que es alfabetico (1.60.10
# va antes que 1.60.9); con ese orden borra la vieja del disco (--remove),
# luego no la encuentra, aborta sin escribir la base y deja la .db apuntando
# al fichero que acaba de borrar. Barre ademas lo que dejara una pasada
# anterior que abortase a mitad.
nuevos="$(printf '%s\n' "${built[@]}")"
for p in "${ORDER[@]}"; do
  while IFS= read -r f; do
    grep -qxF "$f" <<<"$nuevos" || as_user rm -f "$f"
  done < <(find "$OUT" -maxdepth 1 -regextype posix-extended -regex ".*/${p}-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst")
done
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
