#!/bin/sh
# ============================================================================
#  install.sh —— 鲲鹏 NRadio 路由器一键恢复（唯一需要记住的命令）
#
#  一行命令（SSH 进路由器后执行）：
#      wget -qO /tmp/kp.sh https://raw.githubusercontent.com/h910056902/nros-panel/main/install.sh && sh /tmp/kp.sh
#
#  它会自己判断该干什么，全程无需干预：
#      存储没准备好 → 重建 TF 卡分区 → 重启 → 开机后自动接着把安装跑完
#      存储已就绪   → 直接装 OpenClash(外网) + Docker + 1Panel
#
#  可调参数（写在命令前面即可，例如 PANEL_PORT=10091 sh /tmp/kp.sh）：
#      SUB_URL=https://机场订阅   顺带把订阅也配好
#      PANEL_PORT=10091           换 1Panel 端口
#      OVERLAY_SIZE=8G            换系统分区大小（默认 16G；重新分区时才生效，
#                                 需配合 FORCE=1 走重建流程）
#      FORCE=1                    卡上确实有数据，也要重建（给 kp-storage-init 的安全闸放行）
#      REBUILD=1                  强制走「重建 TF 卡」流程 —— 存储明明是好的也要
#                                 推倒重来（换 OVERLAY_SIZE / 换分区方案时用），
#                                 自动蕴含 FORCE=1，清空卡后重启自动续跑安装
#      NO_REBOOT=1                做完不自动重启，便于人工核对后再手动 reboot
#      SCRIPT=kp-install.sh       只跑指定脚本（跳过自动判断）
#
#  仓库文件分工：
#      install.sh          本文件：引导器 + 流程编排
#      kp-ui.sh            终端界面库（改界面只改它）
#      kp-install.sh       主安装脚本：换源 / OpenClash / Docker / 1Panel
#      kp-ocspeed.sh       OpenClash 自动测速插件（自建，opkg 里没有）
#      kp-storage-init.sh  TF 卡分区与格式化
#      kp-ui-preview.sh    界面预览（本地开发用，设备上不需要）
# ============================================================================
set -eu

# set -e 下任何命令返回非 0 都会让脚本**静默退出**。异常中断时至少报出退出码。
# ⚠️ 不能用 `trap ... ERR`：busybox 的 ash 不认这个信号（报 invalid signal specification）。
trap 'rc=$?; [ "$rc" = 0 ] || echo "  ✗ 引导器中断（rc=$rc）" >&2' EXIT

REPO=h910056902/nros-panel
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TMP=/tmp/kp-nros

# 可用环境变量覆盖
: "${DISK:=/dev/mmcblk0}"                 # TF 卡设备
: "${DATA_DIR:=/mnt/storage/data}"        # 数据分区挂载点（判断「存储是否就绪」靠它）
: "${NO_REBOOT:=0}"                       # 1 = 跳过自动重启（核对后再手动 reboot）

# ---------------- 下载 ----------------
# 实测：本设备上 curl 直连 raw.githubusercontent.com 会失败（返回 000），
# 同一地址换 wget 就能拿到 —— 两个工具的网络栈不一样，所以都要试一遍，
# 别把一次源切换浪费在工具差异上。
get() {
  HAS_DL=0
  if command -v curl >/dev/null 2>&1; then
    HAS_DL=1
    curl -fsSL -m 180 -o "$2" "$1" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    HAS_DL=1
    wget -q -T 180 -O "$2" "$1" && return 0
  fi
  [ "$HAS_DL" = 1 ] || { echo "  ✗ 设备上没有 curl / wget：先 opkg update && opkg install curl" >&2; exit 1; }
  return 1
}

fetch() {
  mkdir -p "$TMP"
  for base in "$RAW" "https://ghfast.top/$RAW" "https://gh-proxy.com/$RAW"; do
    if get "$base/$1" "$TMP/$1" 2>/dev/null && [ -s "$TMP/$1" ]; then
      echo "  ✓ 已获取 $1"
      return 0
    fi
  done
  echo "  ✗ $1 下载失败 —— 先确认设备能上网：ping -c2 223.5.5.5" >&2
  return 1
}

