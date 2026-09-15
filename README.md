# nros-panel

鲲鹏无限 / NRadio C2000 Max（同系 C2000 U 亦可）OpenWrt 路由器的**一键恢复套件**。

掉卡、overlay 被重置、固件重刷之后，一条命令把 **外网（OpenClash）+ Docker + 1Panel** 全部装回来。

- 适用：OpenWrt 21.02-SNAPSHOT · aarch64（cortex-a53）· kernel 5.4.281
- 全程**幂等**：装好的不重装，中断了重跑同一条命令即可
- 只依赖 busybox sh，不依赖 bash / tput / 数组

---

## 一条命令

SSH 进路由器（默认 `root` / `admin`），执行：

```sh
wget -qO /tmp/kp.sh https://raw.githubusercontent.com/h910056902/nros-panel/main/install.sh && sh /tmp/kp.sh
```

它会**自己判断该干什么**，全程不用干预：

```
    存储没准备好  →  重建 TF 卡分区  →  自动重启  →  开机后自动接着把安装跑完
    存储已就绪    →  直接装三大件
```

重启之后的进度在这里：

```sh
tail -f /tmp/kp-auto.log
```

> 为什么一定要重启一次？因为 Docker 的 overlay2 驱动不能建在 overlayfs 之上，
> `/overlay` 必须是一块独立分区；而 overlay 的切换只在开机早期完成，没法在线换。

### 带参数

参数写在命令前面，会被透传到子脚本：

