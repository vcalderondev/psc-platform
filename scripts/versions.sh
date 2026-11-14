#!/bin/sh
# Component versions pinned by the build recipes, as key=value lines (versions.txt in
# every release; Lumen PSX copies it into its own release).   scripts/versions.sh [tag]
cd "$(dirname "$0")/.."
v() { sed -n -E "s/^(.*[ ;])?$2=([^ ;#]*).*/\2/p" "$1" | head -1; }
echo "psc-platform=${1:-$(git describe --tags --always 2>/dev/null)}"
echo "wayland=$(v compositor/build.sh WAYLAND)"
echo "wayland-protocols=$(v compositor/build.sh PROTOCOLS)"
echo "weston=$(v compositor/build.sh WESTON)"
echo "libdrm=$(v compositor/build.sh LIBDRM)"
echo "libseat=$(v compositor/build.sh SEATD)"
echo "libdisplay-info=$(v compositor/build.sh DISPLAYINFO)"
echo "retroarch=RetroArch $(v retroarch/build.sh RA)"
echo "joypad-autoconfig=$(v retroarch/build.sh AUTOCONFIG)"
echo "pcsx_rearmed=libretro/pcsx_rearmed@$(v cores/pcsx_rearmed/build.sh COMMIT)"
