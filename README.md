# Yoctocoupler CM5 image

Minimal headless 64-bit Yocto image for the Raspberry Pi Compute Module 5 (CM5) with:

- Raspberry Pi Linux 6.12 with PREEMPT_RT, 1 kHz timers, and GPIO17 PPS support
- systemd-networkd with static wired networking (`192.168.50.2/24`, gateway `192.168.50.1`, DNS `1.1.1.1`)
- OpenSSH for remote administration; no desktop, GUI, or developer/test utilities

The GPIO PPS kernel module is included, but user-space diagnostic tools such as
`rt-tests` and `pps-tools` are intentionally omitted from the production image.

The build uses meta-raspberrypi's shared `raspberrypi5` machine, which includes
CM5 device trees. There is no universal CM5 carrier-board device tree. For a
custom carrier, add its DTB to the kernel's `KERNEL_DEVICETREE` and the boot
partition, and select it with
`device_tree=<carrier>.dtb` in `config.txt` (for example, via
`RPI_EXTRA_CONFIG` in the KAS file). Configure any carrier-specific boot
options before flashing. The GPIO17 PPS overlay requires the PPS signal on
that pin; the included network configuration only matches `eth0` and a direct
`192.168.50.0/24` connection. Adapt these for your carrier as needed.

## Image variants: production vs development

Choose exactly one build profile. Both use the same minimal image recipe and
shared settings, but the dev/QEMU profile does **not** inherit the production
profile.

| | Hardware / production | Development / QEMU |
|---|---|---|
| Intended target | Physical CM5 and its carrier | QEMU `raspi5b` model |
| KAS entry point | `kas/yoctocoupler-cm5.yml` | `kas/yoctocoupler-cm5-qemu.yml` |
| Actions artifact | `yoctocoupler-cm5-preempt-rt` | `yoctocoupler-cm5-qemu-preempt-rt` |
| MCP251XFD SPI CAN driver | Included; carrier overlay required | — |
| IGB emulated Ethernet driver | Not added | Included and autoloaded |
| Virtual CAN | No setup/package added | `vcan` autoloaded; `vcan0` brought up at boot |
| Intended deployment | Flash to hardware | Run with matching kernel `Image` in QEMU |

**Shared:** PREEMPT_RT, SocketCAN raw sockets, GPIO PPS support, static wired
networking, systemd, OpenSSH, and public-key-only root access.
“Development” here means the QEMU networking/virtual-CAN additions—not a compiler,
SDK, desktop, or a general-purpose development distribution.

Build configuration is organized as:

```text
kas/yoctocoupler-common.yml      # Shared BSP pins, machine, distro and system policy
├── yoctocoupler-cm5.yml         # Production-only MCP251XFD package
└── yoctocoupler-cm5-qemu.yml    # QEMU-only IGB, VCAN and vcan0 configuration
```

Kernel fragments follow the same boundary: `yoctocoupler-rt.cfg` and
`yoctocoupler-can.cfg` are shared; `yoctocoupler-hardware-can.cfg` is
production-only; `yoctocoupler-qemu-igb.cfg` contains the dev/QEMU driver policy
(IGB + VCAN). `YOCTOCOUPLER_QEMU` selects the kernel policy
and is set explicitly by each profile. Select a profile rather than overriding
this flag in isolation, so kernel drivers and installed packages stay aligned.

Both profiles currently produce the same WIC filename pattern. Keep downloaded
artifacts in separate directories and never substitute a QEMU WIC for the
production artifact when flashing hardware.

## Build

Docker is required. `scripts/build-image.sh` downloads the pinned KAS wrapper
on first use and verifies its SHA-256 checksum before building the
**hardware/production** image:

```sh
scripts/build-image.sh
```

For the **dev/QEMU** image, select its independent profile. The script keeps its
output in `build/qemu/` by default, separate from the production output in
`build/`:

```sh
scripts/build-image.sh --profile qemu
```

The default KAS image version is 4.7. Override it with `KAS_IMAGE_VERSION`, or
set `KAS_BUILD_DIR` to choose another build directory. `KAS_CONTAINER` can point
to a local wrapper, but it must match the pinned checksum. The wrapper is cached
under `${XDG_CACHE_HOME:-~/.cache}/yoctocoupler/`.