```sh
# 顺带把机场订阅也配好
SUB_URL='https://你的订阅地址' sh /tmp/kp.sh

# 换 1Panel 端口
PANEL_PORT=10091 sh /tmp/kp.sh

# 卡上确实有要留的数据，仍然强制重建（默认会被安全闸拦下）
FORCE=1 sh /tmp/kp.sh

# 存储明明是好的，也要推倒重来（换分区大小 / 换分区方案时用）
# 自动蕴含 FORCE=1，清空卡 → 重启 → 自动续跑安装；已装的包随 overlay 迁移保留
OVERLAY_SIZE=16G REBUILD=1 sh /tmp/kp.sh

# 做完先别重启，人工核对卡上内容后再手动 reboot（首次上手建议用它）
NO_REBOOT=1 sh /tmp/kp.sh

# 只跑某一个脚本，跳过自动判断
SCRIPT=kp-install.sh sh /tmp/kp.sh
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `SUB_URL` | 空 | 机场订阅地址。留空 = 只装到「内核就绪、等订阅」 |
| `SUB_NAME` | `kp` | 订阅显示名 |
| `SUB_UA` | `clash-verge/v2.4.5` | 订阅请求 UA |
| `CORE_TYPE` | `Meta` | 内核类型（Meta / Dev / Smart / Oix） |
| `PANEL_PORT` | `10090` | 1Panel 端口（10086/87/88 已被固件占用） |
| `PANEL_USER` / `PANEL_PASS` / `PANEL_ENT` | `admin` / 随机 / 随机 | 面板账号、密码、入口路径 |
| `PANEL_DIR` | `/mnt/storage/data` | 数据根目录（放 p2 大分区，不吃 overlay） |
| `SKIP` | 空 | 逗号分隔要跳过的阶段：`oc,docker,panel` |
| `REBUILD` | `0` | `1` = 强制走重建流程（存储正常也重建），自动蕴含 `FORCE=1` |
| `FORCE` | `0` | `1` = 卡上确实有数据也要重建（放行 kp-storage-init 的安全闸） |
| `NO_REBOOT` | `0` | `1` = 做完不自动重启，便于先核对卡上内容再手动 `reboot` |
| `OVERLAY_SIZE` | `16G` | p1（系统可写层）容量，仅在重建时生效 |

---

## 文件分工

| 文件 | 作用 |
|---|---|
| `install.sh` | **入口**。引导器 + 流程编排：判断存储状态、迁移 overlay 内容、预置续跑钩子、决定是否重启 |
| `kp-ui.sh` | **终端界面库**。所有输出格式都在这里，改界面只改它 |
| `kp-install.sh` | **主脚本**。四阶段：预检换源 → OpenClash → Docker → 1Panel |
| `kp-storage-init.sh` | **存储初始化**。TF 卡双分区 + f2fs（官方卷标）+ 写 fstab |
| `kp-ui-preview.sh` | **界面预览**。本地跑一遍所有 UI 元素，不用上设备（开发用） |

改界面、改参数、改流程逻辑，各改各的文件，互不影响。

---

## 主脚本的四个阶段

| 阶段 | 做什么 | 关键点 |
|---|---|---|
| `[1/4]` 预检与换源 | 修 opkg 源、确保 bash、建 `/tmp/lock` | **出厂 6 个源全部指向已下线的 SNAPSHOT**，必须整体换（见下） |
| `[2/4]` OpenClash | 装包 → 拉内核 → 配订阅 → 起服务 | 内核复用 `openclash_core.sh`，3 个 CDN 回退 |
| `[3/4]` Docker | 装依赖 → 写 `daemon.json` → 起服务 | data-root 落 `/mnt/storage/data/docker`，host 网络 |
| `[4/4]` 1Panel | 装面板 → 播种凭据 → 验活 | **必须先写好 `1pctl` 再启动**（数据库由它播种） |

跑完打印汇总，并把手感最要紧的信息写进 `/root/1panel-credentials.txt`（600 权限）。

---

## 几个绕不开的硬事实

这一套脚本的很多"奇怪写法"，都是被下面几条逼出来的。改脚本前请先读这段。

### 1. 出厂 opkg 源整体失效，必须全换

`/etc/opkg/distfeeds.conf` 里 6 个源全部指向
`downloads.openwrt.org/releases/21.02-SNAPSHOT` —— 该快照早已下线，实测
**IPv4 / IPv6 / 固定 IP 直连一律 `000`**（不是 404，是连接都建不起来）。
后果是连 `bash` 都装不上。

脚本的做法：检测到 `21.02-SNAPSHOT` 就把整个文件重写成阿里云 21.02.7 镜像：

```
src/gz openwrt_base     https://mirrors.aliyun.com/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/base
src/gz openwrt_packages https://mirrors.aliyun.com/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/packages
src/gz openwrt_routing  https://mirrors.aliyun.com/openwrt/releases/21.02.7/packages/aarch64_cortex-a53/routing
```

原文件备份在 `/etc/opkg/distfeeds.conf.kp-bak`，想还原直接覆盖回去。

> `core` 与 target 源**故意不保留**：里面是严格对齐内核 5.4.281 的 kmod，
> 而官方压根没有 mt7987 这个 target，留着只会让每次 `opkg update` 卡在超时上。

### 2. kmod 依赖只能 `--force-depends` 跳过

本机内核**没编 veth / br_netfilter**，`kmod-tun`、`iptables` 这类包在 opkg 数据库里
显示「未安装」，但**模块和命令其实都在**（固件自带）。

- **Docker**：走 `host` 网络 + `bridge: none` + `iptables: false`，完全用不到 veth/bridge
- **OpenClash**：`kmod-tun` 的 `tun.ko` 就在 `/lib/modules/5.4.281/` 里，`modprobe tun` 正常

所以 `dockerd` / `docker` / OpenClash ipk 一律加 `--force-depends`，
否则 opkg 会以「依赖不满足」直接拒装。

### 3. 重启会换掉整个 overlay：既要搬内容，也要预置续跑钩子

分区完成后 `/overlay` 会从 NOR 的 2MB 分区换成卡上的 p1。
**当前系统里写的任何文件都会随旧 overlay 一起消失**，而新分区是空的。
这会连带两个后果，都必须处理：

**① 身份与网络配置会回落到 `/rom` 出厂值。**
`/rom/etc/shadow` 里 root 是**空密码**（`root::0:0:99999:7:::`），而 dropbear
不允许空密码登录 —— **重启后 SSH 会直接登不上**，LAN IP、防火墙规则也一起回退。

**② 续跑钩子没地方放。**
当前系统里写的任何文件都会随旧 overlay 消失，钩子必须直接落在新卡上。

`install.sh` 的 `arm_auto()` 一次解决两件事，做法和厂商官方完全一致
（见下一节）：

```
<新卡 p1>/
├── upper/            ← 当前 overlay 的 upper 整个 cp -a 过来（含 /etc/config、
│                        密码、dropbear 主机密钥、crontabs、以及 83 个 whiteout）
├── upper/etc/rc.local ← 再覆盖成带续跑代码的版本
└── work/             ← 一并搬过来
```

开机时由 `/rom` 自带的 `/etc/init.d/done`（`S95done`）执行 `/etc/rc.local`，
把 `install.sh` 再拉下来跑一遍 —— 此时存储已就绪，直接进入安装。
跑完自删，不会重复执行。

> 为什么敢直接 `cp -a`：`/overlay/upper/etc/uci-defaults/` 下那 83 个条目是
> **whiteout 字符设备（0,0）**，作用是屏蔽 `/rom` 里的一次性初始化脚本。
> 已实测 busybox `cp -a` 能完整保留字符设备，所以新 overlay 的行为与当前
> 完全一致，那批脚本不会重跑。漏掉它们的话，`10_migrate-shadow` 这类脚本
> 会重新执行，有动 root 密码的风险。

### 4. "存储是否就绪"不能看 `/mnt/storage/data`

固件的热插拔脚本 `/etc/hotplug.d/block/00-mount` 会在分区刚出现时把它先挂到
`/tmp/storage/<设备名>` 下。之后 `/etc/init.d/fstab`（S40）执行 `block mount`
时，fstools 看到设备**已经被挂载**，就直接跳过这一条 ——
**实测 `block mount` 返回 0，但 `/mnt/storage/data` 始终是空的。**

（根因：热插拔里那句判据用的是 `ID_FS_PARTLABEL`，而 MBR 分区表没有 PARTLABEL。
实测 `blkid -o udev /dev/mmcblk0p2` 只给出 `ID_FS_LABEL=nradio_user_data`。
厂商自己的 `sd.lua` 用的是 `blkid --label`，两处判据不一致，属固件自身缺陷。）

所以本套件做两件事：

1. **就绪判据换成"`/overlay` 是否由这张卡的 p1 承载"**（`install.sh`），
   和厂商 `sd.lua` 里 `action_get_partinfo` 的判定方式一致
2. **自己保证数据分区到位**（`kp-install.sh`）：
   - `ensure_data()`：先摘掉热插拔那处挂载，再挂到 `/mnt/storage/data`
   - `install_data_service()`：生成并启用 `/etc/init.d/kp-storage`（`START=41`，
     排在 fstab 之后），保证**每次开机**都挂好

   > 这条服务是必需的，不是锦上添花：dockerd 启动时若 `/mnt/storage/data` 还没挂上，
   > 它会在 overlay 上自建目录，`overlay2` 驱动失效、退化成 vfs。

**如果续跑时看到「存储未就绪」但卡明明是好的** —— 那是就绪判据或 p2 挂载的问题，
`kp-storage-init.sh` 的安全闸会拦下重复清卡（它检查 `/overlay` 是否已在这张卡上），
不会造成数据损失。

---

## 与厂商官方方案对齐（读固件源码得来）

固件自带了官方实现，位置在 `/usr/lib/lua/luci/controller/nradio_adv/sd.lua`
（LuCI → 系统 → SD 卡 页面）。改本套件前建议先读它，几个关键点：

| 环节 | 官方做法 | 本套件的做法 |
|---|---|---|
| 分区 | `o` `n` `p` `1` → **单分区占满全盘** | 多切一个 p2 给 Docker（官方也认这个形态，见下） |
| 格式化 | `mkfs.f2fs -l nradio_tf_overlay` | 卷标照抄官方值 |
| 第二分区卷标 | `blkid --label nradio_user_data` 是它认可的名字 | p2 就用 `nradio_user_data` |
| 启用 | fstab 里 `target=/overlay` `device=/dev/mmcblk0p1` `ignore_uuid=1` + `enabled=1`（`action_set_overlay`） | 完全一致 |
| 内容迁移 | `cp -a /overlay/upper` + `/overlay/work`（`make_sysupgrade_backup`, `cover=0`） | 完全一致 |
| 可用判据 | 卡上存在 `upper/etc/config` | 迁移后校验这一条，不过就中止 |

另外两个容易忽略的机制：

- **热插拔** `/etc/hotplug.d/block/00-mount`：按卷标把分区挂到 `/tmp/storage/`，
  并给 `mmcblk*` 建 `/tmp/istorage` 软链。它只在 `ID_FS_PARTLABEL` 等于
  `nradio_user_data` 时才改挂到 `/mnt/storage/data`（GPT 分区标签，MBR 下为空），
  所以用 MBR 不会和我们的 fstab 抢挂载点。
- **`/overlay` 所在设备被拔出时会自动重启**（同一脚本的 `remove` 分支）——
  这是厂商的保护行为，属正常现象。
- u-boot 环境变量 `boot_from_sd` 是**另一条完全不同的路径**（把系统镜像整盘 dd
  到卡上用 u-boot 直启，见 `action_creat_sysdisk`），与本套件的 overlay 方案无关，
  不要去动它。

---

## 界面规范

所有输出都走 `kp-ui.sh`，脚本里**一行 `printf` 都不该有**。

| 函数 | 用途 |
|---|---|
| `ui_init <标题> <副标题>` | 脚本头横幅 |
| `ui_meta <键> <值>` | 头部信息行（设备 / 数据 / 时间） |
| `ui_stage <序号> <总数> <标题>` | 阶段头 + 进度条 |
| `ui_stage_end` | 阶段收尾（打印本阶段耗时） |
| `ui_ok` / `ui_info` / `ui_warn` | `✓` / `·` / `!` 三种条目 |
| `ui_fail <什么坏了> [怎么办]` | `✗` + 第二行建议，**并 `exit 1`** |
| `ui_kv <键> <值>` | 汇总行的键值对 |
| `ui_hr` / `ui_hr2` / `ui_gap` | 分隔线 / 收尾线 / 空行 |
| `ui_done` | 收尾块开头 |

改完界面本地预览：

```sh
UI_COLOR=always sh kp-ui-preview.sh
```

三条硬约束（决定了版式为什么长这样）：

1. **只用 busybox sh + printf** —— 路由器没有 `tput`，也不保证有 bash 数组，全部用 `while` 循环实现
2. **一律左对齐，不封右边框** —— 中文占 2 列但 `${#s}` 按字节算，右边框必歪
3. **重定向到文件时自动关色** —— 日志里不会混进 `\033`；`UI_COLOR=always|never` 可强制

---

## 手动分步执行（不想用一键）

```sh
# 1. 存储初始化（会清空整张卡，需重启生效）
wget -qO /tmp/s.sh https://raw.githubusercontent.com/h910056902/nros-panel/main/kp-storage-init.sh && sh /tmp/s.sh
reboot

# 2. 重启后装三大件（界面库必须和主脚本同目录，所以两个都要下载）
cd /tmp
wget -qO kp-ui.sh      https://raw.githubusercontent.com/h910056902/nros-panel/main/kp-ui.sh
wget -qO kp-install.sh https://raw.githubusercontent.com/h910056902/nros-panel/main/kp-install.sh
sh kp-install.sh
```

PC 兜底（设备上不了网时）：

```sh
pscp -scp kp-ui.sh kp-install.sh root@192.168.66.1:/tmp/
```

---

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| `缺少界面库 kp-ui.sh` | 主脚本按 `$0` 找同目录的界面库，只传主脚本会失败。两个一起传 |
| `install.sh` 下载失败，但浏览器能打开 | 设备上 `curl` 直连 `raw.githubusercontent.com` 会失败（返回 000），**同一地址换 `wget` 就能拿到**。脚本已内置「curl/wget 双栈 + 三源回退」，一般无需干预 |
| `数据分区 /mnt/storage/data 未挂载` | 通常已由 `ensure_data()` 自动兜底。仍失败就手动 `umount /tmp/storage/mmcblk0p2 && mount -t f2fs /dev/mmcblk0p2 /mnt/storage/data`；持久化靠 `/etc/init.d/kp-storage`（见硬事实 4） |
| 续跑时报「存储未就绪」但卡是好的 | 就绪判据已改为「`/overlay` 是否在 `/dev/mmcblk0p1`」。若仍出现，说明 `/overlay` 没切过来，检查 `/etc/config/fstab` 里那条 `/overlay` 的 `enabled` 是否为 `1` |
| `dockerd 安装失败` | 看 `opkg update` 是否报源错误；源不对时先检查 `distfeeds.conf.kp-bak` |
| 7890 未监听 | 多半是订阅或内核还没就绪，去 LuCI → OpenClash 完成一次配置 |
| 面板端口未监听 | `logread \| grep 1panel`；端口冲突用 `PANEL_PORT=` 换一个 |
| 卡识别不到 | 断电 30 秒 → 取出卡擦净金手指 → 重插到底（软件层无解：3.3V 是 fixed 稳压器，没软件开关） |

---

## 已知边界

- **Docker 只能 host 网络**：内核没编 veth / br_netfilter，端口映射不可用
- **`/overlay` 建议 ≥ 4G**：OpenClash 内核 46MB，装不进 NOR 的 2MB 分区
- **992MB 内存**：跑 Jellyfin 这类应用前先确认 `/config` 和 `/cache` 都在卡上，别落 overlay
- **删容器别用 `docker system prune -a`**：会误删没有运行容器的镜像
