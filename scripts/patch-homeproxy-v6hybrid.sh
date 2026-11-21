#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-v6hybrid.sh —— HomeProxy 混合双栈补丁
#
#   目标：国内域名 v4+v6 直连，海外域名压制 AAAA（仅 v4 进代理），
#   漏网的非 CN IPv6 连接失败闭合阻断，不回落直连。
#
#   背景：bypass_mainland_china + 主节点模式下，UCI 自定义
#   dns_rule / routing_rule / ruleset 段被生成器分支跳过，stock UCI
#   配不出该策略；需在编译树源码层改 generate_client.uc。
#
#   两处改动：
#     1. DNS 全局策略强制 ipv4_only：国内两条内置规则显式 prefer_ipv6
#        覆盖全局，国内双栈保留；海外 / 未匹配域名只返回 A 记录。
#     2. route.rules 注入 logical-and 兜底规则：ip_version=6 且不在
#        geoip-cn 规则集 → block-out。必须用 logical 包裹：扁平规则里
#        ip_version 会被 rule_set/invert 匹配语义吞掉，误杀 v4 连接。
#
#   幂等：重复执行跳过；包缺失 / 未匹配只警告，不阻断构建。
#   用法: bash patch-homeproxy-v6hybrid.sh [openwrt_dir]
# =============================================================

set -u

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

UCS=$(find package/feeds feeds package -name "generate_client.uc" -type f 2>/dev/null | sort -u)

if [ -z "$UCS" ]; then
  echo "::warning::未找到 generate_client.uc，跳过 v6hybrid 补丁"
  exit 0
fi

for F in $UCS; do
  if grep -q "v6hybrid" "$F" 2>/dev/null; then
    echo "  $F v6hybrid 补丁已存在，跳过"
    continue
  fi

  if ! grep -q "dns_default_strategy = (ipv6_support !== '1')" "$F" 2>/dev/null; then
    echo "::warning::$F 未匹配到上游 DNS 策略行，保持原样"
    continue
  fi

  BEFORE=$(md5sum "$F" | cut -d' ' -f1)

  AWK_UC="$(mktemp)"
  cat > "$AWK_UC" <<'AWK'
# Hunk A：全局 DNS 策略强制 ipv4_only
/dns_default_strategy = \(ipv6_support !== '1'\) \? 'ipv4_only' : null;/ {
  print "\tdns_default_strategy = 'ipv4_only'; /* v6hybrid: overseas v4-only; CN rules keep prefer_ipv6 */"
  next
}

# Hunk B：在 config.route 初始化块结束后注入 v6 兜底规则
/default_interface: default_interface$/ { prev_defif = 1; print; next }
prev_defif && /^};$/ {
  print
  print ""
  print "/* v6hybrid-guard: block non-CN IPv6, fail closed; CN v6 direct via nft bypass */"
  print "push(config.route.rules, {"
  print "\ttype: 'logical',"
  print "\tmode: 'and',"
  print "\trules: ["
  print "\t\t{ ip_version: 6 },"
  print "\t\t{ rule_set: ['geoip-cn'], invert: true }"
  print "\t],"
  print "\taction: 'route',"
  print "\toutbound: 'block-out'"
  print "});"
  prev_defif = 0
  next
}

{ print }
AWK

  awk -f "$AWK_UC" "$F" > "$F.tmp" && mv "$F.tmp" "$F"
  rm -f "$AWK_UC"

  AFTER=$(md5sum "$F" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    echo "✅ 已打 v6hybrid 补丁 $F"
    grep -n "v6hybrid" "$F" | sed 's/^/  /'
  else
    echo "::warning::$F 未匹配到目标行，保持原样"
  fi
done

exit 0
