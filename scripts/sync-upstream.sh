#!/usr/bin/env bash
# sync-upstream.sh — mira si hay que actualizar algun PKGBUILD y, si se pide,
# lo actualiza. Es el cerebro de la automatizacion.
#
#   ./scripts/sync-upstream.sh              # solo informa (no toca nada)
#   ./scripts/sync-upstream.sh --apply      # ademas edita los PKGBUILD
#
# Codigo de salida:  0 = nada que cambiar (puede haber avisos)
#                   11 = cambios rutinarios (politica 'auto'): construir y publicar
#                   10 = cambios que necesitan PR (con --apply ya aplicados)
#                   20 = fallo interno inesperado: no fiarse del arbol, abrir issue
# Siempre escribe $REPORT (resumen legible) y $STATE (CODE/CHANGES/AUTO/WARNINGS).
#
# QUE VIGILA CADA PAQUETE, Y POR QUE:
#   gvfs-google            -> el gvfs de Arch [extra]. NUNCA Solus ni GNOME:
#                             gvfsd-google enlaza contra libgvfscommon.so y
#                             libgvfsdaemon.so del gvfs del sistema, sin soname.
#                             Checksum: el .sha256sum de GNOME (por nombre).
#   gnome-online-accounts  -> el GOA de Arch [extra] (pkgver Y pkgrel): sombrea
#                             ese paquete y depende de libgoa=<misma version>.
#                             Nuestro pkgrel = <el de Arch>.1 (vercmp: 1.1 > 1
#                             y < 2). b2sum: el del PKGBUILD oficial de Arch.
#   libsoup2               -> version: GNOME, solo serie 2.74. Parches: el rango
#                             de cherry-pick del libsoup del AUR (PKGBUILD de
#                             Arch), y el commit tiene que estar en la rama
#                             libsoup-2-74 de GNOME. Solus no lleva parches.
#   libgdata               -> GNOME. Archivado: no saltara, pero cuesta poco.
#   Solus (canario)        -> SOLO el bloque setup: de sus package.yml. No se
#                             copia nada; un cambio es un AVISO para una persona,
#                             y no bloquea los bumps rutinarios de los demas.
#
# POLITICA (la fijo el panel de diseno, no este script):
#   auto = bump rutinario cuya guarda del package() ya demuestra lo que importa:
#          gvfs-google cuando cambia solo el ULTIMO numero de gvfs; GOA siguiendo
#          a Arch dentro de la misma serie. Ademas, la version nueva tiene que
#          ser MAYOR (vercmp): un retroceso nunca es rutinario.
#   pr   = todo lo demas: cambio de serie, libsoup2 (version o parches), libgdata.
#
# SEGURIDAD: todo lo que se lee de fuera (AUR, Solus, GNOME, Arch) se VALIDA
# antes de escribirlo en un PKGBUILD: versiones con el alfabeto de pacman,
# hashes hexadecimales de longitud exacta. Nada de eso pasa por un sed sin
# haber pasado antes por una expresion regular estricta.
#
# Necesita: pacman (repos sincronizados: `pacman -Sy`), curl, python3, vercmp.

set -Eeuo pipefail
# Las expresiones regulares [A-Za-z]/[a-f] dependen del locale: en C significan
# exactamente ASCII, que es lo que pacman acepta.
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${REPORT:-${ROOT}/sync-report.md}"
STATE="${STATE:-${ROOT}/sync-state.env}"
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1

CHANGES=(); AUTO=(); WARN=(); NOTES=()

