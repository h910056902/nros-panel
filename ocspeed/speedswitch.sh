#!/bin/sh
# OpenClash 自动测速切换 v3.3 — 全量测速 + 分类测速(视频/流媒体/AI) + 备用节点预选 + WebUI
#
# v3.2 新增: 故障切换备用节点
#   - 每 backup_interval 分钟主动探测一批候选节点, 把最快的若干个写入 $DATA/backup.json
#   - failover_check 故障时优先逐个验证这张短名单, 命中即切, 省掉当场串行探测 Top5 的十几秒
#   - 所有状态一律放 $DATA (overlay, 跨每天 02:00 自动重启保留);
#     /tmp 是 tmpfs, 重启即清空, 只放临时中间文件
#
# v3.3 修复 (全部是「功能静默失效」类缺陷):
#   1. [P0] $DATA/running 残留会让备用预选与故障转移双双永久停摆, 且不写任何日志。
#      改为写入时间戳 + 超时自愈, trap 同步清理。
#   2. [P0] 节点属性错位: name/type 各 62 条而 alive 有 245 条(每个节点的 history 数组里
#      也有 alive), 按行号配对整体错位约 26%, 健康的当前节点被记成 a:false 而永久进不了
#      备用池。改为按花括号深度解析 JSON。
#   3. [P0] 决赛(gemini)延迟抖动达 2.3 倍却用它排名 -> 50% 的切换是劣化。
#      改为: 排名一律用初赛(gstatic, 稳定), 决赛只当可用性闸门且失败重试一次。
#   4. [P1] 备用候选池 head -N 取的是订阅书写顺序而非最快 -> 改成按上次延迟升序取。
#   5. [P1] testnode 的 printf 多传一个参数, POSIX printf 复用格式串吐出多余对象,
#      只要有一个站点超时, 整次返回非法 JSON。
#   6. [P1] 历史记录取的是最旧 10 条(head -10) -> 改 tail -10。
# 端口与密钥从 OpenClash 配置动态读取（重置/改密后不会静默失效），原值兜底
_OC_PORT=$(uci -q get openclash.config.cn_port 2>/dev/null)
[ -z "$_OC_PORT" ] && _OC_PORT=9090
_OC_SECRET=$(uci -q get openclash.config.dashboard_password 2>/dev/null)
[ -z "$_OC_SECRET" ] && _OC_SECRET=7LHZ3l74
API=http://127.0.0.1:$_OC_PORT
SECRET=$_OC_SECRET
DIR=/tmp/ocspeed
DATA=/etc/openclash-helper
LOG=/var/log/ocspeed.log
# running 标记的最大存活秒数。一轮全量测速实测约 2 分钟, 给 15 分钟做兜底。
RUNNING_MAX=900

mkdir -p $DIR $DATA

log() { echo "$(date '+%F %T') [$1] $2" >> $LOG; }

# ---- $DATA/running 生命周期 ----
# 背景: running 放在 overlay 上, 被 kill / 掉电后不会消失, 而互斥用的 $DIR/lock 在
# tmpfs 上、重启即清。二者不一致 -> 一次异常退出就会让 backup_select 和 failover_check
# 永远 return 0(静默停摆)。写入时间戳 + 超时自愈即可根治。
run_mark_set()   { date +%s > $DATA/running; }
run_mark_clear() { rm -f $DATA/running 2>/dev/null; }
# 返回 0 = 忙(有实例在跑), 1 = 空闲
run_busy() {
  [ -f $DATA/running ] || return 1
  local ts=$(cat $DATA/running 2>/dev/null)
  case "$ts" in
    ''|*[!0-9]*) run_mark_clear; return 1 ;;
  esac
  local now=$(date +%s)
  if [ $((now - ts)) -gt ${RUNNING_MAX:-900} ]; then
    log lock "清除残留 running 标记 (已存在 $((now - ts))s > ${RUNNING_MAX:-900}s)"
    run_mark_clear
    return 1
  fi
  return 0
}
get() { uci -q get ocspeed.main.$1 2>/dev/null; }
api_get() { curl -s -m 10 -H "Authorization: Bearer $SECRET" "$API$1" 2>/dev/null; }
urlenc() {
  printf '%s' "$1" | hexdump -v -e '1/1 "%02X"' | awk '{
    out = ""
    for (i = 1; i <= length($0); i += 2) {
      h = substr($0, i, 2)
      v = (index("0123456789ABCDEF", substr(h, 1, 1)) - 1) * 16 + index("0123456789ABCDEF", substr(h, 2, 1)) - 1
      if ((v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 45 || v == 46 || v == 95 || v == 126)
        out = out sprintf("%c", v)
      else
        out = out "%" h
    }
    printf "%s", out
  }'
}
set_progress() { # phase msg pct
  printf '{"phase":"%s","msg":"%s","pct":%s}' "$1" "$2" "$3" > $DIR/progress.json 2>/dev/null
}

node_delay() { # name url timeout -> ms or empty
  local n="$1" u="$2" t="$3" r d
  r=$(curl -s -m $((t/1000+3)) -H "Authorization: Bearer $SECRET" "$API/proxies/$(urlenc "$n")/delay?url=$(urlenc "$u")&timeout=$t" 2>/dev/null)
  d=$(echo "$r" | grep -o '"delay":[0-9]*' | head -1 | cut -d: -f2)
  [ -n "$d" ] && echo "$d"
}

