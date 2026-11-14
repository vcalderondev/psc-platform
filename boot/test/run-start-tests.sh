#!/bin/sh
# Scenario tests for the payload's start script, run offline under ARMv7 emulation with
# the CONSOLE's own /bin/sh (bash 4 from the rootfs dump) and stubbed system commands
# (mount, killall, blkid, systemctl, reboot, ...), which only log what they were asked
# to do. Each scenario then checks the decisions and that nothing touched the eMMC.
#
#   sh psc-platform/boot/test/run-start-tests.sh      (from the workspace folder)
#
# Scenarios
#   patched-exfat    Eris/BleemSync-patched console (mount.exfat present), exFAT stick, Lumen installed
#   virgin-fat32     never-modded console (no mount.exfat, no overlayfs), FAT32 stick, Lumen installed
#   virgin-ext4      never-modded console, ext4 stick, Lumen installed
#   no-lumen         stick without /lumen/boot.sh                    -> Sony menu, parked
#   disabled         <stick>/lumen/disable-boot present              -> Sony menu, parked
#   mount-fails      the stick cannot be mounted (twice)             -> Sony menu, parked
#   no-stick         blkid finds no SONY* stick                      -> Sony menu, parked
#   boot-sh-returns  boot.sh exits 1                                 -> reboot, never returns
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOT="$(dirname "$HERE")"
REPO="$(dirname "$BOOT")"
WS="${PSC_WORKSPACE:-$(dirname "$REPO")}"
SYSROOT="${PSC_SYSROOT:-$WS/device-dump/sysroot}"
[ -x "$SYSROOT/bin/bash" ] || { echo "no console rootfs at $SYSROOT" >&2; exit 2; }

docker run --rm --network none --platform linux/arm/v7 \
  -v "$SYSROOT":/sr:ro -v "$BOOT/payload":/payload-src:ro \
  arm32v7/busybox:1.36 sh -c '
