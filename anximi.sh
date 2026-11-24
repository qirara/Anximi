#!/system/bin/sh
# Anximi - HyperOS/MIUI 隐私模块主脚本
# 用法见 `anximi.sh help`。所有操作都会记录到状态文件，`revert` 可完整还原。
# shellcheck disable=SC3043  # local 在 ash/mksh 中可用

# 统一用 root 管理器自带的 busybox ash 执行，避免 mksh/ash 差异
if [ -z "$ANX_REEXEC" ]; then
  for _bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$_bb" ]; then
      export ANX_REEXEC=1
      exec "$_bb" sh "$0" "$@"
    fi
  done
fi
export ANX_REEXEC=1

ANX_VERSION="v0.1.0"
case "$0" in
  */*) _self_dir=${0%/*} ;;
  *) _self_dir=. ;;
esac
MODDIR=${ANX_MODDIR:-$(cd "$_self_dir" 2>/dev/null && pwd)}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/anximi
DATA=${ANX_DATA:-/data/adb/anximi}
LISTS="$MODDIR/lists"
STATE="$DATA/state"
RUN="$DATA/run"
LOG="$DATA/logs/anximi.log"
APPLIED="$STATE/applied.list"
CHAIN=ANXIMI_OUT
CATS="ads telemetry cloudctl seccloud ai cloud"

# 永远只允许网络拦截的核心包（就算用户强制也不禁用/卸载）
PROTECTED=" android com.android.systemui com.android.settings com.android.phone com.android.shell \
com.miui.securitycenter com.lbe.security.miui com.miui.powerkeeper com.miui.core com.miui.home \
com.miui.system com.miui.rom com.android.providers.settings com.android.providers.telephony \
com.google.android.packageinstaller com.android.packageinstaller com.miui.global.packageinstaller \
com.miui.packageinstaller com.android.permissioncontroller com.google.android.permissioncontroller \
com.android.vending com.google.android.gms com.miui.securitycore "

APPOPS_LIST="RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND GET_USAGE_STATS READ_CLIPBOARD SYSTEM_ALERT_WINDOW 10008"
PERM_LIST="READ_PHONE_STATE READ_PHONE_NUMBERS ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION \
ACCESS_BACKGROUND_LOCATION READ_CONTACTS READ_CALL_LOG READ_SMS RECEIVE_SMS CAMERA RECORD_AUDIO \
READ_EXTERNAL_STORAGE READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_MEDIA_AUDIO POST_NOTIFICATIONS \
NEARBY_WIFI_DEVICES BLUETOOTH_SCAN ACTIVITY_RECOGNITION BODY_SENSORS"

mkdir -p "$STATE" "$RUN" "$DATA/logs" "$DATA/export" 2>/dev/null

# Android 的 cmd 系命令可能读取 stdin，会吃掉 while-read 循环的输入，统一接到 /dev/null
pm() { command pm "$@" < /dev/null; }
am() { command am "$@" < /dev/null; }
appops() { command appops "$@" < /dev/null; }
settings() { command settings "$@" < /dev/null; }
cmd() { command cmd "$@" < /dev/null; }
dumpsys() { command dumpsys "$@" < /dev/null; }
touch "$APPLIED"

# ---------------------------------------------------------------- 通用工具
log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  [ -n "$QUIET" ] || echo "$*"
}

progress() { echo "$*" > "$RUN/progress"; log "$*"; }

rotate_log() {
  [ -f "$LOG" ] || return 0
  _sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$_sz" -gt 524288 ] && mv -f "$LOG" "$LOG.1"
  return 0
}

cfg() { # cfg key [default]
  _v=$(sed -n "s/^$1=//p" "$DATA/config.conf" 2>/dev/null | tail -n 1)
  [ -n "$_v" ] && echo "$_v" || echo "$2"
}

has_word() { # has_word "a,b c" b
  case " $(echo "$1" | tr ',' ' ') " in *" $2 "*) return 0 ;; esac
  return 1
}

strip_list() { # 去掉注释和空行
  [ -f "$1" ] && sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$1"
}

risk_num() { case "$1" in low) echo 1 ;; med) echo 2 ;; high) echo 3 ;; *) echo 2 ;; esac; }

lock() {
  _i=0
  while ! mkdir "$RUN/lock" 2>/dev/null; do
    # 超过 10 分钟的锁视为残留
    if [ -n "$(find "$RUN/lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$RUN/lock" 2>/dev/null; continue
    fi
    _i=$((_i + 1)); [ $_i -gt 120 ] && { log "另一个任务正在运行，放弃"; exit 1; }
    sleep 1
  done
  trap 'rmdir "$RUN/lock" 2>/dev/null' EXIT INT TERM
}

ensure_config() {
  for f in config.conf packages.conf custom.list custom.hosts allow.hosts components.conf; do
    [ -f "$DATA/$f" ] || cp -f "$MODDIR/defaults/$f" "$DATA/$f" 2>/dev/null
  done
}

# ---------------------------------------------------------------- 环境探测
root_impl() {
  if [ -n "$KSU" ] || [ -d /data/adb/ksu ]; then echo KernelSU
  elif [ -n "$APATCH" ] || [ -d /data/adb/ap ]; then echo APatch
  elif [ -d /data/adb/magisk ]; then echo Magisk
  else echo unknown; fi
}

detect_region() {
  _r=$(cfg region auto)
  if [ "$_r" != auto ]; then echo "$_r"; return; fi
  _md=$(getprop ro.product.mod_device 2>/dev/null)
  _br=$(getprop ro.miui.build.region 2>/dev/null)
  _mr=$(getprop ro.miui.region 2>/dev/null)
  case "$_md" in
    *eea*) echo eea; return ;;
    *global*) echo global; return ;;
  esac
  case "$_br" in eea|EEA) echo eea; return ;; cn|CN) echo cn; return ;; ?*) echo global; return ;; esac
  case "$_mr" in CN|cn) echo cn; return ;; esac
  # 国行 mod_device 通常不带后缀；无法判断时按国际版处理
  if [ -n "$_md" ] && [ "$(getprop ro.product.locale 2>/dev/null)" = zh-CN ]; then echo cn; else echo global; fi
}

all_users() {
  pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p'
}

target_users() {
  _want=$(cfg users all)
  _have=$(all_users)
  [ -n "$_have" ] || _have=0
  if [ "$_want" = all ]; then echo "$_have"; return; fi
  for u in $(echo "$_want" | tr ',' ' '); do
    echo "$_have" | grep -qx "$u" && echo "$u"
  done
}

# 每个用户缓存一次包列表：all.U = "包名 uid"（含已为该用户卸载的）、inst.U = 已安装、dis.U = 已禁用
cache_users() {
  for u in $1; do
    pm list packages -U -u --user "$u" 2>/dev/null | sed -n 's/^package:\([^ ]*\) uid:\([0-9]*\).*/\1 \2/p' > "$RUN/all.$u"
    pm list packages --user "$u" 2>/dev/null | sed -n 's/^package:\([^ ]*\).*/\1/p' > "$RUN/inst.$u"
    pm list packages -d --user "$u" 2>/dev/null | sed -n 's/^package:\([^ ]*\).*/\1/p' > "$RUN/dis.$u"
  done
}

