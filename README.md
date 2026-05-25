# minitools

Small standalone scripts organized by category. No installer needed — copy or symlink to `~/.local/bin` or any directory in `$PATH`.

---

## audio

| Script | Description |
|---|---|
| `toggle-mic` | Toggle microphone mute with desktop notification |
| `toggle-vol` | Toggle volume mute with desktop notification |
| `vol` | Set volume to a given level (requires 1 argument) |

## desktop

| Script | Description |
|---|---|
| `choose-font-alacritty.sh` | Interactive font picker for Alacritty using fc-list |
| `deadd.sh` | Start deadd-notification-center if not running; waits for X11 |
| `moveWorkspace.sh` | Move i3 workspace to a given monitor (interactive prompt) |
| `notifydeadd` | Send a desktop notification via deadd (supports icon and timeout) |
| `press_e.sh` | Simulate pressing the E key via xdotool |
| `renameWorkspace.sh` | Rename the currently focused i3 workspace |
| `xcolor` | Pick a screen color and copy hex to clipboard via xclip |

## display

| Script | Description |
|---|---|
| `fehbg` | Set wallpapers via feh across multiple outputs |
| `reset-mouse.sh` | Reinitialize touchpad (PS/2 or I2C); optimized for ThinkPad |
| `set-i3-gaps.sh` | Set i3-gaps size interactively |
| `setscreen` | Add and apply a custom 1366x768 modeline via xrandr |
| `wacom` | Configure Wacom Intuos S tablet area and button mapping |
| `xrandr-Virtual.sh` | Create a virtual extended display (1366x768) and share via VNC |

## files

| Script | Description |
|---|---|
| `fixsuffix.sh` | Fix or normalize file extensions in batch |
| `mv-depth.sh` | Rename files recursively by replacing text in paths |

## misc

| Script | Description |
|---|---|
| `game-of-life.py` | Conway's Game of Life in the terminal (Python/numpy) |
| `nmapAgresiveFasterOut.sh` | Fast ARP ping scan to discover live hosts on a subnet |
| `xev-awk` | Print key name and keycode from xev output |

## system

| Script | Description |
|---|---|
| `lan-connection-lan2lan` | Configure a LAN-to-LAN connection on a given interface |
| `reset-iwd.service.sh` | Atomic idempotent restart of the iwd wireless daemon |
| `rpi-optimize.sh` | Disable optional Raspberry Pi services to reduce overhead |
| `run-java.sh` | Compile, run, and clean a single Java source file |
| `setup-mpd-termux.sh` | Set up MPD (Music Player Daemon) in Termux |

## vm

| Script | Description |
|---|---|
| `a.on` | Start a libvirt VM if not already running |
| `a.off` | Gracefully shut down a libvirt VM |
| `a.foff` | Force-off a libvirt VM |
