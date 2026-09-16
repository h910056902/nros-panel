# 鲲鹏 C2000 U · iStoreOS 风格化 方案与工期

> 参照目标：`wukongdaily/gl-inet-onescript`（GL-iNet 系列一键 iStoreOS 风格化）
> 实测设备：鲲鹏 NRadio C2000 U（`192.168.66.1`），2026-09-16 探测
> 结论一句话：**能，但只做「软件层风格化」，不刷固件；且不建议全局换 Argon 主题，改走「换肤不换骨架」。**

---

## 一、先说参照仓库到底做了什么（这是份封闭清单）

`gl-inet.sh` 的 `install_istore_os_style()` + `do_istore()` 全部动作，逐条列清：

| # | 动作 | 实现 |
|---|---|---|
| 1 | Argon 紫色主题 | `luci-theme-argon` + `luci-app-argon-config` + zh-cn，写 UCI `mediaurlbase=/luci-static/argon` |
| 2 | iStore 应用商店 | 从私源取 `luci-app-store`，解出 `is-opkg` 再装 `taskd` / `luci-lib-taskd` / `luci-lib-xterm` |
| 3 | 首页 Quickstart | `luci-app-quickstart` + `quickstart` 包，隐藏磁盘区格式化按钮 |
| 4 | 文件传输 | `luci-app-filetransfer` + `luci-lib-fs` |
| 5 | 终端 | `opkg install ttyd` |
| 6 | 元包 | `app-meta-sftp` / `app-meta-ddnsto` / `app-meta-diskman` |
| 7 | 改系统标识 | `/etc/openwrt_release` 的 `DISTRIB_DESCRIPTION` → `Openwrt like iStoreOS Style by wukongdaily` |
| 8 | 杂项 | 时区 Asia/Shanghai、防火墙 WAN 入站、DHCP 域名、`/usr/bin/g` 快捷命令 |

**就这些。** 没有刷机、没有内核改动、没有换桌面。所以可复刻范围是**可枚举、封闭**的——这是好消息。

---

## 二、设备现状实测（决定可行性的事实）

| 项 | 实测值 | 对方案的影响 |
|---|---|---|
| 固件 | OpenWrt 21.02-SNAPSHOT，aarch64_cortex-a53，内核 5.4.281 | 与参照仓库的 LuCI 21 系一致 |
| LuCI | **git-26.253.32058**（`luci-base` / `luci-mod-admin-full` / `luci-theme-nradio-v3`） | 与 A 机 git-26.224 同代，但**更新** |
| **菜单机制** | **经典 `entry()`**——`/usr/share/luci/` 整个不存在、`/usr/share/luci/menu.d` MISSING、`dispatcher.lua` 里 `menu.d` 出现 **0 次** | ⚠️ **按 menu.d 注册的插件不会出菜单**，必须补经典 controller 垫片 |
| LuCI 兼容层 | `cbi.lua` 42.7KB、`model/network.lua` 38.4KB、`view/cbi/*` 全在 | ✅ **不需要、也绝不能装 luci-compat**（装了必崩） |
| 主题 | 只有 `/luci-static/nradio`（含 images/css/main.min.css 等） | 换主题必须连带处理厂商页面 |
| 官方 feed | 阿里云 21.02.7 的 base / packages / routing **三个**，**没有 luci 源** | ⚠️ `luci-theme-argon` / `luci-app-quickstart` / `luci-compat` 在 `opkg list` 里**全为 0** → luci 系包只能走第三方 IPK |
| 官方 luci 源可达性 | `.../packages/aarch64_cortex-a53/luci/Packages.gz` → **200 / 177KB**（可达） | ⚠️ **能加，但绝不能加**——那是 git-22 代，与 git-26.253 冲突 |
| iStore 私源 | `istore.istoreos.com/repo/all/store` → **200**（luci-app-store 0.2.1-r1 / taskd 1.0.3-2 / luci-lib-taskd 1.0.26 / luci-lib-xterm 4.18.0）<br>`istore.linkease.com/...` → **000（已死）** | ⚠️ 参照脚本写的是 linkease 域名，**照抄必失败**，要改成 istoreos.com |
| iStore 应用源 | `istore.istoreos.com/repo/aarch64_cortex-a53/nas` → 60+ 包（alist / ddns-go / ddnsto / cups…） | ✅ 可扩展应用，但受「无 veth → 容器只能 host 网络」限制 |
| 未装 | luci-app-store、taskd、quickstart、argon、ttyd、filetransfer、luci-compat、luci-lua-runtime、luci-lib-ipkg | 全部从零开始 |
| 已有基础件 | `curl` / `wget` / `tar` / `gzip` / `zcat` / `unzip` / `bash` **都有**；`jq` 无 | 安装流程可跑 |
| feed 可装 | `ttyd` / `lsblk` / `block-mount` / `e2fsprogs` / `fdisk` / `parted` / `kmod-fs-ext4` / `kmod-fs-vfat` / `zoneinfo-asia` **各 1，可装** | 磁盘管理基础件齐 |
| 资源 | 内存 992MB（可用 **494MB**）、overlay 16G（可用 **15G**）、/tmp 490MB | ✅ 非常充裕，不构成瓶颈 |
| 现有成果 | 1Panel v1.10.34-lts 已原生装成（:10090）；ocspeed 五件套；kp-webui iStoreOS 风格控制台（:10087） | 风格化是**叠在已有成果上**，不是从零 |

