#!/bin/sh
# ============================================================================
#  kp-store-lib.sh —— 鲲鹏商店（原生面板 → 应用中心）注册共享库
#
#  为什么要单独抽出来：
#      注册能力一开始写在 kp-install.sh 里给 OpenClash / 1Panel 用，
#      后来 ocspeed 也要进商店，而它是独立脚本 kp-ocspeed.sh（可单独执行）。
#      复制一份实现必然两边漂移，所以抽成共享库：谁要注册谁 source 它。
#
#  用法（被 source，不要直接执行）：
#      . ./kp-store-lib.sh
#      install_app_stub app-xxx 1.0 "说明"     # 非 opkg 应用先补占位包
#      register_store 显示名 图标 描述 路由 子包1 [子包2...]
#      store_verify 显示名 路由 子包名         # 校验注册是否真的生效
#
#  真实机制（真机逆向确认，别照着 UI 猜）：
#      · 商店目录 = /etc/config/appcenter（UCI），守护进程 /usr/sbin/appcenter 出 ubus
#      · 「已安装」由守护进程对 package_list 里每个包名跑 `opkg info` 实时判定
#        → 非 opkg 安装的应用（1Panel、ocspeed）必须造占位包，否则永远显示未安装
#      · 「卸载」按钮真跑 `opkg remove`，所以占位包要能被正常移除
#      · 「打开」按钮 = iframe 加载 luci_module_route；守护进程**只给远程目录里的
#        应用下发这个字段**，UCI 里手写的会被它重写丢弃
#        → 本地路由放它碰不到的 /etc/kp_store/routes.list，由 patch_store_open()
#          注入的 Lua 覆盖函数 action_app_list_data() 读取
# ============================================================================

# 界面函数兜底：主脚本会 source kp-ui.sh 定义这一套；单独被 source 时（如
# kp-ocspeed.sh 单独跑）用简版，免得因为缺界面库而报 command not found。
if ! command -v ui_ok >/dev/null 2>&1; then
  ui_ok()        { echo "  ✓ $*"; }
  ui_warn()      { echo "  ! $*"; }
  ui_info()      { echo "  · $*"; }
  ui_fail()      { echo "  ✗ $*"; exit 1; }
  ui_stage()     { echo ">>> [$1/$2] $3"; }
  ui_stage_end() { :; }
fi
have() { command -v "$1" >/dev/null 2>&1; }

ICON_DIR=/www/luci-static/nradio/images/icon
ROUTES=/etc/kp_store/routes.list

