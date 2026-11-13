#!/bin/bash
# disk-idle: 监控 USB 硬盘盒里各磁盘的真实读写量，把硬盘盒固件的休眠时间"延长"到设定值。
# - 使用期内定时直读整盘第 0 扇区保活，阻止硬盘盒固件提前休眠（如 Orico 30 秒）
# - 闲置满设定时间后停止保活，由硬盘盒固件自动让硬盘停转（脚本不发休眠命令）
# - 每个检测周期重新扫描磁盘，硬盘盒插上/拔掉/重新识别（sdX 变化）都能自动跟上
# - 按 by-id 识别磁盘，盘符变化不影响计时
# - 读写量取自 /sys/block/sdX/stat（内核内存统计，读取不会访问硬盘）
# - 停止保活后，一旦有超过阈值的真实读写，恢复保活并重新计时
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-$DIR/disk-idle.conf}"
CHECK_INTERVAL=20; IDLE_TIMEOUT=3600; MIN_ACTIVITY_KB=0
DISKS="auto"; EXCLUDE=""; DRY_RUN=0
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

log() { echo "$(date '+%F %T') $*"; }

declare -A LAST_SECTORS LAST_ACTIVE ASLEEP DEVNAME

match_any() {   # $1=名字 $2=空格分隔的通配符列表
    local p
    local -; set -f   # 防止通配符被展开成当前目录文件名
    for p in $2; do
        # shellcheck disable=SC2053
        [[ "$1" == $p ]] && return 0
    done
    return 1
}

# 输出 "id sdX"，每行一个要监控的盘
scan_disks() {
    local link id dev
    local -A done_dev=()
    # 每块盘只取一个 id：ata-（含真实序列号）按字母序排在 usb- 前面，优先使用
    for link in /dev/disk/by-id/ata-* /dev/disk/by-id/usb-*; do
        [ -e "$link" ] || continue
        id="$(basename "$link")"
        case "$id" in *-part*) continue ;; esac
        dev="$(basename "$(readlink -f "$link")")"
        [[ "$dev" == sd* ]] || continue
        [ -d "/sys/block/$dev" ] || continue
        [ -n "${done_dev[$dev]+x}" ] && continue
        done_dev[$dev]=1
        match_any "$id" "$EXCLUDE" && continue
        if [ "$DISKS" = "auto" ]; then
            readlink -f "/sys/block/$dev" | grep -q '/usb' || continue
            [ "$(cat "/sys/block/$dev/queue/rotational")" = "1" ] || continue
        else
            match_any "$id" "$DISKS" || continue
        fi
        echo "$id $dev"
    done
}


# 真实读写量（扇区数）：优先统计分区（文件系统的读写都走分区）；
# 保活读的是整盘设备第 0 扇区，只计入整盘统计、不计入分区统计，因此不会被当成"有人在用"。
# 没有分区表的盘只能用整盘统计，减去保活自己读的扇区数。
activity_sectors() {   # $1=id $2=dev
    local part total=0 rd wr found=0
    for part in /sys/block/"$2"/"$2"*; do
        [ -f "$part/stat" ] || continue
        read -r _ _ rd _ _ _ wr _ < "$part/stat" || continue
        total=$((total + rd + wr)); found=1
    done
    if [ "$found" = "0" ]; then
        read -r _ _ rd _ _ _ wr _ < "/sys/block/$2/stat" || return 1
        total=$((rd + wr - ${KA_SECTORS[$1]:-0}))
    fi
    echo "$total"
}

keepalive() {   # $1=id $2=dev
    if [ "$DRY_RUN" = "1" ]; then return 0; fi
    if dd if="/dev/$2" of=/dev/null bs=4096 count=1 iflag=direct status=none 2>/dev/null; then
        KA_SECTORS[$1]=$(( ${KA_SECTORS[$1]:-0} + 8 ))
    else
        log "保活读取失败 $1 (/dev/$2)"
    fi
}

log "启动：周期 ${CHECK_INTERVAL}s，闲置 ${IDLE_TIMEOUT}s 后停止保活，阈值 ${MIN_ACTIVITY_KB}KB/周期，DISKS=$DISKS EXCLUDE=$EXCLUDE DRY_RUN=$DRY_RUN"

declare -A KA_SECTORS
while true; do
    now=$(date +%s)
    declare -A SEEN=()
    while read -r id dev; do
        [ -n "$id" ] || continue
        SEEN[$id]=1

        # 新连接，或重新识别成了别的 sdX（stat 计数会清零）
        if [ -z "${LAST_SECTORS[$id]+x}" ] || [ "${DEVNAME[$id]}" != "$dev" ]; then
            KA_SECTORS[$id]=0
            sectors=$(activity_sectors "$id" "$dev") || continue
            log "发现磁盘 $id (/dev/$dev)，开始监控"
            LAST_SECTORS[$id]=$sectors; LAST_ACTIVE[$id]=$now; ASLEEP[$id]=0; DEVNAME[$id]=$dev
            keepalive "$id" "$dev"
            continue
        fi

        sectors=$(activity_sectors "$id" "$dev") || continue
        delta_kb=$(( (sectors - LAST_SECTORS[$id]) / 2 ))
        LAST_SECTORS[$id]=$sectors
        idle=$(( now - LAST_ACTIVE[$id] ))
        [ "$DRY_RUN" = "1" ] && log "  $id 本周期真实读写 ${delta_kb}KB，已闲置 ${idle}s"

        # 超过阈值才算真正在用，重新计时；小读写（如 ls）不重置计时，也不恢复保活
        if [ "$delta_kb" -gt "$MIN_ACTIVITY_KB" ]; then
            [ "${ASLEEP[$id]}" = "1" ] && log "$id 有读写 ${delta_kb}KB，恢复保活"
            LAST_ACTIVE[$id]=$now; idle=0; ASLEEP[$id]=0
        fi

        if [ "$idle" -lt "$IDLE_TIMEOUT" ]; then
            # 还在使用期内：读一下，阻止硬盘盒固件提前休眠
            keepalive "$id" "$dev"
        elif [ "${ASLEEP[$id]}" = "0" ]; then
            log "$id 已闲置 $((idle / 60)) 分钟，停止保活，交给硬盘盒自动休眠"
            ASLEEP[$id]=1
        fi
    done < <(scan_disks)

    # 清理已断开的盘
    for id in "${!LAST_SECTORS[@]}"; do
        if [ -z "${SEEN[$id]+x}" ]; then
            log "磁盘 $id 已断开"
            unset "LAST_SECTORS[$id]" "LAST_ACTIVE[$id]" "ASLEEP[$id]" "DEVNAME[$id]" "KA_SECTORS[$id]"
        fi
    done
    unset SEEN
    sleep "$CHECK_INTERVAL"
done