# 多探测点回退: 主 test_url 拿不到延迟时, 依次换 testsites 里的备用站点重试。
# 原逻辑只用单一探测点(gstatic generate_204), 该 URL 一旦被干扰或短暂不可达,
# 全部节点都会返回空 -> 被统一判定成「所有节点都挂了」, 而实际上是探测点本身的问题。
# max_alt 限制回退次数, 避免把 11 个站点全试一遍拖垮每分钟一次的 failover。
probe_delay_multi() { # name timeout [max_alt]
  local n="$1" t="$2" maxalt="${3:-3}" d alt i=0
  local tu=$(get test_url); [ -z "$tu" ] && tu='https://www.gstatic.com/generate_204'
  d=$(node_delay "$n" "$tu" "$t")
  if [ -n "$d" ]; then echo "$d"; return 0; fi
  for alt in $(get testsites | tr '|' ' '); do
    [ -z "$alt" ] && continue
    [ "$alt" = "$tu" ] && continue
    [ "$i" -ge "$maxalt" ] && break
    i=$((i+1))
    d=$(node_delay "$n" "$alt" "$t")
    if [ -n "$d" ]; then
      log failover "探测点回退: $n 改经 $alt 得到 ${d}ms (主探测点 $tu 无响应)"
      echo "$d"
      return 0
    fi
  done
  return 1
}

# 按花括号深度解析 /proxies: 只在 depth==3(某个 proxy 对象内部) 取 name/type/alive。
# 不能用「三次 grep -o 再按行号配对」——每个节点的 history 数组里也有 alive 字段,
# 实测 name/type 各 62 条而 alive 有 245 条, 按下标配对会整体错位约 26%。
# 决定性对照: 台湾01 的 alive 原文是 false, 旧方法把它记成 true;
# 而当前节点(139ms, 全场最快)真实 alive=true 却被记成 false, 于是永远当不了备用节点。
json_nodes_tsv() {
  awk '
  { s = s $0 }
  END {
    n = length(s); depth = 0; instr = 0; esc = 0; mode = 0
    key = ""; val = ""; nm = ""; tp = ""; al = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (instr) {
        if (esc) { esc = 0; if (mode == 1) key = key c; else if (mode == 2) val = val c; continue }
        if (c == "\\") { esc = 1; if (mode == 1) key = key c; else if (mode == 2) val = val c; continue }
        if (c == "\"") {
          instr = 0
          if (mode == 1) { mode = 3 }
          else if (mode == 2) {
            mode = 0
            if (depth == 3) {
              if (key == "name") nm = val
              else if (key == "type") tp = val
            }
          }
          continue
        }
        if (mode == 1) key = key c
        else if (mode == 2) val = val c
        continue
      }
      # mode==4 = 「刚读完冒号, 接下来是值」。此时遇到引号必须切成 mode=2(读值字符串)
      # 且保留 key; 若一律重置成 mode=1, 值会被当成键来读, name/type 永远取不到。
      if (c == "\"") { instr = 1; if (mode == 4) { mode = 2; val = "" } else { mode = 1; key = ""; val = "" } continue }
      if (c == ":") { if (mode == 3) { mode = 4; val = "" } continue }
      if (c == "{") { depth++; mode = 0; continue }
      if (c == "}") {
        if (mode == 4 && depth == 3 && key == "alive") al = val
        if (depth == 3 && nm != "") {
          printf "%s\t%s\t%s\n", nm, al, tp
          nm = ""; tp = ""; al = ""
        }
        depth--; mode = 0; continue
      }
      if (c == ",") {
        if (mode == 4 && depth == 3 && key == "alive") al = val
        mode = 0; val = ""; continue
      }
      if (mode == 4) val = val c
    }
  }' "$1"
}

collect_all_nodes() {
  api_get /proxies > $DIR/proxies.json
  json_nodes_tsv $DIR/proxies.json > $DIR/nt.tsv
  # 兜底: 万一深度解析零输出(上游结构变了), 退回旧的 grep 配对,
  # 宁可拿到错位的数据, 也不能一个节点都收集不到导致整轮空跑。
  if [ ! -s $DIR/nt.tsv ]; then
    log collect "深度解析无输出, 退回 grep 配对(结果可能错位)"
    grep -o '"name":"[^"]*"' $DIR/proxies.json | sed 's/"name":"//;s/"$//' > $DIR/names.txt
    grep -o '"alive":[a-z]*' $DIR/proxies.json | sed 's/"alive"://' > $DIR/alive.txt
    grep -o '"type":"[^"]*"' $DIR/proxies.json | sed 's/"type":"//;s/"$//' > $DIR/types.txt
    awk 'FILENAME==ARGV[1]{n[FNR]=$0;next} FILENAME==ARGV[2]{a[FNR]=$0;next} {print n[FNR]"\t"a[FNR]"\t"$0}' $DIR/names.txt $DIR/alive.txt $DIR/types.txt > $DIR/nt.tsv
  fi
  # names.txt 后面还要用来判断策略组是否存在, 从解析结果里保持一致地生成
  cut -f1 $DIR/nt.tsv > $DIR/names.txt
  : > $DIR/allnodes.txt
  TAB=$(printf '\t')
  while IFS="$TAB" read -r name alive type; do
    case "$type" in
      Vless|Vmess|Trojan|Hysteria|Hysteria2|TUIC|WireGuard|Snell|Shadowsocks|SS|SSR|Socks5|Http) ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\n' "$name" "$type" "$alive" >> $DIR/allnodes.txt
  done < $DIR/nt.tsv
}

is_fake() {
  local name="$1" kw
  local exc=$(get exclude)
  for kw in $exc; do
    [ -z "$kw" ] && continue
    case "$name" in *"$kw"*) return 0 ;; esac
  done
  return 1
}

build_candidates() {
  : > $DIR/candidates.txt
  local TAB=$(printf '\t')
  while IFS="$TAB" read -r name type alive; do
    is_fake "$name" && continue
    echo "$name" >> $DIR/candidates.txt
  done < $DIR/allnodes.txt
  # 持久化一份到 overlay: /tmp 是 tmpfs, 每天 02:00 自动重启后候选池会被清空,
  # 故障转移的兜底路径原本会因为这个拿不到任何节点
  cp $DIR/candidates.txt $DATA/candidates.txt 2>/dev/null
}

