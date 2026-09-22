# Yoctocoupler CM5 image

Minimal 64-bit Yocto image for the Raspberry Pi Compute Module 5 (CM5) with:

- Raspberry Pi Linux 6.12 with PREEMPT_RT, 1 kHz timers, and GPIO17 PPS
- systemd-networkd with static wired networking (`192.168.50.2/24`, gateway `192.168.50.1`, DNS `1.1.1.1`)
- OpenSSH and `rt-tests`

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

To install a root SSH public key, set it before building:

```sh
export YOCTOCOUPLER_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
KAS_IMAGE_VERSION=4.7 /tmp/kas-container build kas/yoctocoupler-cm5.yml
```

Without a key, the root account remains locked. Build artifacts are written to
`build/tmp/deploy/images/raspberrypi5/`.

## Flash

Ensure the CM5 bootloader and carrier support the chosen boot medium (USB, SD,
or eMMC). Write the image to that medium (this erases the target device):

```sh
IMAGE=$(find build/tmp/deploy/images/raspberrypi5 \
  -maxdepth 1 -name '*.rootfs.wic.bz2' -print -quit)
sudo bmaptool copy "$IMAGE" /dev/sdX
sync
```

On a carrier exposing Ethernet as `eth0`, configure the host adapter on
`192.168.50.0/24` (for example, the Mac at `192.168.50.1/24`). After boot, connect with
`ssh root@192.168.50.2`. The serial console is `ttyAMA10`.

## Verify

```sh
zcat /proc/config.gz | grep -E 'CONFIG_(PREEMPT_RT|HZ_1000)='
systemctl is-active systemd-networkd
systemctl is-active systemd-resolved
ip -4 address show dev eth0
ip route show default
resolvectl status eth0
cyclictest --help
ppstest /dev/pps0
```

GitHub Actions builds and uploads the compressed WIC image and bmap file.
