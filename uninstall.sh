#!/system/bin/sh
# 卸载模块时还原所有改动。脚本运行时系统可能还没开机完成、模块目录随后会被删，
# 所以把主脚本复制出来在后台等开机后执行。
MODDIR=${0%/*}
DATA=/data/adb/anximi
mkdir -p "$DATA/uninstall"
cp -f "$MODDIR/anximi.sh" "$MODDIR/module.prop" "$DATA/uninstall/" 2>/dev/null
mkdir -p "$DATA/uninstall/lists" && cp -f "$MODDIR/lists/"* "$DATA/uninstall/lists/" 2>/dev/null
mkdir -p "$DATA/uninstall/defaults" && cp -f "$MODDIR/defaults/"* "$DATA/uninstall/defaults/" 2>/dev/null
(
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
  sleep 10
  ANX_MODDIR="$DATA/uninstall" QUIET=1 sh "$DATA/uninstall/anximi.sh" revert
  cp -f "$DATA/logs/anximi.log" /data/local/tmp/anximi-uninstall.log 2>/dev/null
  rm -rf "$DATA"
) &