speedtest() { # url timeout outfile [total]
  local u="$1" t="$2" out="$3" total="$4" i=0 d cnt
  [ -z "$total" ] && total=0
  : > $out
  : > $DIR/par_$$.out
  while read -r name; do
    [ -z "$name" ] && continue
    ( d=$(node_delay "$name" "$u" "$t"); [ -n "$d" ] && printf '%s\t%s\n' "$d" "$name" >> $DIR/par_$$.out ) &
    i=$((i+1))
    if [ $i -ge 4 ]; then
      wait; i=0
      if [ "$total" -gt 0 ] 2>/dev/null; then
        cnt=$(wc -l < $DIR/par_$$.out)
        set_progress "testing" "全量测速中 ($cnt/$total)" $((40 + cnt*35/total))
      fi
    fi
  done < $DIR/allnodes.list
  wait
  cat $DIR/par_$$.out >> $out 2>/dev/null
  rm -f $DIR/par_$$.out
  sort -n $out > $out.tmp 2>/dev/null && mv $out.tmp $out
}

# 注意: trap 必须同时清 running —— 只清 lock 的话, lock 在 tmpfs 上重启即没,
# 而 running 在 overlay 上会一直留着, 下一次 backup_select / failover_check 就永远跳过。
lock_acquire() {
  mkdir $DIR/lock 2>/dev/null || { log lock "已有实例运行, 跳过"; exit 0; }
  trap 'rmdir $DIR/lock 2>/dev/null; rm -f $DATA/running 2>/dev/null' EXIT INT TERM
}

build_nodes_json() {
  local n_all=$(wc -l < $DIR/allnodes.txt)
  local TAB=$(printf '\t')
  printf '{"ts":%s,"total":%s,"nodes":[' "$(date +%s)" "$n_all" > $DATA/nodes.json
  local first=1
  while IFS="$TAB" read -r name type alive; do
    local d s
    d=$(awk -F '\t' -v n="$name" '$2==n{print $1; exit}' $DIR/allresults.txt 2>/dev/null)
    if is_fake "$name"; then s="fake"
    elif [ -n "$d" ]; then s="ok"
    else s="dead"; fi
    [ $first -eq 0 ] && printf ',' >> $DATA/nodes.json
    first=0
    if [ -n "$d" ]; then
      printf '{"n":"%s","t":"%s","a":%s,"d":%s,"s":"%s"}' "$name" "$type" "$alive" "$d" "$s" >> $DATA/nodes.json
    else
      printf '{"n":"%s","t":"%s","a":%s,"d":null,"s":"%s"}' "$name" "$type" "$alive" "$s" >> $DATA/nodes.json
    fi
  done < $DIR/allnodes.txt
  printf ']}' >> $DATA/nodes.json
}

build_sites_json() {
  local sites=$(get sites)
  [ -z "$sites" ] && sites='https://www.youtube.com|https://www.netflix.com|https://www.disneyplus.com|https://gemini.google.com|https://chatgpt.com|https://claude.ai'
  printf '%s' "$sites" | tr '|' '\n' | grep . > $DIR/sites.list
  head -5 $DIR/stage1.txt | cut -f2 > $DIR/top5nodes.txt
  local idx=0
  while read -r s; do
    idx=$((idx+1))
    : > $DIR/site_$idx.txt
    while read -r name; do
      ( d=$(node_delay "$name" "$s" 5000); [ -n "$d" ] && printf '%s\t%s\n' "$d" "$name" >> $DIR/site_$idx.txt ) &
    done < $DIR/top5nodes.txt
    wait
  done < $DIR/sites.list
  printf '{"ts":%s,"sites":[' "$(date +%s)" > $DATA/sites.json
  local i=0
  while read -r s; do
    local label=$(echo "$s" | sed 's|https://||; s|/.*||; s|^www\.||')
    [ $i -gt 0 ] && printf ',' >> $DATA/sites.json
    printf '"%s"' "$label" >> $DATA/sites.json
    i=$((i+1))
  done < $DIR/sites.list
  printf '],"data":[' >> $DATA/sites.json
  local j=0
  while read -r name; do
    [ $j -gt 0 ] && printf ',' >> $DATA/sites.json
    printf '{"n":"%s","d":[' "$name" >> $DATA/sites.json
    local k=0
    while read -r s; do
      k=$((k+1))
      [ $k -gt 1 ] && printf ',' >> $DATA/sites.json
      d=$(awk -F '\t' -v n="$name" '$2==n{print $1; exit}' $DIR/site_$k.txt 2>/dev/null)
      if [ -n "$d" ]; then printf '%s' "$d" >> $DATA/sites.json; else printf 'null' >> $DATA/sites.json; fi
    done < $DIR/sites.list
    printf ']}' >> $DATA/sites.json
    j=$((j+1))
  done < $DIR/top5nodes.txt
  printf ']}' >> $DATA/sites.json
}

