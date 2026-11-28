#!/bin/bash
# Replaces swap on disk (partition, LVM volume or file) by the zram swap, and
# gives the freed space to the root filesystem. Run by hookscript.pl (steps/post-start/70-template-base.pl, as the
# transient unit hookscript-remove-disk-swap) once zram swap is active; output
# in /var/log/hookscript-remove-disk-swap.log.
#
#   1. backs up /etc/fstab and the partition table (/root/*.vmhook-swap.bak)
#   2. swapoff, swap lines out of /etc/fstab, swap files deleted
#   3. hibernation resume off (RESUME=none, resume= out of GRUB), otherwise
#      every boot waits ~30s for the swap device that's gone
#   4. deletes swap partitions that sit after the root partition on the root
#      disk, and an MBR extended partition after root once it's empty; swap
#      LVs in LVM are removed. Swap anywhere else is only switched off.
#   5. grows root into the freed space (auto-extend-disk.sh)
set -u
log() { echo "remove-disk-swap: $*"; }

swapon --show=NAME --noheadings | grep -q '^/dev/zram' \
    || { log "no zram swap active, leaving disk swap alone"; exit 1; }

# --- what's swap on disk: active ones + the ones in fstab
resolve() {   # fstab spec -> device path (or the spec itself, e.g. a file)
    case $1 in
        UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) findfs "$1" 2>/dev/null || echo "$1" ;;
        *) echo "$1" ;;
    esac
}
mapfile -t swaps < <(
    { swapon --show=NAME --noheadings | grep -v '^/dev/zram'
      awk '$1 !~ /^#/ && $3 == "swap" {print $1}' /etc/fstab | while read -r s; do resolve "$s"; done
    } | while read -r p; do [ -b "$p" ] && readlink -f "$p" || echo "$p"; done | sort -u)
[ ${#swaps[@]} -gt 0 ] || { log "no swap on disk"; exit 0; }
log "swap on disk: ${swaps[*]}"

# --- root disk
ROOT_SRC=$(findmnt -n -o SOURCE /)
root_dev=$(readlink -f "$ROOT_SRC")
if [ "$(lsblk -no TYPE "$root_dev" | head -n1)" = lvm ]; then
    root_part=$(readlink -f "$(pvs --noheadings -o pv_name 2>/dev/null | awk 'NR==1{print $1}')")
else
    root_part=$root_dev
fi
DISK=/dev/$(lsblk -no PKNAME "$root_part" | head -n1)
root_start=$(cat "/sys/class/block/$(basename "$root_part")/start")
log "root on $root_part (disk $DISK)"

# --- 1. backups
cp -n /etc/fstab /root/fstab.vmhook-swap.bak
sfdisk -d "$DISK" > /root/partition-table.vmhook-swap.bak 2>/dev/null || true
log "backups: /root/fstab.vmhook-swap.bak, /root/partition-table.vmhook-swap.bak"

# --- 2. swap off, out of fstab
for p in "${swaps[@]}"; do swapoff "$p" 2>/dev/null; done
if swapon --show=NAME --noheadings | grep -qv '^/dev/zram'; then
    log "swapoff failed (not enough free memory?), stopping"; exit 1
fi
awk '!($1 !~ /^#/ && $3 == "swap")' /etc/fstab > /etc/fstab.vmhook-new && mv -f /etc/fstab.vmhook-new /etc/fstab
log "swap off, removed from /etc/fstab"

# --- 3. hibernation resume off
r=/etc/initramfs-tools/conf.d/resume
if [ -f "$r" ] && ! grep -qx 'RESUME=none' "$r"; then
    echo RESUME=none > "$r"
    update-initramfs -u -k all >/dev/null 2>&1 && log "initramfs: RESUME=none"
fi
if grep -q 'resume=' /etc/default/grub 2>/dev/null; then
    sed -i -E 's/ ?resume=[^ "]*//g' /etc/default/grub
    update-grub >/dev/null 2>&1 && log "GRUB: resume= removed"
fi

# --- 4. files, LVs, partitions (partitions highest number first: deleting an
# MBR logical partition renumbers the ones after it)
parts=()
for p in "${swaps[@]}"; do
    if [ -f "$p" ]; then
        rm -f "$p" && log "deleted swap file $p"
        continue
    fi
    [ -b "$p" ] || continue
    case $(lsblk -no TYPE "$p" | head -n1) in
        lvm)
            lv=$(lvs --noheadings -o lv_path 2>/dev/null | awk '{print $1}' \
                 | while read -r l; do [ "$(readlink -f "$l")" = "$p" ] && echo "$l"; done)
            [ -n "$lv" ] && lvremove -y "$lv" >/dev/null && log "removed swap LV $lv"
            ;;
        part)
            name=$(basename "$p")
            pdisk=/dev/$(lsblk -no PKNAME "$p" | head -n1)
            if [ "$pdisk" = "$DISK" ] && [ "$(cat "/sys/class/block/$name/start")" -gt "$root_start" ]; then
                parts+=("$(cat "/sys/class/block/$name/partition") $p")
            else
                log "swap partition $p is not after root on $DISK, left in place (switched off)"
            fi
            ;;
    esac
done
for entry in $(printf '%s\n' "${parts[@]}" | sort -rn | tr ' ' ':'); do
    n=${entry%%:*} p=${entry#*:}
    sfdisk --no-reread --delete "$DISK" "$n" >/dev/null 2>&1 && partx -d --nr "$n" "$DISK" 2>/dev/null
    log "deleted swap partition $p"
done

# MBR: an extended partition after root with no logical partitions left in it
if sfdisk -d "$DISK" 2>/dev/null | grep -q '^label: dos'; then
    ext=$(sfdisk -d "$DISK" | awk '/type=(5|f|85)([ ,]|$)/ {print $1}')
    logicals=$(sfdisk -d "$DISK" | grep -cE '^/dev/[a-z0-9]*[a-z]p?([5-9]|[1-9][0-9]+) :')
    if [ -n "$ext" ] && [ "$logicals" -eq 0 ] \
       && [ "$(cat "/sys/class/block/$(basename "$ext")/start")" -gt "$root_start" ]; then
        n=$(cat "/sys/class/block/$(basename "$ext")/partition")
        sfdisk --no-reread --delete "$DISK" "$n" >/dev/null 2>&1 && partx -d --nr "$n" "$DISK" 2>/dev/null
        log "deleted empty extended partition $ext"
    fi
fi

# --- 5. grow root
/usr/local/sbin/auto-extend-disk.sh
log "done, root is now $(df -h --output=size / | tail -n1 | tr -d ' ')"
