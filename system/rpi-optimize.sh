#!/bin/sh
# deshabilitar pruebas opcionales
sudo systemctl disable glamor-test.service rp1-test.service

# mantener bluetooth (no tocar bluetooth.service)

# qué es ModemManager
# → gestiona módems 3G/4G (USB o internos), NO es Wi-Fi

# deshabilitar ModemManager
sudo systemctl disable ModemManager.service

# deshabilitar SSH Switch
sudo systemctl disable sshswitch.service

# qué es systemd-pstore
# → guarda logs de kernel en pstore (RAM especial o NVRAM); útil para debugging kernel crashes

# si no es necesario:
sudo systemctl disable systemd-pstore.service

# evitar montajes automáticos y remover herramienta
sudo systemctl disable udisks2.service
sudo apt purge udisks2 gvfs gvfs-backends

# quitar NFS cliente
sudo systemctl disable nfs-client.target
sudo apt purge nfs-common

# qué es remote-fs.target
# → permite activar montajes remotos (NFS, CIFS, etc)

# deshabilitar montajes red
sudo systemctl disable remote-fs.target

# quitar APT daily
sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer

# dpkg-db-backup
# → copia /var/lib/dpkg por seguridad (por si rompe dpkg); no es crítico
sudo systemctl disable dpkg-db-backup.timer
