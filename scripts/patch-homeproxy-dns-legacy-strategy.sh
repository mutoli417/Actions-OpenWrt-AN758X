#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-dns-legacy-strategy.sh —— DNS 规则级 legacy strategy 迁移
#
# 背景：sing-box 1.14 起 DNS 规则动作上的 `strategy` 属 legacy 字段
#   （1.14.0 标记弃用，1.16.0 移除）。当同一配置里同时出现 evaluate/respond、
#   match_response、query_type、ip_version 等新动作/条件时，legacy 模式被禁用，
#   再残留规则级 `strategy: prefer_ipv6` 会触发硬校验错误，`sing-box check` /
#   启动直接被拒（wrong client configuration detected，实例不起）。
#
# 改动：bypass_mainland_china 分支两条国内 DNS 规则上的规则级
#   `strategy: 'prefer_ipv6'` 剥离——
#     1. rule_set: 'geosite-cn' -> china-dns 规则；
#     2. type: 'logical'（geosite-noncn invert + geoip-cn）国内 v6 规则。
#   行为不丢：prefer_ipv6 仍由 china-dns 服务器的 domain_resolver.strategy 承载
#   （stock 生成器第 1 处 prefer_ipv6，本补丁不动）。
#
# 退出码口径（与 v6hybrid / resolver-failover 一致，硬失败及早暴露上游重构）：
#     - 包整体缺失（find 无结果）：::warning:: 跳过，exit 0；
#     - 已打过补丁：幂等跳过，exit 0；
#     - 上游已自行剥离（产物仅剩服务器级一处 prefer_ipv6、无规则级残留）：
#       ::warning:: 跳过，exit 0；
#     - 目标文件存在但规则锚点未命中 / awk 或 mv 失败 / 改写后无变化 /
#       剥离计数不符：::error:: 记录，exit 1 中止构建。
#   用法: bash patch-homeproxy-dns-legacy-strategy.sh [openwrt_dir]
# =============================================================

set -u

RC=0

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

UCS=$(find package/feeds feeds package -name "generate_client.uc" -type f 2>/dev/null | sort -u)

if [ -z "$UCS" ]; then
  echo "::warning::未找到 generate_client.uc，跳过 dns-legacy-strategy 补丁"
  exit 0
fi

for F in $UCS; do
  if grep -q "dns-legacy-strategy: rule-level legacy strategy dropped" "$F" 2>/dev/null; then
    echo "  $F dns-legacy-strategy 补丁已存在，跳过"
    continue
  fi

  if ! grep -q "rule_set: 'geosite-cn'" "$F" 2>/dev/null || ! grep -q "type: 'logical'" "$F" 2>/dev/null; then
    echo "::error::$F 未匹配到国内规则锚点（上游可能已重构），保持原样"
    RC=1
    continue
  fi

  # 上游已自行迁移：仅剩服务器级一处 prefer_ipv6，规则级已无残留 → 跳过
  pref_cnt=$(grep -c "strategy: 'prefer_ipv6'" "$F" 2>/dev/null) || pref_cnt=0
  if [ "$pref_cnt" -le 1 ]; then
    echo "  $F 规则级 legacy strategy 已不存在（上游已迁移），跳过"
    continue
  fi

  BEFORE=$(md5sum "$F" | cut -d' ' -f1)

  AWK_UC="$(mktemp)"
  cat > "$AWK_UC" <<'AWK'
# Hunk：剥离两条国内 DNS 规则上的规则级 legacy strategy；
# 仅在 geosite-cn 规则块与 logical 国内 v6 规则块内生效；
# china-dns 服务器 domain_resolver 内的 strategy 不在这两个块里，原样保留。
/rule_set: 'geosite-cn',?/ { cn_rule = 1; print; next }
/type: 'logical',/ { lg_rule = 1; print; next }

(cn_rule == 1 || lg_rule == 1) && /strategy: 'prefer_ipv6'/ {
  if (match($0, /^\s*/)) indent = substr($0, RSTART, RLENGTH)
  else indent = ""
  print indent "/* dns-legacy-strategy: rule-level legacy strategy dropped; prefer_ipv6 kept on china-dns server domain_resolver */"
  dropped++
  next
}

/\}\);/ { cn_rule = 0; lg_rule = 0; print; next }
{ print }
AWK

  if ! awk -f "$AWK_UC" "$F" > "$F.tmp"; then
    echo "::error::$F awk 生成临时文件失败"
    RC=1
    rm -f "$AWK_UC" "$F.tmp"
    continue
  fi
  if ! mv "$F.tmp" "$F"; then
    echo "::error::$F 临时文件替换失败"
    RC=1
    rm -f "$AWK_UC" "$F.tmp"
    continue
  fi
  rm -f "$AWK_UC"

  # 锚点加固：两处规则级 legacy strategy 都应被剥离；服务器级一处必须保留
  marker_cnt=$(grep -c "dns-legacy-strategy: rule-level legacy strategy dropped" "$F")
  pref_left=$(grep -c "strategy: 'prefer_ipv6'" "$F")

  AFTER=$(md5sum "$F" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    echo "✅ 已打 dns-legacy-strategy 补丁 $F"
    grep -n "dns-legacy-strategy\|prefer_ipv6" "$F" | sed 's/^/  /'
  else
    echo "::error::$F 未匹配到目标行，保持原样"
    RC=1
  fi

  [ "$marker_cnt" -ne 2 ] && { echo "::error::Hunk 剥离计数不符（marker=$marker_cnt，应为 2）$F"; RC=1; }
  [ "$pref_left" -ne 1 ]  && { echo "::error::服务器级 prefer_ipv6 保留计数不符（left=$pref_left，应为 1）$F"; RC=1; }
done

exit "$RC"
