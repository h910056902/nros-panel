module("luci.controller.ocspeed", package.seeall)

function index()
	local fs = require "nixio.fs"
	local e
	if fs.access("/usr/lib/lua/luci/controller/openclash.lua") then
		e = entry({"admin", "services", "openclash", "ocspeed"}, call("action_page"), _("自动测速"), 90)
	else
		e = entry({"admin", "services", "ocspeed"}, call("action_page"), _("自动测速"), 90)
	end
	e.dependent = true
	entry({"admin", "services", "openclash", "ocspeed", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "run"}, post("action_run")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "save"}, post("action_save")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "toggle"}, post("action_toggle")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "log"}, call("action_log")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "nodes"}, call("action_nodes")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "nodes_txt"}, call("action_nodes_txt")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "testnode"}, post("action_testnode")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "switchnode"}, post("action_switchnode")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "progress"}, call("action_progress")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "parts"}, call("action_parts")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "nodetest"}, call("action_nodetest")).leaf = true
	entry({"admin", "services", "openclash", "ocspeed", "backupnow"}, post("action_backupnow")).leaf = true
end

local SCRIPT = "/usr/libexec/openclash-helper/speedswitch.sh"
-- 分类测速结果（speedswitch.sh 的 build_sites_json 写）
local SITES_JSON = "/etc/openclash-helper/sites.json"

-- 延迟分级 → CSS 类名。原先各处写死 #12864b/#b45309/#c62828（浅色底配色），
-- 在深色主题下对比度不够，且换肤色要改四处 Lua。统一收敛到 g/y/r/x 四个类，
-- 具体颜色由 ocspeed.htm / nodetest.htm 的令牌决定。
--   阈值与页面图例一致：<500 绿 · <1000 黄 · ≥1000 红 · 超时 x
function latency_class(d)
	d = tonumber(d)
	if not d then return "x" end
	if d < 500 then return "g" end
	if d < 1000 then return "y" end
	return "r"
end

-- 热力档位 → 底色深浅（h4 最快 … h1 最慢，h0 超时无底色）。
-- 与 latency_class 同向但分档更细：颜色管「这一格可读」，底色管「哪一片更快」。
-- 分类表是 5 行 × 6 列的数字方阵，逐个读数很慢，深浅扫一眼就能定位。
function heat_level(d)
	d = tonumber(d)
	if not d then return 0 end
	if d <= 300 then return 4 end
	if d <= 500 then return 3 end
	if d <= 1000 then return 2 end
	return 1
end

-- 全部可配置项及其默认值（默认值取自设备出厂配置，避免保存时误清空）
local DEFAULTS = {
	interval = "30",
	threshold = "50",
	group     = "宝贝云",
	test_url  = "https://www.gstatic.com/generate_204",
	gemini_url = "https://gemini.google.com",
	exclude   = "剩余流量 套餐到期 重置剩余 无法使用 请更换 请升级 直连地址 TG群 邀请 返佣 公告",
	timeout   = "4000",
	sites     = "https://www.youtube.com|https://www.netflix.com|https://www.disneyplus.com|https://gemini.google.com|https://chatgpt.com|https://claude.ai",
	testsites = "https://www.baidu.com|https://www.bilibili.com|https://www.taobao.com|https://www.qq.com|https://www.google.com|https://www.youtube.com|https://www.netflix.com|https://github.com|https://gemini.google.com|https://chatgpt.com|https://claude.ai",
	failover_enable    = "0",
	failover_cooldown  = "120",
	failover_threshold = "3000",
	backup_enable      = "1",
	backup_interval    = "90",
	backup_probe       = "8",
	backup_keep        = "3"
}