known() { grep -q "^$2 " "$RUN/all.$1" 2>/dev/null; }
installed() { grep -qx "$2" "$RUN/inst.$1" 2>/dev/null; }
disabled() { grep -qx "$2" "$RUN/dis.$1" 2>/dev/null; }
app_id() { _u=$(grep "^$2 " "$RUN/all.$1" 2>/dev/null | head -n 1 | cut -d' ' -f2); [ -n "$_u" ] && echo $((_u % 100000)); }

# ---------------------------------------------------------------- 清单
# 输出：分类|包名|允许手段|区域|风险|说明
all_entries() {
  for c in $CATS; do
    strip_list "$LISTS/$c.list" | sed "s/^/$c|/"
  done
  strip_list "$DATA/custom.list" | awk -F'|' 'NF>=2 { printf "%s|%s|%s|all|%s|%s\n", $1, $2, ($3==""?"net,disable,restrict":$3), ($4==""?"low":$4), $5 }'
}

pkg_override() { sed -n "s/^$1=//p" "$DATA/packages.conf" 2>/dev/null | tail -n 1; }

# 计算某个包在当前配置下实际采用的手段，输出逗号列表或 "skip:原因"
effective_methods() { # cat pkg allowed risk
  _m=$(cfg "cat_$1" "")
  [ -n "$_m" ] || { echo "skip:分类未启用"; return; }
  _ov=$(pkg_override "$2")
  [ "$_ov" = skip ] && { echo "skip:已设为跳过"; return; }
  if [ "$_ov" != include ] && [ "${_ov#only:}" = "$_ov" ]; then
    if [ "$(risk_num "$4")" -gt "$(risk_num "$(cfg risk_level low)")" ]; then
      echo "skip:风险 $4 高于阈值"; return
    fi
  fi
  case "$_ov" in only:*) _m=${_ov#only:} ;; esac
  _out=""
  for x in net disable uninstall restrict; do
    has_word "$_m" "$x" && has_word "$3" "$x" && _out="$_out,$x"
  done
  case "$PROTECTED" in *" $2 "*) has_word "$_out" net && _out=",net" || _out="" ;; esac
  has_word "$_out" uninstall && _out=$(echo "$_out" | sed 's/,disable//')
  _out=${_out#,}
  [ -n "$_out" ] && echo "$_out" || echo "skip:无可用手段"
}

