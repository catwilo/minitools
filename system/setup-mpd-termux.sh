#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "[1/8] Updating packages..."
pkg update -y && pkg upgrade -y

echo "[2/8] Installing dependencies..."
pkg install -y mpd mpc ncmpcpp termux-api pulseaudio

echo "[3/8] Enabling storage access..."
termux-setup-storage

echo "[4/8] Creating MPD directories..."
mkdir -p ~/.local/share/mpd/playlists
mkdir -p ~/.config/mpd
mkdir -p ~/.cache/mpd

echo "[5/8] Writing MPD config..."
cat > ~/.config/mpd/mpd.conf <<'CONF'
music_directory     "/storage/8177-8535/music"
playlist_directory  "~/.local/share/mpd/playlists"
db_file             "~/.local/share/mpd/database"
log_file            "~/.local/share/mpd/log"
pid_file            "~/.local/share/mpd/pid"
state_file          "~/.local/share/mpd/state"
sticker_file        "~/.local/share/mpd/sticker.sql"

audio_output {
    type "pulse"
    name "Android PulseAudio"
}

bind_to_address "127.0.0.1"
port "6600"
CONF

echo "[6/8] Starting PulseAudio..."
pulseaudio --start --exit-idle-time=-1 || true

echo "[7/8] Starting MPD..."
pkill mpd 2>/dev/null || true
mpd ~/.config/mpd/mpd.conf || true

echo "[8/8] Updating music database..."
mpc -h 127.0.0.1 -p 6600 update || true

echo "Done. Test with: mpc status"
