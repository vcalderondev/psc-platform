#!/bin/sh
# Lumen's boot splash: the logo with its letters dark (the first frame of Lumen's own
# startup splash) and "Loading" at the bottom right, in the language Lumen is set to.
#
#   sh splash.sh [1080p]      runs until killed: killall -TERM sdl_display
#
# Two callers: the payload's start, on Sony's Weston (720p) as soon as Sony's boot
# animation ends, and Lumen's boot.sh through /tmp/lumen-splash.sh (written by start),
# once it has swapped the compositor ("1080p" = the pictures made for that output).
#
# Pictures: <stick>/lumen/assets/ first (they belong to the installed Lumen), then the
# copies packed in this payload. The language is the "language" line of
# <stick>/lumen/settings.ini (no file or no line: "es", Lumen's default); a language
# without a text picture gets the English one.
PAYLOAD="$(cd "$(dirname "$0")" && pwd)"
A=/media/lumen/assets
P="${PAYLOAD}/assets"
sfx=""; [ "$1" = 1080p ] && sfx=-1080
lang="$(sed -n 's/^language=//p' /media/lumen/settings.ini 2>/dev/null | tr -d '\r' | tail -1)"
case "${lang}" in ""|*[!A-Za-z0-9_-]*) lang=es ;; esac
# boot.sh stops processes named "sdl_display" (Eris' viewer had that name): ours runs
# under it, through the symlink
ln -sf "${PAYLOAD}/bin/lumen-splash" /tmp/sdl_display
exec /tmp/sdl_display \
  --text "${A}/boot/loading-${lang}${sfx}.png" --text "${P}/boot/loading-${lang}${sfx}.png" \
  --text "${A}/boot/loading-en${sfx}.png" --text "${P}/boot/loading-en${sfx}.png" \
  "${A}/splash${sfx}.png" "${P}/splash${sfx}.png" "${A}/splash.png" "${P}/splash.png"