# ---------------------------------------------------------------------------
# 打通「打开」按钮：给商店的列表接口补本地路由
# ---------------------------------------------------------------------------
# 守护进程只给远程目录里的应用下发 luci_module_route，本地注册的应用拿不到，
# 点「打开」就是一片空白。做法：路由写到守护进程碰不到的 /etc/kp_store/routes.list
# （每行 `应用名|路由`），再在控制器末尾**后定义**同名函数覆盖原实现注入。
# 覆盖方式而不是改原函数体：原函数 100 多行，改它必然跟固件升级冲突。
patch_store_open() {
  local lua=/usr/lib/lua/luci/controller/nradio_adv/appcenter.lua
  [ -f "$lua" ] || return 0
  if grep -q kp_local_route "$lua"; then return 0; fi

  [ -f "$lua.kp-bak" ] || cp "$lua" "$lua.kp-bak"
  cat >> "$lua" <<'LUAEOF'

-- kp_local_route: 让"本地注册"的应用也能被打开。
-- 守护进程只给远程目录里的应用下发 luci_module_route，而且会把
-- /etc/config/appcenter 里它不认识的 option 重写掉（实测丢弃）。
-- 所以本地路由放在守护进程碰不到的 /etc/kp_store/routes.list
-- （每行 `应用名|路由`），这里后定义覆盖原函数注入列表数据。
function action_app_list_data()
	local util = require "luci.util"
	local lng = require "luci.i18n"
	local applist = util.ubus("appcenter", "list") or {parameter={applist={}}}
	if applist and applist.parameter and applist.parameter.applist then
		local kp_r = {}
		local f = io.open("/etc/kp_store/routes.list", "r")
		if f then
			for l in f:lines() do
				local n, rt = l:match("^(.-)|(.*)$")
				if n and rt and #rt > 0 then kp_r[n] = rt end
			end
			f:close()
		end
		for _,v in ipairs(applist.parameter.applist) do
			if v.name and #v.name > 0 then
				v.name_lng = lng.translate("AppcenterKey_"..v.name)
				if v.name_lng:match("^AppcenterKey_") then v.name_lng = "" end
			end
			if v.des and #v.des > 0 then
				v.description_lng = lng.translate("AppcenterDes_"..v.name)
				if v.description_lng:match("^AppcenterDes_") then v.description_lng = "" end
			end
			if (not v.luci_module_route or #v.luci_module_route == 0) and kp_r[v.name] then
				v.luci_module_route = kp_r[v.name]
			end
		end
	end
	return applist.parameter
end
LUAEOF
  # 语法不对就回滚，绝不让商店页面打不开
  if ! lua -e "assert(loadfile('$lua'))" >/dev/null 2>&1; then
    cp "$lua.kp-bak" "$lua"
    ui_warn "Lua 补丁语法异常，已回滚（商店'打开'按钮维持原状）"
    return 0
  fi
  rm -rf /tmp/luci-modulecache /tmp/luci-indexcache
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || :
  ui_ok "已打通商店'打开'按钮（本地应用路由注入）"
}

# 写一行路由（幂等：同名先删再追加）
store_route() {
  local app="$1" route="$2"
  [ -n "$route" ] || return 0
  mkdir -p /etc/kp_store
  touch "$ROUTES"
  grep -v "^${app}|" "$ROUTES" > "$ROUTES.tmp" 2>/dev/null || :
  mv "$ROUTES.tmp" "$ROUTES"
  echo "$app|$route" >> "$ROUTES"
}

# ---------------------------------------------------------------------------
# 给「不走 opkg 安装」的应用造占位包
# ---------------------------------------------------------------------------
# 商店守护进程按 `opkg info` 判「已安装 / 未安装」。1Panel 由官方脚本安装、
# ocspeed 是我们自己拷文件装的 —— opkg 数据库里查无此包，直接注册会永远显示
# 「未安装」，点安装还会去拉不存在的包而报错。所以先造一个空内容占位包让
# opkg 认账。包体是空的（只有一个 README）；商店里的「卸载」只会删掉这个
# 占位包，真正卸载走各自的方式（1Panel 用 `1pctl uninstall`）。
install_app_stub() {
  local name="$1" ver="$2" des="$3"
  opkg status "$name" 2>/dev/null | grep -q 'Status:' && return 0
  local arch D=/tmp/kpstub-$name
  arch=$(sed -n 's/^DISTRIB_ARCH=//p' /etc/openwrt_release 2>/dev/null | tr -d "'\"")
  [ -n "$arch" ] || arch=aarch64_cortex-a53
  rm -rf "$D"
  mkdir -p "$D/control" "$D/data/usr/share/$name"
  {
    echo "Package: $name"
    echo "Version: $ver"
    echo "Depends: libc"
    echo "Section: utils"
    echo "Architecture: $arch"
    echo "Installed-Size: 1"
    echo "Description: $des"
  } > "$D/control/control"
  : > "$D/control/conffiles"
  echo "$des" > "$D/data/usr/share/$name/README"
  ( cd "$D/control" && tar -czf "$D/control.tar.gz" ./control ./conffiles )
  ( cd "$D/data"    && tar -czf "$D/data.tar.gz" . )
  ( cd "$D" && echo 2.0 > debian-binary \
    && tar -czf "/tmp/$name.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz )
  if opkg install "/tmp/$name.ipk" >/dev/null 2>&1; then
    rm -rf "$D"
  else
    ui_warn "$name 占位包安装失败（商店状态可能显示「未安装」，不影响使用）"
  fi
}

# ---------------------------------------------------------------------------
# 1Panel 的「打开」承载页
# ---------------------------------------------------------------------------
# 打开按钮 = iframe 加载 `/cgi-bin/luci/<路由>`，而 1Panel 跑在独立端口上、
# 不是 LuCI 页面，所以造一个同源承载页，由它再套一层 iframe 指向面板。
# 面板地址从 `1pctl user-info` 动态读，端口或入口改了也不用动脚本。
install_panel_page() {
  local ctl=/usr/lib/lua/luci/controller/nradio_adv/kp1panel.lua
  local dir=/usr/lib/lua/luci/view/nradio_kp1panel
  mkdir -p "$dir"
  cat > "$ctl" <<'CTLEOF'
module("luci.controller.nradio_adv.kp1panel", package.seeall)

function index()
    entry({"nradioadv", "system", "kp1panel"}, template("nradio_kp1panel/panel"), nil, nil, true).leaf = true
end
CTLEOF
  cat > "$dir/panel.htm" <<'HTMEOF'
<%-
local uci = require "luci.model.uci".cursor()
local lan = uci:get("network", "lan", "ipaddr") or "192.168.66.1"
local h = io.popen("1pctl user-info 2>/dev/null | grep -oE 'http://[^ ]*' | head -1")
local url = h:read("*l") or ""
h:close()
url = url:gsub("%$LOCAL_IP", lan)
if url == "" then url = "http://" .. lan .. ":10090" end
-%>
<div class="cbi-map" style="padding:0;margin:0">
<iframe src="<%=url%>" style="width:100%;height:calc(100vh - 40px);border:0"></iframe>
</div>
HTMEOF
  # 语法不对就撤销，绝不让商店页面因为我们的文件打不开
  if ! lua -e "assert(loadfile('$ctl'))" >/dev/null 2>&1; then
    rm -f "$ctl"
    ui_warn "1Panel 承载页异常，已撤销"
    return 0
  fi
  rm -rf /tmp/luci-modulecache /tmp/luci-indexcache
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || :
}

# ---------------------------------------------------------------------------
# 注册应用到鲲鹏商店
# 用法：register_store <显示名> <图标名> <描述> <打开路由> <子包1> [子包2 ...]
# 幂等：先把同名旧条目删干净再重写，版本/体积每次取 opkg 实时值。
# ---------------------------------------------------------------------------
register_store() {
  local app="$1" icon="$2" des="$3" route="$4" && shift 4
  have uci || return 0
  [ -x /usr/sbin/appcenter ] || { ui_warn "应用商店组件不存在，跳过 $app 注册"; return 0; }

  # 路由表：一行一个 `应用名|路由`，守护进程不会碰这个文件
  if [ -n "$route" ]; then
    store_route "$app" "$route"
    patch_store_open
  fi

  # 图标：优先用应用自带 logo（调用方先拷进商店图标目录），缺失则回退默认图标
  [ -f "$ICON_DIR/$icon" ] || icon=app_default.png

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

  # 非 opkg 安装的应用（如 1Panel / ocspeed）算不出体积，调用方可用 STORE_SIZE_KB 指定
  [ -n "${STORE_SIZE_KB:-}" ] && total=$STORE_SIZE_KB

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

# ---------------------------------------------------------------------------
# 校验一个应用是否真的「注册 + 可打开」
#   ① ubus 目录里有它        ② opkg 认账（决定商店显示「已安装」）
#   ③ 路由表里有它            ④ 路由真的能返回页面（未登录 403 = 存在，404 = 没有）
# 用法：store_verify <显示名> <路由> <子包名>   返回 0=全通过
# ---------------------------------------------------------------------------
store_verify() {
  local app="$1" route="${2:-}" pkg="${3:-}" rc=0
  have uci || { ui_warn "$app：没有 uci"; return 1; }

  if ubus call appcenter list 2>/dev/null | grep -q "\"name\": \"$app\""; then
    ui_ok "$app：商店目录已注册"
  else
    ui_warn "$app：商店目录里没有（未注册或守护进程未重载）"; rc=1
  fi

  if [ -n "$pkg" ]; then
    if opkg info "$pkg" 2>/dev/null | grep -q "^Package:"; then
      ui_ok "$app：opkg 认账（$(opkg info "$pkg" | awk '/^Version:/{print $2}')）→ 商店显示已安装"
    else
      ui_warn "$app：opkg 查无 $pkg → 商店会显示「未安装」"; rc=1
    fi
  fi

  if [ -n "$route" ]; then
    if grep -q "^${app}|" "$ROUTES" 2>/dev/null; then
      ui_ok "$app：本地路由 $route"
    else
      ui_warn "$app：路由表缺 $route（打开按钮会空白）"; rc=1
    fi
    if grep -q kp_local_route /usr/lib/lua/luci/controller/nradio_adv/appcenter.lua 2>/dev/null; then
      ui_ok "$app：商店列表已打路由补丁"
    else
      ui_warn "$app：appcenter.lua 未打补丁，路由注入不生效"; rc=1
    fi
    # 未登录时 LuCI 返回 403（正常保护），404 才是真没有这个页面
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1/cgi-bin/luci/$route" 2>/dev/null) || code=000
    case "$code" in
      200|403) ui_ok "$app：页面可达（HTTP $code）" ;;
      *)       ui_warn "$app：页面返回 $code（期望 200/403）"; rc=1 ;;
    esac
  fi
  return $rc
}
