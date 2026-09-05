#!/usr/bin/env bash
# sync-upstream.sh — mira si hay que actualizar algun PKGBUILD y, si se pide,
# lo actualiza. Es el cerebro de la automatizacion.
#
#   ./scripts/sync-upstream.sh              # solo informa (no toca nada)
#   ./scripts/sync-upstream.sh --apply      # ademas edita los PKGBUILD
#
# Codigo de salida:  0 = nada que hacer
#                   11 = cambios rutinarios (politica 'auto'): el bot construye y publica
#                   10 = cambios que necesitan PR (con --apply ya aplicados)
#                   20 = hace falta una persona: abrir issue (y no tocar PKGBUILD)
# Ademas escribe un resumen legible en $REPORT (por defecto sync-report.md).
#
# QUE VIGILA CADA PAQUETE, Y POR QUE (esto es lo importante):
#
#   gvfs-google            -> el gvfs de Arch [extra]. NUNCA Solus ni GNOME:
#                             gvfsd-google enlaza contra libgvfscommon.so y
#                             libgvfsdaemon.so del gvfs del sistema, sin soname.
#                             El checksum sale del .sha256sum de GNOME.
#   gnome-online-accounts  -> el GOA de Arch [extra] (pkgver Y pkgrel): sombrea
#                             ese paquete y depende de libgoa=<misma version>.
#                             Nuestro pkgrel = el de Arch + 1, para ganar tambien
#                             en `pacman -U`. El b2sum sale del PKGBUILD oficial.
#   libsoup2               -> version: GNOME, solo serie 2.74 (la 3.x no vale).
#                             parches: el rango de cherry-pick del `libsoup` del
#                             AUR (es el PKGBUILD de Arch). Solus no lleva parches.
#   libgdata               -> GNOME. Upstream esta archivado: no saltara nunca,
#                             pero cuesta 3 lineas vigilarlo.
#   Solus (canario)        -> SOLO el bloque `setup:` de sus package.yml. No se
#                             copia nada; si cambian -Dgoogle=true o
#                             -Dgoogle_files=true, una persona tiene que mirarlo.
#
# Necesita: pacman (con los repos sincronizados: `pacman -Sy`), curl, python3.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${REPORT:-${ROOT}/sync-report.md}"
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1

CHANGES=()   # cambios mecanicos aplicables
AUTO=()      # subconjunto de CHANGES que el bot puede publicar sin PR (ver POLITICA)
HUMAN=()     # cosas que necesitan una persona
NOTES=()     # informativo

# POLITICA de auto-merge (la decide el juez de diseno, no este script):
#   auto  = bump rutinario cuya guarda del package() ya demuestra lo que
#           importa: gvfs-google cuando solo cambia el ULTIMO numero de gvfs
#           (el build aborta si no salen los 2 ficheros y el CI hace ldd), y
#           gnome-online-accounts siguiendo a Arch (el build aborta si el
#           binario no pide el scope de Drive).
#   pr    = todo lo demas: cambio de serie (1.60 -> 1.62, 3.58 -> 3.60),
#           libsoup2 (version o parches), libgdata, o cualquier cosa que un
#           snapshot de Solus haya movido. Una persona pulsa Merge.