# 把调用者传进来的参数透传给子脚本
# （shell 变量默认不跨进程继承，必须显式 export，否则子脚本收不到）
pass() {
  # 注：曾经导出的 DOCKER_ENABLE_BRIDGE 已从这里删除 —— 内核没有 veth，容器只能
  # 走 host 网络，kp-install.sh 里那段"切到网桥"的逻辑早已移除。留着它是个
  # 没人读的假开关：用户设了它以为会生效，实际什么都不会发生。
  for v in FORCE SUB_URL SUB_NAME SUB_UA CORE_TYPE OC_VER PANEL_PORT PANEL_DIR \
           PANEL_USER PANEL_PASS PANEL_ENT SKIP \
           DISK OVERLAY_SIZE DATA_DIR NO_REBOOT \
           OCS_GROUP OCS_INTERVAL OCS_ENABLE OCS_RUN OCS_STORE \
           DOCKER_MIRRORS DOCKER_SMOKE APPS; do
    eval "val=\${$v:-}"
    if [ -n "$val" ]; then export "$v=$val"; fi
  done
}

# ---------------- 清掉上一次残留的「开机续跑」代码（保证幂等）----------------
clear_auto() {
  [ -f /etc/rc.local ] || return 0
  grep -q 'kp-auto' /etc/rc.local 2>/dev/null && sed -i '/kp-auto/d' /etc/rc.local || :
}

# ---------------- 把当前 overlay 迁到新卡，并预置开机续跑 ----------------
# 这里是整个一键流程的关键，分两件事：
#
# 1) 迁移 overlay 内容。新格式化出来的分区是空的，overlayfs 一旦切过去，
#    /etc 下所有配置都会回落到只读的 /rom 出厂值 —— 而 /rom 的 root 是
#    **空密码**（`root::0:0:...`），SSH 会直接登不上，LAN IP / 防火墙规则
#    也会一起回退。所以必须把当前 overlay 的 upper/work 整个搬过去。
#    这不是我们的发明：厂商自带的 SD 卡页面 sd.lua 里
#    make_sysupgrade_backup() 就是 `cp -a /overlay/upper` + `/overlay/work`，
#    并以「卡上存在 upper/etc/config」作为可用的硬判据，这里照办。
#
# 2) 预置续跑钩子。重启后 /overlay 换成卡上分区，现在系统里写的文件都会
#    消失，所以续跑代码要在第 1 步搬完之后、直接写进卡上的 rc.local。
#    执行它的是 /rom 自带的 /etc/init.d/done（S95done），不依赖 overlay。
arm_auto() {
  PREP=/mnt/kp-prep
  # 热插拔脚本可能已经把 p1 挂到 /tmp/storage 下了，先摘掉，避免挂两处
  umount /tmp/storage/"$(basename "$DISK")p1" /mnt/"$(basename "$DISK")p1" "$PREP" 2>/dev/null || :
  mkdir -p "$PREP"
  mount -t f2fs "${DISK}p1" "$PREP" || { echo "  ! 续跑预置失败：${DISK}p1 挂不上" >&2; return 1; }

  rm -rf "$PREP/upper" "$PREP/work"
  cp -a /overlay/upper "$PREP/upper" 2>/dev/null || :
  cp -a /overlay/work  "$PREP/work"  2>/dev/null || :
  if [ ! -d "$PREP/upper/etc/config" ]; then
    echo "  ! 预置失败：卡上缺少 upper/etc/config（厂商 sd.lua 的可用判据）" >&2
    umount "$PREP" 2>/dev/null || :
    return 1
  fi
  echo "  ✓ 当前 overlay 配置已整体迁移到卡上（含 SSH 密钥与网络配置）"

  cat > "$PREP/upper/etc/rc.local" <<EOF
#!/bin/sh
# 本文件由 nros-panel 的 install.sh 预置

if grep -qE MT798 /tmp/sysinfo/board_name; then
	echo 3 > /proc/sys/vm/drop_caches
fi

# >>> kp-auto >>>
# 新 overlay 就位后，把安装接着跑完；完成即自删，不会重复执行。
# 这里同样走「三源 + curl/wget 双栈」，理由见上面 get() 的注释。
(
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break
    sleep 10
  done
  sleep 10
  for u in "$RAW" "https://ghfast.top/$RAW" "https://gh-proxy.com/$RAW"; do
    curl -fsSL -m 120 -o /tmp/kp-auto.sh "\$u/install.sh" 2>/dev/null ||
      wget -q -T 120 -O /tmp/kp-auto.sh "\$u/install.sh" 2>/dev/null || continue
    [ -s /tmp/kp-auto.sh ] || continue
    sh /tmp/kp-auto.sh >>/tmp/kp-auto.log 2>&1
    break
  done
  sed -i '/kp-auto/d' /etc/rc.local
) &
# <<< kp-auto <<<

exit 0
EOF
  chmod 755 "$PREP/upper/etc/rc.local"
  sync
  umount "$PREP" 2>/dev/null || :
  echo "  ✓ 已预置开机续跑"
}

