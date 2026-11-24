#!/system/bin/sh
# 开机早期：防砖计数 + 按配置决定是否挂载 hosts
MODDIR=${0%/*}
DATA=/data/adb/anximi
mkdir -p "$DATA/run" "$DATA/logs"
rm -rf "$DATA/run/lock"

# 连续 3 次没能开机完成 -> 进入救援模式，service.sh 会在 pm 可用时全部还原
c=$(cat "$DATA/run/bootcount" 2>/dev/null || echo 0)
c=$((c + 1))
echo $c > "$DATA/run/bootcount"
[ $c -ge 3 ] && touch "$DATA/run/rescue"

if grep -q '^hosts=0' "$DATA/config.conf" 2>/dev/null; then
  rm -f "$MODDIR/system/etc/hosts"
elif [ ! -f "$MODDIR/system/etc/hosts" ]; then
  mkdir -p "$MODDIR/system/etc"
  printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$MODDIR/system/etc/hosts"
  chmod 644 "$MODDIR/system/etc/hosts"
fi
# 用当前配置刷新 hosts 内容（不依赖 pm）
ANX_MODDIR=$MODDIR QUIET=1 sh "$MODDIR/anximi.sh" hosts-build >/dev/null 2>&1