# ---------------------------------------------------------------- 期望状态
# 每行：类型|用户|目标|参数
gen_desired() {
  _users=$(target_users)
  : > "$RUN/desired"
  : > "$RUN/net.want"
  : > "$RUN/hosts.cats"
  all_entries | while IFS='|' read -r c pkg allowed _region risk _note; do
    eff=$(effective_methods "$c" "$pkg" "$allowed" "$risk")
    case "$eff" in skip:*) continue ;; esac
    for u in $_users; do
      known "$u" "$pkg" || continue
      has_word "$eff" net && echo "$u|$pkg" >> "$RUN/net.want"
      has_word "$eff" disable && echo "disable|$u|$pkg|" >> "$RUN/desired"
      has_word "$eff" uninstall && echo "uninstall|$u|$pkg|" >> "$RUN/desired"
      if has_word "$eff" restrict; then
        echo "appops|$u|$pkg|" >> "$RUN/desired"
        echo "perms|$u|$pkg|" >> "$RUN/desired"
        echo "bucket|$u|$pkg|" >> "$RUN/desired"
      fi
    done
  done
  for c in $CATS; do
    has_word "$(cfg "cat_$c" "")" net && echo "$c" >> "$RUN/hosts.cats"
  done
  if [ "$(cfg components 1)" = 1 ]; then
    strip_list "$DATA/components.conf" | while read -r comp; do
      _p=${comp%%/*}
      for u in $_users; do known "$u" "$_p" && echo "comp|$u|$comp|" >> "$RUN/desired"; done
    done
  fi
  _sets=$(cfg settings "")
  strip_list "$LISTS/settings.list" | while IFS='|' read -r id ns key val _r _n; do
    has_word "$_sets" "$id" && echo "setting|0|$ns:$key|$val" >> "$RUN/desired"
  done
  sort -u "$RUN/desired" -o "$RUN/desired"
}

# ---------------------------------------------------------------- 单项操作
appop_mode() { # user pkg op -> 当前模式
  _o=$(appops get --user "$1" "$2" "$3" 2>/dev/null | grep -v '^Uid mode:' | head -n 1)
  case "$_o" in
    *": "*) echo "$_o" | sed 's/^[^:]*: *\([a-z_]*\).*/\1/' ;;
    *) echo default ;;
  esac
}

granted_perms() { # user pkg -> 已授予的运行时权限（全名）
  dumpsys package "$2" 2>/dev/null | awk -v U="$1" '
    /^Hidden system packages:/ { exit }
    /^ +User [0-9]+:/ { u=$2; sub(":","",u); rt=0; next }
    /runtime permissions:/ { rt=1; next }
    rt && u==U && /granted=true/ { p=$1; sub(":$","",p); print p }
  '
}

bucket_name() {
  case "$1" in 5) echo exempted ;; 10) echo active ;; 20) echo working_set ;; 30) echo frequent ;;
    40) echo rare ;; 45) echo restricted ;; 50) echo never ;; *) echo "$1" ;; esac
}

# apply_one 类型 用户 目标 参数 -> 成功时输出 prev 并返回 0；返回 1 表示无需/未接管
apply_one() {
  case "$1" in
    disable)
      disabled "$2" "$3" && return 1
      installed "$2" "$3" || return 1
      pm disable-user --user "$2" "$3" >/dev/null 2>&1 || { log "  失败: disable $3 (u$2)"; return 1; }
      log "  禁用 $3 (用户 $2)"; echo enabled ;;
    uninstall)
      installed "$2" "$3" || return 1
      pm uninstall -k --user "$2" "$3" >/dev/null 2>&1 || { log "  失败: uninstall $3 (u$2)"; return 1; }
      log "  卸载 $3 (用户 $2，保留 APK)"; echo installed ;;
    appops)
      installed "$2" "$3" || return 1
      _prev=""
      for op in $APPOPS_LIST; do
        _cur=$(appop_mode "$2" "$3" "$op")
        [ "$_cur" = ignore ] && continue
        appops set --user "$2" "$3" "$op" ignore >/dev/null 2>&1 && _prev="$_prev,$op=$_cur"
      done
      log "  限制后台 $3 (用户 $2)${_prev:+: ${_prev#,}}"; echo "${_prev#,}" ;;
    perms)
      installed "$2" "$3" || return 1
      _g=$(granted_perms "$2" "$3")
      _prev=""
      for p in $PERM_LIST; do
        echo "$_g" | grep -qx "android.permission.$p" || continue
        pm revoke --user "$2" "$3" "android.permission.$p" >/dev/null 2>&1 && _prev="$_prev,$p"
      done
      [ -n "$_prev" ] && log "  撤销权限 $3 (用户 $2): ${_prev#,}"; echo "${_prev#,}" ;;
    bucket)
      installed "$2" "$3" || return 1
      _cur=$(am get-standby-bucket --user "$2" "$3" 2>/dev/null | tr -dc '0-9')
      [ -n "$_cur" ] || return 1
      [ "$_cur" -ge 45 ] && return 1
      [ "$_cur" -le 5 ] && return 1   # 豁免分组（系统应用）设了也无效
      am set-standby-bucket --user "$2" "$3" restricted >/dev/null 2>&1 || return 1
      log "  待机分组 $3 -> restricted (用户 $2)"; echo "$_cur" ;;
    comp)
      pm disable --user "$2" "$3" >/dev/null 2>&1 || { log "  失败: 组件 $3 (u$2)"; return 1; }
      log "  禁用组件 $3 (用户 $2)"; echo default ;;
    setting)
      _ns=${3%%:*}; _k=${3#*:}
      _cur=$(settings get "$_ns" "$_k" 2>/dev/null)
      [ "$_cur" = "$4" ] && return 1
      settings put "$_ns" "$_k" "$4" >/dev/null 2>&1 || return 1
      log "  设置 $_ns $_k: $_cur -> $4"; echo "${_cur:-null}" ;;
    *) return 1 ;;
  esac
  return 0
}

