#!/bin/sh
# 端到端测试：在 PC 上用模拟的 Android 命令跑 apply -> 再 apply -> revert，确认可完整还原。
# 用法: sh tests/run.sh [shell]   （默认 dash；可传 "busybox sh"）
set -e
SH=${1:-dash}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod" "$T/data" "$T/mock" "$T/surf/etc" "$T/surf/rules"
# 模拟已装 Surfing：它自己的 hosts（会被 bind mount 到 /system/etc/hosts）和 rules 目录
printf '# Default\n127.0.0.1       localhost\n::1             ip6-localhost\n' > "$T/surf/etc/hosts"
cp "$T/surf/etc/hosts" "$T/surf.hosts.orig"
cp -r "$ROOT/anximi.sh" "$ROOT/module.prop" "$ROOT/lists" "$ROOT/defaults" "$T/mod/"
mkdir -p "$T/mod/system/etc"; printf '127.0.0.1 localhost\n' > "$T/mod/system/etc/hosts"
cat > "$T/mock/state.json" <<'J'
{
 "props": {"ro.product.mod_device": "songyuan_eea_global", "ro.miui.build.region": "eea", "ro.build.version.release": "16"},
 "users": [[0, "Owner"], [10, "Island"]],
 "pkgs": {
  "com.miui.msa.global": {"appid": 10101},
  "com.miui.analytics": {"appid": 10102, "perms": ["android.permission.READ_PHONE_STATE", "android.permission.ACCESS_FINE_LOCATION"]},
  "com.miui.daemon": {"appid": 1000},
  "com.miui.securitycenter": {"appid": 1000},
  "com.miui.guardprovider": {"appid": 10103},
  "com.miui.contentextension": {"appid": 10104, "perms": ["android.permission.POST_NOTIFICATIONS"]},
  "com.xiaomi.joyose": {"appid": 10105},
  "com.miui.global.packageinstaller": {"appid": 10106},
  "com.miui.player": {"appid": 10107},
  "com.android.chrome": {"appid": 10200}
 },
 "settings": {"global:wifi_scan_always_enabled": "1"}
}
J
export MOCK="$T/mock" ANX_DATA="$T/data" ANX_MODDIR="$T/mod" ANX_REEXEC=1 QUIET=1
export ANX_SURF_HOSTS="$T/surf/etc/hosts" ANX_SURF_RULES="$T/surf/rules"
export PATH="$ROOT/tests/mock-bin:$PATH"
cp "$T/mock/state.json" "$T/before.json"
A="$SH $T/mod/anximi.sh"
fail() { echo "FAIL: $*"; echo "--- log"; cat "$T/data/logs/anximi.log"; exit 1; }
q() { python3 -c "import json,sys
s=json.load(open('$T/mock/state.json'))
def P(u,p,k):
    d={'inst':True,'dis':False,'perms':s['pkgs'][p].get('perms',[])}
    return s.get('u',{}).get(u,{}).get(p,d)[k]
print(eval(sys.argv[1]))" "$1"; }

echo "== status"; $A status | head -5
echo "== apply"; $A apply
[ "$(q "P('0','com.miui.msa.global','dis')")" = True ] || fail "msa 未禁用（用户0）"
[ "$(q "P('10','com.miui.msa.global','dis')")" = True ] || fail "msa 未禁用（用户10）"
[ "$(q "P('0','com.miui.securitycenter','dis')")" = False ] || fail "安全中心被禁用了"
[ "$(q "P('0','com.miui.player','dis')")" = False ] || fail "med 风险的音乐被处理了"
[ "$(q "P('0','com.miui.analytics','perms')")" = "[]" ] || fail "权限未撤销"
[ "$(q "s['appops'].get('0:com.miui.analytics:RUN_ANY_IN_BACKGROUND')")" = ignore ] || fail "appops 未设置"
[ "$(q "s['settings']['global:wifi_scan_always_enabled']")" = 0 ] || fail "设置未修改"
rules=$(q "s['iptables']['chains']['ANXIMI_OUT']")
echo "$rules" | grep -q 'uid-owner 10102' || fail "analytics UID 未拦截"
echo "$rules" | grep -q 'uid-owner 1010102' || fail "用户10 的 analytics UID 未拦截"
echo "$rules" | grep -q 'uid-owner 1000 ' && fail "拦截了 system UID"
echo "$rules" | grep -q 'uid-owner 10106' || fail "安装器未断网"
[ "$(q "s['iptables']['OUTPUT'][0]")" = ANXIMI_OUT ] || fail "跳转不在 OUTPUT 首位"
grep -q '^0.0.0.0 data.mistat.xiaomi.com' "$T/mod/system/etc/hosts" || fail "hosts 缺遥测域名"
grep -q "'+.sec.miui.com'" "$T/data/export/anximi-domains.yaml" || fail "mihomo 导出缺通配"
grep -q 'PROCESS-NAME,com.miui.analytics' "$T/data/export/anximi-process.yaml" || fail "mihomo 进程规则缺失"
grep -q '^0.0.0.0 data.mistat.xiaomi.com' "$T/surf/etc/hosts" || fail "未同步到 Surfing 的 hosts"
grep -q '^127.0.0.1       localhost' "$T/surf/etc/hosts" || fail "Surfing hosts 原有内容丢失"
[ "$(grep -c '^# >>> Anximi' "$T/surf/etc/hosts")" = 1 ] || fail "Surfing hosts 区块数不对"
cmp -s "$T/data/export/anximi-domains.yaml" "$T/surf/rules/anximi-domains.yaml" || fail "规则集未自动复制到 Surfing rules"
n1=$(wc -l < "$T/data/state/applied.list")
echo "   已接管 $n1 项"

echo "== apply again (idempotent)"
: > "$T/mock/calls.log"
$A apply
n2=$(wc -l < "$T/data/state/applied.list")
[ "$n1" = "$n2" ] || fail "二次 apply 状态条目变化 $n1 -> $n2"
[ "$(grep -c '^# >>> Anximi' "$T/surf/etc/hosts")" = 1 ] || fail "二次 apply 后 Surfing hosts 区块重复"
grep -qE '^pm (disable-user|uninstall)' "$T/mock/calls.log" && fail "二次 apply 重复执行了禁用"

echo "== change config: ads -> uninstall, telemetry off"
sed -i 's/^cat_ads=.*/cat_ads=net,uninstall/; s/^cat_telemetry=.*/cat_telemetry=/' "$T/data/config.conf"
$A apply
[ "$(q "P('0','com.miui.msa.global','inst')")" = False ] || fail "msa 未卸载"
[ "$(q "P('0','com.miui.analytics','dis')")" = False ] || fail "关闭遥测后 analytics 未还原"
[ "$(q "len(P('0','com.miui.analytics','perms'))")" = 2 ] || fail "关闭遥测后权限未还原"

echo "== manual re-enable is re-applied"
python3 - "$T/mock/state.json" <<'P'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s['u']['0']['com.miui.contentextension']['dis']=False; json.dump(s,open(p,'w'))
P
$A apply
[ "$(q "P('0','com.miui.contentextension','dis')")" = True ] || fail "未重新禁用"

echo "== components"
echo "com.miui.securitycenter/com.x.Tracker" >> "$T/data/components.conf"
$A components com.miui.securitycenter | grep -q 'com.miui.securitycenter/com.miui.securitycenter.UploadService' || fail "组件扫描"
$A apply
[ "$(q "s['comps']['0']['com.miui.securitycenter/com.x.Tracker']")" = True ] || fail "组件未禁用"

echo "== hosts=0 removes Surfing block"
sed -i 's/^hosts=.*/hosts=0/' "$T/data/config.conf"; $A hosts-build
grep -q '^# >>> Anximi' "$T/surf/etc/hosts" && fail "hosts=0 后 Surfing hosts 仍有 Anximi 区块"
sed -i 's/^hosts=.*/hosts=1/' "$T/data/config.conf"; $A hosts-build
grep -q '^0.0.0.0 ' "$T/surf/etc/hosts" || fail "hosts=1 后未重新同步"
echo "== inventory"; $A inventory | head -3
echo "== revert"; $A revert
python3 - "$T/before.json" "$T/mock/state.json" <<'P'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
bad=[]
for u,pk in b.get('u',{}).items():
    for p,x in pk.items():
        orig=set(a['pkgs'][p].get('perms',[]))
        if not x['inst'] or x['dis'] or set(x['perms'])!=orig: bad.append((u,p,x))
if b.get('appops'): bad.append(('appops',b['appops']))
if b.get('settings')!=a.get('settings'): bad.append(('settings',b.get('settings')))
if any(any(v.values()) for v in b.get('comps',{}).values()): bad.append(('comps',b['comps']))
if any(v!=10 for v in b.get('bucket',{}).values()): bad.append(('bucket',b['bucket']))
for t in ('iptables','ip6tables'):
    if 'ANXIMI_OUT' in b[t]['OUTPUT'] or 'ANXIMI_OUT' in b[t]['chains']: bad.append((t,b[t]))
if bad:
    print("FAIL: 未完全还原", bad); sys.exit(1)
P
[ -s "$T/data/state/applied.list" ] && fail "状态文件未清空"
grep -q '^0.0.0.0' "$T/mod/system/etc/hosts" && fail "hosts 未清空"
cmp -s "$T/surf/etc/hosts" "$T/surf.hosts.orig" || fail "还原后 Surfing hosts 未恢复原样"
grep -q 'anximi.invalid' "$T/surf/rules/anximi-domains.yaml" || fail "还原后 Surfing rules 未换成占位"
echo "== hosts-build after revert stays empty"
$A hosts-build; grep -q '^0.0.0.0' "$T/mod/system/etc/hosts" && fail "还原后 hosts-build 又写入了域名"
echo "ALL PASS ($SH)"
