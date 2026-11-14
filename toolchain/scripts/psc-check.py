#!/usr/bin/env python3
"""psc-check: will this ARM binary load on the PlayStation Classic?

For each ELF given, checks against the console's real root filesystem
(PSC_DEVICE_ROOT, the extracted ROOTFS1) that:
  * every NEEDED library exists on the console (or in --bundle dirs we ship),
  * every undefined dynamic symbol (incl. its version, e.g. GLIBC_2.28)
    is provided by the libraries that will actually be loaded.
Exit code 1 if anything would fail at load time.
"""
import argparse, os, re, subprocess, sys

READELF = os.environ.get("CROSS", "arm-linux-gnueabihf-") + "readelf"
LIBDIRS = ["lib", "usr/lib", "usr/local/lib"]
SYM_RE = re.compile(r"^\s*\d+:\s+\S+\s+\d+\s+(\S+)\s+(\S+)\s+\S+\s+(\S+)\s+(\S+)")


def readelf(args, path):
    return subprocess.run([READELF, "-W", *args, path], capture_output=True,
                          text=True, check=False).stdout


def needed(path):
    return re.findall(r"\(NEEDED\).*\[(.+?)\]", readelf(["-d"], path))


def dynsyms(path):
    """-> (defined: set of (name, version|None)), undefined: list of (name, ver, weak))"""
    defined, undefined = set(), []
    for line in readelf(["--dyn-syms"], path).splitlines():
        m = SYM_RE.match(line)
        if not m:
            continue
        typ, bind, ndx, name = m.groups()
        name = name.split(" (")[0]
        if "@@" in name:
            n, v = name.split("@@", 1)
        elif "@" in name:
            n, v = name.split("@", 1)
        else:
            n, v = name, None
        if ndx == "UND":
            if n:
                undefined.append((n, v, bind == "WEAK"))
        else:
            defined.add((n, v))
            defined.add((n, None))
    return defined, undefined


def find_lib(soname, roots):
    for root in roots:
        for d in LIBDIRS + [""]:
            p = os.path.join(root, d, soname)
            if os.path.exists(p):
                return os.path.realpath(p)
    return None


def vkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or ""))


def check(binary, device_root, bundles):
    roots = bundles + [device_root]
    problems, provided, seen = [], set(), set()
    queue = list(needed(binary))
    while queue:
        so = queue.pop()
        if so in seen:
            continue
        seen.add(so)
        path = find_lib(so, roots)
        if not path:
            problems.append(f"missing library on console: {so}")
            continue
        d, _ = dynsyms(path)
        provided |= d
        queue += needed(path)
    _, undef = dynsyms(binary)
    maxver = {}
    for n, v, weak in undef:
        if v:
            fam = re.sub(r"_[\d.]+$", "", v)
            if vkey(v) > vkey(maxver.get(fam)):
                maxver[fam] = v
        if (n, v) not in provided and not weak:
            problems.append(f"unresolved symbol: {n}@{v}" if v else f"unresolved symbol: {n}")
    return problems, sorted(seen), maxver


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--device-root", default=os.environ.get("PSC_DEVICE_ROOT", "/device"))
    ap.add_argument("--bundle", action="append", default=[],
                    help="extra dir with libraries we ship alongside the binary")
    a = ap.parse_args()
    if not os.path.isdir(os.path.join(a.device_root, "lib")):
        sys.exit(f"device root not found: {a.device_root} (mount device-dump/sysroot there)")
    bad = 0
    for f in a.files:
        problems, libs, maxver = check(f, a.device_root, a.bundle)
        status = "OK " if not problems else "FAIL"
        vers = ", ".join(f"{k} {v}" for k, v in sorted(maxver.items()))
        print(f"[{status}] {f}\n       libs: {', '.join(libs) or '-'}\n       max versions: {vers or '-'}")
        for p in problems[:40]:
            print(f"       - {p}")
        if len(problems) > 40:
            print(f"       … {len(problems) - 40} more")
        bad += bool(problems)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