revert_one() { # 类型 用户 目标 参数 prev
  case "$1" in
    disable) pm enable --user "$2" "$3" >/dev/null 2>&1; log "  还原启用 $3 (用户 $2)" ;;
    uninstall)
      pm install-existing --user "$2" "$3" >/dev/null 2>&1 || cmd package install-existing --user "$2" "$3" >/dev/null 2>&1
      log "  还原安装 $3 (用户 $2)" ;;
    appops)
      for kv in $(echo "$5" | tr ',' ' '); do
        appops set --user "$2" "$3" "${kv%%=*}" "${kv#*=}" >/dev/null 2>&1
      done
      log "  还原后台权限 $3 (用户 $2)" ;;
    perms)
      for p in $(echo "$5" | tr ',' ' '); do
        pm grant --user "$2" "$3" "android.permission.$p" >/dev/null 2>&1
      done
      [ -n "$5" ] && log "  还原权限 $3 (用户 $2): $5" ;;
    bucket) am set-standby-bucket --user "$2" "$3" "$(bucket_name "$5")" >/dev/null 2>&1; log "  还原待机分组 $3 (用户 $2)" ;;
    comp) pm default-state --user "$2" "$3" >/dev/null 2>&1 || pm enable --user "$2" "$3" >/dev/null 2>&1; log "  还原组件 $3 (用户 $2)" ;;
    setting)
      _ns=${3%%:*}; _k=${3#*:}
      if [ "$5" = null ] || [ -z "$5" ]; then settings delete "$_ns" "$_k" >/dev/null 2>&1
      else settings put "$_ns" "$_k" "$5" >/dev/null 2>&1; fi
      log "  还原设置 $_ns $_k -> $5" ;;
  esac
}

# ---------------------------------------------------------------- 网络：iptables / bpf
ipt() { "$@" 2>/dev/null; }

net_teardown_ipt() {
  for t in iptables ip6tables; do
    command -v $t >/dev/null 2>&1 || continue
    while ipt $t -w -D OUTPUT -j $CHAIN; do :; done
    ipt $t -w -F $CHAIN; ipt $t -w -X $CHAIN
  done
}

net_teardown_bpf() {
  [ -f "$STATE/net.bpf" ] || return 0
  while read -r p; do
    [ "$p" = "@chain3" ] && continue
    cmd connectivity set-package-networking-enabled true "$p" >/dev/null 2>&1
  done < "$STATE/net.bpf"
  grep -qx "@chain3" "$STATE/net.bpf" && cmd connectivity set-chain3-enabled false >/dev/null 2>&1
  rm -f "$STATE/net.bpf"
}

bpf_supported() { cmd connectivity help 2>/dev/null | grep -q set-package-networking-enabled; }