# ---------------- 取脚本并执行（界面库必须与主脚本同目录）----------------
run() {
  fetch kp-ui.sh || return 1
  fetch kp-store-lib.sh || return 1   # 商店注册共享库（kp-install / kp-ocspeed 都用）
  fetch "$1"     || return 1
  pass
  export KP_TMP="$TMP"   # 子脚本复用已下载的文件，避免重复拉取
  echo
  echo ">>> 执行 $1"
  sh "$TMP/$1"
}

# 跳过列表里是否含某项（SKIP=oc,docker,panel,ocspeed）
skip_has() {
  case ",${SKIP:-}," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# ============================== 主流程 ==============================
echo ">>> nros-panel · 鲲鹏路由器一键恢复"
clear_auto

# REBUILD=1：无视「存储已就绪」，强制走重建流程（重新分区 / 改分区大小时用）。
# 它天然蕴含 FORCE=1 —— kp-storage-init 的安全闸需要它才肯对在用的卡动手。
if [ "${REBUILD:-0}" = 1 ]; then
  export FORCE=1
  echo "  ! REBUILD=1：强制重建 TF 卡（卡上全部数据将被清空）"
fi

# 指定了脚本：跳过自动判断，直接执行
if [ -n "${SCRIPT:-}" ]; then
  echo "  · 指定脚本：$SCRIPT"
  run "$SCRIPT"
  exit 0
fi

# REBUILD=1 时不看就绪状态，直接落到重建分支
if [ "${REBUILD:-0}" != 1 ] \
   && [ "$(awk '$2=="/overlay"{print $1}' /proc/mounts)" = "${DISK}p1" ]; then
  # ---------- 存储就绪：直接安装 ----------
  # 判据刻意用「/overlay 是不是由这张卡的 p1 承载」，而不是「/mnt/storage/data
  # 挂上了没」。后者不可靠：固件热插拔会把数据分区先挂到 /tmp/storage/<设备名>，
  # 之后 /etc/init.d/fstab 的 block mount 看到设备"已被挂载"就跳过，目标点可以
  # 一直空着（实测 block mount 返回 0 却没挂上）。用设备名判断则与厂商
  # sd.lua 里 action_get_partinfo 的判定方式一致。
  echo "  ✓ 存储已就绪（/overlay 在 ${DISK}p1）"
  echo
  run kp-install.sh || {
    echo
    echo "  ✗ 安装中断。脚本是幂等的 —— 修掉上面报的问题后，重跑同一条命令即可。" >&2
    exit 1
  }

  # ---------- ocspeed 自动测速（OpenClash 之上的自建插件）----------
  # 它不在任何 opkg 源里，overlay 重建就会消失，所以每次恢复都要显式装一遍。
  # 失败不阻断整条流水线：外网/Docker/1Panel 已经可用。
  if ! skip_has ocspeed; then
    run kp-ocspeed.sh || echo "  ! ocspeed 未装上（不影响其它组件，可单独重跑：SCRIPT=kp-ocspeed.sh）"
  fi
else
  # ---------- 存储未就绪：重建 → 重启 → 自动续跑 ----------
  echo "  ! 存储未就绪（TF 卡还没分区 / 没挂载）"
  echo "  ! 接下来会重建 TF 卡，卡上现有内容将被清空"
  echo "  ! 若卡上还有要留的数据，现在就按 Ctrl-C，把卡取出来备份"
  echo
  sleep 5
  run kp-storage-init.sh || {
    echo
    echo "  ✗ 存储初始化未完成，已中止（没有重启、没有继续改动）" >&2
    exit 1
  }
  arm_auto || { echo "  ✗ 续跑预置失败 —— 请手动 reboot，起来后重跑同一条命令" >&2; exit 1; }
  echo
  if [ "$NO_REBOOT" = 1 ]; then
    echo ">>> NO_REBOOT=1：已跳过自动重启。核对无误后手动执行 reboot 即可。"
    exit 0
  fi
  echo ">>> 10 秒后自动重启"
  echo ">>> 重启后会自动接着装，进度： ssh 进来 tail -f /tmp/kp-auto.log"
  sleep 10
  reboot
fi