---

## 三、能复刻到什么程度（分三层）

### A 层 · 能做且低风险

| 项 | 依据 |
|---|---|
| iStore 应用商店（`luci-app-store` 0.2.1 + taskd 全家） | 私源实测 200，包名/版本已确认 |
| 改 `DISTRIB_DESCRIPTION` 为 iStoreOS Style | 一行 `sed`，观感直接对齐 |
| `ttyd` 终端 | feed 里有 |
| 磁盘管理基础件（lsblk / block-mount / e2fsprogs / fdisk / parted / kmod-fs-*） | feed 全有 |
| iStore 私源扩展应用（alist / ddns-go / ddnsto 等 60+） | 私源实测可列 |

### B 层 · 能做但要写适配（**工作量主体**）

| 项 | 要额外做的事 |
|---|---|
| **Quickstart 首页**（iStoreOS 观感的核心） | ① 装包；② 补**经典 controller 垫片**（本机无 menu.d）；③ 注入作用域 CSS 修版式（`.main-content:has(#app)` 那套，已有现成补丁）；④ 装成 `init.d` **自愈服务**（重装/重启不丢） |
| `luci-app-filetransfer` | 第三方 IPK + 经典 controller 垫片 |
| **Argon 主题** | 见下方「硬障碍 3」，是全局风险点 |

### C 层 · 做不到 / 不该做

| 项 | 原因 |
|---|---|
| **刷成真 iStoreOS 固件** | iStoreOS 官方**没有 MT7987 / C2000 U 机型**；刷了会丢掉私有的 4G/5G CPE 驱动（`cell`/`cpe`/`sms`/`fanctrl`）——等于把一台 5G CPE 变成普通路由器，且有变砖风险。参照仓库本身也不刷机 |
| iStore 里的 1Panel（`luci-app-istorepanel`） | 走 `is-opkg` 私有通道，公开源拿不到（已验证）。**但 1Panel 本体已经原生装好了**，路径不同而已 |
| iStore 里的 Docker 应用 | 内核**无 veth**（`kmod-veth` 是空包）→ 容器只能 `--network host`，桥接应用一律起不来 |
| 装 OpenWrt 21/22 的 `luci-compat` / `luci-lua-runtime`（git-22 代） | **本机 LuCI git-26.253 已有自带兼容层**；装旧包会污染 `luci-base`，卸载时删走 `cbi.lua` → **整个 LuCI 502** |

---

## 四、三个硬障碍与对策

### 障碍 1：本机 LuCI 是「经典菜单」，iStoreOS 插件多是「menu.d 现代菜单」