# 根据 $RUN/net.want（用户|包）重建拦截规则；system UID (<10000) 只记录不拦（避免断掉整个系统）
net_build() {
  _backend=$(cfg net_backend iptables)
  _target=$(cfg net_target REJECT)
  : > "$RUN/net.uids"; : > "$RUN/net.bpfwant"; : > "$STATE/net.skipped"
  if [ -s "$RUN/net.want" ]; then
    while IFS='|' read -r u p; do
      a=$(app_id "$u" "$p"); [ -n "$a" ] || continue
      if [ "$a" -lt 10000 ]; then echo "$p (uid $a)" >> "$STATE/net.skipped"; continue; fi
      if [ "$_backend" = bpf ] && [ "$u" = 0 ]; then echo "$p" >> "$RUN/net.bpfwant"; continue; fi
      echo $((u * 100000 + a)) >> "$RUN/net.uids"
    done < "$RUN/net.want"
  fi
  sort -u "$RUN/net.uids" -o "$RUN/net.uids"
  sort -u "$STATE/net.skipped" -o "$STATE/net.skipped"

  net_teardown_ipt
  net_teardown_bpf
  [ "$_backend" = none ] && { : > "$STATE/net.uids"; log "网络后端 none：只使用 hosts"; return 0; }

  if [ -s "$RUN/net.bpfwant" ]; then
    if bpf_supported; then
      cmd connectivity set-chain3-enabled true >/dev/null 2>&1 && echo "@chain3" > "$STATE/net.bpf"
      while read -r p; do
        cmd connectivity set-package-networking-enabled false "$p" >/dev/null 2>&1 && echo "$p" >> "$STATE/net.bpf"
      done < "$RUN/net.bpfwant"
      log "bpf chain3 拦截 $(($(wc -l < "$STATE/net.bpf") - 1)) 个包（用户 0）"
    else
      log "系统不支持 bpf chain3，用户 0 回落到 iptables"
      while read -r p; do a=$(app_id 0 "$p"); [ -n "$a" ] && echo "$a" >> "$RUN/net.uids"; done < "$RUN/net.bpfwant"
      sort -u "$RUN/net.uids" -o "$RUN/net.uids"
    fi
  fi

  cp -f "$RUN/net.uids" "$STATE/net.uids"
  [ -s "$RUN/net.uids" ] || { log "iptables：无需拦截的 UID"; return 0; }
  for t in iptables ip6tables; do
    command -v $t >/dev/null 2>&1 || continue
    ipt $t -w -N $CHAIN
    while read -r uid; do
      ipt $t -w -A $CHAIN -m owner --uid-owner "$uid" -j "$_target"
    done < "$RUN/net.uids"
    ipt $t -w -I OUTPUT 1 -j $CHAIN || log "  $t 插入 OUTPUT 跳转失败"
  done
  log "iptables：filter/OUTPUT -> $CHAIN，拦截 $(wc -l < "$RUN/net.uids") 个 UID"
}

net_check() { # 看门狗：跳转被冲掉就补回
  [ -s "$STATE/net.uids" ] || return 0
  for t in iptables ip6tables; do
    command -v $t >/dev/null 2>&1 || continue
    if ! ipt $t -w -C OUTPUT -j $CHAIN; then
      QUIET=1 log "看门狗：$t OUTPUT 跳转丢失，重建"
      _target=$(cfg net_target REJECT)
      ipt $t -w -N $CHAIN; ipt $t -w -F $CHAIN
      while read -r uid; do ipt $t -w -A $CHAIN -m owner --uid-owner "$uid" -j "$_target"; done < "$STATE/net.uids"
      ipt $t -w -I OUTPUT 1 -j $CHAIN
    fi
  done
}

# ---------------------------------------------------------------- hosts 与 mihomo 导出
# 输出拦截域名（保留 "+." 前缀），已剔除放行列表
blocked_domains() {
  {
    if [ -f "$RUN/hosts.cats" ]; then _cats=$(cat "$RUN/hosts.cats")
    else _cats=""; for c in $CATS; do has_word "$(cfg "cat_$c" "")" net && _cats="$_cats $c"; done; fi
    for c in $_cats; do strip_list "$LISTS/$c.hosts"; done
    strip_list "$DATA/custom.hosts"
  } | tr -d '\r' | awk '{print $1}' | sort -u > "$RUN/domains.tmp"
  strip_list "$DATA/allow.hosts" | awk '{print $1}' | sed 's/^+\.//' | sort -u > "$RUN/allow.tmp"
  if [ -s "$RUN/allow.tmp" ]; then
    awk 'NR==FNR { a[$1]=1; next } { d=$1; sub(/^\+\./,"",d); if (!(d in a)) print $1 }' "$RUN/allow.tmp" "$RUN/domains.tmp"
  else cat "$RUN/domains.tmp"; fi
}

hosts_build() {
  _hf="$MODDIR/system/etc/hosts"
  if [ "$(cfg hosts 1)" != 1 ]; then
    [ -f "$_hf" ] && { rm -f "$_hf"; log "hosts 已关闭：下次重启后不再挂载模块的 hosts"; }
    return 0
  fi
  _new=0; [ -f "$_hf" ] || _new=1
  mkdir -p "${_hf%/*}"
  # 从未应用过（或已全部还原）时只写默认内容
  if [ -n "$APPLYING" ] || [ -f "$STATE/last_apply" ]; then
    blocked_domains | sed 's/^+\.//' | sort -u > "$RUN/hosts.domains"
  else : > "$RUN/hosts.domains"; fi
  {
    echo "# Generated by Anximi $ANX_VERSION - do not edit; use /data/adb/anximi/custom.hosts"
    echo "127.0.0.1 localhost"
    echo "::1 ip6-localhost"
    while read -r d; do echo "0.0.0.0 $d"; echo ":: $d"; done < "$RUN/hosts.domains"
  } > "$RUN/hosts.new"
  # 原地写入，保持 inode，已挂载时立即生效
  cat "$RUN/hosts.new" > "$_hf"
  chmod 644 "$_hf"
  cp -f "$RUN/hosts.new" "$DATA/export/hosts.txt"
  log "hosts：$(wc -l < "$RUN/hosts.domains") 个域名"
  [ $_new = 1 ] && log "hosts 文件首次生成，需要重启后挂载生效"
  return 0
}

