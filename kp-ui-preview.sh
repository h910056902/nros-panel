#!/bin/sh
# ============================================================================
#  kp-ui-preview.sh —— 界面预览（开发用，不参与安装）
#
#  作用：把所有 UI 元素跑一遍，改完 kp-ui.sh 后立刻能看效果。
#  用法： UI_COLOR=always sh kp-ui-preview.sh
#
#  第一次改界面时，照着这个文件的写法抄即可。
# ============================================================================
set -eu
KP_DIR=${0%/*}; [ "$KP_DIR" = "$0" ] && KP_DIR=.    # 取脚本所在目录，不依赖 dirname
. "$KP_DIR/kp-ui.sh"

# ---------------------------- 头部 ----------------------------
ui_init "鲲鹏路由器 · 一键恢复" "外网 OpenClash  ·  Docker  ·  1Panel"
ui_meta 设备 "C2000 Max · aarch64 · OpenWrt 21.02.7"
ui_meta 数据 "/mnt/storage/data · 可用 25.1G"
ui_meta 时间 "$(date '+%F %T')"
ui_hr

# ---------------------------- 阶段 1：全绿 ----------------------------
ui_stage 1 5 "环境预检与换源"
ui_info "出厂 opkg 源已失效，准备切到阿里云 21.02.7"
ui_ok "packages / routing 已切到镜像源"
ui_ok "bash 就绪 · 数据分区可用 25.1G"
ui_stage_end

# ---------------------------- 阶段 2：带警告 ----------------------------
ui_stage 2 5 "外网 OpenClash"
ui_ok "包已安装 0.47.156"
ui_info "拉取内核 clash_meta（约 46MB）…"
ui_ok "内核 Meta 已就位 /etc/openclash/core/clash_meta"
ui_warn "未提供订阅地址：外网已就绪，等你在 LuCI 里填订阅链接"
ui_ok "服务 running · 代理端口 7890 已监听"
ui_stage_end

# ---------------------------- 阶段 3：带补充说明 ----------------------------
ui_stage 3 5 "Docker"
ui_info "kmod-veth 未装（本机走 host 网络，不受影响）"
ui_ok "daemon.json 已写入 · overlay2 → /mnt/storage/data/docker"
ui_note "已存在的 daemon.json 不会被覆盖，重跑安全"
ui_ok "dockerd 27.3.1 · 存储驱动 overlay2"
ui_stage_end

# ---------------------------- 阶段 4：正常 ----------------------------
ui_stage 4 5 "1Panel"
ui_ok "安装包已解压并通过 SHA256 校验"
ui_ok "面板 HTTP 200 · docker 就绪"
ui_ok "凭据写入 /root/1panel-credentials.txt"
ui_stage_end

# ---------------------------- 收尾 ----------------------------
ui_done
ui_kv 外网 "running · 代理端口 7890 监听中"
ui_kv 面板 "http://192.168.66.1:10090/kp1a2b3c"
ui_kv 账号 "admin / Xy9kL2mQ"
ui_kv 凭据 "/root/1panel-credentials.txt"
ui_hr2

# ---------------------------- 失败长什么样 ----------------------------
# 取消下面两行注释即可预览失败态（会 exit 1）
# ui_err "dockerd 未就绪"
# ui_fail "数据分区 /mnt/storage/data 未挂载" "先跑 kp-storage-init.sh，再 reboot"
