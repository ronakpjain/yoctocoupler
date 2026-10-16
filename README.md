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

## Build

Docker is required.

```sh
curl -fsSL \
  https://raw.githubusercontent.com/siemens/kas/59e55e4f4e38d659e04de0018c9e5671a2a2fedb/kas-container \
  -o /tmp/kas-container
chmod 0755 /tmp/kas-container
KAS_IMAGE_VERSION=4.7 /tmp/kas-container build kas/yoctocoupler-cm5.yml
```

To install a root SSH public key, set it before building. The `kas-container`
wrapper requires it to be explicitly forwarded into the build container:

```sh
export YOCTOCOUPLER_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
KAS_IMAGE_VERSION=4.7 /tmp/kas-container \
  --runtime-args "-e YOCTOCOUPLER_SSH_PUBLIC_KEY" \
  build kas/yoctocoupler-cm5.yml
```

Without a key, the root account remains locked. Build artifacts are written to
`build/tmp/deploy/images/raspberrypi5/`.

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
It requires Python 3, `ssh-keygen`, `debugfs`/`e2fsck`, GNU `dd`, and `bzip2`
for compressed images.

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

Run the script directly on the Linux host, not in the KAS build container. It
checks the image fits, rejects the current root disk, mounted filesystems, and
active swap, and rechecks the persistent identifier plus device identity and
capacity immediately before writing. It fails closed if root/mount/swap
inspection fails. It then requires the exact `ERASE /dev/...` confirmation and
requests `sudo` only for the actual flash. Use `--dry-run` to check the
selection without writing. If Linux does not identify a USB device as
removable, verify it carefully before using `--allow-nonremovable`.

On a carrier exposing Ethernet as `eth0`, configure the host adapter on
`192.168.50.0/24` (for example, the Mac at `192.168.50.1/24`). After boot, connect with
`ssh root@192.168.50.2`. The serial console is `ttyAMA10`.

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