speedtest_full() {
  local do_switch_allowed="$1"
  lock_acquire
  run_mark_set
  set_progress "start" "开始测速" 3
  v=$(api_get /version)
  if ! echo "$v" | grep -q version; then
    run_mark_clear
    log run "OpenClash API 不可达, 中止"
    exit 1
  fi

  group=$(get group);       [ -z "$group" ] && group='宝贝云'
  test_url=$(get test_url); [ -z "$test_url" ] && test_url='https://www.gstatic.com/generate_204'
  gemini_url=$(get gemini_url); [ -z "$gemini_url" ] && gemini_url='https://gemini.google.com'
  timeout=$(get timeout);   [ -z "$timeout" ] && timeout=4000
  threshold=$(get threshold); [ -z "$threshold" ] && threshold=50

  collect_all_nodes
  set_progress "collect" "节点收集完成" 15
  grep -qx "$group" $DIR/names.txt || { run_mark_clear; log run "策略组 $group 不存在, 中止"; exit 1; }
  n_all=$(wc -l < $DIR/allnodes.txt)
  build_candidates
  n_cand=$(wc -l < $DIR/candidates.txt)
  log run "全量测速: $n_all 节点 (真节点 $n_cand, 目标组=$group)"

  cut -f1 $DIR/allnodes.txt > $DIR/allnodes.list
  set_progress "testing" "全量测速中 ($n_all 节点)" 40
  speedtest "$test_url" "$timeout" $DIR/allresults.txt $n_all
  if [ ! -s $DIR/allresults.txt ]; then
    run_mark_clear
    log run "全部节点测速超时"
    exit 0
  fi
  build_nodes_json
  set_progress "nodes" "节点状态已生成" 60

  now=$(api_get "/proxies/$group" | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4)

  : > $DIR/stage1.txt
  local TAB=$(printf '\t')
  while IFS="$TAB" read -r name type alive; do
    is_fake "$name" && continue
    d=$(awk -F '\t' -v n="$name" '$2==n{print $1; exit}' $DIR/allresults.txt 2>/dev/null)
    [ -n "$d" ] && printf '%s\t%s\n' "$d" "$name" >> $DIR/stage1.txt
  done < $DIR/allnodes.txt
  sort -n $DIR/stage1.txt > $DIR/stage1.tmp 2>/dev/null && mv $DIR/stage1.tmp $DIR/stage1.txt

  # ---- 决赛: 只当可用性闸门, 不再参与排名 ----
  # 排名一律用初赛(gstatic generate_204): 它极其稳定, 同节点相邻两轮实测 151/152ms。
  # 决赛目标是 gemini.google.com, 国内不可达、必须走代理, 抖动可达 2.3 倍
  # (实测同节点两轮 908ms / 2108ms), 而切换阈值只有 50ms —— 拿它排名等于掷骰子。
  # 后果: 历史 8 次切换里 4 次是劣化, 152ms 的节点被 656ms 的顶掉, 半小时后又切回来。
  head -5 $DIR/stage1.txt > $DIR/top5d.txt            # d \t name, 已按初赛升序
  cut -f2 $DIR/top5d.txt > $DIR/top5.txt
  : > $DIR/stage2.txt
  while read -r name; do
    [ -z "$name" ] && continue
    d=$(node_delay "$name" "$gemini_url" 6000)
    # 失败重试一次: 抖动是常态, 重试能滤掉大部分假阴性, 且只有失败时才多花时间
    [ -z "$d" ] && d=$(node_delay "$name" "$gemini_url" 6000)
    [ -n "$d" ] && printf '%s\t%s\n' "$d" "$name" >> $DIR/stage2.txt
  done < $DIR/top5.txt
  sort -n $DIR/stage2.txt > $DIR/stage2.tmp 2>/dev/null && mv $DIR/stage2.tmp $DIR/stage2.txt
  cut -f2 $DIR/stage2.txt > $DIR/stage2_names.txt 2>/dev/null

  # 按初赛顺序过闸门, 第一个通过决赛的就是目标
  : > $DIR/best_order.txt
  while IFS="$TAB" read -r d nm; do
    [ -z "$nm" ] && continue
    grep -qx "$nm" $DIR/stage2_names.txt || continue
    printf '%s\t%s\n' "$d" "$nm" >> $DIR/best_order.txt
  done < $DIR/top5d.txt

  # 闸门全灭时退回初赛第一名, 保证永远有目标
  best=$(head -1 $DIR/best_order.txt 2>/dev/null | cut -f2)
  bestd=$(head -1 $DIR/best_order.txt 2>/dev/null | cut -f1)
  if [ -z "$best" ]; then
    log run "决赛全部未通过, 按初赛排名兜底"
    best=$(head -1 $DIR/top5d.txt | cut -f2)
    bestd=$(head -1 $DIR/top5d.txt | cut -f1)
  fi
  bestdf=$(awk -F '\t' -v n="$best" '$2==n{print $1; exit}' $DIR/stage2.txt 2>/dev/null)
  bestfin="未通过"
  [ -n "$bestdf" ] && bestfin="${bestdf} ms"

  switched=0
  if [ "$do_switch_allowed" = "1" ] && [ -n "$best" ]; then
    if [ "$now" = "$best" ]; then
      log run "无需切换: $now 已是最快 (初赛 $bestd ms, 决赛 $bestfin)"
    else
      dosw=1
      # 比较依据同样换成初赛延迟。原先比的是决赛延迟, 当前节点一旦决赛探测超时
      # (curd 为空) 就会被无脑换掉, 哪怕它初赛是全场最快 —— 这正是劣化切换的主因。
      curd1=$(awk -F '\t' -v n="$now" '$2==n{print $1; exit}' $DIR/stage1.txt 2>/dev/null)
      curdf=$(awk -F '\t' -v n="$now" '$2==n{print $1; exit}' $DIR/stage2.txt 2>/dev/null)
      curdfin="未通过"
      [ -n "$curdf" ] && curdfin="${curdf} ms"
      if [ -n "$curd1" ]; then
        if [ "$bestd" -ge $((curd1 - threshold)) ]; then
          dosw=0
          log run "保持当前: $now 初赛${curd1}ms/决赛${curdfin} vs 最快 $best 初赛${bestd}ms/决赛${bestfin} (阈值${threshold}ms)"
        fi
      else
        log run "当前 $now 初赛无结果(失效或被排除), 将切到 $best (初赛${bestd}ms)"
      fi
      if [ $dosw -eq 1 ]; then
        curl -s -m 8 -X PUT -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "{\"name\":\"$best\"}" "$API/proxies/$group" >/dev/null 2>&1
        switched=1
        # 日志补齐 curd1, 事后才分得清「真的更快」还是「当前节点决赛没测出来」
        log run "已切换 $group: $now (初赛${curd1:-无}) -> $best (初赛${bestd}ms, 决赛${bestfin})"
      fi
    fi
  fi

  # 分类测速 (视频/流媒体/AI)
  set_progress "sites" "分类测速(视频/流媒体/AI)" 78
  build_sites_json

  set_progress "switch" "计算最快节点并切换" 90

  # 状态 JSON: top 按初赛排名输出, d=初赛延迟(排名依据), f=决赛延迟(null=未过闸门)
  printf '{"ts":%s,"group":"%s","now":"%s","switched":%s,"candidates":%s,"top":[' "$(date +%s)" "$group" "$best" "$switched" "$n_cand" > $DATA/status.json
  i=0
  while IFS="$TAB" read -r d nm; do
    [ -z "$nm" ] && continue
    fd=$(awk -F '\t' -v n="$nm" '$2==n{print $1; exit}' $DIR/stage2.txt 2>/dev/null)
    [ $i -gt 0 ] && printf ',' >> $DATA/status.json
    if [ -n "$fd" ]; then
      printf '{"d":%s,"f":%s,"n":"%s"}' "$d" "$fd" "$nm" >> $DATA/status.json
    else
      printf '{"d":%s,"f":null,"n":"%s"}' "$d" "$nm" >> $DATA/status.json
    fi
    i=$((i+1))
  done < $DIR/top5d.txt
  printf ']}' >> $DATA/status.json

  top5line=$(cut -f2 $DIR/top5d.txt | tr '\n' ' ')
  okn=$(grep -o '"s":"ok"' $DATA/nodes.json | wc -l)
  deadn=$(grep -o '"s":"dead"' $DATA/nodes.json | wc -l)
  faken=$(grep -o '"s":"fake"' $DATA/nodes.json | wc -l)
  echo "$(date '+%F %T') switch=$switched group=$group best=$best $bestd ms 可用=$okn 失效=$deadn 假节点=$faken 决赛=${bestdf:-未通过}ms top: $top5line" >> $DATA/history.log
  tail -50 $DATA/history.log > $DATA/history.tmp 2>/dev/null && mv $DATA/history.tmp $DATA/history.log

  sz=$(wc -c < $LOG 2>/dev/null || echo 0)
  [ "$sz" -gt 204800 ] && mv $LOG $LOG.old
  set_progress "done" "测速完成" 100
  run_mark_clear
  # 记录本轮结束时刻: failover 据此避开测速后的探测拥塞尾巴(见其「静默期」判断)
  date +%s > $DATA/last_run 2>/dev/null
  return 0
}

