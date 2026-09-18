#!/bin/sh
# ============================================================================
#  kp-ocspeed.sh —— 安装 / 恢复 OpenClash「自动测速」（ocspeed）
#
#  它是什么：
#     每隔 N 分钟把目标策略组里的节点全量测一遍延迟，自动切到最快的那个；
#     另外挂了两条可选的 cron —— 故障自动切换(failover)、备用节点预选(backup)。
#     装好后 LuCI 里多出一个页面：服务 → OpenClash → 自动测速。
#
#  为什么单独拆一个文件：
#     ocspeed 不是 opkg 里的包，是我方自建的（脚本 + LuCI 页面 + UCI 配置）。
#     它跟着 overlay 走 —— 一旦重建 TF 卡 / 重置分区，这三样会一起消失，
#     而且没有 opkg 能帮你装回来。所以恢复流程里必须显式装一次。
#     （2026-09-16 实测：16G 扩容重建后 /usr/libexec/openclash-helper 整个没了）
#
#  可调参数：
#     OCS_GROUP=宝贝云       测速并自动切换的目标策略组（默认取订阅里的「宝贝云」）
#     OCS_INTERVAL=30        测速间隔（分钟）
#     OCS_ENABLE=1           1=装好后即启用（写 cron），0=只装不启用
#     OCS_RUN=1              装好后立刻跑一次（约 2 分钟，72 节点实测 92 秒）
#     SKIP=...,ocspeed       在整条流水线里跳过本步
#
#  幂等：重复执行只覆盖文件、保留已有的 /etc/config/ocspeed 值。
# ============================================================================
set -eu

# ⚠️ busybox 的 ash 不认 `trap ... ERR`，只能用 EXIT。
trap 'rc=$?; [ "$rc" = 0 ] || echo "  ✗ ocspeed 安装中断（rc=$rc）" >&2' EXIT

REPO=h910056902/nros-panel
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
TMP=${KP_TMP:-/tmp/kp-nros}
OC=$TMP/ocspeed

HELPER=/usr/libexec/openclash-helper
DATA=/etc/openclash-helper
LUA_CTRL=/usr/lib/lua/luci/controller
LUA_VIEW=/usr/lib/lua/luci/view

: "${OCS_GROUP:=}"
: "${OCS_INTERVAL:=}"
: "${OCS_ENABLE:=1}"
: "${OCS_RUN:=0}"
: "${DATA_DIR:=/mnt/storage/data}"
: "${OCS_STORE:=1}"                  # 1 = 注册进鲲鹏商店（0 可跳过）
: "${OCS_ICON:=ocspeed.png}"

# ---------------- 下载 ----------------
# 实测本设备 curl 直连 raw.githubusercontent.com 返回 000，wget 却能通；
# 再叠两个镜像源做兜底。别把失败浪费在工具差异上。
# ⚠️ 这个定义必须排在最前面：下面"补下共享库"那段就要用它。原先它写在
#    调用点之后，shell 是顺序解释的 —— 那一整个补下逻辑其实一次都没生效过
#    （get: not found），单独跑本脚本时只会静默降级成"跳过商店注册"。
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
  [ "$HAS_DL" = 1 ] || { echo "  ✗ 设备上没有 curl / wget" >&2; exit 1; }
  return 1
}