### Download the production image built by GitHub Actions

The workflow uploads compressed WIC image output(s) and their small `.bmap`
sidecars as the `yoctocoupler-cm5-preempt-rt` artifact. This downloads that
output artifact only; it does not download the Yocto build cache:

```sh
RUN_ID=$(gh run list --repo ronakpjain/yoctocoupler \
  --workflow yoctocoupler-image.yml --branch main --status success --limit 1 \
  --json databaseId --jq '.[0].databaseId')
[ -n "$RUN_ID" ] || { echo 'No successful image workflow run found.' >&2; exit 1; }
gh run download "$RUN_ID" --repo ronakpjain/yoctocoupler \
  --name yoctocoupler-cm5-preempt-rt --dir artifacts
find artifacts -type f -name 'yoctocoupler-image-*.wic.bz2' -print
```

Use the resulting `.wic.bz2` directly with either helper below. The workflow
runs the Yocto build on Ubuntu; this macOS support is for post-processing and
flashing the downloaded image.

To install a root SSH public key, set it before building. The script forwards a
non-empty `YOCTOCOUPLER_SSH_PUBLIC_KEY` into the build container automatically:

```sh
export YOCTOCOUPLER_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
scripts/build-image.sh
```

Without a key, the root account remains locked. Production artifacts are written
to `build/tmp/deploy/images/raspberrypi5/`; QEMU artifacts are written under
`build/qemu/tmp/deploy/images/raspberrypi5/` by default.

### Add a key to an already-built image (no rebuild)

Use the helper to create a new image copy with your public key installed in
`/root/.ssh/authorized_keys`:

```sh
IMAGE=$(find build/tmp/deploy/images/raspberrypi5 \
  -maxdepth 1 -type f -name 'yoctocoupler-image-raspberrypi5.rootfs-*.wic.bz2' \
  ! -name '*-with-ssh-key.wic.bz2' -print -quit)
scripts/add-ssh-key-to-image.sh "$IMAGE" ~/.ssh/id_ed25519.pub
KEYED_IMAGE="${IMAGE%.wic.bz2}-with-ssh-key.wic.bz2"
```

The helper appends the key (without duplicating existing entries), applies
root-only SSH key permissions, and writes a sibling `*-with-ssh-key.wic.bz2`;
the input image is left untouched. It uses `debugfs`/`e2fsck` on the ext4
rootfs partition, so it does not invoke BitBake, mount the image, or require
root privileges. It accepts uncompressed `.wic` files too; use `--output` to
choose another output path and `--force` only to replace an existing output.
It requires Python 3, `ssh-keygen`, `debugfs`/`e2fsck`, `dd`, and `bzip2`
for compressed images. On macOS, install the keg-only e2fsprogs tools with
`brew install e2fsprogs`; the helper locates them via `brew --prefix`.

The modified image no longer matches the original `.bmap` sidecar. The flash
helper below uses `bmaptool copy --nobmap` when available, or `dd`, so it does
not reuse a stale map. Without a supplied public key, the root account remains
locked.

## Flash to USB

Ensure the CM5 bootloader and carrier support the chosen USB boot medium. Use
a whole-disk USB device (not a partition); the example defaults to the keyed
copy and can be changed to the stock image if desired:

```sh
IMAGE=$(find build/tmp/deploy/images/raspberrypi5 \
  -maxdepth 1 -type f -name 'yoctocoupler-image-raspberrypi5.rootfs-*.wic.bz2' \
  ! -name '*-with-ssh-key.wic.bz2' -print -quit)
KEYED_IMAGE="${IMAGE%.wic.bz2}-with-ssh-key.wic.bz2"
IMAGE_TO_FLASH="$KEYED_IMAGE" # Set to "$IMAGE" for the unmodified image
lsblk -p -o NAME,TRAN,RM,SIZE,MODEL
scripts/flash-image-to-usb.sh --dry-run "$IMAGE_TO_FLASH" /dev/disk/by-id/usb-REPLACE-ME
scripts/flash-image-to-usb.sh "$IMAGE_TO_FLASH" /dev/disk/by-id/usb-REPLACE-ME
```