LD="/sr/lib/ld-linux-armhf.so.3 --library-path /sr/lib:/sr/usr/lib"
fail=0
stub() { printf "#!/bin/sh\n%s\n" "$2" > /stubs/$1; chmod +x /stubs/$1; }
setup() {  # scenario
  rm -rf /stubs /media /data /tmp/* /usr/bin/wait_sdl /usr/bin/sonyapp-launch /calls /etc/versions /sbin/mount.exfat
  mkdir -p /sbin /stubs /media /data/power /etc/versions /tmp/diag/d8781dae/payload/bin /tmp/diag/d8781dae/payload/assets
  cp -r /payload-src/. /tmp/diag/d8781dae/payload/
  echo test > /tmp/diag/d8781dae/payload/VERSION
  printf "#!/bin/sh\nexit 0\n" > /tmp/diag/d8781dae/payload/bin/lumen-splash; chmod +x /tmp/diag/d8781dae/payload/bin/lumen-splash
  : > /calls; echo 0 > /data/power/disable
  echo MREL > /etc/versions/target
  case "$1" in patched*) echo dev > /etc/versions/variant; echo 47 > /etc/versions/pe_kernel.ver
                         printf "#!/bin/sh\nexit 0\n" > /sbin/mount.exfat; chmod +x /sbin/mount.exfat;;
               *) echo user > /etc/versions/variant;; esac
  FS=exfat; case "$1" in *fat32) FS=vfat;; *ext4) FS=ext4;; esac
  for c in killall systemctl reboot pidof; do stub $c "echo \"$c \$*\" >> /calls"; done
  # pidof: sonyapp exists until killed with TERM/KILL
  stub pidof "echo \"pidof \$*\" >> /calls; [ \"\$1\" = sonyapp ] && ! grep -qE \"killall (-TERM|-s KILL) sonyapp\" /calls"
  if [ "$1" = no-stick ]; then stub blkid "exit 0"
  else stub blkid "if [ -n \"\$1\" ]; then echo \"\$1: LABEL=\\\"SONY\\\" TYPE=\\\"$FS\\\"\"; else echo \"/dev/sda1: LABEL=\\\"SONY\\\" UUID=\\\"1234\\\" TYPE=\\\"$FS\\\"\"; fi"; fi
  if [ "$1" = mount-fails ]; then stub mount "echo \"mount \$*\" >> /calls; exit 32"
  else stub mount "echo \"mount \$*\" >> /calls; exit 0"; fi
  # sleep: short ones pass, a park (>= 60 s) ends the scenario
  stub sleep "case \"\$1\" in 3600|60) echo PARKED >> /calls; kill -9 \$PPID;; esac; exit 0"
  printf "#!/bin/sh\necho wait_sdl >> /calls\n" > /usr/bin/wait_sdl; chmod +x /usr/bin/wait_sdl
  printf "#!/bin/sh\necho sonyapp-launch >> /calls\n" > /usr/bin/sonyapp-launch; chmod +x /usr/bin/sonyapp-launch
  mkdir -p /home/root
  case "$1" in no-lumen|no-stick|mount-fails) ;; *)
    mkdir -p /media/lumen/assets; : > /media/lumen/assets/splash.png
    rc=0; [ "$1" = boot-sh-returns ] && rc=1
    printf "echo \"boot.sh ran cwd=\$(pwd) XDG=\$XDG_RUNTIME_DIR disable=\$(cat /data/power/disable)\" >> /calls\nexit $rc\n" > /media/lumen/boot.sh;;
  esac
  [ "$1" = disabled ] && : > /media/lumen/disable-boot
  return 0
}
run() {  # scenario expected(lumen|stock)
  setup "$1"
  ( cd /tmp/diag/d8781dae/payload && PATH=/stubs:$PATH timeout 20 $LD /sr/bin/bash ./start > /tmp/start.out 2>&1 ); rc=$?
  ok=1; why=""
  bad=$(grep -E "remount,rw|mmcblk|by-partlabel|dd |mkfs|upgrade_app" /calls /tmp/start.out)
  [ -n "$bad" ] && { ok=0; why="$why eMMC-touching call: $bad;"; }
  grep -q "killall -STOP sonyapp" /calls || { ok=0; why="$why sonyapp not frozen first;"; }
  if [ "$2" = lumen ]; then
    grep -q "^boot.sh ran cwd=/home/root XDG=/run/user/0 disable=2" /calls || { ok=0; why="$why boot.sh not run as expected;"; }
    grep -q "^reboot" /calls || { ok=0; why="$why no reboot after boot.sh;"; }
    grep -q "killall -s KILL ui_menu" /calls || { ok=0; why="$why ui_menu not stopped;"; }
    grep -q "^mount -o rw /dev/sda1 /media" /calls || { ok=0; why="$why stick not mounted rw;"; }
    [ "$(sed -n 1p /calls)" = "killall -STOP sonyapp" ] || { ok=0; why="$why first action is not the freeze;"; }
  else
    grep -q "boot.sh ran" /calls && { ok=0; why="$why boot.sh ran;"; }
    grep -qE "killall -s KILL (ui_menu|sonyapp)|killall -TERM sonyapp" /calls && { ok=0; why="$why Sony UI killed;"; }
    grep -q "killall -CONT sonyapp" /calls || { ok=0; why="$why sonyapp not resumed;"; }
    grep -q "^PARKED" /calls || { ok=0; why="$why returned to usb_watch instead of parking;"; }
    grep -q "^reboot" /calls && { ok=0; why="$why rebooted;"; }
    [ "$(cat /data/power/disable)" = 0 ] || { ok=0; why="$why power flag changed;"; }
  fi
  if [ $ok = 1 ]; then echo "PASS $1 -> $2"; else echo "FAIL $1 -> $2:$why"; fail=1; fi
  sed "s/^/    | /" /calls; grep -E "stock menu|mounted|console:|boot.sh returned" /tmp/start.out | sed "s/^/    > /"
}
run patched-exfat lumen
run virgin-fat32 lumen
run virgin-ext4 lumen
run boot-sh-returns lumen
run no-lumen stock
run disabled stock
run mount-fails stock
run no-stick stock
[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
'
