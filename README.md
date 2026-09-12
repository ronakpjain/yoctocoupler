# Yoctocoupler CM5 image

Minimal 64-bit Yocto image for the Raspberry Pi Compute Module 5 IO Board with:

- Raspberry Pi Linux 6.12 with PREEMPT_RT, 1 kHz timers, and GPIO17 PPS
- systemd-networkd with wired DHCP
- OpenSSH and `rt-tests`

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
`build/tmp/deploy/images/raspberrypi-cm5-io-board/`.

## Flash

Ensure the CM5 EEPROM permits USB mass-storage boot, then write the image to a
USB drive or SD card (this erases the target device):

```sh
IMAGE=$(find build/tmp/deploy/images/raspberrypi-cm5-io-board \
  -maxdepth 1 -name '*.rootfs.wic.bz2' -print -quit)
sudo bmaptool copy "$IMAGE" /dev/sdX
sync
```

After boot, find the DHCP address and connect with `ssh root@<address>`. The
serial console is `ttyAMA10`.

## Verify

```sh
zcat /proc/config.gz | grep -E 'CONFIG_(PREEMPT_RT|HZ_1000)='
systemctl is-active systemd-networkd
cyclictest --help
ppstest /dev/pps0
```

GitHub Actions builds and uploads the compressed WIC image and bmap file.