export_mihomo() {
  _e="$DATA/export"
  blocked_domains > "$RUN/mh.domains"
  {
    echo "# Anximi domain rule-provider (behavior: domain) - generated $(date '+%F %T')"
    echo "payload:"
    if [ -s "$RUN/mh.domains" ]; then sed "s/.*/  - '&'/" "$RUN/mh.domains"; else echo "  - 'anximi.invalid'"; fi
  } > "$_e/anximi-domains.yaml"
  {
    echo "# Anximi process rule-provider (behavior: classical) - generated $(date '+%F %T')"
    echo "payload:"
    if [ -s "$RUN/net.want" ]; then cut -d'|' -f2 "$RUN/net.want" | sort -u | sed 's/.*/  - PROCESS-NAME,&/'
    else echo "  - PROCESS-NAME,anximi.placeholder"; fi
  } > "$_e/anximi-process.yaml"
  _d=$(cfg mihomo_export_dir "")
  if [ -n "$_d" ] && [ -d "$_d" ]; then
    cp -f "$_e/anximi-domains.yaml" "$_e/anximi-process.yaml" "$_d/" && log "mihomo 规则集已复制到 $_d"
  fi
  log "mihomo 规则集：$_e/anximi-domains.yaml ($(wc -l < "$RUN/mh.domains") 条)，anximi-process.yaml"
}

# ---------------------------------------------------------------- 主流程
cmd_apply() {
  lock; rotate_log; ensure_config
  APPLYING=1
  progress "开始应用 (区域 $(detect_region)，root $(root_impl))"
  _users=$(target_users); [ -n "$_users" ] || _users=0
  progress "目标用户: $(echo $_users)"
  cache_users "$_users"
  progress "计算期望状态"
  gen_desired
  cut -d'|' -f1-4 "$RUN/desired" > "$RUN/desired.keys"

  progress "撤销已不再需要的改动"
  : > "$RUN/applied.new"
  while IFS='|' read -r t u tg pa prev; do
    [ -n "$t" ] || continue
    if grep -qxF "$t|$u|$tg|$pa" "$RUN/desired.keys"; then
      # 校验：被系统更新/用户手动改回的禁用、卸载重新执行
      case "$t" in
        disable) installed "$u" "$tg" && ! disabled "$u" "$tg" && pm disable-user --user "$u" "$tg" >/dev/null 2>&1 && log "  重新禁用 $tg (用户 $u)" ;;
        uninstall) installed "$u" "$tg" && pm uninstall -k --user "$u" "$tg" >/dev/null 2>&1 && log "  重新卸载 $tg (用户 $u)" ;;
      esac
      echo "$t|$u|$tg|$pa|$prev" >> "$RUN/applied.new"
    else
      revert_one "$t" "$u" "$tg" "$pa" "$prev"
    fi
  done < "$APPLIED"
  cut -d'|' -f1-4 "$RUN/applied.new" > "$RUN/applied.keys"

  _n=$(wc -l < "$RUN/desired"); _i=0
  while IFS='|' read -r t u tg pa; do
    _i=$((_i + 1))
    grep -qxF "$t|$u|$tg|$pa" "$RUN/applied.keys" && continue
    progress "[$_i/$_n] $t $tg (用户 $u)"
    if prev=$(apply_one "$t" "$u" "$tg" "$pa"); then
      echo "$t|$u|$tg|$pa|$prev" >> "$RUN/applied.new"
      # 边做边落盘，中途中断也能还原
      cp -f "$RUN/applied.new" "$APPLIED"
    fi
  done < "$RUN/desired"
  cp -f "$RUN/applied.new" "$APPLIED"

  # 被禁用/卸载的包顺手 force-stop；受限包也停一次让限制生效
  grep -E '^(appops|disable|uninstall)\|' "$APPLIED" | cut -d'|' -f2,3 | sort -u | while IFS='|' read -r u p; do
    am force-stop --user "$u" "$p" >/dev/null 2>&1
  done

  progress "重建网络拦截"
  net_build
  progress "生成 hosts"
  hosts_build
  export_mihomo
  date '+%F %T' > "$STATE/last_apply"
  progress "完成：已接管 $(wc -l < "$APPLIED") 项改动"
}

