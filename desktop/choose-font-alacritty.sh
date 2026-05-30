#!/usr/bin/env bash
# choose-font-alacritty — pick a font from fc-list and apply to alacritty.toml
set -euo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/alacritty/alacritty.toml"
[[ -f "$CONFIG" ]] || { echo "Error: $CONFIG not found"; exit 1; }
command -v fzf >/dev/null || { echo "Error: fzf required"; exit 1; }

font=$(fc-list : family | sed 's/,.*//;s/ $//' | sort -u | fzf --prompt="Font: ")
[[ -z "$font" ]] && exit 0

sed -i "s/^\(family *= *\"\)[^\"]*\"*/\1${font}\"/" "$CONFIG"   && echo "Font set: $font"
