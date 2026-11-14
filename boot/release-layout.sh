#!/bin/sh
# Turn a Lumen PSX release zip (current layout: lumen/ + boot/project_eris/...) into the
# ready-to-use, Eris-free stick layout of research-notes/no-eris-boot.md §9.2:
#
#   d8781dae-c45c-4fc1-b961-e03eedebbffb/{diag,LDIAG.BIN}   our signed boot payload
#   lumen/  (+ lumen/logs/)                                Lumen as released
#   games/<system>/                                        empty, one per lumen/systems/*.ini
#   README-INSTALL.txt                                     new instructions
#   (no boot/, no project_eris/)
#
#   sh psc-platform/boot/release-layout.sh <lumen-psx-vX.zip> <stick dir from build-payload.sh> <out.zip>
#
# Reference for what lumen/scripts/package.sh should produce once it ships the payload;
# also used to simulate "download the release, unzip on a stick" before that exists.
set -e
ZIP=$1; STICK=$2; OUTZIP=$3
ID=d8781dae-c45c-4fc1-b961-e03eedebbffb
[ -f "$ZIP" ] && [ -f "$STICK/$ID/LDIAG.BIN" ] && [ -n "$OUTZIP" ] ||
  { echo "usage: $0 <lumen-psx-vX.zip> <stick dir with $ID/LDIAG.BIN> <out.zip>"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
unzip -q "$ZIP" -d "$T"
[ -f "$T/lumen/boot.sh" ] || { echo "not a Lumen release zip (no lumen/boot.sh)"; exit 1; }
VER="$(head -1 "$T/lumen/VERSION" 2>/dev/null)"
rm -rf "$T/boot"                                   # Eris hand-off: gone
mkdir -p "$T/$ID" "$T/lumen/logs"
cp "$STICK/$ID/LDIAG.BIN" "$T/$ID/LDIAG.BIN"; : > "$T/$ID/diag"
# game folders from the systems' library paths (/media/games/<x>)
for p in $(sed -n 's|^paths *= */media/games/\([A-Za-z0-9_-]*\).*|\1|p' "$T"/lumen/systems/*.ini | sort -u); do
  mkdir -p "$T/games/$p"
done
cat > "$T/games/README.txt" <<'EOF'
Put your games in the folder of their system (psx, snes, nes, megadrive, gba, n64, arcade).
The console's own 20 games are always there too (they live inside the console).
EOF
cat > "$T/README-INSTALL.txt" <<EOF
$VER for the PlayStation Classic: ready to use, no other mod needed

1. Format a USB stick as FAT32 (MS-DOS FAT on macOS), with the name SONY.
   (exFAT also works, but only on a console that already had Project Eris or BleemSync.)
2. Unzip this file at the root of the stick: you get d8781dae-.../, lumen/, games/.
3. Put games in games/<system>/ (optional).
4. Plug the stick into the console (the port on the left, under the flap) and power on.

Nothing is installed on the console: everything runs from the stick and from RAM.
Without the stick, the console is exactly as it was.

To get the original PlayStation Classic menu with the stick plugged in: create an empty
file named disable-boot inside lumen/. Delete it to get Lumen back.
Logs, if something does not work: lumen/logs/ (payload.log, boot.log).
Versions of every component: lumen/VERSION.
EOF
mkdir -p "$(dirname "$OUTZIP")"; OUTZIP="$(cd "$(dirname "$OUTZIP")" && pwd)/$(basename "$OUTZIP")"
rm -f "$OUTZIP"; (cd "$T" && zip -qr -X "$OUTZIP" .)
echo "$OUTZIP"
unzip -l "$OUTZIP" | awk 'NR>3 {print $4}' | grep -E '^[^/]+/?$|^d8781dae|^games/[^/]+/$|logs/$' | sort