# ---------- 备用节点预选 ----------
# 把 $DIR/bak_top.txt (延迟<TAB>节点名, 已排序) 写成 $DATA/backup.json
write_backup_json() { # group now probed_count
  local group="$1" now="$2" probed="$3"
  local TAB=$(printf '\t')
  local j=0
  printf '{"ts":%s,"group":"%s","now":"%s","probed":%s,"list":[' "$(date +%s)" "$group" "$now" "$probed" > $DATA/backup.json
  while IFS="$TAB" read -r d nm; do
    [ -z "$nm" ] && continue
    [ $j -gt 0 ] && printf ',' >> $DATA/backup.json
    printf '{"n":"%s","d":%s}' "$nm" "$d" >> $DATA/backup.json
    j=$((j+1))
  done < $DIR/bak_top.txt
  printf ']}' >> $DATA/backup.json
  date +%s > $DATA/last_backup
}

backup_do() {
  v=$(api_get /version)
  if ! echo "$v" | grep -q version; then
    log backup "OpenClash API 不可达, 跳过"
    return 1
  fi

  local group=$(get group); [ -z "$group" ] && group='宝贝云'
  local tu=$(get test_url); [ -z "$tu" ] && tu='https://www.gstatic.com/generate_204'
  local thr=$(get failover_threshold); [ -z "$thr" ] && thr=3000
  local probe=$(get backup_probe); [ -z "$probe" ] && probe=8
  local keep=$(get backup_keep); [ -z "$keep" ] && keep=3
  local to=$(get timeout); [ -z "$to" ] && to=4000

  local cur=$(api_get "/proxies/$group" | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4)
  local TAB=$(printf '\t')
  # cur 为空时 grep -vF "" 会把所有行都过滤掉, 用一个不可能出现的哨兵兜住
  local curf="$cur"
  [ -z "$curf" ] && curf='__none__'

  # 候选池: 优先持久化的 nodes.json (带上次延迟, 跨重启可用), 退回持久化的 candidates.txt
  # 必须按上次延迟升序再取前 probe 个 —— 原先直接 head -probe 取的是 nodes.json 的书写
  # 顺序(也就是订阅顺序), 实测会漏掉比入选者更快的中转节点, 「预选最快节点」名不副实。
  : > $DIR/bak_cand.txt
  tr '{' '\n' < $DATA/nodes.json 2>/dev/null \
    | grep '"d":[0-9]*,"s":"ok"' \
    | sed 's#.*"n":"\([^"]*\)".*"d":\([0-9]*\).*#\2'"$TAB"'\1#' \
    | sort -n | grep -vF "$curf" | cut -f2 | head -$probe > $DIR/bak_cand.txt
  [ -s $DIR/bak_cand.txt ] || {
    grep -vF "$curf" $DATA/candidates.txt 2>/dev/null | head -$probe > $DIR/bak_cand.txt
  }
  [ -s $DIR/bak_cand.txt ] || { log backup "无候选节点, 跳过"; return 1; }

  local n_total=$(wc -l < $DIR/bak_cand.txt)
  : > $DIR/bak_res.txt
  : > $DIR/bak_par.out
  local i=0
  while read -r name; do
    [ -z "$name" ] && continue
    # 不再按 failover_threshold 预筛: 阈值内的节点常常只有一两个,
    # 一旦它们也超时就没有退路。备用池改为「有响应即收录, 按延迟升序保留」,
    # 真断网时一个 3 秒的节点也强过没有节点。
    ( d=$(node_delay "$name" "$tu" "$to")
      [ -n "$d" ] && printf '%s\t%s\n' "$d" "$name" >> $DIR/bak_par.out ) &
    i=$((i+1))
    [ $i -ge 4 ] && { wait; i=0; }
  done < $DIR/bak_cand.txt
  wait
  cat $DIR/bak_par.out >> $DIR/bak_res.txt 2>/dev/null
  rm -f $DIR/bak_par.out
  sort -n $DIR/bak_res.txt > $DIR/bak_res.tmp 2>/dev/null && mv $DIR/bak_res.tmp $DIR/bak_res.txt

  head -$keep $DIR/bak_res.txt > $DIR/bak_top.txt
  local n_keep=$(wc -l < $DIR/bak_top.txt)
  write_backup_json "$group" "$cur" "$n_total"

  if [ "$n_keep" -gt 0 ]; then
    log backup "已预选 $n_keep 个备用节点 (探测 $n_total): $(cut -f2 $DIR/bak_top.txt | tr '\n' ' ')| 当前 $cur"
  else
    log backup "候选节点全部超时 (探测 $n_total), 未选出备用节点"
  fi
  return 0
}

