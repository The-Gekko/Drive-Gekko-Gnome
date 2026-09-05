# Canario de Solus

Cada `<paquete>.setup` es el bloque `setup:` del `package.yml` de ese paquete en
el monorepo de Solus (https://github.com/getsolus/packages), tal y como estaba
la última vez que el sincronizador lo miró.

**No se copia nada de aquí a los PKGBUILD.** Solus no es upstream de este repo
(lo es GNOME, y para las versiones de gvfs y GOA lo es Arch). Lo único que se
toma de Solus son dos decisiones de compilación — `-Dgoogle=true` en gvfs y
`-Dgoogle_files=true` en gnome-online-accounts — y estos ficheros existen para
enterarse si Solus las cambia. Cuando `scripts/sync-upstream.sh` ve una
diferencia, abre un issue con el antes y el después y guarda el snapshot nuevo
en `main` (en un commit propio, o dentro del PR si hay uno), para que una
persona decida si el cambio nos afecta. **No bloquea** los bumps rutinarios de
los demás paquetes.
