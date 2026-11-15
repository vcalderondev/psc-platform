#!/bin/sh
# Scenario tests for the payload's start script, run offline under ARMv7 emulation with
# the CONSOLE's own /bin/sh (bash 4 from the rootfs dump) and stubbed system commands
# (mount, killall, blkid, systemctl, reboot, ...), which only log what they were asked
# to do. Each scenario then checks the decisions and that nothing touched the eMMC.
#
#   sh psc-platform/boot/test/run-start-tests.sh      (from the workspace folder)
#
# Scenarios
#   patched-exfat    Eris/BleemSync-patched console (mount.exfat present, v47 kernel: no module
#                    may be loaded), exFAT stick, Lumen installed
#   virgin-fat32     never-modded console (no mount.exfat, stock kernel without overlayfs/xpad:
#                    overlay.ko + xpad.ko must be loaded before boot.sh), FAT32 stick, Lumen installed
#   virgin-ext4      never-modded console, ext4 stick, Lumen installed
#   no-lumen         stick without /lumen/boot.sh                    -> Sony menu, parked
#   disabled         <stick>/lumen/disable-boot present              -> Sony menu, parked
#   mount-fails      the stick cannot be mounted (twice)             -> Sony menu, parked
#   no-stick         blkid finds no SONY* stick                      -> Sony menu, parked
#   boot-sh-returns  boot.sh exits 1                                 -> reboot, never returns
# Splash (every scenario that starts Lumen): it is started before boot.sh with the text
# picture of the language in <stick>/lumen/settings.ini (virgin-ext4: fr; the others have
# no settings.ini: es, Lumen's default) and the English one as fallback, and
# /tmp/lumen-splash.sh starts it again with the 1080p pictures for boot.sh.
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
  printf "#!/bin/sh\necho \"lumen-splash \$*\" >> /calls\n" > /tmp/diag/d8781dae/payload/bin/lumen-splash; chmod +x /tmp/diag/d8781dae/payload/bin/lumen-splash
  : > /calls; echo 0 > /data/power/disable
  echo MREL > /etc/versions/target
  case "$1" in patched*) echo dev > /etc/versions/variant; echo 47 > /etc/versions/pe_kernel.ver
                         printf "#!/bin/sh\nexit 0\n" > /sbin/mount.exfat; chmod +x /sbin/mount.exfat;;
               *) echo user > /etc/versions/variant;; esac
  FS=exfat; case "$1" in *fat32) FS=vfat;; *ext4) FS=ext4;; esac
  for c in killall systemctl reboot pidof insmod; do stub $c "echo \"$c \$*\" >> /calls"; done
  # kernel: patched consoles run Eris v47 (overlay + xpad built in), virgin ones Sony stock
  mkdir -p /tmp/diag/d8781dae/payload/modules /tmp/sysmod; : > /tmp/diag/d8781dae/payload/modules/overlay.ko; : > /tmp/diag/d8781dae/payload/modules/xpad.ko
  case "$1" in patched*)
    stub uname "case \"\$1\" in -r) echo 4.4.22;; -v) echo \"#1 SMP PREEMPT Sun Feb 23 19:09:17 UTC 2020\";; *) echo Linux;; esac"
    printf "nodev\tsysfs\n\text4\nnodev\toverlay\n" > /tmp/filesystems; mkdir -p /tmp/sysmod/xpad;;
  *)
    stub uname "case \"\$1\" in -r) echo 4.4.22;; -v) echo \"#1 SMP PREEMPT Sun Sep 9 15:21:14 UTC 2018\";; *) echo Linux;; esac"
    printf "nodev\tsysfs\n\text4\n\tvfat\nnodev\tfuse\n" > /tmp/filesystems;;
  esac
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
  [ "$1" = virgin-ext4 ] && printf "version=1\r\nlanguage=fr\r\nprofile=main\r\n" > /media/lumen/settings.ini
  return 0
}
run() {  # scenario expected(lumen|stock)
  setup "$1"
  ( cd /tmp/diag/d8781dae/payload && LUMEN_TEST_FILESYSTEMS=/tmp/filesystems LUMEN_TEST_SYSMODULE=/tmp/sysmod PATH=/stubs:$PATH timeout 20 $LD /sr/bin/bash ./start > /tmp/start.out 2>&1 ); rc=$?
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
    lang=es; [ "$1" = virgin-ext4 ] && lang=fr
    sleep 0.3   # the splash runs in the background
    grep -q "^lumen-splash --text /media/lumen/assets/boot/loading-$lang.png .*loading-en.png .*/media/lumen/assets/splash.png" /calls ||
      { ok=0; why="$why splash not started with the $lang text;"; }
    [ "$(grep -n "^lumen-splash" /calls | head -1 | cut -d: -f1)" -lt "$(grep -n "^boot.sh ran" /calls | cut -d: -f1)" ] 2>/dev/null ||
      { ok=0; why="$why splash not started before boot.sh;"; }
    n=$(grep -c "^lumen-splash" /calls); sh /tmp/lumen-splash.sh 1080p; sleep 0.2
    [ "$(grep -c "^lumen-splash" /calls)" = $((n + 1)) ] && tail -1 /calls | grep -q "loading-$lang-1080.png .*/media/lumen/assets/splash-1080.png" ||
      { ok=0; why="$why /tmp/lumen-splash.sh 1080p does not start the 1080p splash;"; }
    case "$1" in
      patched*) grep -q "^insmod" /calls && { ok=0; why="$why module loaded into a non-stock kernel;"; } ;;
      *) grep -q "^insmod .*/modules/overlay.ko" /calls && grep -q "^insmod .*/modules/xpad.ko" /calls ||
           { ok=0; why="$why overlay.ko/xpad.ko not loaded on the stock kernel;"; }
         [ "$(grep -n "^insmod" /calls | head -1 | cut -d: -f1)" -lt "$(grep -n "^boot.sh ran" /calls | cut -d: -f1)" ] ||
           { ok=0; why="$why modules not loaded before boot.sh;"; } ;;
    esac
  else
    grep -q "boot.sh ran" /calls && { ok=0; why="$why boot.sh ran;"; }
    grep -qE "killall -s KILL (ui_menu|sonyapp)|killall -TERM sonyapp" /calls && { ok=0; why="$why Sony UI killed;"; }
    grep -q "killall -CONT sonyapp" /calls || { ok=0; why="$why sonyapp not resumed;"; }
    grep -q "^PARKED" /calls || { ok=0; why="$why returned to usb_watch instead of parking;"; }
    grep -q "^reboot" /calls && { ok=0; why="$why rebooted;"; }
    grep -q "^insmod" /calls && { ok=0; why="$why module loaded on the Sony-menu path;"; }
    grep -q "^lumen-splash" /calls && { ok=0; why="$why splash shown on the Sony-menu path;"; }
    [ "$(cat /data/power/disable)" = 0 ] || { ok=0; why="$why power flag changed;"; }
  fi
  if [ $ok = 1 ]; then echo "PASS $1 -> $2"; else echo "FAIL $1 -> $2:$why"; fail=1; fi
  sed "s/^/    | /" /calls; grep -E "stock menu|mounted|console:|boot.sh returned|module" /tmp/start.out | sed "s/^/    > /"
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