Run the script directly on the Linux or macOS host, not in the KAS build
container. On Linux it checks the image fits, rejects the current root disk,
mounted filesystems, and active swap, and rechecks device identity and capacity
immediately before writing. On macOS it uses `diskutil` plist data, checks the
system/Data/VM APFS backing stores and mounted volumes, and writes through
`/dev/rdiskN`. Both paths require the exact `ERASE /dev/...` confirmation and
request `sudo` only for the actual flash. Use `--dry-run` to check the
selection without writing. Inspection failures abort; the script never
unmounts devices automatically.

### Flash from macOS

Keep the helper files in `scripts/` together. macOS uses Python 3's standard
library to inspect `diskutil` plist output; no additional Python packages are
needed. First inspect external physical disks and unmount the selected whole
disk. Pass its `/dev/diskN` path (not a partition such as `/dev/diskNs1`);
the script selects the corresponding raw `/dev/rdiskN` only after its safety
checks:

```sh
diskutil list external physical
# Replace diskN with the verified external whole-disk identifier.
diskutil unmountDisk /dev/diskN
scripts/flash-image-to-usb.sh --dry-run "$IMAGE_TO_FLASH" /dev/diskN
scripts/flash-image-to-usb.sh "$IMAGE_TO_FLASH" /dev/diskN
```

macOS disk numbers can change after reconnecting devices, so re-run
`diskutil list external physical` and repeat the dry run if the device is
reconnected. The script refuses internal, virtual, system-backed, or mounted
disks and ejects the disk after a successful write. `--allow-nonremovable` can
be used only when macOS does not mark a verified external disk as USB/removable;
it never permits an internal or system disk.

On a carrier exposing Ethernet as `eth0`, configure the host adapter on
`192.168.50.0/24` (for example, the Mac at `192.168.50.1/24`). After boot, connect with
`ssh root@192.168.50.2`. The serial console is `ttyAMA10`.

## Run in QEMU

The Pi 5 QEMU model is pinned as an optional top-level submodule at
`tools/rpi5-machine`; it is host-side test tooling, not a Yocto layer or part
of the target image. Build it once with the helper (see [its README](tools/rpi5-machine/README.md)
for the full dependency list):

```sh
scripts/build-rpi5-qemu.sh
```

On macOS, the helper arranges Homebrew Bash and GNU coreutils for the fork's
setup scripts, supplies Homebrew libfdt include/link paths for `dtmerge`, and
passes `--disable-pvg` to avoid compiling Apple's obsolete Paravirtualized
Graphics API (the `-nographic` Pi 5 run does not use it). It uses four Ninja
workers by default; adjust with `--jobs N`. Install Xcode Command Line Tools
if needed. To have the helper install its Homebrew prerequisites first, run
`scripts/build-rpi5-qemu.sh --install-deps`. The build-only GNU coreutils path
is scoped to the helper; do not export it globally when running the image
runner, which uses macOS's native `stat -f` syntax.

To use the development/QEMU profile (IGB + virtual CAN), build and boot its
image with the matching kernel from the profile's separate output directory:

```sh
scripts/build-image.sh --profile qemu
QEMU_DEPLOY=build/qemu/tmp/deploy/images/raspberrypi5
QEMU_IMAGE=$(find "$QEMU_DEPLOY" -maxdepth 1 -type f \
  \( -name 'yoctocoupler-image-*.wic' -o -name 'yoctocoupler-image-*.wic.bz2' \) \
  -print -quit)
scripts/run-image-in-qemu.sh --kernel "$QEMU_DEPLOY/Image" "$QEMU_IMAGE"
```

The runner can also boot the newest unmodified WIC image from the default
production build directory, or a specific image paired with its matching
kernel:

```sh
scripts/run-image-in-qemu.sh
KERNEL=build/tmp/deploy/images/raspberrypi5/Image
scripts/run-image-in-qemu.sh --kernel "$KERNEL" "$KEYED_IMAGE"
```

