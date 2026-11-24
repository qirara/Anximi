#!/system/bin/sh
# 模块「操作」按钮（KernelSU / APatch / Magisk 28+）：没有 WebUI 时快速应用或还原
MODDIR=${0%/*}
ANX="$MODDIR/anximi.sh"
export ANX_MODDIR=$MODDIR
echo "Anximi 操作：音量+ 应用当前配置，音量- 全部还原（10 秒内无操作则只显示状态）"
key=""
if command -v getevent >/dev/null 2>&1; then
  key=$(timeout 10 getevent -qlc 1 2>/dev/null | awk '/KEY_VOLUME(UP|DOWN)/ {print $3; exit}')
fi
case "$key" in
  KEY_VOLUMEUP) sh "$ANX" apply ;;
  KEY_VOLUMEDOWN) sh "$ANX" revert ;;
  *) sh "$ANX" status ;;
esac
