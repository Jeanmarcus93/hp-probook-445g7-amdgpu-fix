# amdgpu fix for HP ProBook 445 G7 — AMD Renoir black screen

Fix for the black screen bug on the HP ProBook 445 G7 (AMD Renoir iGPU) under
Ubuntu 26.04 / kernel 7.0.0-27-generic.

**Status: ✅ RESOLVED AND PERMANENT.** On normal boot `amdgpu` loads from
initramfs, the internal panel (eDP-1) lights up at 1920×1080 native.

---

## Summary

| Item | Value |
|------|-------|
| Machine | HP ProBook 445 G7 |
| GPU | AMD Renoir iGPU (`1002:1636`, subsystem HP `103C:8730`), PCI `0000:05:00.0` |
| OS | Ubuntu 26.04, kernel **7.0.0-27-generic** |
| Symptom | 100% black screen with `amdgpu`; `amdgpu_get_bios()` / display stage failed |
| Root cause | The VBIOS image in the **HP flash is a generic template with no eDP object**; the real VBIOS (with the panel) only exists in the **ROM BAR**, populated by the SBIOS during POST |
| Fix | (a) `amdgpu` recompiled with **file-load of VBIOS** + HPD underflow fix; (b) `vbios.bin` = dump of the **real ROM BAR**; (c) early load via dracut |
| Result | `card1 → amdgpu`, eDP-1 = 1920×1080/1680×1050/…; no `Failed to create link encoder`, no `wait timed out` |

---

## The problem

On **all** tested kernels (6.8, 6.17, 7.0) `amdgpu` failed to probe with
`-22` (EINVAL), leaving the display on `simple-framebuffer` (simpledrm) — or,
with the patched module probing deeper, in a **black screen with no fallback**.

`amdgpu_get_bios()` tries to obtain the VBIOS in this order: **ATRM → VFCT →
VRAM BAR → ROM BAR → platform**. On this machine, in normal boot state:

- **ATRM**: no ACPI method → absent.
- **VFCT**: no VFCT ACPI table in this ACPI.
- **VRAM shadow**: absent.
- **ROM BAR**: returned `I/O error` when the GPU had not been POSTed.
- **platform**: picked up the copy the SBIOS shadows at `0xC0000` — the **generic VBIOS**.

Even when a VBIOS was obtained, the display (DC) stage failed:

```
create_links: BIOS object table - number of connectors: 5
... link_id: 21, is_internal_display: 0, hpd_int_gpio_uid id: 0
*ERROR* Failed to create link encoder!
construct_phy failed.
```

### Root cause of "Failed to create link encoder"

- `link_factory.c` → `construct_phy`: without HPD in the VBIOS, executes
  `link->hpd_src = hpd_info.hpd_int_gpio_uid - 1`. With `uid = 0` (generic VBIOS)
  → `hpd_src = -1` (**unsigned underflow** → huge value).
- `dcn21_link_encoder_create` (`dcn21_resource.c`):
  `if (... || enc_init_data->hpd_source >= ARRAY_SIZE(link_enc_hpd_regs)) return NULL;`
  `link_enc_hpd_regs[]` has 5 entries; huge `hpd_source` → `NULL` →
  "Failed to create link encoder" for **all** links → no CRTC → black screen.

### The decisive discovery: two different VBIOSes

Comparing the VBIOS extracted from the HP firmware with the dump of the **ROM BAR**
(read with the GPU already POSTed for simpledrm), the images differ in ~351 bytes,
**all in the `0xCC00–0xD300` region** (LCD_Info @`0xCCD8` + Display Object Table @`0xD248`):

| Region | HP flash (`renoir_vbios_113-RENOIR-037.rom`) | Real ROM BAR (`vbios_rombar.bin`) |
|--------|----------------------------------------------|-----------------------------------|
| LCD_Info @`0xCCD8` | **zeroed** (no panel timing) | real timing **1920×1080** (`0x780`×`0x438`) |
| Connector table @`0xD250` | **5× `0x15` (MXM)** — generic placeholder | `0x14` (**eDP**, internal panel) + `0x0C` (HDMI) + 2× `0x13` (DP), with valid HPD/GPIO |
| Strings | "Renoir Generic VBIOS" | real OEM mapping |

**Conclusion:** the eDP/panel mapping is **not in the flash**; it is assembled by the
SBIOS during iGPU POST. The correct VBIOS always existed — in the ROM BAR.

---

## The fix (3 components)

### 1. Patched `amdgpu` module (2 patches)

Source downloaded from apt pool `linux_7.0.0-27.27` and extracted with `dpkg-source`.

**Patch 1 — VBIOS file-load** (`drivers/gpu/drm/amd/amdgpu/amdgpu_bios.c`):
- New `amdgpu_read_bios_from_file()` that calls `request_firmware("amdgpu/vbios.bin")`
  and validates with `check_atom_bios`.
