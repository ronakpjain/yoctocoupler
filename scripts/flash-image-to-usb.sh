#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: flash-image-to-usb.sh [--dry-run] [--allow-nonremovable] IMAGE.wic[.bz2] USB_DEVICE

Write a built WIC image to a USB/removable whole-disk device. Flashing
replaces its partition table and image region; existing data is not preserved.
This is not a secure wipe of any extra capacity beyond the image. The script
requires an interactive typed confirmation and refuses mounted devices and
the current root disk.

Options:
      --dry-run             Validate and show the selected image/device; do not write
      --allow-nonremovable  Allow devices not reported as USB/removable by Linux
  -h, --help                Show this help

Use a whole disk (for example /dev/sdX or /dev/disk/by-id/usb-...), not a
partition. Prefer the persistent /dev/disk/by-id path. The script uses
bmaptool when installed, otherwise dd; compressed .wic.bz2 images are
supported by both paths.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

allow_nonremovable=0
dry_run=0
while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --allow-nonremovable)
      allow_nonremovable=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -* )
      die "unknown option: $1 (see --help)"
      ;;
    *)
      break
      ;;
  esac
done
(($# == 2)) || { usage >&2; die 'provide an image and a whole-disk USB device'; }
image_arg=$1
target_arg=$2

if ! image=$(realpath -e -- "$image_arg"); then
  die "image not found: $image_arg"
fi
[[ -f $image && -r $image ]] || die "image is not a readable regular file: $image"
case "$image" in
  *.wic.bz2) compressed=1 ;;
  *.wic) compressed=0 ;;
  *) die 'image must end in .wic or .wic.bz2' ;;
esac
if ! target=$(realpath -e -- "$target_arg"); then
  die "device not found: $target_arg"
fi
[[ -b $target ]] || die "target is not a block device: $target"

for tool in lsblk findmnt realpath grep wc swapon; do
  command -v "$tool" >/dev/null 2>&1 || die "required safety tool not found: $tool"
done
if ((compressed)); then
  command -v bzip2 >/dev/null 2>&1 || die 'required tool not found: bzip2'
fi
bmaptool_bin=$(command -v bmaptool 2>/dev/null || true)
if [[ -z $bmaptool_bin ]]; then
  command -v dd >/dev/null 2>&1 || die 'install bmaptool or provide dd for the raw-write fallback'
fi
command -v sync >/dev/null 2>&1 || die 'required tool not found: sync'

# Capture fields that normally identify a physical device and its capacity.
# Rechecking these after the prompt/authentication binds confirmation to the
# device the user saw, even when a /dev/sdX name is reassigned.
device_fingerprint() {
  local device=$1 field value
  for field in TYPE TRAN RM SIZE MODEL SERIAL WWN MAJ:MIN; do
    value=$(lsblk --nodeps --noheadings --raw --output "$field" -- "$device") || return 1
    printf '%s=%q\n' "$field" "$value"
  done
}