The runner uses Bash and native host utilities, and supports Linux and macOS
when given a QEMU binary built for that host with the `raspi5b` model. The
fork's setup scripts are less portable: they require Bash 4 and GNU coreutils
(in particular GNU `realpath`). On macOS, install Homebrew `bash` and
`coreutils`, put them first in `PATH`, and install equivalents of the fork's
listed build dependencies; for example:

```sh
export PATH="$(brew --prefix bash)/bin:$(brew --prefix coreutils)/libexec/gnubin:$PATH"
```

This QEMU-fork build path has not been tested here. You can also select a
host-compatible binary with `--qemu PATH`. The runner boots the
Yocto kernel directly (not the Pi firmware or bootloader), attaches a temporary
copy of the WIC as the SD card, and prints the serial console on `ttyAMA10`.
The input image is left untouched. For explicit WIC paths, it requires
`--kernel` (or `KERNEL_IMAGE`) to avoid pairing an older root filesystem with a
newer kernel and mismatched modules. This is not a test of the CM5 carrier's
Ethernet, GPIO/PPS wiring, or physical-board latency.

### CAN support

Both image variants include SocketCAN raw sockets. The production hardware
image includes the `mcp251xfd` driver for MCP2517FD/MCP2518FD SPI controllers.
On hardware, supply a carrier-specific
device tree/overlay describing the SPI bus, chip select, interrupt GPIO, and
oscillator; no wiring-specific overlay is enabled by default. The driver loads
through device discovery. Configure the resulting `can0` with the bitrates and
CAN FD settings required by your bus before using it.

The development/QEMU variant additionally includes and autoloads `vcan`.
systemd-networkd creates and brings up `vcan0` at boot, without an IP address.
Use `vcan0` for application-level SocketCAN tests; it does not emulate SPI,
interrupts, physical CAN arbitration/timing, or the MCP2518FD hardware.
Configure your application to use `can0` on hardware and `vcan0` in QEMU.
After boot, verify with `ip -details link show vcan0` and `lsmod | grep vcan`.
CAN utilities such as `cansend`/`candump` are not installed by default.

The hardware image intentionally omits the QEMU-only `kernel-module-igb`,
`kernel-module-vcan`, and virtual-interface configuration.
The workflow also publishes a separate `yoctocoupler-cm5-qemu-preempt-rt`
artifact containing IGB, the virtual CAN setup, and its matching kernel `Image`; the normal
hardware artifact remains unchanged. Download the QEMU artifact, add your
public key to a copy, and boot it with SSH forwarding:

```sh
RUN_ID=$(gh run list --repo ronakpjain/yoctocoupler \
  --workflow yoctocoupler-image.yml --branch main --status success --limit 1 \
  --json databaseId --jq '.[0].databaseId')
[ -n "$RUN_ID" ] || { echo 'No successful image workflow run found.' >&2; exit 1; }
gh run download "$RUN_ID" --repo ronakpjain/yoctocoupler \
  --name yoctocoupler-cm5-qemu-preempt-rt --dir qemu-artifacts
IMAGE=$(find qemu-artifacts -type f -name 'yoctocoupler-image-*.wic.bz2' -print -quit)
[ -n "$IMAGE" ] || { echo 'No QEMU WIC image found.' >&2; exit 1; }
KERNEL=qemu-artifacts/Image
scripts/add-ssh-key-to-image.sh "$IMAGE" ~/.ssh/id_ed25519.pub
KEYED_IMAGE="${IMAGE%.wic.bz2}-with-ssh-key.wic.bz2"
scripts/run-image-in-qemu.sh --ssh-forward 2222 --kernel "$KERNEL" "$KEYED_IMAGE"
ssh -p 2222 root@127.0.0.1
```

SSH forwarding needs both the authorized root key and `kernel-module-igb`;
both are present only in the QEMU-specific image after you inject your key.

## Verify

```sh
zcat /proc/config.gz | grep -E '^CONFIG_(PREEMPT_RT|HZ_1000|PPS|PPS_CLIENT_GPIO)='
systemctl is-active systemd-networkd
systemctl is-active systemd-resolved
systemctl is-active sshd.socket
ip -4 address show dev eth0
ip route show default
resolvectl status eth0
test -e /sys/class/pps/pps0
```

GitHub Actions builds and uploads the compressed WIC image and bmap file.
