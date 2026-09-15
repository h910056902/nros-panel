#!/bin/sh
# ============================================================================
#  kp-install.sh —— 鲲鹏 NRadio 路由器一键恢复
#                   外网(OpenClash) + Docker + 1Panel
#
#  适用：OpenWrt 21.02-SNAPSHOT / aarch64 / kernel 5.4.281（C2000 Max、C2000 U）
#
#  特性：幂等。已装好的组件只做「确保运行 + 回读凭据」，不重装、不覆盖配置，
#        所以随时可以重跑，也可以分阶段跑。
#
#  用法：
#     sh kp-install.sh                            全套安装
#     SUB_URL=https://xxx sh kp-install.sh        同时配置机场订阅
#     SKIP=docker,panel sh kp-install.sh          只装外网
#     PANEL_PORT=10091 sh kp-install.sh           换面板端口
#     CORE_TYPE=Meta sh kp-install.sh             换内核类型
#
#  四个阶段（想改哪块，就找对应函数）：
#     [1/4] 预检与换源   修 opkg 源（出厂 SNAPSHOT 源已 404）
#     [2/4] OpenClash    装包 → 拉内核 → 配订阅 → 起服务
#     [3/4] Docker       补 kmod 桩包 → 装包 → 写 UCI → 起服务
#     [4/4] 1Panel       装面板 → 播种凭据 → 验活
#     跑完打印汇总（汇总不是阶段，没有编号）
#
#  依赖：同目录下的 kp-ui.sh（终端界面库，改界面只改那个文件）
# ============================================================================
set -eu

# set -e 下任何命令返回非 0 都会让脚本**静默退出**（连报错都没有，最难查）。
# 这里的 EXIT 陷阱就是给这种情况留线索：异常中断时至少会报出退出码。
# ⚠️ 不能用 `trap ... ERR` —— busybox 的 ash 不认这个信号，会直接报
#    "ERR: invalid signal specification"（实测踩过）。EXIT 则是通用的。
trap 'rc=$?; [ "$rc" = 0 ] || echo "  ✗ 脚本中断（rc=$rc）—— 上面最后一行输出就是线索" >&2' EXIT

# ============================== 参数（环境变量可覆盖） ==============================
: "${SUB_URL:=}"                              # 机场订阅地址，留空 = 只装不订阅
: "${SUB_NAME:=kp}"                           # 订阅显示名
: "${SUB_UA:=clash-verge/v2.4.5}"             # 订阅请求 UA
: "${CORE_TYPE:=Meta}"                        # 内核类型 Meta/Dev/Smart/Oix
: "${OC_VER:=0.47.156}"                       # OpenClash 版本
: "${OC_LOCAL_IPK:=/tmp/oc.ipk}"              # 优先用这个本地 ipk，没有才联网下
: "${PANEL_PORT:=10090}"                      # 面板端口（10086/87/88 已被固件占用）
: "${PANEL_DIR:=/mnt/storage/data}"           # 数据根目录（放 p2 大分区，不吃 overlay）
: "${DATA_DEV:=/dev/mmcblk0p2}"              # 数据分区设备，用于兜底挂载（见 ensure_data）
: "${PANEL_USER:=admin}"
: "${PANEL_PASS:=}"                           # 留空 = 随机生成
: "${PANEL_ENT:=}"                            # 面板入口路径，留空 = 随机生成
: "${ONEPANEL_VER:=v1.10.34-lts}"
: "${DOCKER_MIRRORS:=https://docker.1ms.run https://docker.m.daocloud.io}"  # 国内镜像加速（空格分隔）
: "${SKIP:=}"                                 # 逗号分隔要跳过的阶段：oc,docker,panel
: "${CRED:=/root/1panel-credentials.txt}"     # 凭据落盘位置

# 派生变量
BASE=$PANEL_DIR/1panel
DB=$BASE/db/1Panel.db
TMP=$PANEL_DIR/kp-tmp
DIR="1panel-$ONEPANEL_VER-linux-arm64"
PKG="$DIR.tar.gz"
PANEL_DL="https://resource.fit2cloud.com/1panel/package/stable/$ONEPANEL_VER/release"
OC_IPK_URL="https://github.com/vernesong/OpenClash/releases/download/v$OC_VER/luci-app-openclash_${OC_VER}_all.ipk"
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.66.1)
OC_CORE=/etc/openclash/core/clash_meta
ALI=https://mirrors.aliyun.com/openwrt/releases/21.02.7/packages/aarch64_cortex-a53

