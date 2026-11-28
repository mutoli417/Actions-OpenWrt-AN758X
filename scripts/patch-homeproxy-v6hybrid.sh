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
#   三处改动：
#     1. DNS 全局策略强制 ipv4_only：国内双栈由 china-dns 服务器
#        domain_resolver.strategy=prefer_ipv6 承载；规则级 legacy strategy
#        由 dns-legacy-strategy 补丁剥离（1.16 前必须完成的 schema 迁移）。
#        海外 / 未匹配域名只返回 A 记录。
#     2. route.rules 注入 logical-and 兜底规则：ip_version=6 且不在
#        geoip-cn 规则集 → block-out。必须用 logical 包裹：扁平规则里
#        ip_version 会被 rule_set/invert 匹配语义吞掉，误杀 v4 连接。
#     3. 追加两台境外备用 DNS：在 main-dns（TCP 8.8.8.8，detour main-out）之后
#        依次追加 main-dns-alt（TCP 1.1.1.1）、main-dns-alt2（TCP 8.8.4.4），
#        均同走 main-out、共用 default-dns 域解析器；final 仍指向 main-dns。
#        注：sing-box 配置层不做按服务器顺序的自动逐级转移，备用服务器必须由
#        规则显式引用；真正的并行兜底由 resolver-failover 补丁的
#        evaluate/respond+race 提供，缓解主上游经节点间歇 EOF/RST/deadline。
#
#   退出码口径（硬失败，及早暴露上游重构 / 写入异常）：
#     - 包整体缺失（find 无结果）：::warning:: 跳过，exit 0；
#     - 已打过补丁：幂等跳过，exit 0；
#     - 目标文件存在但锚点未命中 / awk 或 mv 失败 / 改写后无变化 / 任一
#       hunk 标记未落入产物：::error:: 记录，exit 1 中止构建。
#   用法: bash patch-homeproxy-v6hybrid.sh [openwrt_dir]
# =============================================================

set -u

RC=0

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
    echo "::error::$F 未匹配到上游 DNS 策略行（上游可能已重构），保持原样"
    RC=1
    continue
  fi

  BEFORE=$(md5sum "$F" | cut -d' ' -f1)

  # 锚点命中计数：patch 后逐项校验，未命中显式报错，避免上游重构后静默漏打
  hit_a=0; hit_b=0; hit_c=0

  AWK_UC="$(mktemp)"
  cat > "$AWK_UC" <<'AWK'
# Hunk A：全局 DNS 策略强制 ipv4_only
/dns_default_strategy = \(ipv6_support !== '1'\) \? 'ipv4_only' : null;/ {
  print "\tdns_default_strategy = 'ipv4_only'; /* v6hybrid: overseas v4-only; CN dual-stack kept via china-dns server domain_resolver */"
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

# Hunk C：main-dns 之后追加两级备用境外 DNS（同走 main-out 节点）
/config\.dns\.final = 'main-dns';/ {
  print
  print ""
  print "/* v6hybrid-dns-alt: standby overseas DNS over main-out; referenced by resolver-failover race rules */"
  print "push(config.dns.servers, {"
  print "\ttag: 'main-dns-alt',"
  print "\tdomain_resolver: {"
  print "\t\tserver: 'default-dns',"
  print "\t\tstrategy: (ipv6_support !== '1') ? 'ipv4_only' : null"
  print "\t},"
  print "\tdetour: 'main-out',"
  print "\ttype: 'tcp',"
  print "\tserver: '1.1.1.1'"
  print "});"
  print ""
  print "/* v6hybrid-dns-alt2: second backup overseas DNS over main-out */"
  print "push(config.dns.servers, {"
  print "\ttag: 'main-dns-alt2',"
  print "\tdomain_resolver: {"
  print "\t\tserver: 'default-dns',"
  print "\t\tstrategy: (ipv6_support !== '1') ? 'ipv4_only' : null"
  print "\t},"
  print "\tdetour: 'main-out',"
  print "\ttype: 'tcp',"
  print "\tserver: '8.8.4.4'"
  print "});"
  next
}

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

  # 锚点加固：检查三处 hunk 标记是否都落进产物
  grep -q "v6hybrid: overseas v4-only" "$F" && hit_a=1
  grep -q "v6hybrid-guard" "$F" && hit_b=1
  grep -q "v6hybrid-dns-alt" "$F" && hit_c=1

  AFTER=$(md5sum "$F" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    echo "✅ 已打 v6hybrid 补丁 $F"
    grep -n "v6hybrid" "$F" | sed 's/^/  /'
  else
    echo "::error::$F 未匹配到目标行，保持原样"
    RC=1
  fi

  [ "$hit_a" -ne 1 ] && { echo "::error::Hunk A (dns_default_strategy ipv4_only) 未命中 $F"; RC=1; }
  [ "$hit_b" -ne 1 ] && { echo "::error::Hunk B (v6 guard block-out) 未命中 $F"; RC=1; }
  [ "$hit_c" -ne 1 ] && { echo "::error::Hunk C (main-dns-alt 备用 DNS) 未命中 $F"; RC=1; }
  if [ "$hit_a" -ne 1 ] || [ "$hit_b" -ne 1 ] || [ "$hit_c" -ne 1 ]; then
    echo "::error::$F 存在未命中锚点，请核对上游 generate_client.uc 是否重构"
  fi
done

exit "$RC"
