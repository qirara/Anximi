#!/bin/sh
# 打包模块 zip：sh build.sh  ->  out/Anximi-<version>.zip
set -e
cd "$(dirname "$0")"
v=$(sed -n 's/^version=//p' module.prop)
mkdir -p out
rm -f "out/Anximi-$v.zip"
zip -r9 "out/Anximi-$v.zip" \
  META-INF module.prop customize.sh post-fs-data.sh service.sh action.sh uninstall.sh \
  anximi.sh lists defaults webroot system/bin LICENSE README.md \
  -x '*/.DS_Store'
echo "out/Anximi-$v.zip"