# ============================== 界面（全部实现在 kp-ui.sh） ==============================
KP_DIR=${0%/*}; [ "$KP_DIR" = "$0" ] && KP_DIR=.     # 取脚本所在目录，不依赖 dirname
if [ ! -f "$KP_DIR/kp-ui.sh" ]; then
  echo "缺少界面库 kp-ui.sh —— 它必须和本脚本放在同一个目录里" >&2
  exit 1
fi
. "$KP_DIR/kp-ui.sh"

AVAIL=$(df -h "$PANEL_DIR" 2>/dev/null | awk 'NR==2{print $4}')
ui_init "鲲鹏路由器 · 一键恢复" "外网 OpenClash  ·  Docker  ·  1Panel"
ui_meta 设备 "$(cat /tmp/sysinfo/model 2>/dev/null || echo Unknown) · $(uname -m) · kernel $(uname -r)"
if [ -n "$AVAIL" ]; then ui_meta 数据 "$PANEL_DIR · 可用 $AVAIL"
else ui_meta 数据 "$PANEL_DIR（未挂载）"; fi
ui_meta 时间 "$(date '+%F %T')"
ui_hr

# ============================== 工具函数 ==============================
have()  { command -v "$1" >/dev/null 2>&1; }
skip()  { case ",$SKIP," in *",$1,"*) return 0 ;; esac; return 1; }
rnd()   { head -c 32 /dev/urandom | md5sum | cut -c1-"$1"; }
port()  { netstat -lnt 2>/dev/null | grep -q ":$1 "; }

# 轮询等待：poll 30 docker info  →  最多等 30 次（每次 2s）
poll()  { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; n=$((n-1)); sleep 2; done; return 1; }

# 装包（已装则跳过），天然幂等
pkg()   { opkg status "$1" 2>/dev/null | grep -q 'install ok installed' && return 0; opkg install "$@"; }

# 下载：curl 优先，wget 兜底
get()   { if have curl; then curl -fsSL -m 600 -o "$2" "$1"; else wget -q -T 600 -O "$2" "$1"; fi; }

# GitHub 直连不稳，直链 + 两个镜像前缀依次尝试
mirrors() { echo "$1"; echo "https://ghfast.top/$1"; echo "https://gh-proxy.com/$1"; }

# 从 1pctl 回读真实凭据。1Panel 首启是用 1pctl 里的值播种数据库的，
# 所以 1pctl 是凭据的唯一真相源（值里的 \ 是转义符，要还原）
pv()    { sed -n "s/^$1=//p" /usr/local/bin/1pctl 2>/dev/null | head -n1 | sed 's/\\//g'; }

# ---------------- 数据分区保障 ----------------
# 为什么需要这一套：固件自带的热插拔脚本 /etc/hotplug.d/block/00-mount 会把
# 新分区先挂到 /tmp/storage/<设备名> 下。它只在 ID_FS_PARTLABEL 等于
# nradio_user_data 时才改挂到 /mnt/storage/data，而用 MBR 分区的表根本没有
# PARTLABEL（实测 blkid -o udev 只给出 ID_FS_LABEL），这个判据永远不成立。
# 随后 /etc/init.d/fstab 的 `block mount` 看到设备"已经被挂载"，就直接跳过 ——
# 实测返回 0 但 /mnt/storage/data 始终是空的。所以这里自己兜底：先摘掉那处
# 挂载，再挂到目标点；已经挂好则什么都不做。
ensure_data() {
  grep -q " $PANEL_DIR " /proc/mounts && return 0
  for mp in $(grep "^$DATA_DEV " /proc/mounts | cut -d' ' -f2); do
    umount "$mp" 2>/dev/null || :
  done
  mkdir -p "$PANEL_DIR"
  mount -t f2fs -o noatime "$DATA_DEV" "$PANEL_DIR" 2>/dev/null || :
}

# 装一个开机自启的小服务，保证每次开机后数据分区都在目标点。
# 只有它到位，dockerd 启动时数据根目录才真的落在卡上 —— 否则 dockerd 会在
# overlay 上自建目录，overlay2 驱动失效（退化成 vfs，又慢又占空间）。
# 幂等：已存在就只确保它是启用的，不覆盖。
install_data_service() {
  SVC=/etc/init.d/kp-storage
  if [ -f "$SVC" ]; then
    [ -x /etc/rc.d/S41kp-storage ] || "$SVC" enable >/dev/null 2>&1 || :
    return 0
  fi
  cat > "$SVC" <<EOF
#!/bin/sh /etc/rc.common
# 由 nros-panel 生成：保证数据分区 $DATA_DEV 挂到 $PANEL_DIR
# 原因见 kp-install.sh 里 ensure_data() 的注释（热插拔先占用，block mount 跳过）。
# 排在 fstab（S40）之后执行。
START=41

start() {
	grep -q " $PANEL_DIR " /proc/mounts && return 0
	for mp in \$(grep "^$DATA_DEV " /proc/mounts | cut -d' ' -f2); do
		umount "\$mp" 2>/dev/null
	done
	mkdir -p "$PANEL_DIR"
	mount -t f2fs -o noatime "$DATA_DEV" "$PANEL_DIR" 2>/dev/null ||
		logger -t kp-storage "挂载 $DATA_DEV 到 $PANEL_DIR 失败"
}

stop() {
	umount "$PANEL_DIR" 2>/dev/null
}
EOF
  chmod 755 "$SVC"
  "$SVC" enable >/dev/null 2>&1 || ui_warn "kp-storage 开机自启未生效"
}

# ---------------- kmod 桩包 ----------------
# 为什么需要：dockerd 的 Depends 里点名了 6 个 kmod ——
#   kmod-veth / kmod-dm / kmod-fs-btrfs / kmod-br-netfilter / kmod-ikconfig / kmod-nf-ipvs
# 厂商固件跑的是 mt7987 私有内核（5.4.281），官方源里根本没有这个 target，
# 这几个 kmod 包也不存在，于是 opkg 在「挑选候选包」这一步就选不出来，
# 报的却是容易误导的文案：
#   Packages for dockerd found, but incompatible with the architectures configured
# 实测 --force-depends 也绕不过去：那个开关只跳过「装包时」的依赖检查，
# 而失败发生在「选候选包时」，早了一步。
# 本机跑 host 网络 + 不启 iptables + overlay2 落在 f2fs 上，这 6 个 kmod
# 运行时一个都用不到 —— 所以现场用 busybox 打一个只声明 Provides 的桩包，
# 把依赖链补闭合，dockerd 就能正常装上（其他依赖都是真包，照常下载）。
KMOD_STUBS="kmod-veth kmod-dm kmod-fs-btrfs kmod-br-netfilter kmod-ikconfig kmod-nf-ipvs"
STUB_IPK=/tmp/kp-kmod-stub.ipk

install_kmod_stub() {
  # 已经补过就什么都不做（幂等）
  if opkg status kmod-kp-stub 2>/dev/null | grep -q 'Status:'; then return 0; fi
  # 6 个 kmod 只要 opkg 全都认得（固件或源里本来就有），就不必补桩
  MISSING=0
  for k in $KMOD_STUBS; do
    if ! opkg status "$k" 2>/dev/null | grep -q 'Status:'; then MISSING=1; break; fi
  done
  if [ "$MISSING" = 0 ]; then return 0; fi

  D=/tmp/kpstub
  rm -rf "$D"
  mkdir -p "$D/control" "$D/data/usr/share/kmod-kp-stub"
  {
    echo "Package: kmod-kp-stub"
    echo "Version: 1.0.0-1"
    echo "Depends: libc"
    echo "Provides: $(echo $KMOD_STUBS | tr ' ' ',')"
    echo "Section: kernel"
    echo "Architecture: aarch64_cortex-a53"
    echo "Installed-Size: 1024"
    echo "Description: Stubs for kmod packages the Kunpeng mt7987 vendor kernel does not ship. These features are either built into the vendor kernel or unused with host-network containers."
  } > "$D/control/control"
  : > "$D/control/conffiles"
  echo "kmod stubs for the Kunpeng mt7987 vendor kernel (generated by nros-panel)" \
    > "$D/data/usr/share/kmod-kp-stub/README"
  # .ipk = 外层 tar.gz，里面装 debian-binary / control.tar.gz / data.tar.gz
  ( cd "$D/control" && tar -czf "$D/control.tar.gz" ./control ./conffiles )
  ( cd "$D/data"    && tar -czf "$D/data.tar.gz" . )
  ( cd "$D" && echo 2.0 > debian-binary \
    && tar -czf "$STUB_IPK" ./debian-binary ./control.tar.gz ./data.tar.gz )
  opkg install --force-depends "$STUB_IPK" >/dev/null 2>&1 \
    || ui_fail "kmod 桩包安装失败" "确认 /tmp 可写、opkg 没被其他进程占用"
  ui_info "已补 kmod 桩包（厂商内核没有这些 kmod，运行时用不到）：$KMOD_STUBS"
}

# ---------------- dockerd 配置（只走 UCI） ----------------
# 为什么不用 /etc/docker/daemon.json：固件自带的 /etc/init.d/dockerd 会把 **UCI**
# 渲染成 /tmp/dockerd/daemon.json，再用 `dockerd --config-file` 加载它。
# 也就是说直接往 /etc/docker/daemon.json 写配置根本没人读 —— 实测这样跑出来的
# Docker Root Dir 还是 UCI 默认的 /opt/docker（落在 4G 系统分区上，镜像会把它吃满），
# 存储驱动也退化成 vfs。它只有在 UCI 里设了 alt_config_file 时才会软链外部文件，
# 但那条路更绕且会绕开 iptables / 镜像源等其它 UCI 项，所以统一用 UCI。
# 三个值的作用：
#   data_root        —— 镜像/容器全落到 p2 大分区，不吃系统分区
#   log_level        —— warn，别让 json 日志把 2MB NOR 后备根写爆
#   registry_mirrors —— 国内直连 registry-1.docker.io 必超时（实测 15s 无响应）
config_dockerd() {
  CH=0
  [ "$(uci -q get dockerd.globals.data_root)" = "$PANEL_DIR/docker" ] \
    || { uci set dockerd.globals.data_root="$PANEL_DIR/docker"; CH=1; }
  [ "$(uci -q get dockerd.globals.log_level)" = warn ] \
    || { uci set dockerd.globals.log_level=warn; CH=1; }
  if [ -z "$(uci -q get dockerd.globals.registry_mirrors)" ]; then
    for m in $DOCKER_MIRRORS; do uci add_list dockerd.globals.registry_mirrors="$m"; done
    CH=1
  fi
  if [ "$CH" = 1 ]; then
    uci commit dockerd
    /etc/init.d/dockerd restart >/dev/null 2>&1 || :
    ui_ok "UCI 已配置：数据目录 $PANEL_DIR/docker · 镜像加速 $(echo $DOCKER_MIRRORS | wc -w) 个"
  else
    ui_ok "UCI 配置已就绪（数据目录 $(uci -q get dockerd.globals.data_root)）"
  fi
}

# 注册应用到鲲鹏商店（原生面板 → 应用中心）。
# 真实机制（真机逆向确认）：
#   · 商店目录 = /etc/config/appcenter（UCI），守护进程 /usr/sbin/appcenter 提供 ubus 接口
#   · 「已安装」状态由守护进程对 package_list 里每个包名跑 `opkg info` 实时判定，
#     所以只要包真的装了，状态就一定是准的 —— 不造假、无需手动维护
#   · 「卸载」按钮会真跑 `opkg remove`，行为一致
# 用法：register_store <显示名> <图标名> <描述> <子包1> [子包2 ...]
# 幂等：先把同名旧条目删干净再重写，版本/体积每次取实时值。
register_store() {
  local app="$1" icon="$2" des="$3" && shift 3
  have uci || return 0
  [ -x /usr/sbin/appcenter ] || { ui_warn "应用商店组件不存在，跳过 $app 注册"; return 0; }

  # 图标：优先用应用自带 logo（调用方先拷进商店图标目录），缺失则回退默认图标
  local icon_dir=/www/luci-static/nradio/images/icon
  [ -f "$icon_dir/$icon" ] || icon=app_default.png

  # --- 删旧条目（删除会让索引左移，所以只在没删时才 ++） ---
  local i=0 sec
  while uci -q get appcenter.@package[$i] >/dev/null 2>&1; do
    if [ "$(uci -q get appcenter.@package[$i].name)" = "$app" ]; then
      uci delete appcenter.@package[$i]
    else
      i=$((i+1))
    fi
  done
  i=0
  while uci -q get appcenter.@package_list[$i] >/dev/null 2>&1; do
    if [ "$(uci -q get appcenter.@package_list[$i].parent)" = "$app" ]; then
      uci delete appcenter.@package_list[$i]
    else
      i=$((i+1))
    fi
  done

  # --- 子包条目：包名/版本/体积全部取 opkg 实时值，status 由守护进程自己判 ---
  local pkg ver size total=0 first_ver=""
  for pkg in "$@"; do
    ver=$(opkg info "$pkg" 2>/dev/null | awk '/^Version:/{print $2; exit}')
    [ -n "$ver" ] || ver=unknown
    [ -n "$first_ver" ] || first_ver=$ver
    size=$(opkg files "$pkg" 2>/dev/null | sed 1d | xargs du -ck 2>/dev/null | awk '/total$/{print $1; exit}')
    [ -n "$size" ] || size=0
    total=$((total + size))
    sec=$(uci add appcenter package_list)
    uci set appcenter.$sec.name="$pkg"
    uci set appcenter.$sec.pkg_name="$pkg"
    uci set appcenter.$sec.parent="$app"
    uci set appcenter.$sec.size="$((size * 1024))"
    uci set appcenter.$sec.version="$ver"
    uci set appcenter.$sec.has_luci='0'
    uci set appcenter.$sec.type='0'
  done

  # --- 主条目（商店卡片）：size 单位是字节（与出厂条目一致） ---
  sec=$(uci add appcenter package)
  uci set appcenter.$sec.name="$app"
  uci set appcenter.$sec.version="$first_ver"
  uci set appcenter.$sec.icon="$icon"
  uci set appcenter.$sec.des="$des"
  uci set appcenter.$sec.size="$((total * 1024))"
  uci set appcenter.$sec.status='1'
  uci set appcenter.$sec.has_luci='1'
  uci set appcenter.$sec.open='0'
  uci commit appcenter

  # --- 重启守护进程让 ubus 列表生效，并验证 ---
  /etc/init.d/appcenter restart >/dev/null 2>&1 || :
  sleep 2
  if ubus call appcenter list 2>/dev/null | grep -q "\"name\": \"$app\""; then
    ui_ok "已注册鲲鹏商店：$app（原生面板 → 应用中心可见）"
  else
    ui_warn "$app 商店注册未生效（不影响应用本身）"
  fi
}

# ============================== [1/4] 预检与换源 ==============================
stage_env() {
  ui_stage 1 4 "环境预检与换源"

  [ "$(id -u)" = 0 ] || ui_fail "必须以 root 运行"
  [ "$(uname -m)" = aarch64 ] || ui_fail "仅支持 aarch64，当前是 $(uname -m)"

  # 数据分区：先兜底挂上，再装开机自启保障（见文件上方 ensure_data 的注释）
  ensure_data
  install_data_service
  grep -q " $PANEL_DIR " /proc/mounts \
    || ui_fail "数据分区 $PANEL_DIR 未挂载" "确认 TF 卡 p2 已格式化（跑过 kp-storage-init.sh）后 reboot"

  for t in curl tar gzip md5sum sha256sum; do have "$t" || ui_fail "缺少工具 $t"; done

  # 1) 换源。出厂 distfeeds 的 6 个源全部指向 downloads.openwrt.org 的
  #    21.02-SNAPSHOT，而该快照早已下线 —— 实测 v4 / v6 / 固定 IP 直连全是
  #    000，连 bash 都装不上。整体换成阿里云 21.02.7 镜像。
  #    只留 base / packages / routing 三个：core 与 target 源里是严格对齐
  #    内核 5.4.281 的 kmod，而官方根本没有 mt7987 这个 target，留着不但
  #    取不到东西，还会让每次 opkg update 卡在超时上。真缺 kmod 依赖时，
  #    用 --force-depends 跳过（本机用不到 veth / br_netfilter，见 Docker 段）。
  F=/etc/opkg/distfeeds.conf
  [ -f "$F.kp-bak" ] || cp "$F" "$F.kp-bak"          # 只备份一次，方便还原
  if grep -q "21.02-SNAPSHOT" "$F"; then
    cat > "$F" <<EOF
src/gz openwrt_base     $ALI/base
src/gz openwrt_packages $ALI/packages
src/gz openwrt_routing  $ALI/routing
EOF
    ui_info "6 个出厂源已整体换成阿里云 21.02.7（原文件备份：$F.kp-bak）"
  fi
  # 第三方 ipk（OpenClash 等）没有官方签名，关掉校验免得装不上
  sed -i '/check_signature/d' /etc/opkg.conf 2>/dev/null || :

  opkg update >/dev/null 2>&1 || ui_warn "opkg update 有源失败（通常无碍，继续）"
  ui_ok "opkg 源就绪"

  # 2) bash：1pctl 与 OpenClash 的脚本都依赖它
  pkg bash >/dev/null 2>&1 || ui_fail "bash 安装失败"
  # 3) OpenClash 系列脚本用 flock 锁，缺 /tmp/lock 会静默失败
  mkdir -p /tmp/lock
  ui_ok "aarch64 · bash 就绪 · $PANEL_DIR 可用 $(df -h "$PANEL_DIR" | awk 'NR==2{print $4}')"
  ui_stage_end
}

# ============================== [2/4] 外网 OpenClash ==============================
stage_openclash() {
  ui_stage 2 4 "外网 OpenClash"
  if skip oc; then ui_info "按 SKIP 跳过"; ui_stage_end; return 0; fi

  CHANGED=0

  # --- 装包：优先本地 ipk（离线可用），否则联网下载（直链+2 镜像） ---
  if [ -x /etc/init.d/openclash ]; then
    ui_ok "包已安装（$(opkg status luci-app-openclash 2>/dev/null | sed -n 's/^Version: //p')）"
  else
    if [ ! -s "$OC_LOCAL_IPK" ]; then
      for u in $(mirrors "$OC_IPK_URL"); do get "$u" "$OC_LOCAL_IPK" && break || :; done
    fi
    [ -s "$OC_LOCAL_IPK" ] || ui_fail "OpenClash 下载失败" "手动下载 ipk 放到 $OC_LOCAL_IPK 后重跑"
    # 依赖里的 luci-compat / kmod-tun 等，固件其实自带（只是 opkg 库里查不到
    # 记录：prec 探测显示 kmod-tun、iptables 这类"未装"但命令和模块都在），
    # 所以必须 --force-depends，否则 opkg 会以「依赖不满足」直接拒装。
    opkg install --force-depends "$OC_LOCAL_IPK" || ui_fail "OpenClash 安装失败"
    CHANGED=1
    ui_ok "包已安装"
  fi

  # --- 内核：用 OpenClash 自带的下载器（含版本探测、解压、赋权）---
  #     第 2 个参数是 GitHub 加速前缀，0 = 官方直连
  if [ ! -x "$OC_CORE" ] && [ -x /usr/share/openclash/openclash_core.sh ]; then
    ui_info "拉取内核 $CORE_TYPE（约 46MB）…"
    for m in 0 https://gh-proxy.com/ https://ghfast.top/; do
      bash /usr/share/openclash/openclash_core.sh "$CORE_TYPE" "$m" >/dev/null 2>&1 || continue
      if [ -x "$OC_CORE" ]; then CHANGED=1; break; fi
    done
  fi
  if [ -x "$OC_CORE" ]; then
    ui_ok "内核 $("$OC_CORE" -v 2>/dev/null | awk '{print $2, $3}') · $CORE_TYPE"
  else
    ui_warn "内核缺失：到 LuCI → OpenClash → 内核管理 下载，或检查 github_address_mod"
  fi

  # --- 内核自检：把"内核就绪"从推断变成实测 ---
  # 没有订阅时脚本只能停在"待订阅"，此时"内核能否真的跑起来"从未被验证过
  # —— 万一内核跑不起来，填了订阅照样失败。这里用一份最小配置把内核真拉起
  # 来验一次活，测完立刻 kill。
  # 刻意避开 7890/9090（真实服务端口），且配置是 mode: direct、不开 tun、
  # 不劫持 DNS、不加防火墙 —— 全程不碰网络设置，测完不留痕迹。
  oc_selftest() {
    [ -x "$OC_CORE" ] || return 1
    local y=/tmp/oc-selftest.yaml pid= ok=0 i
    printf 'mixed-port: 7899\nexternal-controller: 127.0.0.1:9099\nmode: direct\nlog-level: warning\n' > "$y"
    "$OC_CORE" -f "$y" -d /tmp >/tmp/oc-selftest.log 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 10 ]; do
      sleep 1
      i=$((i + 1))
      if curl -s -m 2 http://127.0.0.1:9099/version >/dev/null 2>&1; then ok=1; break; fi
    done
    kill "$pid" 2>/dev/null || :
    sleep 1
    kill -9 "$pid" 2>/dev/null || :
    rm -f "$y" /tmp/oc-selftest.log
    return $((1 - ok))
  }

  # 只在"还没有任何配置"时自检：有配置就说明服务本身能起，没必要多跑一次
  if [ -z "$(ls /etc/openclash/config/*.yaml 2>/dev/null)" ] \
     && [ -z "$(uci -q get openclash.config.config_path)" ]; then
    if oc_selftest; then
      ui_ok "内核自检通过（拉起→监听→响应，测完已清理）"
      OC_SELFTEST=1
    else
      ui_warn "内核自检失败：二进制在但跑不起来，看 /tmp/oc-selftest.log"
    fi
  fi

  # --- 订阅：写进 UCI，然后调 OpenClash 自带脚本拉取 ---
  if [ -n "$SUB_URL" ] && ! uci show openclash 2>/dev/null | grep -qF "$SUB_URL"; then
    uci add openclash config_subscribe >/dev/null
    uci set openclash.@config_subscribe[-1].name="$SUB_NAME"
    uci set openclash.@config_subscribe[-1].address="$SUB_URL"
    uci set openclash.@config_subscribe[-1].sub_ua="$SUB_UA"
    uci set openclash.@config_subscribe[-1].enabled=1
    uci commit openclash
    CHANGED=1
    ui_ok "订阅「$SUB_NAME」已写入"
  elif [ -z "$SUB_URL" ]; then
    ui_warn "未提供订阅地址：内核就绪后，到 LuCI → OpenClash 里填订阅即可"
  fi

  # --- 起服务 ---
  # 关键前置：OpenClash 没有配置文件时根本起不来（没东西可跑），
  # 这时去等 7890 是白等 —— 实测每次白耗 1 分钟。所以先看有没有配置再决定等不等。
  #
  # ⚠️ 每处 `X=$(cmd)` 后面都必须跟 `|| X=""`：本脚本开了 set -e，而
  #    「纯赋值语句的退出码 = 命令替换的退出码」—— uci get 对未设置的键返回 1，
  #    不兜住就会让整个脚本**静默退出**（没有任何报错，最难查的一类）。
  /etc/init.d/openclash enable
  OC_CONF=$(uci -q get openclash.config.config_path) || OC_CONF=""
  [ -n "$OC_CONF" ] || OC_CONF=$(ls /etc/openclash/config/*.yaml 2>/dev/null | head -n1) || OC_CONF=""

  if [ "$CHANGED" = 1 ]; then
    /etc/init.d/openclash restart >/dev/null 2>&1 || /etc/init.d/openclash start
    # 服务起来后主动拉一次订阅，确保配置文件落地
    [ -x /usr/share/openclash/openclash.sh ] && bash /usr/share/openclash/openclash.sh >/dev/null 2>&1 || :
    OC_CONF=$(uci -q get openclash.config.config_path) || OC_CONF=""
    [ -n "$OC_CONF" ] || OC_CONF=$(ls /etc/openclash/config/*.yaml 2>/dev/null | head -n1) || OC_CONF=""
  else
    /etc/init.d/openclash status 2>/dev/null | grep -q '^running' || /etc/init.d/openclash start
  fi

  # --- 没指定用哪份配置时，自动指向第一份 yaml ---
  if [ -n "$OC_CONF" ] && [ -z "$(uci -q get openclash.config.config_path)" ]; then
    uci set openclash.config.config_path="$OC_CONF"
    uci commit openclash
    /etc/init.d/openclash restart >/dev/null 2>&1 || :
    ui_ok "已指定配置 $(basename "$OC_CONF")"
  fi

  if [ -n "$OC_CONF" ] && [ -x "$OC_CORE" ]; then
    poll 30 port 7890 || ui_warn "7890 未监听（去 LuCI → OpenClash 确认一次）"
  fi

  # --- ocspeed 自动测速：脚本是固件自带的，这里只补 3 条 cron ---
  if [ -x /usr/libexec/openclash-helper/speedswitch.sh ] \
     && ! grep -q speedswitch /etc/crontabs/root 2>/dev/null; then
    cat >> /etc/crontabs/root <<'EOF'
*/30 * * * * /usr/libexec/openclash-helper/speedswitch.sh run >>/var/log/ocspeed.log 2>&1
* * * * * /usr/libexec/openclash-helper/speedswitch.sh failover >>/var/log/ocspeed.log 2>&1
* * * * * /usr/libexec/openclash-helper/speedswitch.sh backup >>/var/log/ocspeed.log 2>&1
EOF
    ui_ok "ocspeed 自动测速 cron 已补"
  fi
  /etc/init.d/cron enable 2>/dev/null || :
  /etc/init.d/cron restart 2>/dev/null || :

  # --- 收尾汇报：状态要说实话，"未跑起来"不能报成 ✓ ---
  OC_STAT=$(/etc/init.d/openclash status 2>/dev/null | head -n1 | tr -d '\r')
  if port 7890; then
    ui_ok "服务 running · 代理端口 7890 已监听"
  elif [ -n "$OC_CONF" ] && [ -x "$OC_CORE" ]; then
    ui_warn "服务 $OC_STAT（配置与内核都在，但没起来 —— 看 logread | grep -i clash）"
  else
    ui_warn "服务 $OC_STAT —— 缺配置文件，去 LuCI → OpenClash 填订阅后即可启动"
    if [ "${OC_SELFTEST:-0}" = 1 ]; then
      OC_STAT="$OC_STAT（内核已验活，只差订阅）"
    else
      OC_STAT="$OC_STAT（待订阅）"
    fi
  fi

  # --- 注册进鲲鹏商店（原生面板 → 应用中心）---
  #    顺手把 OpenClash 自带 logo 拷成商店图标；包状态由商店守护进程
  #    按 opkg 实时判定，卸载按钮也是真卸载，行为完全一致。
  cp -f /www/luci-static/resources/openclash/img/logo.png \
        /www/luci-static/nradio/images/icon/openclash.png 2>/dev/null || :
  register_store OpenClash openclash.png \
    "Clash Meta 内核的代理客户端，支持订阅管理与规则分流" \
    luci-app-openclash pkg-openclash-dep

  ui_stage_end
}

