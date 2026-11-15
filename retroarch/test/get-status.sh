#!/bin/sh
# GET_STATUS must be answered while a game runs, also for a core without an .info file.
# lumen-buttons' watchdog (lumen: src/buttons.c) asks it every 2 s and kills a RetroArch
# that stops answering; RetroArch 1.22.2 itself crashed on the question (patches/0004).
#
#   toolchain/psc sh psc-platform/retroarch/test/get-status.sh <retroarch> <psc-weston-16.tar.gz>
#
# Runs the console binary itself, inside the (throw-away) toolchain container: the console's
# loader and libraries (/device, plus the compositor overlay as on the console) under the host's
# ARM emulation (binfmt/qemu-user: Docker Desktop has it, on Linux install qemu-user-static
# or docker/setup-qemu-action). No display, no sound: the null drivers.
# Layout as Lumen's: libretro_directory = the folder of the core, network commands on.
#   case 1  no .info next to the core -> "GET_STATUS PLAYING <library_name>,<content>,crc32=..."
#   case 2  an .info with systemid    -> "GET_STATUS PLAYING <systemid>,<content>,crc32=..."
# Exit: 0 pass, 1 fail, 77 ARM binaries do not run here (nothing was tested).
RA=$1; OVERLAY=$2
[ -f "$RA" ] && [ -f "$OVERLAY" ] || { echo "usage: get-status.sh <retroarch> <psc-weston-16.tar.gz>"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
. /opt/psc/bin/psc-env
T=/tmp/ra-get-status; rm -rf "$T"; mkdir -p "$T/overlay" "$T/cores" "$T/config" "$T/system"
LD=/device/lib/ld-linux-armhf.so.3
tar xzf "$OVERLAY" -C "$T/overlay"
LIBS="$T/overlay/lib:/device/usr/lib:/device/lib"
$CC $PSC_FLAGS -O1 -shared -fPIC -o "$T/cores/psctest_libretro.so" "$HERE/testcore.c" || { echo "get-status: test core did not build"; exit 1; }
# The binary starts through its own interpreter path, as on the console (the loader run by
# hand maps a non-PIE program over qemu-user's own mappings): give this container the
# console's loader there if it has none.
[ -e /lib/ld-linux-armhf.so.3 ] || ln -s "$LD" /lib/ld-linux-armhf.so.3
# (env, not a shell function: $! below must be RetroArch itself, to signal and to reap)
env LD_LIBRARY_PATH="$LIBS" "$RA" --version > "$T/version.log" 2>&1 ||
  { echo "get-status: SKIPPED, the console binary does not run here (no binfmt/qemu-user for ARM?)"; tail -3 "$T/version.log"; exit 77; }
printf 'not a game' > "$T/game.bin"
cat > "$T/retroarch.cfg" <<CFG
config_save_on_exit = "false"
video_driver = "null"
audio_driver = "null"
input_driver = "null"
input_joypad_driver = "null"
menu_driver = "rgui"
network_cmd_enable = "true"
network_cmd_port = "55355"
libretro_directory = "$T/cores"
libretro_info_path = "$T/cores"
system_directory = "$T/system"
savefile_directory = "$T/system"
savestate_directory = "$T/system"
rgui_config_directory = "$T/config"
cache_directory = "$T/system"
core_info_cache_enable = "false"
savestate_auto_save = "false"
history_list_enable = "false"
log_verbosity = "true"
CFG

ask() {  # ask <tag> <expected reply prefix>: start a game, ask GET_STATUS until the game answers
  env LD_LIBRARY_PATH="$LIBS" "$RA" --config "$T/retroarch.cfg" -L "$T/cores/psctest_libretro.so" "$T/game.bin" > "$T/$1.log" 2>&1 &
  pid=$!
  python3 - "$pid" "$2" <<'PY'
import os, socket, sys, time
pid, want = int(sys.argv[1]), sys.argv[2]
def alive():
    try:
        os.kill(pid, 0)
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.0)
end, asked, reply = time.time() + 60, 0, ""
while time.time() < end:
    if not alive():
        print("retroarch died after %d GET_STATUS" % asked); sys.exit(1)
    s.sendto(b"GET_STATUS", ("127.0.0.1", 55355)); asked += 1
    try:
        reply = s.recv(4096).decode("latin-1").strip()
    except socket.timeout:
        continue          # still loading: the command socket is read from the main loop
    except OSError:
        time.sleep(0.5); continue   # ICMP port unreachable: not listening yet
    if reply.startswith("GET_STATUS PLAYING") or reply.startswith("GET_STATUS PAUSED"):
        break
    time.sleep(0.5)       # CONTENTLESS: the content is not up yet
else:
    print("no answer from a running game in 60 s (last: %r)" % reply); sys.exit(1)
time.sleep(1.0)           # a crash on the question shows as a dead process
if not alive():
    print("retroarch died after answering %r" % reply); sys.exit(1)
print("reply: " + reply)
sys.exit(0 if reply.startswith(want) else 1)
PY
  rc=$?
  kill -TERM $pid 2>/dev/null; ( sleep 5; kill -KILL $pid 2>/dev/null ) & k=$!
  wait $pid; ec=$?; kill $k 2>/dev/null
  [ $rc = 0 ] && { echo "get-status: PASS $1"; return 0; }
  echo "get-status: FAIL $1 (wanted \"$2...\", retroarch exit=$ec)"; tail -5 "$T/$1.log"
  return 1
}

fail=0
ask no-info "GET_STATUS PLAYING PSC Test Core,game,crc32=" || fail=1
printf 'display_name = "PSC Test Core"\nsupported_extensions = "bin"\nsystemid = "psc_test"\n' > "$T/cores/psctest_libretro.info"
ask with-info "GET_STATUS PLAYING psc_test,game,crc32=" || fail=1
exit $fail
