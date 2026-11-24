#!/system/bin/sh
# 安装脚本（Magisk / KernelSU / APatch 通用）
# shellcheck disable=SC2034  # 由安装器读取
SKIPUNZIP=0
DATA=/data/adb/anximi

ui_print "- Anximi 隐私模块"
if [ "$KSU" = true ]; then ui_print "- Root: KernelSU ($KSU_VER_CODE)"
elif [ "$APATCH" = true ]; then ui_print "- Root: APatch ($APATCH_VER_CODE)"
else ui_print "- Root: Magisk ($MAGISK_VER_CODE)"; fi

[ "$API" -lt 30 ] && ui_print "! 警告: 仅在 Android 11+ 上测试过设计"

mkdir -p "$DATA/state" "$DATA/run" "$DATA/logs" "$DATA/export"
for f in config.conf packages.conf custom.list custom.hosts allow.hosts components.conf; do
  if [ -f "$DATA/$f" ]; then
    ui_print "- 保留现有 $f"
  else
    cp -f "$MODPATH/defaults/$f" "$DATA/$f"
  fi
done

# 安装时先放一个默认 hosts，保证开机即被挂载；之后内容由 anximi.sh 原地改写
mkdir -p "$MODPATH/system/etc"
printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$MODPATH/system/etc/hosts"
if grep -q '^hosts=0' "$DATA/config.conf" 2>/dev/null; then
  rm -f "$MODPATH/system/etc/hosts"
  ui_print "- 配置 hosts=0，不挂载 hosts"
fi

md=$(getprop ro.product.mod_device)
ui_print "- 设备: $(getprop ro.product.device) / $md"
ui_print "- 系统: $(getprop ro.mi.os.version.name) Android $(getprop ro.build.version.release)"

if [ -d /data/adb/modules/Surfing ] || [ -d /data/adb/box_bll ]; then
  ui_print "- 检测到 Surfing：Anximi 只用 filter 表自有链 ANXIMI_OUT，不碰 mangle/nat/路由标记，可共存"
fi
for m in /data/adb/modules/*/system/etc/hosts; do
  case "$m" in */anximi/*) continue ;; esac
  [ -f "$m" ] && ui_print "! 另一个模块也挂载 hosts: ${m%/system/etc/hosts}，可在配置中设 hosts=0"
done

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in anximi.sh service.sh post-fs-data.sh action.sh uninstall.sh system/bin/anximi; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
rm -rf "$MODPATH/tests" "$MODPATH/docs" "$MODPATH/.github" "$MODPATH/build.sh"

ui_print "- 安装完成。重启后打开 KernelSU 模块页的 WebUI 选择分类，然后点「应用」。"
ui_print "- 未应用前模块不会改动任何东西。Magisk 用户可用模块的「操作」按钮或终端 anximi。"