- Called **first** in `amdgpu_get_bios_apu()`.
- `MODULE_FIRMWARE("amdgpu/vbios.bin")` → ensures `vbios.bin` is pulled into initramfs.

**Patch 2 — HPD underflow fix** (`drivers/gpu/drm/amd/display/dc/link/link_factory.c`):
```c
/* before */ link->hpd_src = hpd_info.hpd_int_gpio_uid - 1;
/* after  */ link->hpd_src = hpd_info.hpd_int_gpio_uid ? hpd_info.hpd_int_gpio_uid - 1 : 0;
```
> With the real VBIOS this fix is a no-op (VBIOS already provides valid HPD),
> but it protects against regression.

### 2. `vbios.bin` = real ROM BAR dump

- Source: `/sys/bus/pci/devices/0000:05:00.0/rom` (readable with GPU already POSTed).
- 54784 bytes, mod256 checksum = 0 (valid), `113-RENOIR-037`,
  `ATOMBIOSBK-AMD VER017.010.000.031`.
- **sha256: `e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a`**
- Install to `/lib/firmware/amdgpu/vbios.bin`.

### 3. Early load (dracut)

Ubuntu 26.04 uses **dracut**, not mkinitramfs.
- `/etc/dracut.conf.d/amdgpu.conf` → `add_drivers+=" amdgpu "`
- `update-initramfs -u -k 7.0.0-27-generic` embeds `amdgpu.ko.zst` + `vbios.bin`
  in the initramfs.

---

## Build notes (lessons learned)

### Error 1 — modversions CRC mismatch
- Symptom: `amdgpu: disagrees about version of symbol module_layout`.
- Cause: single-module in-tree build (`make drivers/.../amdgpu.ko`) without `vmlinux.o`
  generates CRCs from source headers, not the binary kernel.
- Fix: EXTMOD build (`make -C $SRC M=drivers/gpu/drm/amd/amdgpu modules`)
  with `Module.symvers` **from the binary kernel**
  (`/lib/modules/.../build/Module.symvers`, `module_layout=0xb0c84d61`) copied
  into the source tree.

### Error 2 — rejected relocation
- Symptom: `x86/modules: Invalid relocation target, existing value is nonzero ...`
  (fatal, `-ENOEXEC`) → module aborts before probe.
- Cause: kernel has `CONFIG_DEBUG_INFO_BTF_MODULES=y`, which adds **24 bytes**
  to `struct module` (fields `btf_*`) **before** the `exit` field. Our `.config`
  had the option disabled → `cleanup_module` landed at the wrong offset (`0x490` vs `0x4a8`).
- Fix: rebuild with `KCFLAGS="-DCONFIG_DEBUG_INFO_BTF_MODULES=1"` (no need for
  pahole/vmlinux). `cleanup_module` moved to `0x4a8`. ✅
- **Lesson:** when copying `Module.symvers` from the kernel to match CRCs, you must
  also match **every** `.config` option that changes the layout of an exported struct —
  otherwise CRC passes but the binary/relocation diverges.

### Validated build
- vermagic `7.0.0-27-generic SMP preempt mod_unload modversions` ✅
- `module_layout = 0xb0c84d61` (== kernel), 0/1130 divergent symbols ✅
- `firmware: amdgpu/vbios.bin` present ✅
- Build env: gcc 15.2.0 (identical to kernel build), Secure Boot OFF,
  `MODULE_SIG_FORCE` off, lockdown `[none]`.
- Required packages: `flex bison libelf-dev`.

---

## Installation — quick start

**Precondition:** boot with the GPU already POSTed and the `amdgpu` module *not*
driving the display (the broken state qualifies: simpledrm active, or recovery /
`nomodeset` boot). The ROM BAR is only readable after POST.

```bash
sudo apt install dkms patch flex bison libelf-dev linux-headers-$(uname -r)
git clone https://github.com/Jeanmarcus93/hp-probook-445g7-amdgpu-fix.git
cd hp-probook-445g7-amdgpu-fix
sudo bash install.sh
# reboot via the normal GRUB entry
```

`install.sh` runs the four steps in order:

1. **`scripts/dump_vbios_rom.sh`** — auto-detects the AMD GPU on the PCI bus,
   enables the ROM BAR, dumps the real VBIOS and validates it (0x55AA signature,
   mod-256 checksum, `ATOMBIOSBK` marker).
2. **`scripts/install_vbios.sh`** — installs the dump as
   `/lib/firmware/amdgpu/vbios.bin` (with backup of any previous file).
