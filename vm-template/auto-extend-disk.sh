#!/bin/bash
# Grow the root partition and filesystem to fill the disk.
# Runs at boot and on a live resize (udev RESIZE=1 -> auto-extend-disk.service).
# Works out the disk itself, so virtio-blk (vda), scsi (sda) and nvme all work.
set -u

ROOT_SRC=$(findmnt -n -o SOURCE /)

# On LVM the root LV sits on a PV partition; otherwise root is the partition itself
if lvs "$ROOT_SRC" >/dev/null 2>&1; then
    PARTITION=$(pvs --noheadings -o pv_name 2>/dev/null | awk 'NR==1{print $1}')
else
    PARTITION=$ROOT_SRC
fi
PARTITION=$(readlink -f "$PARTITION")
PART_NAME=$(basename "$PARTITION")
DISK=/dev/$(lsblk -no PKNAME "$PARTITION" | head -n1)
PART_NUM=$(cat "/sys/class/block/$PART_NAME/partition")

echo "Root on $PARTITION (disk $DISK, partition $PART_NUM)"

# growpart exits 1 with NOCHANGE when there's nothing to grow; that's fine
out=$(growpart "$DISK" "$PART_NUM" 2>&1)
case "$out" in
    CHANGED*)  echo "Partition grown: $out" ;;
    NOCHANGE*) echo "Partition already fills the disk" ;;
    *)         echo "growpart failed: $out" >&2 ;;
esac

if pvs "$PARTITION" >/dev/null 2>&1; then
    pvresize "$PARTITION"
    lvextend -r -l +100%FREE "$ROOT_SRC" 2>/dev/null || true
else
    case "$(blkid -o value -s TYPE "$PARTITION")" in
        ext4|ext3) resize2fs "$PARTITION" ;;
        xfs)       xfs_growfs / ;;
    esac
fi
