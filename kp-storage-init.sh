#!/bin/sh
# ============================================================================
#  kp-storage-init.sh —— TF 卡初始化（分区 + 格式化 + 写 fstab）
#
#  ⚠️  会清空整张卡！只在「换了新卡」或「卡被重置」之后跑一次。
#      卡正常工作时脚本会自己拦下来（除非 FORCE=1）。
#
#  分区规划（以 29G 卡为例）：
#     p1   4G     f2fs  →  /overlay              系统可写层（装软件、存 LuCI 配置）
#     p2   剩余   f2fs  →  /mnt/storage/data     Docker 数据 / 媒体文件
#
#  为什么要分两块：Docker 的 overlay2 存储驱动不能建在 overlayfs 之上，
#  必须有一块「独立挂载的裸文件系统」。p2 就是给它的，所以要单独分区。
#
#  用法：
#     sh kp-storage-init.sh             常规执行（带安全闸）
#     FORCE=1 sh kp-storage-init.sh     明知卡在用也要重建（例如真要推倒重来）
#
#  跑完必须重启才生效：reboot
#
#  依赖：同目录下的 kp-ui.sh（终端界面库，改界面只改那个文件）
# ============================================================================
set -eu

# ---------------------------- 可调参数（一般不用改） ----------------------------
: "${DISK:=/dev/mmcblk0}"              # TF 卡设备节点
: "${OVERLAY_SIZE:=4G}"                # p1 容量，系统可写层够用即可
: "${DATA_DIR:=/mnt/storage/data}"     # p2 挂载点，Docker 数据放这里

P1="${DISK}p1"
P2="${DISK}p2"

