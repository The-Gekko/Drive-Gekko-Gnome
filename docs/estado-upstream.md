# Estado upstream — por qué este repo existe

> Verificado el 4 de septiembre de 2026 contra archlinux.org, aur.archlinux.org
> y GNOME GitLab. Vuelve a comprobarlo con `./scripts/check-sources.sh` antes
> de fiarte de esta página.

Resumen en una línea: **la integración de Google Drive en GNOME está muerta
upstream y Arch ya la retiró de sus repos**. Si la quieres, hay que mantenerla
uno mismo. Este documento explica cómo se llegó ahí y qué alternativas hay.

## Qué pasó, en orden

| Cuándo | Qué |
| --- | --- |
| ~2022 | GNOME pide ayuda para `libgdata`: todo lo demás migró a libsoup 3, libgdata se quedó en libsoup 2.4. Nadie la adopta. |
| ~2025 | gvfs desactiva la opción `google` (MR !266). El texto del propio MR recomienda a las distros dejarla apagada, y sugiere que quien la eche de menos porte la parte de Drive a una librería nueva sobre libsoup3. |
| ago–nov 2025 | Debian y Ubuntu quitan el backend de Google de `gvfs-backends`. Motivo declarado: libgdata está sin mantener, sigue en libsoup 2.4, y el equipo de seguridad no quiere seguir parcheando libsoup2 (CVEs de 2025). |
| **19 feb 2026** | **GNOME Online Accounts mete el soporte de Drive detrás de la opción de compilación `google_files`, apagada por defecto** (commit *«build: Disable google provider Files feature»*). Arch compila con el valor por defecto; Solus pasa `-Dgoogle_files=true`. Esta es la pieza que casi nadie ve: sin ella, `gvfsd-google` no sirve de nada. |
| ~mar 2026 | `libgdata` se **archiva** en GNOME GitLab. |
| may 2026 | Arch retira `libgdata` y `libsoup` (2.4) de los repos oficiales. Ambos aparecen en el AUR el 31 de mayo. |
| 11–12 jun 2026 | Incidente **"Atomic Arch"**: se adoptan masivamente paquetes huérfanos del AUR y se les inyecta malware (un paquete npm `atomic-lockfile` que suelta un robador de credenciales en Rust). Arch cifra el alcance en ~400 al principio, y luego se habla de más de 1500. `libgdata` figura en la lista consolidada de paquetes afectados, aunque su repositorio git del AUR no tiene ningún commit dentro de la ventana del ataque (ver más abajo). Los repos oficiales **no** se vieron afectados. |
| ago 2026 | `gvfs` 1.60.2-4 en `[extra]` lleva `Replaces/Conflicts: gvfs-google<=1.58.3-1` y ya no instala `gvfsd-google`. |

## Situación hoy en Arch

| Paquete | ¿Repos oficiales? | Notas |
| --- | --- | --- |
| `gvfs` | ✅ `extra` 1.60.2-4 | Bien mantenido. **No lo tocamos.** |
| `gvfs-goa` | ✅ `extra` | Sigue existiendo, hace falta para la cuenta. |
| `gvfs-google` | ❌ eliminado | Lo construimos nosotros desde el tarball oficial de gvfs. |
| `libgdata` | ❌ solo AUR | Archivado upstream. El `PKGBUILD` del AUR es el de Arch, íntegro. |
| `libsoup` (2.4) | ❌ solo AUR | Sin releases upstream. Arch mantiene 17 parches de CVE sobre el tag. |
| `gnome-online-accounts` | ⚠️ `extra` 3.58.1-1 | Está, pero **compilado sin `-D google_files=true`**: no pide el permiso de Drive. Hay que recompilarlo. |
| `deja-dup` | ✅ `extra` 50.1-1 | Usa el oficial. |
| `rclone` | ✅ `extra` | La alternativa viva. |

## Por qué no tiramos del AUR ni de Chaotic-AUR

La pregunta razonable es: si `libgdata` y `libsoup` están en el AUR, ¿por qué
compilar aquí? La respuesta honesta, después de comprobarlo:

**Chaotic-AUR queda descartado sin discusión**: no tiene ninguno de los que faltan (`libsoup` 2.4, `libgdata`, `gvfs-google`).
Comprobado con `pacman -Sl chaotic-aur` sobre una base de 3149 paquetes.

**El AUR, en cambio, está bien.** Se clonó el git de ambos y se revisó:

- `libgdata`: último commit del **28-feb-2026, por heftig (staff de Arch)**.
  Ningún commit dentro de la ventana del ataque (9–14 de junio). El `PKGBUILD`
  es el de Arch íntegro: `git+gitlab.gnome.org` con tag y `b2sums`, sin
  `.install`, sin hooks, sin `npm`. Su mantenedor actual **no** figura entre las
  cuentas atacantes documentadas.
- `libsoup`: último commit del **05-ago-2025, también de heftig**. Ni siquiera
  aparece en la lista de afectados.

Que `libgdata` esté en la lista consolidada encaja con haber sido *adoptado*
durante la ventana, no con haber sido troyanizado — el mismo perfil que la
lista de correo documentó para cuentas como `ivonahruskova` o `simongeisler`,
marcadas para vigilancia sin commits maliciosos. Salvedad: el AUR permite
force-push, así que un commit borrado no dejaría rastro. No se puede descartar
al 100 %, pero lo que te bajas hoy es el `PKGBUILD` limpio de Arch.

**Entonces, ¿por qué existe este repo?**

1. **`gvfs-google` no existe en ninguna parte.** Ni en oficiales, ni en el AUR,
   ni en Chaotic. Hay que construirlo sí o sí.
2. **La recompilación de GOA con `-D google_files=true` tampoco existe.** Y sin
   ella lo demás no funciona.
3. Ya puestos, la cadena entera se construye igual, y así queda todo en un solo
   sitio auditable: tarball o tag de GNOME → checksum en git → build local.

Lo que **sí** se toma de Arch son los parches: los 17 commits de CVE que heftig
mantiene sobre `libsoup` 2.74.3. El tarball pelado no los lleva, y compilarlo a
secas — que es lo que hace Solus — deja esos desbordamientos de heap dentro.

## La decisión honesta: ¿de verdad quieres esta cadena?

Instalar `libsoup2` + `libgdata` + `gvfs-google` significa meter en tu sistema
una librería HTTP sin soporte upstream para tener una carpeta en Nautilus.
Merece la pena decidirlo a conciencia.

### Opción A — Cadena completa (este repo)

- ✅ Google Drive aparece en Nautilus y en cualquier app GTK vía GIO.
- ✅ Integrado con la cuenta de GNOME Online Accounts.
- ❌ Mantienes tú libsoup 2.4, con CVEs y sin upstream.
- ❌ Cada subida de `gvfs` en Arch obliga a reconstruir `gvfs-google`.
- ❌ Sustituyes `gnome-online-accounts`, un paquete oficial. Cuando Arch lo
  actualice, Drive dejará de montar **sin ningún error visible** (por eso el
  repo instala un hook de pacman que lo grita).
- ❌ Es una cuenta con acceso a tu Drive detrás de código sin auditar.

### Opción B — rclone (recomendada si solo quieres tus archivos)

`rclone` está en `[extra]`, tiene upstream activo y soporta Drive de forma
nativa. Cubre el 90 % de los casos sin deuda de seguridad:

```bash
sudo pacman -S rclone
rclone config                      # asistente: n -> drive -> seguir pasos
mkdir -p ~/Drive
rclone mount gdrive: ~/Drive --vfs-cache-mode writes
```

Como servicio de usuario, para que se monte solo:

```bash
systemctl --user edit --force --full rclone-drive.service
```

```ini
[Unit]
Description=Montaje de Google Drive con rclone
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount gdrive: %h/Drive --vfs-cache-mode writes
ExecStop=/bin/fusermount3 -u %h/Drive
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now rclone-drive.service
```

Lo que pierdes frente a la Opción A: no sale en el lateral de Nautilus como
"cuenta online", y no se integra con GOA. Es una carpeta normal.

### Opción C — Déjà Dup con rclone

Si lo único que querías era **respaldar** en Drive, ni siquiera necesitas
montar nada: `deja-dup` de `[extra]` ofrece Drive y OneDrive como destino
apoyándose en `rclone`.

```bash
sudo pacman -S deja-dup rclone
```

Esta opción no requiere nada de este repositorio.

## Cuándo podríamos archivar este repo

El día que alguien porte la parte de Drive de libgdata a libsoup3 (que es
justo lo que sugiere el MR !266 de gvfs) y gvfs reactive la opción `google`.
Si eso pasa, `libsoup2` y `libgdata` salen de aquí y solo quedaría seguir el
paquete nuevo. Merece la pena revisarlo cada pocos meses.
