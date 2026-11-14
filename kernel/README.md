# kernel: modules for the PlayStation Classic's stock Sony kernel

Sony's stock kernel (Linux 4.4.22, BOOTIMG2 on every console, BOOTIMG1 on a never-modded
one) lacks overlayfs (needed by the PSC compositor) and xpad. These are built here as
loadable modules. Lumen's boot payload (`boot/`) loads them from RAM, only on that exact
stock build: no flash, nothing persistent.

```
sh psc-platform/kernel/build-modules.sh     # from the workspace folder; docker; ~10 min at -j4
sh psc-platform/kernel/check-modules.sh     # re-run the checks only
```

- **Source**: Sony's GPL tarball as imported in
  [lscorcia/linux-sony-psclassic](https://github.com/lscorcia/linux-sony-psclassic),
  commit `d716d7e`, sha256-pinned in `build-modules.sh`.
- **Config**: Sony's `arch/arm/configs/aiv8167_rockman_emmc_defconfig` with only
  `CONFIG_OVERLAY_FS=m` and `CONFIG_JOYSTICK_XPAD=m` (`out/kernel/config.diff`).
- **Toolchain** (`docker/Dockerfile`): GCC 6.3.0 + binutils 2.28 from Debian stretch
  (Sony used GCC 6.2), on a bookworm base. Two build flags:
  - `O=` out-of-tree, like Sony's Yocto build;
  - `-fno-PIE`, because Debian's GCC 6 defaults to PIE, which Linux 4.4 does not expect.
- **Checks** (`check-modules.sh`, against the stock kernel taken from `LRECOVERY.EPB` on
  the USB backup):
  - provenance: every symbol exported by the built kernel is in the stock image, and they
    share 5 899 of 5 900 printk messages;
  - vermagic `4.4.22 SMP preempt ARMv7 p2v8`;
  - no `_GLOBAL_OFFSET_TABLE_` references;
  - every undefined symbol of each module is exported by the stock kernel.

Output: `out/kernel/modules/{overlay.ko,xpad.ko,SHA256SUMS,check.txt}` (git-ignored).
The kernel has no `MODULE_UNLOAD`: a loaded module stays until power-off.

GPL: whoever distributes these `.ko` files must offer the corresponding source (the
pinned tarball + this folder).
