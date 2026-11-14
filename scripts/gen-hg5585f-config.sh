#!/bin/bash
set -euo pipefail
WS="${GITHUB_WORKSPACE:-.}"
PROFILE="${PROFILE:-fiberhome_hg5585f-ct}"

case "$PROFILE" in
  fiberhome_hg5382a)
    DEVICE="fiberhome_hg5382a"
    CFG="configs/fiberhome_hg5382a.config"
    ;;
  fiberhome_hg5585f-ct|*)
    DEVICE="fiberhome_hg5585f-ct"
    CFG="configs/fiberhome_hg5585f-ct.config"
    ;;
esac

echo "== 生成配置: $DEVICE =="

# B-M11: subtarget 不再写死 an7581。先从现有 .config 读取已选 subtarget
#   （an7581 / an7583 …），读不到再回退 an7581，避免 7583 机型套错 an7581 目录。
SUBTARGET="$(grep -m1 '^CONFIG_TARGET_SUBTARGET=' .config 2>/dev/null | cut -d= -f2 | tr -d '\"')"
SUBTARGET="${SUBTARGET:-an7581}"
echo "  subtarget: $SUBTARGET"

# 先清除所有机型配置，只保留目标机型（避免全机型编译）
sed -i '/CONFIG_TARGET_DEVICE_/d; /^CONFIG_TARGET_MULTI_PROFILE=/d' .config

{
  echo "CONFIG_TARGET_MULTI_PROFILE=y"
  echo "CONFIG_TARGET_DEVICE_airoha_${SUBTARGET}_DEVICE_${DEVICE}=y"
  echo "CONFIG_TARGET_DEVICE_PACKAGES_airoha_${SUBTARGET}_DEVICE_${DEVICE}=\"\""
} >> .config

if [ -f "$WS/$CFG" ]; then
  cat "$WS/$CFG" >> .config
  echo "✅ 已追加 $CFG"
else
  echo "::warning::未找到 $WS/$CFG"
fi
