#!/bin/bash
# 校验 DOUY.dylib 是否是可注入的 iOS arm64 动态库
# 用法：./scripts/verify.sh build/DOUY.dylib
set -euo pipefail

FILE="${1:-DOUY.dylib}"

if [ ! -f "$FILE" ]; then
  echo "::error::找不到产物 $FILE"
  exit 1
fi

echo "== file =="
file "$FILE"

echo "== Mach-O header =="
otool -hv "$FILE"

echo "== install name / 依赖 =="
otool -L "$FILE"

echo "== LC_BUILD_VERSION =="
otool -l "$FILE" | grep -A6 "LC_BUILD_VERSION" || true

fail=0

# 1) 必须是 arm64 的动态库
if ! file "$FILE" | grep -q "Mach-O 64-bit dynamically linked shared library arm64"; then
  echo "::error::不是 arm64 动态库"
  fail=1
fi

# 2) 必须没有 LC_CODE_SIGNATURE 之外的问题：至少要能被 ldid/codesign 重签
if ! codesign -dv "$FILE" 2>&1 | grep -q "Signature=adhoc"; then
  echo "::warning::不是 ad-hoc 签名（注入器通常会重签，不致命）"
fi

# 3) 不能含可选依赖缺失（otool -L 里不应出现 @rpath 之外的第三方）
if otool -L "$FILE" | grep -Ei "ffmpeg|avcodec|boost|gstreamer" ; then
  echo "::error::引入了不应存在的第三方依赖"
  fail=1
fi

# 4) 架构数量
ARCHS=$(lipo -archs "$FILE" 2>/dev/null || echo unknown)
echo "== archs: $ARCHS =="
if [ "$ARCHS" != "arm64" ]; then
  echo "::warning::期望单架构 arm64，实际 $ARCHS"
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::产物校验失败"
  exit 1
fi

echo "== 校验通过：可注入的 arm64 iOS 动态库 =="