cmd_revert() {
  lock; rotate_log
  progress "开始全部还原"
  sed '1!G;h;$!d' "$APPLIED" > "$RUN/rev.tmp"
  _n=$(wc -l < "$RUN/rev.tmp"); _i=0
  while IFS='|' read -r t u tg pa prev; do
    [ -n "$t" ] || continue
    _i=$((_i + 1)); progress "[$_i/$_n] 还原 $t $tg"
    revert_one "$t" "$u" "$tg" "$pa" "$prev"
  done < "$RUN/rev.tmp"
  : > "$APPLIED"
  net_teardown_ipt; net_teardown_bpf
  : > "$STATE/net.uids"
  _hf="$MODDIR/system/etc/hosts"
  if [ -f "$_hf" ]; then
    printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$_hf"
    log "hosts 已清空（模块仍挂载一个默认 hosts；如需完全移除请把 hosts=0 并重启）"
  fi
  : > "$RUN/net.want"; echo none > "$RUN/hosts.cats"
  printf "payload:\n  - 'anximi.invalid'\n" > "$DATA/export/anximi-domains.yaml"
  printf 'payload:\n  - PROCESS-NAME,anximi.placeholder\n' > "$DATA/export/anximi-process.yaml"
  _d=$(cfg mihomo_export_dir "")
  [ -n "$_d" ] && [ -d "$_d" ] && cp -f "$DATA/export/anximi-domains.yaml" "$DATA/export/anximi-process.yaml" "$_d/"
  rm -f "$STATE/last_apply"
  progress "完成：所有改动已还原"
}

cmd_status() {
  _users=$(target_users)
  echo "version=$ANX_VERSION"
  echo "root=$(root_impl)"
  echo "region=$(detect_region)"
  echo "mod_device=$(getprop ro.product.mod_device 2>/dev/null)"
  echo "os=$(getprop ro.mi.os.version.name 2>/dev/null) $(getprop ro.build.version.incremental 2>/dev/null)"
  echo "android=$(getprop ro.build.version.release 2>/dev/null)"
  echo "users_all=$(all_users | tr '\n' ' ')"
  echo "users_target=$(echo $_users)"
  for u in $(all_users); do
    _n=$(pm list users 2>/dev/null | sed -n "s/.*UserInfo{$u:\([^:]*\):.*/\1/p" | head -n 1)
    echo "user_name_$u=$_n"
  done
  echo "backend=$(cfg net_backend iptables)"
  echo "bpf_supported=$(bpf_supported && echo 1 || echo 0)"
  if iptables -w -C OUTPUT -j $CHAIN 2>/dev/null; then echo "ipt_hooked=1"; else echo "ipt_hooked=0"; fi
  echo "net_uids=$( [ -f "$STATE/net.uids" ] && wc -l < "$STATE/net.uids" || echo 0)"
  echo "net_skipped=$( [ -f "$STATE/net.skipped" ] && tr '\n' ';' < "$STATE/net.skipped")"
  _hf="$MODDIR/system/etc/hosts"
  echo "hosts_file=$( [ -f "$_hf" ] && grep -c '^0\.0\.0\.0' "$_hf" || echo -)"
  echo "hosts_live=$(grep -c '^0\.0\.0\.0' /system/etc/hosts 2>/dev/null || echo 0)"
  for t in disable uninstall appops perms bucket comp setting; do
    echo "applied_$t=$(grep -c "^$t|" "$APPLIED" 2>/dev/null)"
  done
  echo "last_apply=$(cat "$STATE/last_apply" 2>/dev/null)"
  echo "rescue=$( [ -f "$DATA/rescued" ] && cat "$DATA/rescued")"
  echo "surfing=$( [ -d /data/adb/modules/Surfing ] && echo 1 || echo 0)"
  echo "running=$( [ -d "$RUN/lock" ] && echo 1 || echo 0)"
}

# WebUI 用：清单 + 安装情况 + 实际手段
# 分类|包名|允许|区域|风险|说明|已安装用户|实际手段|已接管
cmd_inventory() {
  _users=$(target_users); [ -n "$_users" ] || _users=0
  _allu=$(all_users); [ -n "$_allu" ] || _allu=0
  cache_users "$_allu"
  all_entries | while IFS='|' read -r c pkg allowed region risk note; do
    iu=""
    for u in $_allu; do installed "$u" "$pkg" && iu="$iu,$u"; done
    if [ -z "$iu" ]; then
      for u in $_allu; do known "$u" "$pkg" && iu="$iu,($u)"; done
    fi
    eff=$(effective_methods "$c" "$pkg" "$allowed" "$risk")
    own=$(grep -c "|$pkg|" "$APPLIED" 2>/dev/null)
    echo "$c|$pkg|$allowed|$region|$risk|$note|${iu#,}|$eff|$own"
  done
}

