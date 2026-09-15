#!/bin/sh
# ============================================================================
#  kp-store-check.sh —— 检查「自注册应用」在鲲鹏商店里的状态
#
#  一行命令：
#      SCRIPT=kp-store-check.sh sh /tmp/kp.sh
#
#  它回答三件事（每个应用逐项核对，不靠猜）：
#      ① 商店目录里有没有它（ubus call appcenter list）
#      ② 商店会不会显示「已安装」（opkg 里查不查得到它的包）
#      ③ 点「打开」能不能出内容（路由表 + Lua 补丁 + 页面 HTTP 状态码）
#
#  为什么需要它：商店的「已安装」是守护进程实时跑 `opkg info` 判的，
#  「打开」依赖 /etc/kp_store/routes.list 与 appcenter.lua 的补丁。
#  任一环节掉了都不会报错，只是按钮变空白 —— 肉眼很难判断是哪一环。
#
#  参数：APPS="1Panel OpenClash ocspeed"   只查指定的（默认三个全查）
# ============================================================================
set -u

REPO=h910056902/nros-panel
BRANCH=main
RAW=https://raw.githubusercontent.com/$REPO/$BRANCH
KP_DIR=${0%/*}; [ "$KP_DIR" = "$0" ] && KP_DIR=.
: "${APPS:=1Panel OpenClash ocspeed}"

get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -m 180 -o "$2" "$1" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 180 -O "$2" "$1" && return 0
  fi
  return 1
}

if [ ! -f "$KP_DIR/kp-store-lib.sh" ]; then
  for base in "$RAW" "https://ghfast.top/$RAW" "https://gh-proxy.com/$RAW"; do
    get "$base/kp-store-lib.sh" "$KP_DIR/kp-store-lib.sh" 2>/dev/null \
      && [ -s "$KP_DIR/kp-store-lib.sh" ] && break
  done
fi
if [ ! -f "$KP_DIR/kp-store-lib.sh" ]; then
  echo "✗ 缺少 kp-store-lib.sh" >&2; exit 1
fi
. "$KP_DIR/kp-store-lib.sh"

echo "================ 鲲鹏商店 · 自注册应用检查 ================"
echo "时间: $(date '+%F %T')"

# 每个应用的检查参数：路由 与 opkg 包名
#   1Panel     跑在独立端口 → 走造出来的同源承载页
#   OpenClash  自带 LuCI 页面，包是 opkg 装的
#   ocspeed    自带 LuCI 页面，但不是 opkg 包 → 占位包 app-ocspeed
params() {
  case "$1" in
    1Panel)     echo "nradioadv/system/kp1panel|app-1panel" ;;
    OpenClash)  echo "admin/services/openclash|luci-app-openclash" ;;
    ocspeed)    echo "admin/services/openclash/ocspeed|app-ocspeed" ;;
    *)          echo "unknown|" ;;
  esac
}

FAIL=0
for app in $APPS; do
  echo
  echo "---------------- $app ----------------"
  p=$(params "$app")
  route=${p%%|*}; pkg=${p##*|}
  [ "$route" = unknown ] && { echo "  未知应用，跳过"; continue; }
  store_verify "$app" "$route" "$pkg" || FAIL=1
done

# Docker 顺带看一眼：1Panel 的容器能力依赖它
echo
echo "---------------- Docker ----------------"
if [ -x /usr/bin/dockerd ] && docker info >/dev/null 2>&1; then
  echo "  ✓ dockerd $(docker version --format '{{.Server.Version}}' 2>/dev/null) · $(docker info --format '{{.Driver}}' 2>/dev/null)"
  echo "  · 数据目录 $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  echo "  · 镜像 $(docker images -q 2>/dev/null | wc -l | tr -d ' ') 个 · 容器 $(docker ps -aq 2>/dev/null | wc -l | tr -d ' ') 个"
  [ -f /etc/rc.d/S99dockerd ] && echo "  ✓ 开机自启已开" || { echo "  ! 开机自启未开（/etc/init.d/dockerd enable）"; FAIL=1; }
  if [ "$(lsmod 2>/dev/null | grep -c '^veth')" = 0 ]; then
    echo "  ! 内核无 veth → 容器只能用 --network host（桥接会报 veth pair 失败）"
  fi
else
  echo "  ! dockerd 未运行"
  FAIL=1
fi

echo
echo "=========================================================="
if [ "$FAIL" = 0 ]; then
  echo "全部通过。商店入口：原生面板 → 应用中心"
else
  echo "有项目未通过（见上方 ! 行）。重跑对应安装脚本即可修复，都是幂等的。"
fi
