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
#      FORCE=1                    卡上确实有数据，也要重建
#      SCRIPT=kp-install.sh       只跑指定脚本（跳过自动判断）
#
#  仓库文件分工：
#      install.sh          本文件：引导器 + 流程编排
#      kp-ui.sh            终端界面库（改界面只改它）
#      kp-install.sh       主安装脚本：换源 / OpenClash / Docker / 1Panel
#      kp-storage-init.sh  TF 卡分区与格式化
#      kp-ui-preview.sh    界面预览（本地开发用，设备上不需要）
# ============================================================================
set -eu

REPO=h910056902/nros-panel
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TMP=/tmp/kp-nros

# 可用环境变量覆盖
: "${DISK:=/dev/mmcblk0}"                 # TF 卡设备
: "${DATA_DIR:=/mnt/storage/data}"        # 数据分区挂载点（判断「存储是否就绪」靠它）

# ---------------- 下载：三源回退（GitHub 直连 → ghfast → gh-proxy）----------------
get() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -m 180 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -T 180 -O "$2" "$1"
  else echo "  ✗ 设备上没有 curl / wget：先执行 opkg update && opkg install curl" >&2; exit 1
  fi
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
  for v in FORCE SUB_URL SUB_NAME SUB_UA CORE_TYPE OC_VER PANEL_PORT PANEL_DIR \
           PANEL_USER PANEL_PASS PANEL_ENT SKIP DOCKER_ENABLE_BRIDGE \
           DISK OVERLAY_SIZE DATA_DIR; do
    eval "val=\${$v:-}"
    if [ -n "$val" ]; then export "$v=$val"; fi
  done
}

# ---------------- 清掉上一次残留的「开机续跑」代码（保证幂等）----------------
clear_auto() {
  [ -f /etc/rc.local ] || return 0
  grep -q 'kp-auto' /etc/rc.local 2>/dev/null && sed -i '/kp-auto/d' /etc/rc.local || :
}

# ---------------- 往「新卡的 overlay」里预置开机续跑 ----------------
# 这里是整个一键流程的关键：重启后 /overlay 会换成新卡上的分区，
# 现在系统里写的任何文件都会随之消失。所以续跑代码必须直接预置进
# 新卡 p1 的 upper 层（overlayfs 上层优先于 /rom），再由 /rom 自带的
# /etc/init.d/done（S95done）在开机时执行 /etc/rc.local 把它跑起来。
arm_auto() {
  PREP=/mnt/kp-prep
  mkdir -p "$PREP"
  mount -t f2fs "${DISK}p1" "$PREP" || { echo "  ! 续跑预置失败：${DISK}p1 挂不上" >&2; return 1; }
  mkdir -p "$PREP/upper/etc" "$PREP/work"
  cat > "$PREP/upper/etc/rc.local" <<EOF
#!/bin/sh
# 本文件由 nros-panel 的 install.sh 预置

if grep -qE MT798 /tmp/sysinfo/board_name; then
	echo 3 > /proc/sys/vm/drop_caches
fi

# >>> kp-auto >>>
# 新 overlay 就位后，把安装接着跑完；完成即自删，不会重复执行。
(
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && break
    sleep 10
  done
  sleep 10
  curl -fsSL -m 180 "$RAW/install.sh" | sh >>/tmp/kp-auto.log 2>&1
  sed -i '/kp-auto/d' /etc/rc.local
) &
# <<< kp-auto <<<

exit 0
EOF
  chmod 755 "$PREP/upper/etc/rc.local"
  sync
  umount "$PREP"
  echo "  ✓ 已预置开机续跑"
}

# ---------------- 取脚本并执行（界面库必须与主脚本同目录）----------------
run() {
  fetch kp-ui.sh || return 1
  fetch "$1"     || return 1
  pass
  echo
  echo ">>> 执行 $1"
  sh "$TMP/$1"
}

# ============================== 主流程 ==============================
echo ">>> nros-panel · 鲲鹏路由器一键恢复"
clear_auto

# 指定了脚本：跳过自动判断，直接执行
if [ -n "${SCRIPT:-}" ]; then
  echo "  · 指定脚本：$SCRIPT"
  run "$SCRIPT"
  exit 0
fi

if grep -q " $DATA_DIR " /proc/mounts; then
  # ---------- 存储就绪：直接安装 ----------
  echo "  ✓ 存储已就绪（$DATA_DIR）"
  echo
  run kp-install.sh || {
    echo
    echo "  ✗ 安装中断。脚本是幂等的 —— 修掉上面报的问题后，重跑同一条命令即可。" >&2
    exit 1
  }
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
  echo ">>> 10 秒后自动重启"
  echo ">>> 重启后会自动接着装，进度： ssh 进来 tail -f /tmp/kp-auto.log"
  sleep 10
  reboot
fi