# ============================== [3/4] Docker ==============================
stage_docker() {
  ui_stage 3 4 "Docker"
  if skip docker; then ui_info "按 SKIP 跳过"; ui_stage_end; return 0; fi

  # 判据刻意用 dockerd（守护进程）而不是 docker（CLI）—— 它们是两个独立的包。
  # 踩过的坑：只判 `have docker` 时，一旦 CLI 先装上了、守护进程没装上，
  # 再次运行整段就被跳过，永远修不回来。
  if [ ! -x /usr/bin/dockerd ]; then
    install_kmod_stub      # 原因见函数注释：厂商内核缺 6 个 kmod，依赖链要先补闭合
    pkg dockerd || ui_fail "dockerd 安装失败" "看上方 opkg 输出定位是哪一步"
  fi
  if [ ! -x /usr/bin/docker ]; then
    pkg docker || ui_fail "docker CLI 安装失败"
  fi
  pkg docker-compose >/dev/null 2>&1 || ui_warn "docker-compose 缺失：面板能用，但商店部署应用会失败"
  pkg zoneinfo-asia  >/dev/null 2>&1 || :

  # 配置走 UCI（原因见 config_dockerd 的注释：固件 init 只认 UCI）
  config_dockerd

  docker info >/dev/null 2>&1 || { /etc/init.d/dockerd enable; /etc/init.d/dockerd start; }
  poll 30 docker info || ui_fail "dockerd 未就绪" "看 logread | grep dockerd 排查"

  # 数据根目录必须落在 p2 上：落在 overlay（4G 系统分区）会被镜像吃满，
  # 而且 overlay2 在 overlayfs 上不可用，会静默退化成 vfs。
  DR=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) || DR=""
  [ "$DR" = "$PANEL_DIR/docker" ] \
    || ui_warn "docker 数据根目录是 $DR（期望 $PANEL_DIR/docker）—— 大概率是数据分区没挂上"
  ui_ok "dockerd $(docker version --format '{{.Server.Version}}' 2>/dev/null) · $(docker info --format '{{.Driver}}' 2>/dev/null) · $DR"
  ui_stage_end
}

