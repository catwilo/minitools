nmap -sn -PR -n -T5 --max-retries 0 --host-timeout 20s 192.168.x.0/24  # replace with your subnet

# nmap: herramienta de escaneo de red usada aquí para detectar hosts vivos.
# -sn: "ping scan". No escanea puertos; solo detecta hosts activos.
# -PR: usa ARP ping en LAN. Muy rápido y fiable en subredes Ethernet. Requiere root.
# -n: desactiva resolución DNS inversa. Evita esperas por nombres de host.
# -T5: plantilla de tiempo más agresiva. Prioriza velocidad sobre sigilo/precisión.
# --max-retries 0: no reintenta probes fallidos. Reduce tiempo por host.
# --host-timeout 20s: tiempo máximo a gastar por cada host antes de descartarlo.
# 192.168.1.0/24: objetivo de red; ajustar a tu subred real antes de ejecutar.
# Resultado: lista breve de hosts activos con IPs. No muestra puertos ni detalles extensos.