C=$'\033[1;36m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; R=$'\033[1;31m'; O=$'\033[0m'
info()   { printf '%s==>%s %s\n' "$C" "$O" "$*"; }
change() { CHANGES+=("$1"); printf '%s  cambio%s %s\n' "$Y" "$O" "$1"; }
auto()   { AUTO+=("$1"); change "$1 [auto]"; }
warn()   { WARN+=("$1");   printf '%s  AVISO%s  %s\n' "$Y" "$O" "$1"; }
note()   { NOTES+=("$1");  printf '     %s\n' "$1"; }
series() { echo "${1%.*}"; }

write_report() {
  {
    echo "## Sincronizacion upstream"; echo
    if (( ${#CHANGES[@]} )); then echo "### Cambios mecanicos"; printf -- '- %s\n' "${CHANGES[@]}"; echo
      if (( ${#AUTO[@]} == ${#CHANGES[@]} )); then echo "**Politica:** todos rutinarios -> el bot construye y publica sin PR."
      else echo "**Politica:** hay cambios no rutinarios -> PR para que una persona lo mire."; fi; echo; fi
    if (( ${#WARN[@]} )); then echo "### Avisos (necesitan una persona; no bloquean lo rutinario)"; printf -- '- %s\n' "${WARN[@]}"; echo; fi
    echo "### Estado"; printf -- '- %s\n' "${NOTES[@]:-sin datos}"
  } > "$REPORT"
  printf 'CODE=%s\nCHANGES=%s\nAUTO=%s\nWARNINGS=%s\n' "$1" "${#CHANGES[@]}" "${#AUTO[@]}" "${#WARN[@]}" > "$STATE"
}
# Ningun fallo en silencio, y ningun fallo sin informe: un error inesperado
# (red, formato, sed) deja el arbol como este y sale con 20.
on_err() { WARN+=("FALLO INTERNO en la linea $1: $2 (no fiarse de los PKGBUILD editados)"); write_report 20; printf '%s=> fallo interno (20)%s\n' "$R" "$O"; exit 20; }
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# --- helpers: nunca fallan, devuelven vacio si no hay dato -------------------
get()      { curl -fsSL --max-time 40 "$1" 2>/dev/null || true; }
pkgvar()   { grep -m1 "^$2=" "${ROOT}/packages/$1/PKGBUILD" | cut -d= -f2- | tr -d "'\"" || true; }
# SIEMPRE con el prefijo extra/: sin el, en una maquina con el repo local
# delante de [core], `pacman -Si gnome-online-accounts` devolveria NUESTRA
# version primero (3.58.1-1.1) y el bot calcularia pkgrel=1.1.1.
arch_ver() { LC_ALL=C pacman -Si "extra/$1" 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' || true; }
is_ver()   { [[ "$1" =~ ^[0-9][0-9A-Za-z.+_~]*$ ]]; }              # pkgver de pacman (sin '-' ni ':')
is_rel()   { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_int()   { [[ "$1" =~ ^[0-9]+$ ]]; }
is_hex()   { [[ "$1" =~ ^[0-9a-f]+$ && ${#1} -eq $2 ]]; }
newer()    { local r; r="$(vercmp "$1" "$2" 2>/dev/null)" || return 1; [[ "$r" -gt 0 ]]; }   # $1 mas nueva que $2
# Escriben SOLO en la linea que empieza por la variable (los comentarios
# empiezan por '#'). Y comprueban que la linea quedo como se queria: un sed
# que no casa sale con 0 sin tocar nada, y eso aqui es un fallo interno.
set_var()  { (( APPLY )) || return 0; sed -i -E "s|^($2=).*|\1$3|" "${ROOT}/packages/$1/PKGBUILD"; grep -qx "$2=$3" "${ROOT}/packages/$1/PKGBUILD"; }
set_sum()  { (( APPLY )) || return 0; sed -i -E "s|^($2=\(')[0-9a-fA-F]+('\))|\1$3\2|" "${ROOT}/packages/$1/PKGBUILD"; grep -qx "$2=('$3')" "${ROOT}/packages/$1/PKGBUILD"; }
gnome_sum() { get "https://download.gnome.org/sources/$1/${2%.*}/$1-$2.sha256sum" | awk -v f="$1-$2.tar.xz" '$2==f{print $1}' || true; }
gnome_latest() { # $1 modulo, $2 prefijo de serie ('' = cualquiera)
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
if vs: print(sorted(vs,key=lambda v:[int(p) for p in v.split(".")])[-1])' "$1" "$2" 2>/dev/null || true
}
json_field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1" 2>/dev/null || true; }

# ───────────────────────── gvfs-google ← Arch [extra] ─────────────────────────
info "gvfs-google"
loc="$(pkgvar gvfs-google pkgver)"; full="$(arch_ver gvfs)"; ext="${full%-*}"
if [[ -z "$full" ]]; then warn "gvfs: no se pudo leer la version en [extra] (¿pacman -Sy?); se omite"
elif [[ "$full" == *:* ]]; then warn "gvfs en [extra] lleva epoch ($full): el pin 'gvfs=\$pkgver' necesita revisarse a mano"
elif ! is_ver "$ext"; then warn "gvfs: version con formato inesperado en [extra]: '$ext'; se omite"
elif [[ "$loc" == "$ext" ]]; then note "gvfs-google $loc = gvfs $ext en [extra]"
elif ! newer "$ext" "$loc"; then warn "gvfs en [extra] ($ext) es ANTERIOR a nuestro pin ($loc): retroceso; revisar a mano"
else
  opts="$(get "https://gitlab.gnome.org/GNOME/gvfs/-/raw/${ext}/meson_options.txt")"
  sum="$(gnome_sum gvfs "$ext")"
  if [[ -z "$opts" ]] || ! grep -q "^option('" <<<"$opts"; then warn "gvfs $ext en [extra] pero no pude leer un meson_options.txt valido para confirmar la opcion google; no se bumpea"
  elif ! grep -q "^option('google'" <<<"$opts"; then warn "gvfs $ext YA NO TIENE la opcion 'google': gvfs-google no se puede construir. Fin del camino (docs/estado-upstream.md)"
  elif ! is_hex "$sum" 64; then warn "gvfs $ext: no pude obtener un sha256 valido del .sha256sum de GNOME; no se bumpea"
  else
    set_var gvfs-google pkgver "$ext"; set_var gvfs-google pkgrel 1; set_sum gvfs-google sha256sums "$sum"
    msg="gvfs-google: $loc -> $ext (sigue al gvfs de [extra]; sha256 del .sha256sum de GNOME)"
    if [[ "$(series "$loc")" == "$(series "$ext")" ]]; then auto "$msg"; else change "$msg (cambio de serie: PR)"; fi
    grep "^option('google'" <<<"$opts" | grep -q deprecated && note "la opcion google sigue marcada deprecated en gvfs $ext"
  fi
fi

# ───────────────────── gnome-online-accounts ← Arch [extra] ─────────────────────
info "gnome-online-accounts"
loc_v="$(pkgvar gnome-online-accounts pkgver)"; loc_r="$(pkgvar gnome-online-accounts pkgrel)"
full="$(arch_ver gnome-online-accounts)"; ext_v="${full%-*}"; ext_r="${full##*-}"; want_r="${ext_r}.1"
if [[ -z "$full" ]]; then warn "gnome-online-accounts: no se pudo leer [extra]; se omite"
elif [[ "$full" == *:* ]]; then warn "gnome-online-accounts en [extra] lleva epoch ($full): revisar a mano"
elif ! is_ver "$ext_v" || ! is_int "$ext_r" || ! is_rel "$want_r"; then warn "gnome-online-accounts: version con formato inesperado en [extra]: '$full' (el pkgrel de Arch tiene que ser entero); se omite"
elif [[ "$loc_v" == "$ext_v" && "$loc_r" == "$want_r" ]]; then note "GOA $loc_v-$loc_r sigue a Arch $full: bien"
elif ! newer "$ext_v-$want_r" "$loc_v-$loc_r"; then warn "GOA en [extra] ($full) no es mas nuevo que el nuestro ($loc_v-$loc_r): retroceso; revisar a mano"
elif [[ "$loc_v" == "$ext_v" ]]; then
  set_var gnome-online-accounts pkgrel "$want_r"
  auto "gnome-online-accounts: pkgrel $loc_r -> $want_r (Arch publico $full; regla <Arch>.1)"
else
  pk="$(get 'https://gitlab.archlinux.org/archlinux/packaging/packages/gnome-online-accounts/-/raw/main/PKGBUILD')"
  pk_v="$(grep -m1 '^pkgver=' <<<"$pk" | cut -d= -f2 || true)"
  pk_b2="$(grep -m1 '^b2sums=' <<<"$pk" | grep -oE '[0-9a-f]{128}' | head -1 || true)"
  opts="$(get "https://gitlab.gnome.org/GNOME/gnome-online-accounts/-/raw/${ext_v}/meson_options.txt")"
  if [[ "$pk_v" != "$ext_v" ]]; then warn "GOA: [extra] tiene $ext_v pero el PKGBUILD git de Arch esta en '${pk_v:-?}'; reintentar mas tarde"
  elif ! is_hex "$pk_b2" 128; then warn "GOA $ext_v: no pude extraer un b2sum valido del PKGBUILD oficial de Arch"
  elif [[ -n "$opts" ]] && grep -q "^option('" <<<"$opts" && ! grep -q "^option('google_files'" <<<"$opts"; then warn "GOA $ext_v YA NO TIENE la opcion 'google_files': investigar antes de subir"
  else
    set_var gnome-online-accounts pkgver "$ext_v"; set_var gnome-online-accounts pkgrel "$want_r"; set_sum gnome-online-accounts b2sums "$pk_b2"
    msg="gnome-online-accounts: $loc_v-$loc_r -> $ext_v-$want_r (sigue al GOA de [extra]; b2sum del PKGBUILD oficial de Arch)"
    if [[ "$(series "$loc_v")" == "$(series "$ext_v")" ]]; then auto "$msg"; else change "$msg (cambio de serie: PR)"; fi
    [[ -z "$opts" ]] && note "no pude confirmar google_files en GOA $ext_v (sin acceso a GitLab); el package() del PKGBUILD abortara si no esta"
  fi
fi

# ───────────── libsoup2 ← GNOME (serie 2.74) + rango de cherry-pick de Arch ─────────────
info "libsoup2"
loc="$(pkgvar libsoup2 pkgver)"; loc_r="$(pkgvar libsoup2 pkgrel)"; loc_c="$(pkgvar libsoup2 _cvecommit)"
new_v=""; new_c=""
up="$(gnome_latest libsoup 2.74)"
aur="$(get 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=libsoup')"
aur_v="$(grep -m1 '^pkgver=' <<<"$aur" | cut -d= -f2 || true)"
aur_c="$(grep -oE 'cherry-pick -n [0-9.]+\.\.[0-9a-f]{7,40}' <<<"$aur" | head -1 | sed 's/.*\.\.//' || true)"
if [[ -z "$up" ]]; then note "sin acceso a GNOME para libsoup (se omite)"
elif ! is_ver "$up"; then warn "libsoup: version con formato inesperado en GNOME: '$up'"
elif [[ "$up" != "$loc" ]]; then
  if ! newer "$up" "$loc"; then warn "libsoup: GNOME lista $up, anterior a nuestra $loc; se omite"
  elif [[ "$aur_v" == "$up" ]]; then
    b2="$(grep -A1 '^b2sums=' <<<"$aur" | grep -oE '[0-9a-f]{128}' | head -1 || true)"
    if is_hex "$b2" 128; then new_v="$up"; else warn "libsoup $up: el AUR ya lo tiene pero no pude extraer su b2sum"; fi
  else warn "libsoup $up publicado por GNOME, pero el libsoup del AUR sigue en '${aur_v:-?}': esperar a que Arch lo suba (trae el rango de parches)"
  fi
else note "libsoup2 $loc es la ultima 2.74.x"
fi
if [[ -z "$aur_c" ]]; then note "no pude leer el rango de cherry-pick del AUR (se omite)"
else
  # Normaliza a sha completo y exige que el commit este en la rama de
  # mantenimiento de GNOME (no vale cualquier objeto: MRs de terceros tambien
  # responden 200 en /commits/<sha>).
  cinfo="$(get "https://gitlab.gnome.org/api/v4/projects/GNOME%2Flibsoup/repository/commits/${aur_c}")"
  full_c="$(json_field id <<<"$cinfo")"
  if ! is_hex "$full_c" 40; then warn "libsoup2: el AUR apunta al commit ${aur_c:0:10} pero NO existe en gitlab.gnome.org/GNOME/libsoup; no se aplica"
  elif [[ "$full_c" != "$loc_c" ]]; then
    refs="$(get "https://gitlab.gnome.org/api/v4/projects/GNOME%2Flibsoup/repository/commits/${full_c}/refs?type=branch")"
    if grep -q '"name":"libsoup-2-74"' <<<"$refs"; then new_c="$full_c"
    else warn "libsoup2: el commit ${full_c:0:10} del AUR existe en GNOME pero NO esta en la rama libsoup-2-74; no se aplica"; fi
  else note "rango de parches de libsoup2 igual al de Arch"; fi
fi
if [[ -n "$new_v" || -n "$new_c" ]]; then
  rel=1; [[ -z "$new_v" ]] && rel=$(( ${loc_r%%.*} + 1 ))
  [[ -n "$new_v" ]] && { set_var libsoup2 pkgver "$new_v"; set_sum libsoup2 b2sums "$b2"; }
  [[ -n "$new_c" ]] && set_var libsoup2 _cvecommit "$new_c"
  set_var libsoup2 pkgrel "$rel"
  [[ -n "$new_v" ]] && change "libsoup2: $loc -> $new_v (GNOME publico 2.74.x nuevo; b2sum del libsoup de Arch/AUR; pkgrel $rel)"
  [[ -n "$new_c" ]] && change "libsoup2: Arch amplio el rango de parches: _cvecommit ${loc_c:0:10} -> ${new_c:0:10} (pkgrel $rel)"
fi

# ───────────────────────────── libgdata ← GNOME ─────────────────────────────
info "libgdata"
loc="$(pkgvar libgdata pkgver)"; up="$(gnome_latest libgdata '')"
if [[ -z "$up" ]]; then note "sin acceso a GNOME para libgdata (se omite)"
elif ! is_ver "$up"; then warn "libgdata: version con formato inesperado en GNOME: '$up'"
elif [[ "$up" == "$loc" ]]; then note "libgdata $loc (archivado upstream: lo esperado)"
elif ! newer "$up" "$loc"; then warn "libgdata: GNOME lista $up, anterior a $loc; se omite"
else
  sum="$(gnome_sum libgdata "$up")"
  if is_hex "$sum" 64; then set_var libgdata pkgver "$up"; set_var libgdata pkgrel 1; set_sum libgdata sha256sums "$sum"
    change "libgdata: $loc -> $up (¡upstream archivado publico algo!; sha256 de GNOME)"
  else warn "libgdata $up en GNOME pero sin .sha256sum legible"; fi
fi

# ───────────────────── Solus: canario de flags (no se copia nada) ─────────────────────
info "Solus (canario de flags de compilacion)"
declare -A SOLUS=( [gvfs]=g/gvfs [gnome-online-accounts]=g/gnome-online-accounts [libgdata]=l/libgdata [libsoup]=l/libsoup [deja-dup]=d/deja-dup )
for n in gvfs gnome-online-accounts libgdata libsoup deja-dup; do
  yml="$(get "https://raw.githubusercontent.com/getsolus/packages/main/packages/${SOLUS[$n]}/package.yml")"
  if [[ -z "$yml" ]]; then note "Solus/$n: sin acceso (se omite)"; continue; fi
  now="$(awk '/^setup *:/{f=1;next} f&&/^[a-z]/{f=0} f' <<<"$yml" | sed 's/^[[:space:]]*//' | grep -v '^$' || true)"
  snap="${ROOT}/upstream/solus/${n}.setup"
  if [[ -z "$now" ]]; then warn "Solus/$n: no pude extraer el bloque setup: (¿cambio el formato del package.yml?); no se toca el snapshot"
  elif [[ ! -f "$snap" ]]; then (( APPLY )) && printf '%s\n' "$now" > "$snap"; note "Solus/$n: primer snapshot"
  else
    old="$(cat "$snap")"
    if [[ "$now" != "$old" ]]; then
      warn "Solus cambio el setup de $n. Antes: [$(tr '\n' ' ' <<<"$old")] Ahora: [$(tr '\n' ' ' <<<"$now")]. ¿Nos afecta? (upstream/solus/README.md)"
      (( APPLY )) && printf '%s\n' "$now" > "$snap"
    else note "Solus/$n: sin cambios en setup:"; fi
  fi
done

# ───────────────────────────────── salida ─────────────────────────────────
echo
if (( ${#CHANGES[@]} == 0 )); then
  write_report 0; (( ${#WARN[@]} )) && printf '%s=> nada que cambiar, %d aviso(s)%s\n' "$Y" "${#WARN[@]}" "$O" || printf '%s=> todo al dia%s\n' "$G" "$O"; exit 0
fi
if (( ${#AUTO[@]} == ${#CHANGES[@]} )); then code=11; else code=10; fi
write_report "$code"
printf '%s=> %d cambio(s)%s%s, %d aviso(s)%s\n' "$Y" "${#CHANGES[@]}" "$( (( APPLY )) && echo ' aplicados' || echo ' (sin --apply no se ha tocado nada)')" "$( (( code == 11 )) && echo ' [todos rutinarios]' )" "${#WARN[@]}" "$O"
exit "$code"
