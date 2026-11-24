#!/system/bin/sh
# late_start：等开机完成后应用配置、启动 iptables 看门狗
MODDIR=${0%/*}
DATA=/data/adb/anximi
ANX="$MODDIR/anximi.sh"
export ANX_MODDIR=$MODDIR QUIET=1

if [ -f "$DATA/run/rescue" ]; then
  # 救援：系统可能卡在开机，只要 package 服务起来就全部还原
  until [ -n "$(pm path android 2>/dev/null)" ]; do sleep 2; done
  sh "$ANX" revert
  sed -i 's/^boot_apply=.*/boot_apply=0/' "$DATA/config.conf"
  date '+%F %T 连续开机失败，已自动全部还原并关闭开机应用' > "$DATA/rescued"
  rm -f "$DATA/run/rescue"
  echo 0 > "$DATA/run/bootcount"
  exit 0
fi

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
# 等桌面起来、Surfing 等其他模块先完成它们的 iptables 设置（顺序无关，只是减少 xtables 锁竞争）
sleep 20

if grep -q '^boot_apply=1' "$DATA/config.conf" 2>/dev/null; then
  sh "$ANX" apply
else
  sh "$ANX" net-build
fi

# 开机后稳定 60 秒才清零防砖计数
( sleep 60; echo 0 > "$DATA/run/bootcount" ) &

if grep -q '^net_watchdog=1' "$DATA/config.conf" 2>/dev/null; then
  while true; do
    sleep 300
    sh "$ANX" net-check
  done &
fi