# cron 每分钟唤起, 这里按 backup_interval 自检时间戳决定是否真跑。
# 不用 */90: cron 分钟字段最大 59, 写不出 90 分钟周期。
# 自检还有个好处 —— 设备每天 02:00 自动重启, 固定时间点会被跳过, 自检不会。
backup_select() {
  [ "$(get backup_enable)" = "0" ] && return 0
  # 残留自愈必须排在间隔检查【之前】: 否则间隔没到就提前 return,
  # 陈旧标记会一直挂着, 最长要等一个完整间隔(90 分钟)才被清掉。
  # 与主测速互斥: 两边都用 mkdir 锁 + $DATA/running 标记(带超时自愈)
  run_busy && return 0
  local iv=$(get backup_interval); [ -z "$iv" ] && iv=90
  local now=$(date +%s)
  local last=$(cat $DATA/last_backup 2>/dev/null || echo 0)
  [ $((now - last)) -lt $((iv * 60)) ] && return 0
  mkdir $DIR/lock 2>/dev/null || return 0
  trap 'rmdir $DIR/lock 2>/dev/null; rm -f $DATA/running 2>/dev/null' EXIT INT TERM
  run_mark_set
  backup_do
  local rc=$?
  run_mark_clear
  return $rc
}

failover_check() { # 断线自动故障转移
  run_busy && return 0
  local now=$(date +%s)
  # 冷却时间戳放 overlay: 原先在 /tmp, 每天 02:00 重启后被清零, 冷却形同虚设
  local last=$(cat $DATA/last_failover 2>/dev/null || cat $DIR/last_failover 2>/dev/null || echo 0)
  local cd=$(get failover_cooldown); [ -z "$cd" ] && cd=120
  [ $((now - last)) -lt $cd ] && return 0
  v=$(api_get /version)
  echo "$v" | grep -q version || { log failover "API不可达, 跳过"; return 0; }
  local group=$(get group); [ -z "$group" ] && group='宝贝云'
  local cur=$(api_get "/proxies/$group" | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -z "$cur" ] && return 0
  case "$cur" in GLOBAL|DIRECT|REJECT|REJECT-DROP|COMPATIBLE|PASS|PASS-RULE|自动选择|延迟最低|宝贝云) return 0 ;; esac
  # 静默期: 一轮 44 节点全量测速结束后, mihomo 的延迟探测通道会留下十几秒的
  # 拥塞尾巴, 此时连刚测过、延迟正常的节点都会返回超时。等它冷却再检测,
  # 否则每轮测速后必然紧跟一次「全节点超时」的伪故障转移。
  # 对照日志可见: 20:09:46 测速 -> 20:11:01 全超时, 20:11:21 测速 -> 20:14:20 全超时。
  local lr=$(cat $DATA/last_run 2>/dev/null || echo 0)
  local quiet=$(get failover_quiet); [ -z "$quiet" ] && quiet=90
  if [ "$lr" -gt 0 ] && [ $((now - lr)) -lt $quiet ]; then
    log failover "全量测速刚结束 $((now-lr))s (静默期 ${quiet}s), 跳过本轮检测"
    return 0
  fi
  local thr=$(get failover_threshold); [ -z "$thr" ] && thr=3000
  local tu=$(get test_url); [ -z "$tu" ] && tu='https://www.gstatic.com/generate_204'
  local TAB=$(printf '\t')
  local d=$(probe_delay_multi "$cur" 5000)
  if [ -z "$d" ] || [ "$d" -gt "$thr" ]; then
    # 抖动过滤: 首探失败不立刻判故障, 隔 3 秒复测一次。
    # 单次超时常常只是瞬时拥塞(测速尾巴、上游抖动), 一次就切换既没必要,
    # 还容易从 270ms 的好节点切到 800ms 的差节点。
    sleep 3
    local d2=$(probe_delay_multi "$cur" 5000)
    if [ -n "$d2" ] && [ "$d2" -le "$thr" ]; then
      log failover "瞬时抖动已恢复: $cur 首探${d:-超时}ms -> 复测 ${d2}ms"
      return 0
    fi
    d="$d2"
  fi
  if [ -n "$d" ] && [ "$d" -le "$thr" ]; then
    log failover "正常: $cur $d ms"
    return 0
  fi
  log failover "异常: $cur ${d:-超时}ms (阈值$thr ms, 已二次复测), 开始故障转移"

  local best="" bestd=0 bsrc=""

  # 优先用预先选好的备用节点短名单, 逐个验证, 命中即切。
  # 每个只需一次探测 (实测约 2.3s), 比当场串行探测 Top5 的十几秒快一个量级。
  if [ "$(get backup_enable)" != "0" ] && [ -f $DATA/backup.json ]; then
    local biv=$(get backup_interval); [ -z "$biv" ] && biv=90
    local bts=$(grep -o '"ts":[0-9]*' $DATA/backup.json 2>/dev/null | head -1 | cut -d: -f2)
    local bage=$((now - ${bts:-0}))
    # 名单最多接受 3 倍间隔的陈旧度; 超期说明预选已停摆, 数据不可信, 退回实时探测
    if [ -n "$bts" ] && [ "$bage" -le $((biv * 60 * 3)) ]; then
      grep -o '"n":"[^"]*","d":[0-9]*' $DATA/backup.json 2>/dev/null \
        | sed 's#"n":"##; s#","d".*##' > $DIR/bak_list.txt
      # 不再「命中即 break、超阈值即丢弃」: 先把全部备用节点探一遍记下延迟,
      # 阈值内取最快的; 若全部超阈值但仍有响应, 降级取最快的 ——
      # 原逻辑是超阈值就丢、全丢光则放弃切换,
      # 于是断网时明明有慢节点可用却只能干等下一个冷却周期。
      : > $DIR/bak_probe.txt
      while read -r nm; do
        [ -z "$nm" ] && continue
        [ "$nm" = "$cur" ] && continue
        local vd=$(probe_delay_multi "$nm" 5000)
        if [ -n "$vd" ]; then
          printf '%s\t%s\n' "$vd" "$nm" >> $DIR/bak_probe.txt
          log failover "备用节点探测: $nm ${vd}ms"
        else
          log failover "备用节点不可用: $nm 超时ms"
        fi
      done < $DIR/bak_list.txt
      if [ -s $DIR/bak_probe.txt ]; then
        local hit=$(sort -n $DIR/bak_probe.txt | awk -F'\t' -v t="$thr" '$1<=t {print; exit}')
        if [ -n "$hit" ]; then
          bestd=$(echo "$hit" | cut -f1); best=$(echo "$hit" | cut -f2); bsrc="备用名单"
        else
          local dg=$(sort -n $DIR/bak_probe.txt | head -1)
          bestd=$(echo "$dg" | cut -f1); best=$(echo "$dg" | cut -f2); bsrc="备用名单(降级)"
          log failover "阈值${thr}ms内无节点, 降级选用最快: $best ${bestd}ms"
        fi
      fi
    else
      log failover "备用名单已过期 (${bage}s), 改用实时探测"
    fi
  fi

  # 备用名单没命中, 退回原有逻辑: 从上次全量结果里取 Top5 当场串行探测
  if [ -z "$best" ]; then
    tr '{' '\n' < $DATA/nodes.json 2>/dev/null \
      | grep '"d":[0-9]*,"s":"ok"' \
      | sed 's#.*"n":"\([^"]*\)".*"d":\([0-9]*\).*#\2'"$TAB"'\1#' \
      | sort -n | grep -vF "$cur" | cut -f2 | head -5 > $DIR/failover_list.txt
    [ -s $DIR/failover_list.txt ] || {
      cp $DATA/candidates.txt $DIR/failover_list.txt 2>/dev/null
      [ -s $DIR/failover_list.txt ] || cp $DIR/candidates.txt $DIR/failover_list.txt 2>/dev/null
      grep -vF "$cur" $DIR/failover_list.txt > $DIR/failover_list.tmp 2>/dev/null && mv $DIR/failover_list.tmp $DIR/failover_list.txt
    }
    while read -r name; do
      [ -z "$name" ] && continue
      local dd=$(probe_delay_multi "$name" 5000)
      if [ -n "$dd" ]; then
        if [ -z "$best" ] || [ "$dd" -lt "$bestd" ]; then best="$name"; bestd=$dd; bsrc="实时探测"; fi
      fi
    done < $DIR/failover_list.txt
  fi

  if [ -n "$best" ]; then
    curl -s -m 8 -X PUT -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "{\"name\":\"$best\"}" "$API/proxies/$group" >/dev/null 2>&1
    date +%s > $DATA/last_failover
    # 备用名单已被消耗 (切换目标成了新的当前节点), 下一分钟立刻重新预选
    rm -f $DATA/last_backup 2>/dev/null
    log failover "已故障转移($bsrc): $cur -> $best ($bestd ms)"
  else
    # 切换失败只压短冷却: 原逻辑在这里同样写满 failover_cooldown(默认120s),
    # 结果是最需要重试的时刻反而等待最久。失败后 30 秒即重试。
    local short=$cd; [ "$short" -gt 30 ] && short=30
    if ! date -d "@$(( now - (cd - short) ))" +%s > $DATA/last_failover 2>/dev/null; then
      date +%s > $DATA/last_failover
    fi
    log failover "无可用备用节点, 保持 $cur (${short}s 后重试)"
    log failover "诊断: 主节点与全部备用节点同时超时, 更像整体链路拥塞而非单节点故障, 此时切换无意义"
  fi
}