KP_DIR=${0%/*}; [ "$KP_DIR" = "$0" ] && KP_DIR=.     # 脚本所在目录，不依赖 dirname

# 商店注册实现在共享库里（kp-install.sh 也用同一份）。由 install.sh 调度时
# 它已经下载到同目录了；单独执行时这里补下。
if [ ! -f "$KP_DIR/kp-store-lib.sh" ]; then
  for base in "$RAW" "https://ghfast.top/$RAW" "https://gh-proxy.com/$RAW"; do
    get "$base/kp-store-lib.sh" "$KP_DIR/kp-store-lib.sh" 2>/dev/null \
      && [ -s "$KP_DIR/kp-store-lib.sh" ] && break
  done
fi
if [ -f "$KP_DIR/kp-store-lib.sh" ]; then
  . "$KP_DIR/kp-store-lib.sh"
else
  OCS_STORE=0
  echo "  ! 拿不到 kp-store-lib.sh，跳过商店注册（自动测速本身照常安装）"
fi

fetch_oc() {
  # ⚠️ 这里原先是「$OC/$1 已存在就 return 0」，直接复用第一次下载的那份。
  #    实测后果：$OC 在 /tmp/kp-nros/ocspeed（tmpfs，开机内一直保留），
  #    所以同一次开机里第二次跑一键链 —— 包括用户 overlay 重建后"重跑恢复"
  #    这种最典型的场景 —— 装的全是旧版，仓库里修好的 bug 永远上不了机，
  #    而脚本照样打印「✓ 文件已就位」，看不出来。
  #    正确做法：每次都下到 .new，成功才 mv 覆盖；只有网络全挂时才退回缓存，
  #    并且要把"用的是旧版"说出来。
  mkdir -p "$OC"
  local tmp="$OC/$1.new"
  rm -f "$tmp" 2>/dev/null || :
  for base in "$RAW" "https://ghfast.top/$RAW" "https://gh-proxy.com/$RAW"; do
    if get "$base/ocspeed/$1" "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv -f "$tmp" "$OC/$1" && return 0
    fi
  done
  rm -f "$tmp" 2>/dev/null || :
  if [ -s "$OC/$1" ]; then
    echo "  ! ocspeed/$1 下载失败，沿用本机缓存的旧版（恢复网络后重跑可更新）"
    return 0
  fi
  echo "  ✗ ocspeed/$1 下载失败" >&2
  return 1
}

# ---------------- 前置检查 ----------------
# ocspeed 完全是 OpenClash 的附属品：没有 OpenClash 就没有策略组可切。
if [ ! -x /etc/init.d/openclash ]; then
  echo "  ! 未检测到 OpenClash —— 跳过 ocspeed（它是 OpenClash 的自动测速插件）"
  exit 0
fi

echo ">>> ocspeed · OpenClash 自动测速"

for f in speedswitch.sh ocspeed.lua ocspeed.htm nodetest.htm config.ocspeed; do
  fetch_oc "$f" || exit 1
done
echo "  ✓ 文件已就位"

# ---------------- 落盘 ----------------
mkdir -p "$HELPER" "$DATA" /tmp/ocspeed /var/log

cp -f "$OC/speedswitch.sh" "$HELPER/speedswitch.sh"
chmod 0755 "$HELPER/speedswitch.sh"
cp -f "$OC/ocspeed.lua" "$LUA_CTRL/ocspeed.lua"
cp -f "$OC/ocspeed.htm" "$LUA_VIEW/ocspeed.htm"
cp -f "$OC/nodetest.htm" "$LUA_VIEW/nodetest.htm"

# UCI 配置：已存在就保留用户改过的值，只做首次播种
if [ ! -f /etc/config/ocspeed ]; then
  cp -f "$OC/config.ocspeed" /etc/config/ocspeed
  echo "  ✓ 已写入默认配置 /etc/config/ocspeed"
else
  echo "  · 已有 /etc/config/ocspeed，保留原值"
fi

# 目标策略组：只有显式传了 OCS_GROUP 才覆盖，否则沿用 /etc/config/ocspeed 里的值。
# （原先这里还有一个 GUESS=$(uci -q get openclash.config.config_path) —— 赋值后
#  从未被使用，纯粹是残留代码，而且 config_path 是配置文件路径、不是策略组名，
#  留着只会让人误以为"猜过策略组"。）
if [ -n "$OCS_GROUP" ]; then
  uci -q set ocspeed.main.group="$OCS_GROUP"
elif [ -z "$(uci -q get ocspeed.main.group)" ]; then
  echo "  ! 未指定 OCS_GROUP，且 ocspeed 里也没存过 —— 去页面里点选一个策略组"
fi
[ -n "$OCS_INTERVAL" ] && uci -q set ocspeed.main.interval="$OCS_INTERVAL"
uci -q set ocspeed.main.enabled="$OCS_ENABLE"
uci -q commit ocspeed

# ---------------- 让 LuCI 看见新页面 ----------------
# 控制器是 Lua 源码：不清缓存的话，uhttpd 还会用旧的模块索引。
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || :
rm -rf /tmp/luci-modulecache 2>/dev/null || :
/etc/init.d/uhttpd restart >/dev/null 2>&1 || :
echo "  ✓ LuCI 缓存已刷新"

# ---------------- 备份到数据盘 ----------------
# overlay 会随重建/重置清空，数据盘不会。留一份，丢了能直接 cp 回来。
if [ -d "$DATA_DIR" ]; then
  mkdir -p "$DATA_DIR/ocspeed-backup"
  cp -f "$HELPER/speedswitch.sh"  "$DATA_DIR/ocspeed-backup/" 2>/dev/null || :
  cp -f "$LUA_CTRL/ocspeed.lua"    "$DATA_DIR/ocspeed-backup/" 2>/dev/null || :
  cp -f "$LUA_VIEW/ocspeed.htm"    "$DATA_DIR/ocspeed-backup/" 2>/dev/null || :
  cp -f "$LUA_VIEW/nodetest.htm"   "$DATA_DIR/ocspeed-backup/" 2>/dev/null || :
  cp -f /etc/config/ocspeed        "$DATA_DIR/ocspeed-backup/config.ocspeed" 2>/dev/null || :
  echo "  ✓ 已备份到 $DATA_DIR/ocspeed-backup"
fi

# ---------------- 建 cron ----------------
# enable/disable 内部会按 UCI 重建 3 条 cron（自动测速 / 故障切换 / 备用预选），
# 并 restart cron。改变 backup_enable 时也会重建，不用手工 sed。
if [ "$OCS_ENABLE" = 1 ]; then
  "$HELPER/speedswitch.sh" enable >/dev/null 2>&1 || :
  echo "  ✓ 已启用自动测速（cron：每 $(uci -q get ocspeed.main.interval) 分钟）"
else
  "$HELPER/speedswitch.sh" disable >/dev/null 2>&1 || :
  echo "  · 已停用自动测速（页面里可随时开）"
fi

# ---------------- 可选：立刻跑一次 ----------------
if [ "$OCS_RUN" = 1 ]; then
  echo "  · 立即测速一次（约 2 分钟）..."
  "$HELPER/speedswitch.sh" run >/dev/null 2>&1 || :
  echo "  ✓ 首次测速完成，当前选中：$(uci -q get openclash.config.config_path >/dev/null; sed -n 's/.*"now":"\([^"]*\)".*/\1/p' "$DATA/status.json" 2>/dev/null | head -1)"
fi

# ---------------- 注册进鲲鹏商店 ----------------
# 与 OpenClash / 1Panel 同一套机制（见 kp-store-lib.sh）：
#   ① ocspeed 不是 opkg 包 → 先造占位包 app-ocspeed，否则商店永远显示「未安装」
#   ② 打开按钮 = iframe 加载本地路由 admin/services/openclash/ocspeed
#      （这个页面是真实存在的 LuCI 页面，不需要像 1Panel 那样造承载页）
if [ "$OCS_STORE" = 1 ]; then
  OCS_VER=$(sed -n 's/^# OpenClash 自动测速切换 v\([0-9.]*\).*/\1/p' "$HELPER/speedswitch.sh" | head -1)
  [ -n "$OCS_VER" ] || OCS_VER=3.3

  install_app_stub app-ocspeed "$OCS_VER" \
    "Placeholder registering the ocspeed auto speedtest plugin (installed outside opkg) with the Kunpeng app center."

  # 图标：没有专属图标时借 OpenClash 的（同一生态，视觉上不突兀），
  # 将来放一个真正的 ocspeed.png 进图标目录即可自动生效。
  if [ ! -f "$ICON_DIR/$OCS_ICON" ] && [ -f "$ICON_DIR/openclash.png" ]; then
    cp -f "$ICON_DIR/openclash.png" "$ICON_DIR/$OCS_ICON" 2>/dev/null || :
  fi

  STORE_SIZE_KB=$(( $(du -sk "$HELPER/speedswitch.sh" "$LUA_CTRL/ocspeed.lua" "$LUA_VIEW/ocspeed.htm" \
       2>/dev/null | awk '{s+=$1} END{print s+0}') ))
  register_store ocspeed "$OCS_ICON" \
    "OpenClash 自动测速：定时全量测延迟并切到最快节点，含故障切换与备用节点预选" \
    "admin/services/openclash/ocspeed" app-ocspeed
  store_verify ocspeed "admin/services/openclash/ocspeed" app-ocspeed || :
fi

echo "  ✓ ocspeed 完成 —— LuCI：服务 → OpenClash → 自动测速 / 应用中心"