# ---------------------------- 界面 ----------------------------
KP_DIR=${0%/*}; [ "$KP_DIR" = "$0" ] && KP_DIR=.     # 取脚本所在目录，不依赖 dirname
if [ ! -f "$KP_DIR/kp-ui.sh" ]; then
  echo "缺少界面库 kp-ui.sh —— 它必须和本脚本放在同一个目录里" >&2
  exit 1
fi
. "$KP_DIR/kp-ui.sh"

ui_init "TF 卡初始化" "分区 · 格式化 · 写 fstab"
ui_meta 设备 "$DISK"
ui_meta 时间 "$(date '+%F %T')"
ui_hr
ui_gap
ui_warn "本脚本会清空整张卡。卡上若还有要留的数据，请先取出来备份。"
ui_warn "卡正在正常使用时脚本会自己拦下来，需要显式 FORCE=1 才会动手。"

# ============================ [1/4] 安全检查 ============================
ui_stage 1 4 "安全检查"
[ "$(id -u)" = 0 ] || ui_fail "请用 root 运行"

[ -b "$DISK" ] || ui_fail "$DISK 不存在 —— 卡没被系统识别" "断电 30 秒 → 取出卡擦净金手指 → 重插到底 → 上电"

SECT=$(cat "/sys/block/$(basename "$DISK")/size" 2>/dev/null || echo 0)
SECT=${SECT:-0}
ui_ok "$DISK 存在，容量约 $((SECT / 2097152)) G"

# 安全闸：如果 /overlay 已经来自这张卡，说明卡是好的，别把数据冲掉
CUR=$(awk '$2=="/overlay"{print $1}' /proc/mounts)
case "$CUR" in
  /dev/mmcblk*)
    [ "${FORCE:-0}" = 1 ] || ui_fail "/overlay 已经在这张卡上（$CUR）—— 卡是好的" \
      "确实要清空重建，请显式加 FORCE=1 重跑"
    ui_warn "FORCE=1：明知卡在用，仍然继续重建"
    ;;
esac
ui_ok "检查通过"
ui_stage_end

# ============================ [2/4] 创建分区 ============================
ui_stage 2 4 "创建分区"
ui_info "p1 = $OVERLAY_SIZE → /overlay，p2 = 剩余 → $DATA_DIR"

# 先卸载可能占用这两个分区的东西，免得格式化时报 busy
umount "$P1" 2>/dev/null || :
umount "$P2" 2>/dev/null || :
umount "$DATA_DIR" 2>/dev/null || :

# 抹掉旧分区表。前 8MB 足够覆盖 MBR 和 GPT 主/备头
dd if=/dev/zero of="$DISK" bs=1M count=8 conv=fsync 2>/dev/null
sync
ui_ok "旧分区表已抹除"

# fdisk 非交互分区：
#   o       新建 DOS(MBR) 分区表
#   n p 1   新建主分区 1，起止扇区回车用默认
#   +4G     分区 1 大小
#   n p 2   新建主分区 2，占满剩余
#   w       写入
( echo o
  echo n; echo p; echo 1; echo; echo "+$OVERLAY_SIZE"
  echo n; echo p; echo 2; echo; echo
  echo w ) | fdisk "$DISK" >/dev/null 2>&1 || ui_fail "fdisk 分区失败"

# 让内核重读分区表并生成设备节点
mdev -s 2>/dev/null || :
sleep 2
if [ ! -b "$P1" ] || [ ! -b "$P2" ]; then
  ui_fail "分区节点未出现（$P1 / $P2）" "内核没重读分区表 —— 执行 reboot，重启后重跑本脚本"
fi
ui_ok "分区已创建：$P1 与 $P2"
ui_stage_end

# ============================ [3/4] 格式化 ============================
ui_stage 3 4 "格式化为 f2fs"
command -v mkfs.f2fs >/dev/null 2>&1 || ui_fail "缺少 mkfs.f2fs（固件自带，本机应有）"

mkfs.f2fs -f -l kpoverlay "$P1" >/dev/null 2>&1 || ui_fail "$P1 格式化失败"
ui_ok "$P1 → f2fs（卷标 kpoverlay）"
mkfs.f2fs -f -l kpstorage "$P2" >/dev/null 2>&1 || ui_fail "$P2 格式化失败"
ui_ok "$P2 → f2fs（卷标 kpstorage）"
ui_stage_end

# ============================ [4/4] 写 fstab ============================
ui_stage 4 4 "写入 fstab（开机自动挂载）"

# 找一个已存在的 fstab mount 段；没有就新建一个
# 用法：mount_index /overlay  →  回显该 target 对应的索引
mount_index() {
  uci show fstab 2>/dev/null \
    | sed -n "s/^fstab\.\(@mount\[[0-9]*\]\)\.target='$1'$/\1/p" | head -n1
}

# --- p1 → /overlay ---
IDX=$(mount_index /overlay)
if [ -z "$IDX" ]; then uci -q add fstab mount >/dev/null; IDX='@mount[-1]'; fi
uci -q set "fstab.$IDX.device=$P1"
uci -q set "fstab.$IDX.target=/overlay"
uci -q set "fstab.$IDX.fstype=f2fs"
uci -q set "fstab.$IDX.enabled=1"
uci -q set "fstab.$IDX.enabled_fsck=0"
ui_ok "$P1 → /overlay"

# --- p2 → DATA_DIR ---
IDX=$(mount_index "$DATA_DIR")
if [ -z "$IDX" ]; then uci -q add fstab mount >/dev/null; IDX='@mount[-1]'; fi
uci -q set "fstab.$IDX.device=$P2"
uci -q set "fstab.$IDX.target=$DATA_DIR"
uci -q set "fstab.$IDX.fstype=f2fs"
uci -q set "fstab.$IDX.enabled=1"
uci -q set "fstab.$IDX.enabled_fsck=0"
ui_ok "$P2 → $DATA_DIR"

uci commit fstab
mkdir -p "$DATA_DIR"
ui_ok "fstab 已提交"
ui_stage_end

# ============================ 收尾 ============================
ui_done
ui_kv 系统 "$P1 → /overlay · f2fs"
ui_kv 数据 "$P2 → $DATA_DIR · f2fs"
ui_kv 接着 "执行 reboot —— 重启后 /overlay 就落在卡上"
ui_hr2