**实测**：`dispatcher.lua` 完全不读 `menu.d`，`/usr/share/luci/` 目录不存在。
**后果**：插件文件装上了、路由也通，但**侧边栏不出现**——最难排查的一类故障。
**对策**：给每个插件补一个**经典 controller 垫片**（`controller/<name>.lua` 里 `entry({"admin","<name>"}, template(...))`）。技能库里 `unm_luci_shim`（网易云解锁那次）已经是可复用样板：

```
controller.lua  →  entry({"admin","<plugin>"}, template("<plugin>/index"), _("标题"), 60)
model.lua       →  转发到插件自己的 SPA/接口
```

### 障碍 2：feed 里没有 luci 源，luci 系包全要手动取

**实测**：`luci-theme-argon` / `luci-app-quickstart` / `luci-compat` 在 `opkg list` 里**全是 0**。
**对策**：
- 第三方 IPK 走 `raw.githubusercontent.com/wukongdaily/gl-inet-onescript/master/...`（实测三个 argon/filetransfer IPK URL 都 **200**）
- **不加官方 luci 源**（git-22 代，必崩）
- 下载必须 **curl + wget 双栈**（本机 curl 拉 raw 会 000、wget 可以——已在技能库记过）

### 障碍 3（最关键）：全局换 Argon 主题会让**厂商 4G/5G 页面破相**

**机理**：`luci.main.mediaurlbase` 是**全局唯一**的。切成 `/luci-static/argon` 后，主题自己的 `header.htm` 只加载 Argon 的 CSS，**不再加载** `nradio.min.css` / `bootstrap-dialog.min.css` / `cascade.min.css`。而厂商 50+ 个 `nradio_adv` 页面（CPE 状态、短信、APN、锁频、风扇……）全是照 nradio 主题的类名写的 → **破相甚至不可用**。

**这三条路，必须选一条：**

| 路线 | 做法 | 风险 | 建议 |
|---|---|---|---|
| **① 保守** | 不换主题。只装 iStore 商店 + quickstart（quickstart 自带独立样式，不吃全局主题） | 极低 | 想要「功能像 iStoreOS」选它 |
| **② 换肤不换骨架（推荐）** | `cp -r /www/luci-static/nradio /www/luci-static/istoreos`，**在副本上**覆盖主色/卡片圆角/阴影/间距，保留全部原有 CSS 与类名，再把 `mediaurlbase` 指到副本 | 低 | 想要「看着像 iStoreOS」又不想牺牲 4G/5G 页面 |
| **③ 激进** | 直接切 Argon | **高**：厂商页面破相 | 只有你确认那些页面不重要时才做 |

> ② 的关键优势：副本里 **images/ 一起复制**，厂商页面里写死 `/luci-static/nradio/...` 的绝对路径仍然有效（原目录还在），所以是**双向安全**的。

---

## 五、流程（P0 → P6，每阶段都有回滚点）

| 阶段 | 内容 | 产物 | 回滚点 |
|---|---|---|---|
| **P0 备份** | 快照 `/overlay` 关键路径：`/etc/config/`、`/usr/lib/lua/luci/controller`、`/www/luci-static/`、`/etc/opkg/` → 打包到 `/mnt/storage/data/backup/` | `pre-istore-<ts>.tar.gz` | —— |
| **P1 iStore 框架** | 取 `luci-app-store` IPK → 解出 `is-opkg` → 装 `taskd`/`luci-lib-taskd`/`luci-lib-xterm`/`luci-app-store`。**私源改 istoreos.com** | `/cgi-bin/luci/admin/store` 可开 | 删装进去的 4 个目录 + 清 LuCI 缓存 |
| **P2 Quickstart** | 装 quickstart → 补经典 controller 垫片 → 注入版式修复 CSS → 装自愈 `init.d` | `/cgi-bin/luci/admin/quickstart` 200 | 删 `view/quickstart` + 垫片 |
| **P3 皮肤** | 按选定路线（①②③）做主题；①跳过、②复制+覆盖、③切 Argon | 新主题目录 + UCI | `uci set mediaurlbase=/luci-static/nradio` 一行回滚 |
| **P4 附赠件** | `luci-app-filetransfer` + `luci-lib-fs`；`ttyd`；磁盘件（lsblk/block-mount/e2fsprogs/fdisk/parted） | 文件传输菜单 + ttyd:7681 | `opkg remove` |
| **P5 商店注册 + 自愈** | 把 quickstart / iStore 注册进鲲鹏原生商店的「打开」目标（写 `routes.list` + 覆盖 `action_app_list_data`）；自愈脚本装成服务 | 商店卡片可点开 | 还原 `routes.list` |
| **P6 验收 + 文档** | 逐项验收表 + 真机截图 + 写进仓库 docs | 验收报告 | —— |

