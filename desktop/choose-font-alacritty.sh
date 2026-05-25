#!/bin/dash

fnts=$(fc-list : family | sort -u)

setActualPreview() {
	s/\(^family = "\)[^"]*\("\)/\1@\2/ ~/.config/alacritty/alacritty.toml
}

for f in $fnts; do
	setActualPreview "$f
done