cron_apply() {
  local iv
  iv=$(get interval); [ -z "$iv" ] && iv=30
  sed -i '/ocspeed-auto/d; /ocspeed-failover/d; /ocspeed-backup/d; /speedswitch.sh run/d; /speedswitch.sh failover/d; /speedswitch.sh backup/d' /etc/crontabs/root 2>/dev/null
  if [ "$(get enabled)" = "1" ]; then
    echo "#ocspeed-auto" >> /etc/crontabs/root
    echo "*/$iv * * * * /usr/libexec/openclash-helper/speedswitch.sh run >>/var/log/ocspeed.log 2>&1" >> /etc/crontabs/root
  fi
  if [ "$(get failover_enable)" = "1" ]; then
    echo "#ocspeed-failover" >> /etc/crontabs/root
    echo "* * * * * /usr/libexec/openclash-helper/speedswitch.sh failover >>/var/log/ocspeed.log 2>&1" >> /etc/crontabs/root
  fi
  # 备用节点预选: cron 每分钟唤起, 由脚本自检时间戳决定是否真跑
  if [ "$(get backup_enable)" != "0" ]; then
    echo "#ocspeed-backup" >> /etc/crontabs/root
    echo "* * * * * /usr/libexec/openclash-helper/speedswitch.sh backup >>/var/log/ocspeed.log 2>&1" >> /etc/crontabs/root
  fi
  /etc/init.d/cron restart >/dev/null 2>&1
}