# ============================== [4/4] 1Panel ==============================
stage_panel() {
  ui_stage 4 4 "1Panel"
  if skip panel; then ui_info "按 SKIP 跳过"; ui_stage_end; return 0; fi

  if [ -f "$DB" ] && have 1pctl; then
    # 已装：从 1pctl 回读真实凭据（重新生成会把凭据文件写坏、探测 404）
    PANEL_PORT=$(pv ORIGINAL_PORT)
    PANEL_USER=$(pv ORIGINAL_USERNAME)
    PANEL_ENT=$(pv ORIGINAL_ENTRANCE)
    PANEL_PASS=$(pv ORIGINAL_PASSWORD)
    [ -n "$PANEL_ENT" ] && [ -n "$PANEL_PORT" ] || ui_fail "1pctl 读不到入口/端口，安装状态异常"
    ui_ok "已安装，回读凭据：端口 $PANEL_PORT · 入口 $PANEL_ENT"
  else
    [ -n "$PANEL_PASS" ] || PANEL_PASS=$(rnd 12)
    [ -n "$PANEL_ENT" ]  || PANEL_ENT=$(rnd 10)
    if port "$PANEL_PORT"; then ui_fail "端口 $PANEL_PORT 被占用" "用 PANEL_PORT=xxxx 换一个端口重跑"; fi

    # 下载 → 校验 → 解包
    mkdir -p "$TMP"; cd "$TMP"
    get "$PANEL_DL/checksums.txt" checksums.txt || ui_fail "checksums.txt 下载失败"
    SUM=$(grep " $PKG\$" checksums.txt | cut -d' ' -f1)
    [ -n "$SUM" ] || ui_fail "checksums.txt 里找不到 $PKG"
    if [ ! -f "$PKG" ]; then get "$PANEL_DL/$PKG" "$PKG" || ui_fail "1Panel 安装包下载失败"; fi
    if [ "$(sha256sum "$PKG" | cut -d' ' -f1)" != "$SUM" ]; then
      rm -f "$PKG"; ui_fail "安装包 SHA256 校验不匹配" "损坏包已删除，重跑即可重下"
    fi
    rm -rf "$BASE" "$DIR"; tar zxf "$PKG"; cd "$DIR"
    ui_ok "安装包已解压并通过 SHA256 校验"

    # 落文件。关键顺序：先写好 1pctl，再启动服务 ——
    # 1panel 二进制会读 1pctl 里的 BASE_DIR/ORIGINAL_* 来播种数据库。
    mkdir -p /usr/local/bin
    cp 1panel 1pctl /usr/local/bin/
    chmod +x /usr/local/bin/1panel /usr/local/bin/1pctl
    ln -sf /usr/local/bin/1panel /usr/bin/1panel
    ln -sf /usr/local/bin/1pctl  /usr/bin/1pctl
    ESC_PW=$(echo "$PANEL_PASS" | sed 's/[!@#$%*_,.?]/\\\\&/g')   # 按 1pctl 的转义规则处理
    sed -i -e "s|^BASE_DIR=.*|BASE_DIR=$PANEL_DIR|" \
           -e "s|^ORIGINAL_PORT=.*|ORIGINAL_PORT=$PANEL_PORT|" \
           -e "s|^ORIGINAL_USERNAME=.*|ORIGINAL_USERNAME=$PANEL_USER|" \
           -e "s|^ORIGINAL_PASSWORD=.*|ORIGINAL_PASSWORD=$ESC_PW|" \
           -e "s|^ORIGINAL_ENTRANCE=.*|ORIGINAL_ENTRANCE=$PANEL_ENT|" \
           -e "s|^LANGUAGE=.*|LANGUAGE=zh|" /usr/local/bin/1pctl
    mkdir -p "$BASE/geo"; cp -f GeoIP.mmdb "$BASE/geo/" 2>/dev/null || :
    rm -rf /usr/local/bin/lang            # 先删再拷，否则会嵌套成 lang/lang
    cp -r lang /usr/local/bin/lang
    cp initscript/1paneld.procd /etc/init.d/1paneld && chmod +x /etc/init.d/1paneld
    /etc/init.d/1paneld enable || ui_warn "1paneld 开机自启未生效"
    cp -rf initscript "$BASE/"
    cd /; rm -rf "$TMP/$DIR" "$TMP/$PKG" "$TMP/checksums.txt"
    ui_ok "文件就位，凭据已播种"
  fi

  # 起服务并验活
  /etc/init.d/1paneld status 2>/dev/null | grep -q '^running' || /etc/init.d/1paneld start
  poll 30 port "$PANEL_PORT" || ui_fail "面板端口 $PANEL_PORT 未监听" "看 logread | grep 1panel 排查"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://127.0.0.1:$PANEL_PORT/$PANEL_ENT") || CODE=000
  [ "$CODE" = 200 ] || ui_fail "面板 HTTP 返回 $CODE（期望 200）"
  ! skip docker && { docker info >/dev/null 2>&1 || ui_fail "docker info 失败"; } || :
  ui_ok "面板 HTTP 200 · docker 就绪"

  # 凭据落盘（600 权限，只有 root 能读）
  umask 077
  cat > "$CRED" <<EOF
# 1Panel 安装信息（$(date '+%F %T')）
版本:     $ONEPANEL_VER
地址:     http://$LAN_IP:$PANEL_PORT/$PANEL_ENT
用户名:   $PANEL_USER
密码:     $PANEL_PASS
数据目录: $BASE
服务管理: /etc/init.d/1paneld {start|stop|restart|status}
命令行:   1pctl {status|user-info|version|update|reset|uninstall}
EOF
  chmod 600 "$CRED"
  ui_ok "凭据写入 $CRED"

  # 注意：1Panel 不注册进鲲鹏商店 —— 它不是 opkg 包，商店守护进程
  # 按 `opkg info` 判状态会永远显示「未安装」，安装按钮还会去拉占位
  # URL 报错。入口以凭据文件和 1pctl 为准。
  ui_stage_end
}

# ============================== 汇总（不是阶段） ==============================
stage_summary() {
  ui_done
  [ -n "${OC_STAT:-}" ] && ui_kv 外网 "$OC_STAT"
  if ! skip panel && [ -n "${PANEL_ENT:-}" ]; then
    ui_kv 面板 "http://$LAN_IP:$PANEL_PORT/$PANEL_ENT"
    ui_kv 账号 "$PANEL_USER / $PANEL_PASS"
    ui_kv 凭据 "$CRED"
  fi
  ui_hr2
}

# ============================== 主流程 ==============================
# 每个阶段一个函数，按顺序跑，出错即停（ui_fail 会 exit 1）。
stage_env
stage_openclash
stage_docker
stage_panel
stage_summary