local function esc_html(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
	return s
end

-- 读取 UCI 值，缺失时回落到默认值
local function uval(c, opt)
	local v = c:get("ocspeed", "main", opt)
	if v == nil or v == "" then v = DEFAULTS[opt] or "" end
	return v
end

-- 是否正在测速：后端用 mkdir /tmp/ocspeed/lock 互斥，并用 /etc/openclash-helper/running 标记
-- 两者都在脚本正常结束时清理；同时判断可覆盖「已加锁但尚未 touch running」的窗口
local function is_busy()
	local fs = require "nixio.fs"
	return fs.access("/tmp/ocspeed/lock") or fs.access("/etc/openclash-helper/running")
end

-- 组装页面动态片段（状态卡片 + 三张表）
-- 首屏渲染与测速完成后「原地刷新」共用同一份逻辑，避免两侧渲染结果不一致
local function build_parts(filt)
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local uci = require "luci.model.uci"
	local p = {}

	-- 1. 节点表数据 (nodes.json)
	local rows, summary, tsh = "", "尚未测速", ""
	local body = fs.readfile("/etc/openclash-helper/nodes.json")
	if body then
		local d = jsonc.parse(body)
		if d and d.nodes then
			local ok, dead, fake = 0, 0, 0
			for _, x in ipairs(d.nodes) do
				if x.s == "ok" then ok = ok + 1
				elseif x.s == "dead" then dead = dead + 1
				else fake = fake + 1 end
			end
			summary = "共 " .. #d.nodes .. " · 可用 " .. ok .. " · 失效 " .. dead .. " · 假节点 " .. fake
			for _, x in ipairs(d.nodes) do
				if filt == "all" or (filt == "ok" and x.s == "ok") or (filt == "dead" and x.s == "dead") or (filt == "fake" and x.s == "fake") then
					local stxt = x.s == "ok" and "可用" or (x.s == "dead" and "失效" or "假节点")
					-- 状态色改由 CSS 类决定：原来写死的 #12864b/#c62828 是给浅色底配的，
					-- 在深色底上对比度不足，而且换主题得改 Lua。
					local scls = x.s == "ok" and "st-ok" or (x.s == "dead" and "st-dead" or "st-fake")
					local delay = x.d and (x.d .. " ms") or "超时"
				local dnum = x.d and tostring(x.d) or "999999"
				-- 假节点是按排除关键词判定的订阅方公告/流量信息，不是真实节点，视觉上弱化
				local cls = x.s == "fake" and "node-row junk" or "node-row"
				rows = rows .. '<tr class="' .. cls .. '" data-name="' .. esc_html(x.n) .. '" title="点击测速并切换">'
						.. '<td class="c-node">' .. esc_html(x.n) .. '</td>'
						.. '<td>' .. esc_html(x.t) .. '</td>'
						.. '<td class="d" data-v="' .. dnum .. '">' .. delay .. '</td>'
						.. '<td class="' .. scls .. '">' .. stxt .. '</td></tr>'
				end
			end
		end
	end
	-- 上次测速时间: 优先 status.json (测速完成), 回退 nodes.json
	local stjson = jsonc.parse(fs.readfile("/etc/openclash-helper/status.json") or "null")
	local tsval = nil
	if stjson and stjson.ts then tsval = stjson.ts end
	if not tsval and body then
		local nb = jsonc.parse(body)
		if nb and nb.ts then tsval = nb.ts end
	end
	local ts_raw = ""
	if tsval then
		tsh = "上次测速: " .. os.date("%Y-%m-%d %H:%M:%S", tonumber(tsval))
		ts_raw = tostring(tsval)
	end

	-- 2. 分类测速表 (sites.json)
	-- 这一版按「一眼看出哪个节点适合哪个分类」排：
	--   · 列按分类聚拢，分类带横跨其上 —— 原来 6 列域名平铺，得逐个认域名才知道
	--     哪几列是 AI 站，问「选哪个节点上 AI」时根本没法扫；
	--   · 底色做延迟热力（越快越绿、越慢越红），数字本身仍按阈值上色 ——
	--     30 个格子里找「哪一片更绿」比逐个读数快得多；
	--   · 每列最快的格子加 best 标记，每行加「综合」（各站延迟中位数，抗单点抖动）；
	--   · 顶部直接给结论：每个分类的最佳节点 + 该分类中位数；
	--   · 超时不写「超时」二字，只留一个 –。十几个「超时」叠在一起会把整张表压成
	--     一片红字，真正可用的格子反而看不见了（这个毛病上一版就有）。
	local sites_table = '<p class="muted">暂无分类测速数据，点击测速生成</p>'
	local sj = jsonc.parse(fs.readfile(SITES_JSON) or "null")
	if sj and sj.sites and #sj.sites > 0 then
		local sites = sj.sites
		local cats = sj.cats or {}
		-- 老版 sites.json 没有 cats 字段（或用户填了未收录的域名）→ 一律归「其他」
		for i = 1, #sites do
			if not cats[i] or cats[i] == "" then cats[i] = "其他" end
		end

		local CAT_ORDER = { "视频", "流媒体", "AI", "其他" }
		local CAT_CLS = { ["视频"] = "c-video", ["流媒体"] = "c-media", ["AI"] = "c-ai", ["其他"] = "c-other" }
		local function catcls(c) return CAT_CLS[c] or "c-other" end

		-- 中位数。入参必须是紧实数组（无 nil 空洞）。
		-- 踩过的坑：原先写成「for _, x in ipairs(t) 收集非空值」，而站点超时会在
		-- 向量里留下 nil 空洞 —— ipairs 遇到第一个 nil 就停，`#t` 对带空洞的表
		-- 也是未定义行为。合成数据里 A 节点 5 个值的中位数被算成了第 1 个值
		-- （440 变成 120）。所以先用 densify() 抽出紧实数组再算。
		local function med(a)
			local n = #a
			if n == 0 then return nil end
			table.sort(a)
			local h = math.floor((n + 1) / 2)
			if n % 2 == 1 then return a[h] end
			return math.floor((a[h] + a[h + 1]) / 2)
		end

		-- 「按站点下标索引、可能含 nil」的向量 → 紧实数组
		local function densify(v, n)
			local a = {}
			for i = 1, n do
				if v[i] then a[#a + 1] = v[i] end
			end
			return a
		end

		-- 抽数值 + 每列最快
		local rows, colmin = {}, {}
		for _, row in ipairs(sj.data or {}) do
			local v = {}
			for k = 1, #sites do
				local d = tonumber(row.d and row.d[k])
				v[k] = d
				if d and (not colmin[k] or d < colmin[k]) then colmin[k] = d end
			end
			rows[#rows + 1] = { n = row.n, v = v }
		end
		for _, r in ipairs(rows) do r.m = med(densify(r.v, #sites)) end

		-- 行按「综合」升序排名。行本身保持初赛延迟顺序不动 —— 两者不一致时
		-- （初赛最快但分类综合排第 3）正好把「通用快 ≠ 分类快」暴露出来。
		local seq = {}
		for i = 1, #rows do seq[i] = i end
		table.sort(seq, function(a, b)
			local ma, mb = rows[a].m, rows[b].m
			if ma and mb then
				if ma ~= mb then return ma < mb end
			elseif ma then
				return true
			elseif mb then
				return false
			end
			return rows[a].n < rows[b].n
		end)
		local rank = {}
		for pos, i in ipairs(seq) do rank[i] = pos end

		-- 列顺序：按分类聚拢（分组表头要求同分类列连续），分类内保持原顺序
		local cols, ins = {}, {}
		for _, c in ipairs(CAT_ORDER) do
			for k = 1, #sites do
				if cats[k] == c then cols[#cols + 1] = k; ins[k] = true end
			end
		end
		for k = 1, #sites do
			if not ins[k] then cols[#cols + 1] = k end
		end

		-- 每个分类的最佳节点
		local catbest = {}
		for _, c in ipairs(CAT_ORDER) do
			local ks = {}
			for k = 1, #sites do
				if cats[k] == c then ks[#ks + 1] = k end
			end
			if #ks > 0 then
				local bi, bm = nil, nil
				for i, r in ipairs(rows) do
					local a = {}
					for _, k in ipairs(ks) do
						if r.v[k] then a[#a + 1] = r.v[k] end
					end
					local m = med(a)
					if m and (not bm or m < bm) then bi, bm = i, m end
				end
				if bi then catbest[c] = { n = rows[bi].n, m = bm } end
			end
		end

		local h = ''
		-- 结论条：先给答案，再给证据（表在下面）
		if next(catbest) then
			h = h .. '<div class="catbest">'
			for _, c in ipairs(CAT_ORDER) do
				local e = catbest[c]
				if e then
					h = h .. '<span class="cb ' .. catcls(c) .. '"><i>' .. esc_html(c) .. '</i>'
						.. '<b title="' .. esc_html(e.n) .. '">' .. esc_html(e.n) .. '</b>'
						.. '<em>' .. e.m .. 'ms</em></span>'
				end
			end
			h = h .. '</div>'
		end

		h = h .. '<table class="sites"><thead>'
		-- 表头第一行：分类带。首尾两个固定列用 rowspan=2 占满两行
		h = h .. '<tr class="catrow"><th class="cn" rowspan="2" data-sort="str" data-col="0">节点</th>'
		local p = 1
		while p <= #cols do
			local c = cats[cols[p]]
			local q = p
			while q <= #cols and cats[cols[q]] == c do q = q + 1 end
			h = h .. '<th class="cbth ' .. catcls(c) .. '" colspan="' .. (q - p) .. '">'
				.. esc_html(c) .. '<em>' .. (q - p) .. '</em></th>'
			p = q
		end
		-- data-col 是必需的：rowspan/colspan 会让「第几个 data-sort 表头」和
		-- 「第几个 td」错位，排序会串列（综合列排的是第一个站点的值）
		h = h .. '<th class="agg" rowspan="2" data-sort="num" data-col="' .. (#cols + 1)
			.. '" title="各站延迟中位数（超时不计）">综合</th></tr>'
		-- 表头第二行：站点名
		h = h .. '<tr class="domrow">'
		for n, k in ipairs(cols) do
			local ttl = (sj.urls and sj.urls[k]) or sites[k] or ""
			h = h .. '<th data-sort="num" data-col="' .. n .. '" title="' .. esc_html(ttl) .. '">'
				.. esc_html(sites[k] or "") .. '</th>'
		end
		h = h .. '</tr></thead><tbody>'

		local b = ''
		for i, r in ipairs(rows) do
			-- data-rk 必须挂在 td 上（不是 tr）：::before 的 attr() 只读元素自身的属性；
			-- 而排名用 CSS 渲染而不是塞进文本，是为了不污染按节点名排序时的 textContent。
			-- data-heat 让 decorateAll 跳过这些格子：分类表用底色表达快慢，
			-- 再叠 30 根延迟条只会糊成一片。
			b = b .. '<tr class="node-row" data-name="' .. esc_html(r.n) .. '" title="点击测速并切换">'
				.. '<td class="c-node" data-rk="' .. (rank[i] and tostring(rank[i]) or "") .. '">'
				.. esc_html(r.n) .. '</td>'
			for n, k in ipairs(cols) do
				local d = r.v[k]
				if d then
					local bst = (colmin[k] and d <= colmin[k]) and ' best' or ''
					b = b .. '<td class="d ' .. latency_class(d) .. ' h' .. heat_level(d) .. bst
						.. '" data-v="' .. d .. '" data-heat="1">' .. d .. '</td>'
				else
					-- 视觉上只留一个 –（title 里保留「超时」说法）
					b = b .. '<td class="d x h0" data-v="999999" data-heat="1" title="超时">&ndash;</td>'
				end
			end
			local m = r.m
			b = b .. '<td class="d agg" data-v="' .. (m and tostring(m) or "999999")
				.. '" data-heat="1">'
				.. (m and (m .. '<span class="u">ms</span>') or '&ndash;') .. '</td></tr>'
		end
		h = h .. b .. '</tbody></table>'

		-- 表下注释：采样规模 + 数据时刻 + 颜色图例
		local age = sj.ts and os.date("%m-%d %H:%M", tonumber(sj.ts)) or "-"
		h = h .. '<div class="tmeta"><span>采样 ' .. tostring(#rows) .. ' 节点 × ' .. tostring(#sites) .. ' 站点</span>'
			.. '<span class="sep">·</span><span>分类于 ' .. esc_html(age) .. '</span>'
			.. '<span class="sep">·</span><span class="lgd2">'
			.. '<i class="q g"></i>≤500<i class="q y"></i>≤1000<i class="q r"></i>&gt;1000<i class="q x"></i>超时'
			.. '</span></div>'
		sites_table = h
	end

	-- 3. 状态卡片 (status.json + live API)
	local uci = require "luci.model.uci"
	local group = "宝贝云"
	local ug = uci.cursor()
	local g = ug:get("ocspeed", "main", "group")
	if g and g ~= "" then group = g end
	-- 控制端口与密钥必须和 speedswitch.sh 取同一处 UCI（openclash.config.cn_port /
	-- dashboard_password）。写死 9090 + 固定密钥时，用户只要在 LuCI 里改过
	-- dashboard_password，这条查询就永远 401；而下面第 354 行有 `cur == ""` 兜底，
	-- 页面会静默退化成显示 status.json 里的旧值 —— 看起来"能用"，其实是陈的。
	local ocport = ug:get("openclash", "config", "cn_port") or ""
	if ocport == "" then ocport = "9090" end
	local ocsec = ug:get("openclash", "config", "dashboard_password") or ""
	-- 未设置时留空：按无密钥访问 mihomo（切勿写死真实密钥）
	-- 密钥/端口来自用户输入，会拼进 shell 单引号串：先剔掉会截断命令的字符
	ocsec = ocsec:gsub("'", "")
	ocport = ocport:gsub("[^0-9]", "")
	if ocport == "" then ocport = "9090" end
	local cur = luci.sys.exec('curl -s -m 6 -H "Authorization: Bearer ' .. ocsec .. '" http://127.0.0.1:' .. ocport .. '/proxies/' .. group .. ' 2>/dev/null')
	cur = cur:match('"now":"([^"]*)"') or ""
	cur = cur:gsub("%s+$", "")
	local best_node, best_delay, cands, swinfo = "-", "-", "0", "未变"
	local st = jsonc.parse(fs.readfile("/etc/openclash-helper/status.json") or "null")
	if st then
		if st.top and #st.top > 0 then
			best_node = st.top[1].n
			best_delay = tostring(st.top[1].d) .. " ms"
		end
		if st.candidates then cands = tostring(st.candidates) end
		if st.switched == 1 then swinfo = "已切换" end
		if cur == "" then cur = st.now or "-" end
	end

	-- 4. 节点排行 (status.json top)
	-- v3.3: top 里的 d 是初赛(gstatic)延迟, 也就是排名依据; f 是决赛(gemini)延迟,
	-- 只作为可用性闸门的结果展示, null 表示未通过。排名不再看决赛 —— 决赛走代理
	-- 抖动可达 2.3 倍, 用它排名会让最快的节点被更慢的顶掉。
	local top_table = '<tr><td colspan="3" class="muted">暂无数据，点击测速</td></tr>'
	if st and st.top and #st.top > 0 then
		top_table = ""
		for i, t in ipairs(st.top) do
			local d = t.d or 0
			local lv = latency_class(d)
			-- 决赛延迟塞进 tooltip: 加列会动表头, 不改结构更稳
			local tip = (t.f and ("决赛 " .. tostring(t.f) .. " ms") or "决赛未通过(不影响排名)")
				.. " · 点击测速并切换"
			top_table = top_table .. '<tr class="node-row" data-name="' .. esc_html(t.n) .. '" title="' .. esc_html(tip) .. '">'
				.. '<td>' .. i .. '</td><td class="c-node">' .. esc_html(t.n) .. '</td>'
				.. '<td class="d ' .. lv .. '" data-v="' .. tostring(d) .. '">' .. d .. ' ms</td></tr>'
		end
	end

	-- 5. 备用节点 (backup.json)
	-- 由 speedswitch.sh 每 backup_interval 分钟预选，故障时 failover 按名次依次验证接管。
	-- 这份数据在 overlay 上，跨每天 02:00 的自动重启保留。
	local backup_html, backup_sub, backup_ts_raw = "", "", ""
	local bj = jsonc.parse(fs.readfile("/etc/openclash-helper/backup.json") or "null")
	if bj and bj.list and #bj.list > 0 then
		for i, x in ipairs(bj.list) do
			local dv = x.d
			local lv = latency_class(dv)
			backup_html = backup_html .. '<span class="bk-item r' .. i .. '"><i>' .. i .. '</i>'
				.. '<span class="nm">' .. esc_html(x.n) .. '</span>'
				.. '<b class="' .. lv .. '">' .. (dv and (tostring(dv) .. " ms") or "-") .. '</b></span>'
		end
		backup_ts_raw = tostring(bj.ts or 0)
		backup_sub = "上次预选 " .. os.date("%H:%M:%S", tonumber(bj.ts or os.time()))
			.. " · 探测 " .. tostring(bj.probed or 0) .. " 个候选 · 故障时可 1 秒内接管"
	else
		backup_html = '<span class="bk-empty">尚未预选，点「立即预选」生成</span>'
		backup_sub = "名单为空时，故障转移会退回当场串行探测（实测约 6 秒）"
	end

	-- 空状态：筛选后一行不剩 / 压根没测过，都要给句话，而不是留一片空白
	if rows == "" then
		rows = '<tr><td colspan="4" class="muted" style="text-align:center;padding:20px 10px">'
			.. (filt == "all" and '暂无节点数据，点击上方「测速并切换」生成'
			                  or '当前筛选条件下没有节点，点「全部」返回')
			.. '</td></tr>'
	end

	p.cur          = cur
	p.best         = best_node
	p.bestd        = best_delay
	p.cands        = cands
	p.swinfo       = swinfo
	p.top_table    = top_table
	p.nodes_rows   = rows
	p.nodes_sum    = summary
	p.tsh          = tsh
	p.ts_raw       = ts_raw
	p.sites_table  = sites_table
	p.backup_html  = backup_html
	p.backup_sub   = backup_sub
	p.backup_ts_raw = backup_ts_raw
	return p
end

function action_page()
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"

	-- 刷新页面即重新测速: 无测速在跑且距上次测速>60秒才触发
	local need_test = not is_busy()
	if need_test then
		local nd = jsonc.parse(fs.readfile("/etc/openclash-helper/nodes.json") or "null")
		if nd and nd.ts and (os.time() - tonumber(nd.ts)) < 60 then need_test = false end
	end
	if need_test then
		luci.sys.call("( " .. SCRIPT .. " run >/dev/null 2>&1 & )")
	end

	local filt = luci.http.formvalue("filter") or "all"
	local filt_all, filt_ok, filt_dead, filt_fake = "", "", "", ""
	if filt == "all" then filt_all = " active"
	elseif filt == "ok" then filt_ok = " active"
	elseif filt == "dead" then filt_dead = " active"
	elseif filt == "fake" then filt_fake = " active"
	end

	local p = build_parts(filt)

	-- 5. 自动开关信息
	local ug2 = require("luci.model.uci").cursor()
	local auto_intv, auto_checked = "自动测速已停用", ""
	if ug2:get("ocspeed", "main", "enabled") == "1" then
		auto_intv = "每 " .. (ug2:get("ocspeed", "main", "interval") or "30") .. " 分钟自动测速"
		auto_checked = " checked"
	end

	-- 故障转移状态
	local fo_en = ug2:get("ocspeed", "main", "failover_enable")
	local fo_checked = ""
	local fo_info = "故障转移: 停用"
	if fo_en == "1" then
		fo_checked = " checked"
		local fo_thr = ug2:get("ocspeed", "main", "failover_threshold") or "3000"
		local fo_cd  = ug2:get("ocspeed", "main", "failover_cooldown") or "120"
		fo_info = "故障转移: 启用 · 阈值 " .. fo_thr .. "ms · 冷却 " .. fo_cd .. "s"
	end

	-- 备用节点状态
	local bk_en = ug2:get("ocspeed", "main", "backup_enable")
	local bk_checked = " checked"
	if bk_en == "0" then bk_checked = "" end

	-- 禁止浏览器缓存页面：改完模板刷新即可生效，避免一直看到旧页面
	luci.http.header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
	luci.http.header("Pragma", "no-cache")
	luci.http.header("Expires", "0")

	-- 页面版本戳：模板文件最后修改时间，用于确认浏览器加载的是最新版本
	local tst = fs.stat("/usr/lib/lua/luci/view/ocspeed.htm")
	local page_ver = tst and os.date("%m-%d %H:%M", tst.mtime) or "-"

	-- 渲染 (chrome 模板, 与 OpenClash 一致)
	luci.template.render("ocspeed", {
		ver     = page_ver,
		base    = luci.dispatcher.build_url("admin", "services", "openclash", "ocspeed"),
		token   = luci.dispatcher.context.authtoken or "",
		fo_info = fo_info,
		fo_checked = fo_checked,
		bk_checked = bk_checked,
		backup_html  = p.backup_html,
		backup_sub   = p.backup_sub,
		backup_ts_raw = p.backup_ts_raw,
		cur     = p.cur,
		best    = p.best,
		bestd   = p.bestd,
		cands   = p.cands,
		swinfo  = p.swinfo,
		top_table    = p.top_table,
		nodes_rows   = p.nodes_rows,
		nodes_sum    = p.nodes_sum,
		tsh     = p.tsh,
		ts_raw  = p.ts_raw,
		sites_table  = p.sites_table,
		thr     = esc_html(uval(ug2, "threshold")),
		busy    = is_busy() and "1" or "0",
		intv    = auto_intv,
		auto_checked = auto_checked,
		filt_all = filt_all,
		filt_ok  = filt_ok,
		filt_dead = filt_dead,
		filt_fake = filt_fake,
		-- 设置表单回填（原先缺失，导致保存时把配置重置为默认值）
		f_interval   = esc_html(uval(ug2, "interval")),
		f_threshold  = esc_html(uval(ug2, "threshold")),
		f_group      = esc_html(uval(ug2, "group")),
		f_test_url   = esc_html(uval(ug2, "test_url")),
		f_gemini_url = esc_html(uval(ug2, "gemini_url")),
		f_exclude    = esc_html(uval(ug2, "exclude")),
		f_timeout    = esc_html(uval(ug2, "timeout")),
		f_sites      = esc_html(uval(ug2, "sites")),
		f_testsites  = esc_html(uval(ug2, "testsites")),
		f_fo_threshold = esc_html(uval(ug2, "failover_threshold")),
		f_fo_cooldown  = esc_html(uval(ug2, "failover_cooldown")),
		f_backup_interval = esc_html(uval(ug2, "backup_interval")),
		f_backup_probe    = esc_html(uval(ug2, "backup_probe")),
		f_backup_keep     = esc_html(uval(ug2, "backup_keep"))
	})
end

function action_status()
	local fs = require "nixio.fs"
	local body
	if fs.access("/var/log/ocspeed.log") then
		body = luci.sys.exec(SCRIPT .. " status 2>/dev/null")
		if body == nil or body == "" then
			body = '{"running":false,"enabled":false,"interval":"30","threshold":"50","group":"","current":"","last":null,"history":[]}'
		end
	else
		body = '{"running":false,"enabled":false,"interval":"30","threshold":"50","group":"","current":"","last":null,"history":[]}'
	end
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(body)
end

function action_run()
	local sw = luci.http.formvalue("switch") or "1"
	-- 后端用 mkdir 做互斥：重复触发时脚本静默 exit 0（连 running 都不会 touch）。
	-- 此前这里无条件返回 ok:true，前端无法区分「已启动」和「被锁跳过」，
	-- 表现为点了没反应。派发前先探测，把真实状态告诉前端。
	if is_busy() then
		luci.http.prepare_content("application/json; charset=utf-8")
		luci.http.write('{"ok":false,"busy":true,"msg":"已有测速在运行"}')
		return
	end
	luci.sys.call("( " .. SCRIPT .. (sw == "0" and " test" or " run") .. " >/dev/null 2>&1 & )")
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write('{"ok":true,"busy":false}')
end

-- 测速完成后原地刷新：只回传动态片段，不触发测速、不重载整页
function action_parts()
	local jsonc = require "luci.jsonc"
	local filt = luci.http.formvalue("filter") or "all"
	local p = build_parts(filt)
	-- nixio.fs.access 命中返回 true、未命中返回 nil；直接赋值 nil 在 Lua 里等于删除该键，
	-- 会让 JSON 里整个 running 字段消失。显式收敛成布尔值。
	p.running = is_busy() and true or false
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(jsonc.stringify(p))
end

function action_toggle()
	local en = luci.http.formvalue("enabled")
	if en == "1" then
		luci.sys.call(SCRIPT .. " enable >/dev/null 2>&1")
	else
		luci.sys.call(SCRIPT .. " disable >/dev/null 2>&1")
	end
	luci.http.prepare_content("application/json")
	luci.http.write('{"ok":true}')
end

function action_save()
	local uci = require("luci.model.uci").cursor()
	local fs = require "nixio.fs"
	if not fs.access("/etc/config/ocspeed") then
		fs.writefile("/etc/config/ocspeed", "config ocspeed 'main'\n")
	end
	-- 空值回落到默认值；表单已回填，正常保存不会丢配置
	local function set(opt)
		local v = luci.http.formvalue(opt)
		if v == nil or v == "" then v = DEFAULTS[opt] or "" end
		uci:set("ocspeed", "main", opt, v)
	end
	set("interval")
	set("threshold")
	set("group")
	set("test_url")
	set("gemini_url")
	set("exclude")
	-- 以下为原先界面无法编辑的选项
	set("timeout")
	set("sites")
	set("testsites")
	set("failover_threshold")
	set("failover_cooldown")
	set("backup_interval")
	set("backup_probe")
	set("backup_keep")
	-- 复选框：未勾选时浏览器不提交，需显式置 0
	local fo = luci.http.formvalue("failover_enable")
	uci:set("ocspeed", "main", "failover_enable", (fo == "1") and "1" or "0")
	-- 备用节点预选的开关同时决定 cron 里有没有那条每分钟唤起的 backup 行
	local bk = luci.http.formvalue("backup_enable")
	uci:set("ocspeed", "main", "backup_enable", (bk == "1") and "1" or "0")
	uci:commit("ocspeed")
	-- 无条件重建 crontab：改 backup_enable 要增删那一行，不用等 enabled 状态
	luci.sys.call(SCRIPT .. (uci:get("ocspeed", "main", "enabled") == "1" and " enable" or " disable") .. " >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write('{"ok":true}')
end

-- 立即重新预选备用节点（不等下一个 90 分钟周期）
function action_backupnow()
	if is_busy() then
		luci.http.prepare_content("application/json; charset=utf-8")
		luci.http.write('{"ok":false,"busy":true,"msg":"已有测速在运行"}')
		return
	end
	local out = luci.sys.exec(SCRIPT .. " backupnow 2>/dev/null")
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(out)
end

function action_nodetest()
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local body = fs.readfile("/tmp/ocspeed/testnode_result.json")
	local node, results = "", ""
	if body then
		local d = jsonc.parse(body)
		if d and d.node then node = d.node end
		if d and d.results then
			local rows = ""
			for _, r in ipairs(d.results) do
				local delay, col
				if r.d then
					delay = r.d .. " ms"
					col = r.d < 500 and "#12864b" or (r.d < 1000 and "#b45309" or "#c62828")
				else
					delay = "超时"
					col = "#c62828"
				end
				rows = rows .. "<tr><td>" .. esc_html(r.site) .. "</td><td style='color:" .. col .. "'>" .. delay .. "</td></tr>"
			end
			results = rows
		end
	end
	-- 节点名转义: node_html 用于HTML显示, node_js 用于JS字符串
	local node_html = esc_html(node)
	local node_js = node:gsub("\\", "\\\\"):gsub('"', '\\"')
	luci.template.render("nodetest", {
		node_html = node_html,
		node_js = node_js,
		results_rows = results,
		token = luci.dispatcher.context.authtoken or "",
		switch_url = luci.dispatcher.build_url("admin", "services", "openclash", "ocspeed", "switchnode"),
		back = luci.dispatcher.build_url("admin", "services", "openclash", "ocspeed")
	})
end

function action_progress()
	local fs = require "nixio.fs"
	local body = fs.readfile("/tmp/ocspeed/progress.json") or '{"phase":"idle","msg":"空闲","pct":0}'
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(body)
end

function action_log()
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(luci.sys.exec("tail -n 200 /var/log/ocspeed.log 2>/dev/null"))
end

function action_nodes()
	local fs = require "nixio.fs"
	local body = fs.readfile("/etc/openclash-helper/nodes.json") or '{"ts":0,"total":0,"nodes":[]}'
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(body)
end

function action_testnode()
	local name = luci.http.formvalue("name")
	if not name or name == "" then
		luci.http.prepare_content("application/json")
		luci.http.write('{"ok":false,"msg":"缺少节点名"}')
		return
	end
	name = name:gsub("'", ""):gsub(";", ""):gsub("&", "")
	local out = luci.sys.exec(SCRIPT .. " testnode '" .. name .. "' 2>/dev/null")
	require("nixio.fs").writefile("/tmp/ocspeed/testnode_result.json", out)
	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write(out)
end

function action_switchnode()
	local name = luci.http.formvalue("name")
	if not name or name == "" then
		luci.http.prepare_content("application/json")
		luci.http.write('{"ok":false,"msg":"缺少节点名"}')
		return
	end
	name = name:gsub("'", ""):gsub(";", ""):gsub("&", "")
	luci.sys.call(SCRIPT .. " switchnode '" .. name .. "' >/dev/null 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write('{"ok":true}')
end

function action_nodes_txt()
	local fs = require "nixio.fs"
	local body = fs.readfile("/etc/openclash-helper/nodes.json")
	local out = ""
	if body then
		local jsonc = require "luci.jsonc"
		local d = jsonc.parse(body)
		if d and d.nodes then
			for _, x in ipairs(d.nodes) do
				local st = x.s == "ok" and "可用" or (x.s == "dead" and "失效" or "假节点")
				local delay = x.d and (x.d .. "ms") or "超时"
				out = out .. st .. "\t" .. delay .. "\t" .. x.n .. "\n"
			end
		end
	end
	if out == "" then out = "无节点数据, 请先在页面点击「测速并切换」\n" end
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(out)
end