**每阶段结束都做三件事**（技能铁律）：读回验证 → `free -k` 复核内存 → 清 LuCI 缓存（`rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache` + 重启 uhttpd）。

---

## 六、开发时间

**前提假设**：管线已踩通（`kunpeng-istore.sh` 已有完整移植版、quickstart 版式补丁已有、经典 controller 垫片有样板），我全程执行，你只需在 3 个决策点回话 + 最终验收。

| 档位 | 范围 | 我的执行时长 | 你需要投入 |
|---|---|---|---|
| **最小可用** | P0 + P1 + P2（iStore 商店 + Quickstart 首页 + 自愈） | **约 3–4 小时** | 验收 15 分钟 |
| **推荐整套（路线②）** | P0–P6 全做，皮肤走「换肤不换骨架」 | **约 1.5–2 个工作日**（10–14 小时） | 3 个决策点 + 验收 30 分钟 |
| **激进整套（路线③）** | 同上但切 Argon 全局主题 | 追加 **1–2 小时**，但**额外预留半天排障**（厂商页面修复不可预期） | 同上 + 接受 4G/5G 页面风险 |

**时间分布（推荐整套）**

| 阶段 | 时长 | 说明 |
|---|---|---|
| P0 备份 | 0.3 h | 纯拷贝 |
| P1 iStore 框架 | 0.7 h | 取包 + 装 + 验证 |
| P2 Quickstart + 垫片 + CSS | 2.0 h | **含真机反复**（垫片要试路由） |
| P3 皮肤（路线②） | 2.5 h | **设计占比最高**：覆盖变量、卡片、间距、图标 |
| P4 附赠件 | 1.0 h | 结构简单 |
| P5 商店注册 + 自愈 | 1.5 h | 覆盖 `action_app_list_data` 要小心 |
| P6 验收 + 文档 | 1.5 h | 含回滚演练 |

**工期风险项**：① 设备拉 `raw.githubusercontent.com` 间歇失败（curl 000 / wget 200）→ 每个下载点都要双栈重试；② 每次改 LuCI 文件都可能触发 500，**已预留约 30% 缓冲**；③ 若你在路线②里对视觉有反复修改要求，P3 会变成迭代式，另行计。

---

## 七、需要你拍板的 3 点

1. **主题走哪条路？** ① 保守不换 / ② 换肤不换骨架（推荐）/ ③ 全局切 Argon
2. **要不要 iStore 商店？** 它和鲲鹏原生商店**并存**（两个入口），不冲突。但会引入 `taskd` 常驻进程（约几 MB）
3. **范围到哪？** 只做「商店 + 首页」（3–4 小时），还是整套（1.5–2 天）

---

## 八、附录：不可碰清单（血泪教训）

- ❌ **绝不装** `luci-compat` / `luci-lua-runtime` 的 git-22 版本（本机 LuCI git-26.253）→ 会导致**全站 502**
- ❌ **绝不加**官方 luci 源（`.../packages/aarch64_cortex-a53/luci`）→ 同因
- ❌ 不用 `istore.linkease.com`（已死）→ 用 `istore.istoreos.com`
- ❌ 不为了「像 iStoreOS」去动 4G/5G 相关目录（`controller/nradio_adv/*`、`/usr/sbin/appcenter`）
- ✅ 崩溃急救：从只读 `/rom` **只补不覆盖**地同步回 `/usr/lib/lua/luci`（30 秒全量恢复）