3. **`scripts/build_dkms.sh`** — downloads the matching `linux-source` package,
   extracts only `drivers/gpu/drm/amd/` (the subtree is self-contained:
   `FULL_AMD_PATH=$(src)/..`), applies the patches from `patches/`, installs the
   tree in `/usr/src/amdgpu-rombar-<version>/` and runs
   `dkms add/build/install`.
4. **`scripts/make_amdgpu_permanent.sh`** — dracut early-load conf
   (`add_drivers+=" amdgpu "`) + initramfs regeneration + sanity checks.

Each script can also be run individually; all take optional arguments
(PCI BDF, dump path, kernel version) and default to auto-detection.

**Optional no-reboot test with auto-recovery:** `sudo bash scripts/test_amdgpu_real.sh`
loads the module manually and, if the panel doesn't light up in 90 s, reboots
back to simpledrm on its own.

---

## DKMS

The module is packaged as `amdgpu-rombar` with `AUTOINSTALL="yes"`: every new
kernel installed via apt triggers an automatic rebuild against that kernel's
headers — no `apt-mark hold` needed, no manual rebuild.

The build is **EXTMOD against the headers package** of the target kernel, so
modversions CRCs, autoconf (`CONFIG_DEBUG_INFO_BTF_MODULES`) and the
`struct module` layout come out right automatically (see
[Build notes](#build-notes-lessons-learned) for why that matters).

> **Secure Boot:** Ubuntu's dkms signs modules automatically with the MOK key in
> `/var/lib/shim-signed/mok/` if one is enrolled. With Secure Boot enabled and
> no enrolled MOK, the module will not load — enroll one first
> (`sudo update-secureboot-policy --new-key` + `mokutil --import`).

---

## Patches

The `patches/` directory contains unified diffs against the vanilla
`linux_7.0.0-27.27` source:

- `0001-amdgpu-bios-add-file-load-vbios.patch` — VBIOS file-load in `amdgpu_bios.c`
- `0002-link-factory-fix-hpd-underflow.patch` — HPD underflow fix in `link_factory.c`
- `0003-amdgpu-trace-fix-out-of-tree-include-path.patch` — `TRACE_INCLUDE_PATH .`
  in `amdgpu_trace.h`. **Only needed for the out-of-tree/DKMS build** (the
  in-tree relative path `../../drivers/gpu/drm/amd/amdgpu` doesn't exist when
  building as an external module). Skip it if you're patching a full kernel tree.

Apply to a full kernel tree with `patch -p1`, or to the extracted `amd/`
subtree with `patch -p4` (which is what `build_dkms.sh` does).

The reconstructed tree (vanilla source + these patches) was verified
**byte-identical** to the DKMS tree running on the reference machine.

---

## Verification (current confirmed state)

```bash
uname -r
# 7.0.0-27-generic

readlink -f /sys/class/drm/card1/device/driver
# .../bus/pci/drivers/amdgpu

dmesg | grep -iE 'Fetched VBIOS|Display Core|eDP-1'
# amdgpu 0000:05:00.0: Fetched VBIOS from file (amdgpu/vbios.bin)
# [drm] Display Core v3.2.369 initialized on DCN 2.1
# [drm] Using ACPI provided EDID for eDP-1

cat /sys/class/drm/card1-eDP-1/modes | head
# 1920x1080
# 1680x1050

sha256sum /lib/firmware/amdgpu/vbios.bin
# e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a
```

The `Fetched VBIOS from file` timestamp at ~8.5 s confirms the load happens
**on boot** (via initramfs/dracut), not via manual modprobe.

---

## Rollback / recovery

**If the screen goes black:**

1. In GRUB (hold Shift/Esc), choose **Advanced options → recovery**
   (`nomodeset`): `amdgpu` won't probe and simpledrm restores video.

2. Remove the DKMS module (the stock module in
   `/lib/modules/.../kernel/...` takes over again):
   ```bash
   sudo dkms remove amdgpu-rombar/$(uname -r | cut -d- -f1) --all
   sudo rm -f /etc/dracut.conf.d/amdgpu.conf
   sudo depmod -a
   sudo update-initramfs -u -k "$(uname -r)"
   ```

3. Reboot.

---

## Hardware / IDs

- GPU: AMD Renoir iGPU, PCI `0000:05:00.0` (bus 5, slot 0, func 0)
- `1002:1636`, subsystem HP `103C:8730`
- HP BIOS S79 (password-locked: F10 setup and flashrom inaccessible → flash immutable)
- Generic VBIOS from HP flash: `113-RENOIR-037`, sha256 `fb51268390b6ee18a20a2f5d6840f72844ddc88715dd91f6cce9c686182445a7`
- Real VBIOS (ROM BAR): same string, sha256 `e40fd9a8f8a244d3dbea3c7e9834032740a2c0d71000aa1d81d61989cf95425a`
