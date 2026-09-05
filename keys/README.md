# Firma del repositorio (opcional, recomendada)

Hoy el repo se publica **sin firma**: la integridad la da HTTPS desde GitHub y
`SigLevel = Optional TrustAll` en el bloque de `pacman.conf`. Es lo que hacen
muchos repos personales, pero la norma de Arch es firmar. Activarlo son diez
minutos, una vez, y solo puede hacerlo el propietario de la cuenta de GitHub.

## Activar la firma (propietario)

```bash
# 1. Clave dedicada, sin passphrase (su proteccion es el almacen de secretos
#    de GitHub) y sin caducidad (una clave que caduca es una bomba de relojeria
#    para un repo mantenido por una persona).
gpg --batch --quick-generate-key 'Drive-Gekko-Gnome (firma del repo pacman) <TU_CORREO>' ed25519 sign never
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"

# 2. Clave PUBLICA al repo, y su huella al README (segundo canal para verificarla)
gpg --armor --export "$FPR" > keys/drive-gekko-gnome.asc
echo "$FPR"

# 3. Clave PRIVADA como secreto de GitHub (Settings -> Secrets -> Actions):
#    nombre REPO_GPG_KEY, valor = la salida de:
gpg --armor --export-secret-keys "$FPR"

# 4. Guarda una copia cifrada de esa salida en tu gestor de contrasenas.
#    Si se pierde la clave, no se puede volver a publicar: habria que crear
#    otra y que cada usuario la reimporte.
```

A partir del siguiente run, `scripts/ci-prepare.sh` importa la clave,
`scripts/publish-repo.sh` firma los paquetes nuevos y la base de datos, y sube
los `.sig`.

## Usarla (cada usuario)

```bash
curl -fsSLo /tmp/dgg.asc https://raw.githubusercontent.com/The-Gekko/Drive-Gekko-Gnome/main/keys/drive-gekko-gnome.asc
gpg --show-keys --fingerprint /tmp/dgg.asc      # compara la huella con la del README
sudo pacman-key --add /tmp/dgg.asc
sudo pacman-key --lsign-key <HUELLA>
```

y en el bloque `[drive-gekko-gnome]` de `/etc/pacman.conf`, cambiar
`SigLevel = Optional TrustAll` por `SigLevel = Required DatabaseOptional`.
`Optional TrustAll` sigue funcionando con un repo firmado; `Required` es el
paso de endurecimiento.