# 列出某个包的组件（只能看到带 intent-filter 或在 dumpsys 中出现的）
cmd_components() {
  _p=$1; [ -n "$_p" ] || { echo "用法: components <包名>"; return 1; }
  dumpsys package "$_p" 2>/dev/null | grep -oE "$_p/[A-Za-z0-9_.\$]+" | sed "s#^$_p/\.#$_p/$_p.#" | sort -u
}

# 找出清单里没有的小米系组件，方便补充
cmd_discover() {
  cache_users 0
  all_entries | cut -d'|' -f2 | sort -u > "$RUN/known.tmp"
  cut -d' ' -f1 "$RUN/all.0" | grep -E '^(com\.miui\.|com\.xiaomi\.|com\.mi\.|com\.milink\.|com\.mipay\.|com\.mfashiongallery\.|com\.lbe\.)' \
    | sort -u | grep -vxF -f "$RUN/known.tmp"
}

cmd_preset() {
  ensure_config
  case "$1" in
    conservative) set -- "cat_ads=net,disable" "cat_telemetry=net,disable" "cat_cloudctl=" "cat_seccloud=" "cat_ai=net" "cat_cloud=" "risk_level=low" ;;
    recommended) set -- "cat_ads=net,disable,restrict" "cat_telemetry=net,disable,restrict" "cat_cloudctl=net" "cat_seccloud=net" "cat_ai=net,disable,restrict" "cat_cloud=" "risk_level=low" ;;
    aggressive) set -- "cat_ads=net,uninstall,restrict" "cat_telemetry=net,disable,restrict" "cat_cloudctl=net,disable,restrict" "cat_seccloud=net,disable,restrict" "cat_ai=net,disable,restrict" "cat_cloud=net,disable,restrict" "risk_level=med" ;;
    *) echo "预设: conservative | recommended | aggressive"; return 1 ;;
  esac
  for kv in "$@"; do conf_set "${kv%%=*}" "${kv#*=}"; done
  log "已切换到预设 $1（尚未应用）"
}

conf_set() {
  if grep -q "^$1=" "$DATA/config.conf"; then
    sed -i "s|^$1=.*|$1=$2|" "$DATA/config.conf"
  else echo "$1=$2" >> "$DATA/config.conf"; fi
}

# WebUI 写文件：put <文件名> <base64>
cmd_put() {
  case "$1" in
    config.conf|packages.conf|custom.list|custom.hosts|allow.hosts|components.conf) ;;
    *) echo "不允许写入 $1"; return 1 ;;
  esac
  echo "$2" | base64 -d > "$DATA/$1.tmp" && mv -f "$DATA/$1.tmp" "$DATA/$1" && echo ok
}

cmd_bg() { # 后台执行，WebUI 轮询 progress
  [ -d "$RUN/lock" ] && { echo busy; return 1; }
  : > "$RUN/progress"
  QUIET=1 nohup sh "$MODDIR/anximi.sh" "$@" < /dev/null > "$RUN/bg.out" 2>&1 &
  echo started
}

usage() {
  cat <<EOF
Anximi $ANX_VERSION — HyperOS/MIUI 隐私模块
用法: anximi <命令>
  apply                 按配置应用（增量；不再需要的改动会自动还原）
  revert                还原本模块做过的全部改动
  status                环境与状态
  inventory             清单 + 安装情况 + 实际手段
  preset <名称>         conservative / recommended / aggressive（只改配置）
  components <包名>     列出包的组件
  discover              列出清单之外的小米系包
  net-build | net-check | hosts-build | export-mihomo
  bg <命令>             后台执行（WebUI 用）
配置目录: $DATA
EOF
}

ensure_config
case "$1" in
  apply) QUIET=$QUIET cmd_apply ;;
  revert) cmd_revert ;;
  status) cmd_status ;;
  inventory) cmd_inventory ;;
  preset) shift; cmd_preset "$@" ;;
  components) shift; cmd_components "$@" ;;
  discover) cmd_discover ;;
  net-build) lock; cache_users "$(target_users)"; gen_desired; net_build ;;
  net-check) net_check ;;
  hosts-build) QUIET=1 hosts_build ;;
  export-mihomo) cache_users "$(target_users)"; gen_desired; export_mihomo ;;
  put) shift; cmd_put "$@" ;;
  bg) shift; cmd_bg "$@" ;;
  progress) cat "$RUN/progress" 2>/dev/null; [ -d "$RUN/lock" ] && echo "@running" || echo "@idle" ;;
  log) tail -n "${2:-200}" "$LOG" 2>/dev/null ;;
  version) echo "$ANX_VERSION" ;;
  *) usage ;;
esac