web_status() {
  echo '{'
  echo -n '"running":'; if run_busy; then echo 'true,'; else echo 'false,'; fi
  echo -n '"enabled":'; [ "$(get enabled)" = "1" ] && echo 'true,' || echo 'false,'
  echo -n '"failover_enable":'; [ "$(get failover_enable)" = "1" ] && echo 'true,' || echo 'false,'
  echo -n '"failover_threshold":"'; echo -n "$(get failover_threshold)"; echo '",'
  echo -n '"last_failover":'; cat $DATA/last_failover 2>/dev/null || echo 0
  echo ','
  echo -n '"backup_enable":'; [ "$(get backup_enable)" != "0" ] && echo 'true,' || echo 'false,'
  echo -n '"backup_interval":"'; echo -n "$(get backup_interval)"; echo '",'
  echo -n '"backup":'
  cat $DATA/backup.json 2>/dev/null || echo 'null'
  echo ','
  echo -n '"interval":"'; echo -n "$(get interval)"; echo '",'
  echo -n '"threshold":"'; echo -n "$(get threshold)"; echo '",'
  echo -n '"group":"'; echo -n "$(get group)"; echo '",'
  echo -n '"test_url":"'; echo -n "$(get test_url)"; echo '",'
  echo -n '"gemini_url":"'; echo -n "$(get gemini_url)"; echo '",'
  echo -n '"exclude":"'; echo -n "$(get exclude)"; echo '",'
  now=$(api_get "/proxies/$(get group)" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo -n '"current":"'; echo -n "$now"; echo '",'
  echo -n '"last":'
  cat $DATA/status.json 2>/dev/null || echo 'null'
  echo ','
  if [ -f $DATA/nodes.json ]; then
    totaln=$(grep -o '"n":"' $DATA/nodes.json | wc -l)
    okn=$(grep -o '"s":"ok"' $DATA/nodes.json | wc -l)
    deadn=$(grep -o '"s":"dead"' $DATA/nodes.json | wc -l)
    faken=$(grep -o '"s":"fake"' $DATA/nodes.json | wc -l)
    echo -n '"nodes":{"total":'$totaln',"ok":'$okn',"dead":'$deadn',"fake":'$faken'},'
  else
    echo -n '"nodes":{"total":0,"ok":0,"dead":0,"fake":0},'
  fi
  echo -n '"history":['
  if [ -f $DATA/history.log ]; then
    tail -10 $DATA/history.log | sed 's/^/"/; s/$/"/' | tr '\n' ',' | sed 's/,$//'
  fi
  echo ']'
  echo '}'
}

testnode() {
  local name="$1"
  local sites=$(get testsites)
  [ -z "$sites" ] && sites='https://www.baidu.com|https://www.bilibili.com|https://www.taobao.com|https://www.qq.com|https://www.google.com|https://www.youtube.com|https://www.netflix.com|https://github.com|https://gemini.google.com|https://chatgpt.com|https://claude.ai'
  printf '%s' "$sites" | tr '|' '\n' | grep . > $DIR/tsites.list
  printf '{"node":"%s","results":[' "$name"
  local i=0
  while read -r s; do
    [ -z "$s" ] && continue
    local label=$(echo "$s" | sed 's|https://||; s|/.*||; s|^www\.||')
    local d=$(node_delay "$name" "$s" 2000)
    [ $i -gt 0 ] && printf ','
    if [ -n "$d" ]; then printf '{"site":"%s","d":%s}' "$label" "$d"; else printf '{"site":"%s","d":null}' "$label"; fi
    i=$((i+1))
  done < $DIR/tsites.list
  printf ']}'
}

switchnode() {
  local name="$1"
  local group=$(get group); [ -z "$group" ] && group='宝贝云'
  curl -s -m 8 -X PUT -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}" "$API/proxies/$group"
}

case "$1" in
  run)     speedtest_full 1 ;;
  testnode) testnode "$2" ;;
  switchnode) switchnode "$2" ;;
  test)    speedtest_full 0 ;;
  nodes)   cat $DATA/nodes.json 2>/dev/null || echo '{"ts":0,"total":0,"nodes":[]}' ;;
  enable)  uci -q set ocspeed.main.enabled='1'; uci commit ocspeed; cron_apply; log cron "已启用自动测速"; echo '{"ok":true}' ;;
  disable) uci -q set ocspeed.main.enabled='0'; uci commit ocspeed; cron_apply; log cron "已停用自动测速"; echo '{"ok":true}' ;;
  status)  web_status ;;
  failover) failover_check ;;
  backup)  backup_select ;;
  backupnow) if run_busy; then
               echo '{"ok":false,"busy":true,"msg":"已有测速在运行"}'
             else
               rm -f $DATA/last_backup 2>/dev/null
               backup_select
               echo '{"ok":true}'
             fi ;;
  backupjson) cat $DATA/backup.json 2>/dev/null || echo '{"ts":0,"group":"","now":"","probed":0,"list":[]}' ;;
  progress) cat $DIR/progress.json 2>/dev/null || echo '{"phase":"idle","msg":"空闲","pct":0}' ;;
  *) echo "usage: $0 run|test|status|nodes|enable|disable|failover|backup|backupnow"; exit 1 ;;
esac