target_identity=''
# Validate the target as a whole disk, prove the root backing chain, and refuse
# to overwrite mounted filesystems or active swap. Inspection failures abort.
validate_target() {
  local current_target device_type removable transport
  local root_source root_real root_tree mountpoints mount_sources
  local mount_source mount_real mount_tree swap_sources swap_source swap_real swap_tree
  local current_identity

  current_target=$(realpath -e -- "$target_arg") || die "target identifier no longer resolves: $target_arg"
  [[ $current_target == "$target" ]] || die "target identifier now resolves to a different device: $current_target"
  [[ -b $current_target ]] || die "target is no longer a block device: $current_target"
  device_type=$(lsblk --nodeps --noheadings --raw --output TYPE -- "$current_target") || \
    die 'could not inspect target device type'
  [[ $device_type == disk ]] || die "select a whole disk, not a partition (target type: $device_type)"

  removable=$(lsblk --nodeps --noheadings --raw --output RM -- "$current_target") || die 'could not inspect removable status'
  transport=$(lsblk --nodeps --noheadings --raw --output TRAN -- "$current_target") || die 'could not inspect device transport'
  if [[ $removable != 1 && ${transport,,} != usb && $allow_nonremovable -eq 0 ]]; then
    die "Linux does not identify $current_target as USB/removable; verify the device or use --allow-nonremovable"
  fi

  if ! root_source=$(findmnt --noheadings --raw --output SOURCE --target /); then
    die 'could not determine the current root filesystem source'
  fi
  root_source=${root_source%%\[*}
  [[ -n $root_source && -b $root_source ]] || \
    die "cannot establish the root filesystem's backing block device ($root_source); run this on the Linux host"
  root_real=$(realpath -e -- "$root_source") || die "could not resolve root block source: $root_source"
  root_tree=$(lsblk --inverse --list --noheadings --paths --output NAME -- "$root_real") || \
    die "could not inspect the root backing-device chain: $root_real"
  [[ -n $root_tree ]] && grep -Fqx -- "$root_real" <<< "$root_tree" || \
    die "could not establish the complete root backing-device chain: $root_real"
  if grep -Fqx -- "$current_target" <<< "$root_tree"; then
    die "refusing to overwrite $current_target: it contains the current root filesystem"
  fi

  mountpoints=$(lsblk --list --noheadings --paths --output MOUNTPOINT -- "$current_target") || \
    die 'could not inspect target mountpoints'
  if grep -q '[^[:space:]]' <<< "$mountpoints"; then
    die 'target or one of its partitions is mounted; unmount it first'
  fi
  if ! mount_sources=$(findmnt --list --noheadings --output SOURCE); then
    die 'could not enumerate mounted filesystem sources'
  fi
  [[ -n $mount_sources ]] || die 'mount enumeration returned no sources; refusing to write'
  while IFS= read -r mount_source; do
    mount_source=${mount_source%%\[*}
    [[ -n $mount_source && -b $mount_source ]] || continue
    mount_real=$(realpath -e -- "$mount_source") || die "could not resolve mounted block source: $mount_source"
    mount_tree=$(lsblk --inverse --list --noheadings --paths --output NAME -- "$mount_real") || \
      die "could not inspect mounted block source: $mount_real"
    [[ -n $mount_tree ]] || die "could not establish mounted block-source ancestry: $mount_real"
    if grep -Fqx -- "$current_target" <<< "$mount_tree"; then
      die "target backs a mounted filesystem ($mount_real); unmount it first"
    fi
  done <<< "$mount_sources"

  if ! swap_sources=$(swapon --show --noheadings --raw --output NAME); then
    die 'could not enumerate active swap devices'
  fi
  while IFS= read -r swap_source; do
    [[ -n $swap_source && -b $swap_source ]] || continue
    swap_real=$(realpath -e -- "$swap_source") || die "could not resolve active swap source: $swap_source"
    swap_tree=$(lsblk --inverse --list --noheadings --paths --output NAME -- "$swap_real") || \
      die "could not inspect active swap source: $swap_real"
    [[ -n $swap_tree ]] || die "could not establish active swap ancestry: $swap_real"
    if grep -Fqx -- "$current_target" <<< "$swap_tree"; then
      die "target backs active swap ($swap_real); disable it first"
    fi
  done <<< "$swap_sources"

  if [[ -n $target_identity ]]; then
    current_identity=$(device_fingerprint "$current_target") || die 'could not recheck target hardware identity'
    [[ $current_identity == "$target_identity" ]] || \
      die 'target hardware identity or capacity changed after confirmation; nothing was written'
  fi
}
validate_target

target_identity=$(device_fingerprint "$target") || die 'could not capture target hardware identity'
if ((compressed)); then
  if ! image_bytes=$(bzip2 -dc -- "$image" | wc -c); then
    die 'could not decompress the input image to determine its size'
  fi
else
  image_bytes=$(wc -c < "$image")
fi
image_bytes=${image_bytes//[[:space:]]/}
[[ $image_bytes =~ ^[0-9]+$ ]] || die 'could not determine image size'

device_bytes=''
check_device_capacity() {
  local current_bytes
  current_bytes=$(lsblk --bytes --nodeps --noheadings --raw --output SIZE -- "$target") || \
    die 'could not determine target capacity'
  [[ $current_bytes =~ ^[0-9]+$ ]] || die 'could not parse target capacity'
  if [[ -n $device_bytes && $current_bytes != "$device_bytes" ]]; then
    die 'target capacity changed after confirmation; nothing was written'
  fi
  ((current_bytes >= image_bytes)) || \
    die "USB device is too small (${current_bytes} bytes; image expands to ${image_bytes} bytes)"
  device_bytes=$current_bytes
}
check_device_capacity

printf 'Image: %s (%s bytes uncompressed)\n' "$image" "$image_bytes"
printf 'Confirmed identifier: %s\nResolved block device: %s\n' "$target_arg" "$target"
if [[ $target_arg != /dev/disk/by-id/* ]]; then
  printf 'For extra protection against device renumbering, prefer /dev/disk/by-id/…\n'
fi
printf 'Device and hardware identity:\n'
lsblk --list --paths --output NAME,TYPE,TRAN,RM,SIZE,MODEL,SERIAL,WWN,MAJ:MIN -- "$target"
if [[ -n $bmaptool_bin ]]; then
  printf 'Write method: bmaptool copy --nobmap\n'
else
  printf 'Write method: dd (bmaptool not found)\n'
fi
if ((dry_run)); then
  printf 'Dry run complete; no device was written.\n'
  exit 0
fi

[[ -t 0 ]] || die 'refusing to write without an interactive terminal'
printf '\nWARNING: this overwrites the partition table and image area on %s.\n' "$target_arg"
printf 'Type "ERASE %s" to continue: ' "$target_arg"
IFS= read -r confirmation || die 'confirmation input was closed; nothing was written'
[[ $confirmation == "ERASE $target_arg" ]] || die 'confirmation did not match; nothing was written'

if ((EUID == 0)); then
  ROOT=()
else
  command -v sudo >/dev/null 2>&1 || die 'sudo is required to write to the USB device'
  sudo -v || die 'could not obtain sudo authorization'
  ROOT=(sudo)
fi
run_root() {
  "${ROOT[@]}" "$@"
}

# Resolve the persistent identifier, identity, root/mount/swap ancestry and
# capacity again immediately before opening the destination for writing.
validate_target
check_device_capacity
if [[ -n $bmaptool_bin ]]; then
  run_root "$bmaptool_bin" copy --nobmap "$image" "$target_arg"
elif ((compressed)); then
  bzip2 -dc -- "$image" | run_root dd of="$target_arg" bs=4M conv=fsync status=progress
else
  run_root dd if="$image" of="$target_arg" bs=4M conv=fsync status=progress
fi
run_root sync
printf 'Flash completed and synchronized. You can safely eject %s.\n' "$target_arg"