C=$'\033[1;36m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; O=$'\033[0m'
info() { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
change() { CHANGES+=("$1"); printf '%s  cambio%s %s\n' "$Y" "$O" "$1"; }
auto()   { AUTO+=("$1"); change "$1 [auto]"; }
series() { echo "${1%.*}"; }   # 1.60.2 -> 1.60 ; 3.58.1 -> 3.58
human()  { HUMAN+=("$1");   printf '%s  HUMANO%s %s\n' "$Y" "$O" "$1"; }
note()   { NOTES+=("$1");   printf '     %s\n' "$1"; }

get() { curl -fsSL --max-time 40 "$1" 2>/dev/null; }
pkgvar() { grep -m1 "^$2=" "${ROOT}/packages/$1/PKGBUILD" | cut -d= -f2- | tr -d "'\""; }
arch_ver() { LC_ALL=C pacman -Si "$1" 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}'; }

# edita una variable simple (pkgver=, pkgrel=, _cvecommit=) en un PKGBUILD
set_var() { (( APPLY )) || return 0; sed -i -E "s|^($2=).*|\1$3|" "${ROOT}/packages/$1/PKGBUILD"; }
# sustituye el unico hash de sha256sums=('...') o b2sums=('...')
set_sum() { (( APPLY )) || return 0; sed -i -E "s|^($2=\(')[0-9a-fA-F]+('\))|\1$3\2|" "${ROOT}/packages/$1/PKGBUILD"; }

gnome_sum() { # $1 modulo $2 version -> sha256 del .tar.xz, filtrando por NOMBRE (el .sha256sum tiene varias lineas)
  get "https://download.gnome.org/sources/$1/${2%.*}/$1-$2.sha256sum" | awk -v f="$1-$2.tar.xz" '$2==f{print $1}'
}
gnome_latest() { # $1 modulo $2 prefijo de serie ('' = cualquiera)
  get "https://download.gnome.org/sources/$1/cache.json" | python3 -c '
import json,sys
mod,pref=sys.argv[1],sys.argv[2]
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
vs=None
for e in data:
    if isinstance(e,dict) and mod in e:
        v=e[mod]; vs=list(v.keys()) if isinstance(v,dict) else [x for x in v if isinstance(x,str)]
        if vs: break
vs=[v for v in (vs or []) if v.startswith(pref) and all(p.isdigit() for p in v.split("."))]
if vs: print(sorted(vs,key=lambda v:[int(p) for p in v.split(".")])[-1])' "$1" "$2"
}

# ───────────────────────── gvfs-google ← Arch [extra] ─────────────────────────
info "gvfs-google"
loc="$(pkgvar gvfs-google pkgver)"; ext="$(arch_ver gvfs | cut -d- -f1)"
if [[ -z "$ext" ]]; then human "no se pudo leer la version de gvfs en [extra] (¿pacman -Sy?)"
elif [[ "$loc" == "$ext" ]]; then note "gvfs-google $loc = gvfs $ext en [extra]"
else
  opts="$(get "https://gitlab.gnome.org/GNOME/gvfs/-/raw/${ext}/meson_options.txt" || true)"
  if [[ -z "$opts" ]]; then human "gvfs $ext en [extra] pero no pude leer su meson_options.txt para confirmar que sigue la opcion google"
  elif ! grep -q "^option('google'" <<<"$opts"; then human "gvfs $ext YA NO TIENE la opcion 'google': gvfs-google no se puede construir. Fin del camino (docs/estado-upstream.md)"
  else
    sum="$(gnome_sum gvfs "$ext")"
    if [[ -z "$sum" ]]; then human "gvfs $ext: no pude obtener el sha256 del .sha256sum de GNOME"
    else
      set_var gvfs-google pkgver "$ext"; set_var gvfs-google pkgrel 1; set_sum gvfs-google sha256sums "$sum"
      msg="gvfs-google: $loc -> $ext (sigue al gvfs de [extra]; sha256 del .sha256sum de GNOME)"
      if [[ "$(series "$loc")" == "$(series "$ext")" ]]; then auto "$msg"; else change "$msg (cambio de serie: PR)"; fi
      grep -q "deprecated" <<<"$(grep "^option('google'" <<<"$opts")" && note "la opcion google sigue marcada deprecated en gvfs $ext"
    fi
  fi
fi

# ───────────────────── gnome-online-accounts ← Arch [extra] ─────────────────────
info "gnome-online-accounts"
loc_v="$(pkgvar gnome-online-accounts pkgver)"; loc_r="$(pkgvar gnome-online-accounts pkgrel)"
full="$(arch_ver gnome-online-accounts)"; ext_v="${full%-*}"; ext_r="${full##*-}"
# Regla: nuestro pkgrel = <pkgrel de Arch>.1 (vercmp: 1.1 > 1 y < 2). Gana
# siempre a [extra] en version y nunca colisiona el nombre del fichero en cache.
want_r="${ext_r}.1"
if [[ -z "$full" ]]; then human "no se pudo leer gnome-online-accounts en [extra]"
elif [[ "$loc_v" == "$ext_v" && "$loc_r" == "$want_r" ]]; then note "GOA $loc_v-$loc_r sigue a Arch $full: bien"
else
  if [[ "$loc_v" == "$ext_v" ]]; then
    set_var gnome-online-accounts pkgrel "$want_r"
    auto "gnome-online-accounts: pkgrel $loc_r -> $want_r (Arch publico $full; regla <Arch>.1)"
  else
    pk="$(get 'https://gitlab.archlinux.org/archlinux/packaging/packages/gnome-online-accounts/-/raw/main/PKGBUILD' || true)"
    pk_v="$(grep -m1 '^pkgver=' <<<"$pk" | cut -d= -f2)"; pk_b2="$(grep -m1 '^b2sums=' <<<"$pk" | grep -oE "[0-9a-f]{128}" | head -1)"
    opts="$(get "https://gitlab.gnome.org/GNOME/gnome-online-accounts/-/raw/${ext_v}/meson_options.txt" || true)"
    if [[ "$pk_v" != "$ext_v" ]]; then human "GOA: [extra] tiene $ext_v pero el PKGBUILD git de Arch esta en ${pk_v:-?}; reintentar mas tarde"
    elif [[ -z "$pk_b2" ]]; then human "GOA $ext_v: no pude extraer el b2sum del PKGBUILD oficial de Arch"
    elif [[ -n "$opts" ]] && ! grep -q "^option('google_files'" <<<"$opts"; then human "GOA $ext_v YA NO TIENE la opcion 'google_files': hay que investigar antes de subir"
    else
      set_var gnome-online-accounts pkgver "$ext_v"; set_var gnome-online-accounts pkgrel "$want_r"; set_sum gnome-online-accounts b2sums "$pk_b2"
      msg="gnome-online-accounts: $loc_v-$loc_r -> $ext_v-$want_r (sigue al GOA de [extra]; b2sum del PKGBUILD oficial de Arch)"
      if [[ "$(series "$loc_v")" == "$(series "$ext_v")" ]]; then auto "$msg"; else change "$msg (cambio de serie: PR)"; fi
      [[ -z "$opts" ]] && note "no pude confirmar la opcion google_files en GOA $ext_v (sin acceso a GitLab); el package() del PKGBUILD abortara si no esta"
    fi
  fi
fi

# ───────────── libsoup2 ← GNOME (serie 2.74) + rango de cherry-pick de Arch ─────────────
info "libsoup2"
loc="$(pkgvar libsoup2 pkgver)"; loc_r="$(pkgvar libsoup2 pkgrel)"; loc_c="$(pkgvar libsoup2 _cvecommit)"
up="$(gnome_latest libsoup 2.74)"
aur="$(get 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=libsoup' || true)"
aur_v="$(grep -m1 '^pkgver=' <<<"$aur" | cut -d= -f2)"
aur_c="$(grep -oE 'cherry-pick -n [0-9.]+\.\.[0-9a-f]{7,40}' <<<"$aur" | head -1 | sed 's/.*\.\.//')"
if [[ -z "$up" ]]; then note "sin acceso a GNOME para libsoup (se omite)"
elif [[ "$up" != "$loc" ]]; then
  if [[ "$aur_v" == "$up" ]]; then
    b2="$(grep -A1 '^b2sums=' <<<"$aur" | grep -oE "[0-9a-f]{128}" | head -1)"
    set_var libsoup2 pkgver "$up"; set_var libsoup2 pkgrel 1; [[ -n "$b2" ]] && set_sum libsoup2 b2sums "$b2"
    change "libsoup2: $loc -> $up (GNOME publico 2.74.x nuevo; b2sum del libsoup de Arch/AUR)"
  else human "libsoup $up publicado por GNOME, pero el libsoup del AUR sigue en ${aur_v:-?}: esperar a que Arch lo suba (trae el rango de parches)"
  fi
else note "libsoup2 $loc es la ultima 2.74.x"
fi
if [[ -n "$aur_c" && "$aur_c" != "$loc_c" ]]; then
  # Guarda: el commit tiene que existir en el repositorio de GNOME (no vale
  # cualquier hash que aparezca en un PKGBUILD del AUR).
  if get "https://gitlab.gnome.org/api/v4/projects/GNOME%2Flibsoup/repository/commits/${aur_c}" | grep -q '"id"'; then
    set_var libsoup2 _cvecommit "$aur_c"; set_var libsoup2 pkgrel $((${loc_r%%.*} + 1))
    change "libsoup2: Arch amplio el rango de parches: _cvecommit ${loc_c:0:10} -> ${aur_c:0:10} (pkgrel -> $((${loc_r%%.*}+1)))"
  else human "libsoup2: el AUR apunta al commit ${aur_c:0:10} pero NO existe en gitlab.gnome.org/GNOME/libsoup. No se aplica."
  fi
elif [[ -z "$aur_c" ]]; then note "no pude leer el rango de cherry-pick del AUR (se omite)"
else note "rango de parches de libsoup2 igual al de Arch"
fi

# ───────────────────────────── libgdata ← GNOME ─────────────────────────────
info "libgdata"
loc="$(pkgvar libgdata pkgver)"; up="$(gnome_latest libgdata '')"
if [[ -z "$up" ]]; then note "sin acceso a GNOME para libgdata (se omite)"
elif [[ "$up" != "$loc" ]]; then
  sum="$(gnome_sum libgdata "$up")"
  if [[ -n "$sum" ]]; then set_var libgdata pkgver "$up"; set_var libgdata pkgrel 1; set_sum libgdata sha256sums "$sum"
    change "libgdata: $loc -> $up (¡upstream archivado publico algo!; sha256 de GNOME)"
  else human "libgdata $up en GNOME pero sin .sha256sum legible"; fi
else note "libgdata $loc (archivado upstream: lo esperado)"
fi

# ───────────────────── Solus: canario de flags (no se copia nada) ─────────────────────
info "Solus (canario de flags de compilacion)"
declare -A SOLUS=( [gvfs]=g/gvfs [gnome-online-accounts]=g/gnome-online-accounts [libgdata]=l/libgdata [libsoup]=l/libsoup [deja-dup]=d/deja-dup )
for n in gvfs gnome-online-accounts libgdata libsoup deja-dup; do
  yml="$(get "https://raw.githubusercontent.com/getsolus/packages/main/packages/${SOLUS[$n]}/package.yml" || true)"
  if [[ -z "$yml" ]]; then note "Solus/$n: sin acceso (se omite)"; continue; fi
  now="$(awk '/^setup *:/{f=1;next} f&&/^[a-z]/{f=0} f' <<<"$yml" | sed 's/^[[:space:]]*//' | grep -v '^$' || true)"
  snap="${ROOT}/upstream/solus/${n}.setup"
  if [[ ! -f "$snap" ]]; then (( APPLY )) && printf '%s\n' "$now" > "$snap"; note "Solus/$n: primer snapshot"
  elif [[ "$now" != "$(cat "$snap")" ]]; then
    (( APPLY )) && printf '%s\n' "$now" > "$snap"
    human "Solus cambio el setup de $n. Antes: [$(tr '\n' ' ' < "$snap")]  Ahora: [$(tr '\n' ' ' <<<"$now")]. Revisar si nos afecta (upstream/solus/README.md)"
  else note "Solus/$n: sin cambios en setup:"; fi
done

# ───────────────────────────────── informe ─────────────────────────────────
{
  echo "## Sincronizacion upstream"
  echo
  if (( ${#CHANGES[@]} )); then echo "### Cambios mecanicos"; printf -- '- %s\n' "${CHANGES[@]}"; echo; fi
  if (( ${#CHANGES[@]} )); then
    if (( ${#HUMAN[@]} == 0 && ${#AUTO[@]} == ${#CHANGES[@]} )); then echo "**Politica:** todos rutinarios -> el bot publica sin PR."
    else echo "**Politica:** hay cambios no rutinarios -> PR para que una persona lo mire."; fi; echo
  fi
  if (( ${#HUMAN[@]} ));   then echo "### Necesita una persona"; printf -- '- %s\n' "${HUMAN[@]}"; echo; fi
  echo "### Estado"; printf -- '- %s\n' "${NOTES[@]}"
} > "$REPORT"

echo
# Codigos: 0 nada; 11 cambios todos rutinarios (auto); 10 cambios que van a PR; 20 persona.
if (( ${#HUMAN[@]} ));   then printf '%s=> hace falta una persona (%d)%s\n' "$Y" "${#HUMAN[@]}" "$O"; exit 20; fi
if (( ${#CHANGES[@]} )); then
  printf '%s=> %d cambio(s) mecanico(s)%s%s\n' "$Y" "${#CHANGES[@]}" "$( (( APPLY )) && echo ' aplicados' || echo ' (sin --apply no se ha tocado nada)')" "$O"
  (( ${#AUTO[@]} == ${#CHANGES[@]} )) && exit 11 || exit 10
fi
printf '%s=> todo al dia%s\n' "$G" "$O"; exit 0
