#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-resolver-failover.sh —— 出站节点域名解析冗余加固（B 方案）
#
# 背景：bypass 模式下，主节点出站域名（如 productandservice.infralinkplus.com）
#   在拨号前由 route.default_domain_resolver 解析，当前指向 china-dns
#   （223.5.5.5 UDP 直连）。该直连 DNS 间歇丢包时，节点域名 lookup 直接
#   deadline，连带 main-out 拨号失败。
#
# 已核实 sing-box 1.14.3 语义（源码 dns/router.go、client.go、transport_manager.go、
# option/rule_action.go，1.14.0 与 master 一致）：
#   · 配置层不提供多服务器自动转移：Exchange 单次只发往一条 transport，出错直接
#     返回，无 next-server 链；server / domain_resolver 均为单个 tag（非数组）。
#   · evaluate/respond + race 是源码中唯一的并行兜底机制：多条 evaluate 并发
#     发起 future，respond 竞态规则取首个 settled 的有效响应。它只覆盖规则驱动
#     的入站 DNS 查询；出站 inner 解析不走规则 walk，evaluate/respond 管不到。
#
# 改动：
#   Hunk A：config.dns 初始化块结束后追加备用直连 DNS direct-dns-alt
#     （TCP 119.29.29.29，direct-out；TCP 经受 UDP 53 丢包的能力强于单 UDP 报文）。
#   Hunk B：给 main-out 的 endpoint / outbound 显式挂 domain_resolver =
#     direct-dns-alt（带 timeout 3s，失败快速浮出便于重试），把节点域名解析从
#     china-dns 关键路径上剥离；请求域名的国内/海外分流仍走
#     default_domain_resolver，行为不变。
#   注：配置层解析器仍是单 tag（源码 Server 为标量，无第二解析器/组/自动接力），
#     本 hunk 只能在单 tag 内叠加显式超时与 TCP 传输，配不出多上游切换。
#   Hunk C：对 proxy-domain 境外查询接入 evaluate/respond+race 三路并行
#     （main-dns / main-dns-alt / main-dns-alt2），取首条有效响应；三台备用
#     服务器由 v6hybrid 补丁定义，本补丁只补规则引用。
#
# 退出码口径（硬失败，同 v6hybrid）：
#   包整体缺失：::warning:: 跳过，exit 0；已打补丁：幂等 exit 0；
#   锚点未命中 / awk 或 mv 失败 / 改写后无变化 / hunk 标记未落入产物：
#   ::error:: 记录，exit 1 中止构建。
# 用法: bash patch-homeproxy-resolver-failover.sh [openwrt_dir]
# =============================================================

set -u

RC=0

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

UCS=$(find package/feeds feeds package -name "generate_client.uc" -type f 2>/dev/null | sort -u)

if [ -z "$UCS" ]; then
  echo "::warning::未找到 generate_client.uc，跳过 resolver-failover 补丁"
  exit 0
fi

for F in $UCS; do
  if grep -q "resolver-failover" "$F" 2>/dev/null; then
    echo "  $F resolver-failover 补丁已存在，跳过"
    continue
  fi

  if ! grep -q "client_subnet: dns_client_subnet" "$F" 2>/dev/null; then
    echo "::error::$F 未匹配到上游 DNS 初始化锚点（上游可能已重构），保持原样"
    RC=1
    continue
  fi

  # Hunk C 依赖 v6hybrid 定义的两台境外备用 DNS；缺失则规则会悬空，直接硬失败
  if ! grep -q "main-dns-alt2" "$F" 2>/dev/null; then
    echo "::error::$F 缺少 main-dns-alt2（v6hybrid 备用境外 DNS 未先应用），保持原样"
    RC=1
    continue
  fi

  BEFORE=$(md5sum "$F" | cut -d' ' -f1)

  # 锚点命中计数：patch 后逐项校验，未命中显式报错，避免上游重构后静默漏打
  hit_a=0; hit_b_ep=0; hit_b_ob=0; hit_c=0

  AWK_UC="$(mktemp)"
  cat > "$AWK_UC" <<'AWK'
# Hunk A：config.dns 初始化块结束后追加备用直连 DNS
/client_subnet: dns_client_subnet$/ { prev_dns = 1; print; next }
prev_dns && /^};$/ {
  print
  print ""
  print "/* resolver-failover: backup direct resolver (TCP, rides out UDP 53 loss) for outbound node domain */"
  print "push(config.dns.servers, {"
  print "\ttag: 'direct-dns-alt',"
  print "\ttype: 'tcp',"
  print "\tserver: '119.29.29.29',"
  print "\tdetour: self_mark ? 'direct-out' : null"
  print "});"
  prev_dns = 0
  next
}

# Hunk B1：wireguard 端点挂显式解析器
/config\.endpoints\[length\(config\.endpoints\)-1\]\.tag = 'main-out';/ {
  print
  print "\tconfig.endpoints[length(config.endpoints)-1].domain_resolver = {"
  print "\t\tserver: 'direct-dns-alt',"
  print "\t\ttimeout: '3s',"
  print "\t\tstrategy: (ipv6_support !== '1') ? 'ipv4_only' : null"
  print "\t};"
  next
}

# Hunk B2：普通出站挂显式解析器
/config\.outbounds\[length\(config\.outbounds\)-1\]\.tag = 'main-out';/ {
  print
  print "\tconfig.outbounds[length(config.outbounds)-1].domain_resolver = {"
  print "\t\tserver: 'direct-dns-alt',"
  print "\t\ttimeout: '3s',"
  print "\t\tstrategy: (ipv6_support !== '1') ? 'ipv4_only' : null"
  print "\t};"
  next
}

# Hunk C：proxy-domain 境外查询三路并行 race（evaluate/respond+race）
# 锚点：proxy-domain -> main-dns 的 route 规则块，在其闭合 }); 之后注入
/server: 'main-dns'$/ { pending_race = 1; print; next }
pending_race && /\}\);$/ {
  print
  print ""
  print "\t\t/* resolver-failover: parallel overseas DNS race (evaluate/respond+race); first valid response wins */"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\taction: 'evaluate',"
  print "\t\t\t\tserver: 'main-dns',"
  print "\t\t\t\ttag: 'odns-1',"
  print "\t\t\t\tspeculative: true"
  print "\t\t\t});"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\taction: 'evaluate',"
  print "\t\t\t\tserver: 'main-dns-alt',"
  print "\t\t\t\ttag: 'odns-2',"
  print "\t\t\t\tspeculative: true"
  print "\t\t\t});"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\taction: 'evaluate',"
  print "\t\t\t\tserver: 'main-dns-alt2',"
  print "\t\t\t\ttag: 'odns-3',"
  print "\t\t\t\tspeculative: true"
  print "\t\t\t});"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\tmatch_response: 'odns-1',"
  print "\t\t\t\taction: 'respond',"
  print "\t\t\t\trace: true"
  print "\t\t\t});"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\tmatch_response: 'odns-2',"
  print "\t\t\t\taction: 'respond',"
  print "\t\t\t\trace: true"
  print "\t\t\t});"
  print "\t\tif (length(proxy_domain_list))"
  print "\t\t\tpush(config.dns.rules, {"
  print "\t\t\t\trule_set: 'proxy-domain',"
  print "\t\t\t\tmatch_response: 'odns-3',"
  print "\t\t\t\taction: 'respond',"
  print "\t\t\t\trace: true"
  print "\t\t\t});"
  pending_race = 0
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

  # 锚点加固：检查四处 hunk 标记是否都落进产物
  grep -q "resolver-failover: backup direct resolver" "$F" && hit_a=1
  grep -q "config.endpoints\[length(config.endpoints)-1\].domain_resolver" "$F" && hit_b_ep=1
  grep -q "config.outbounds\[length(config.outbounds)-1\].domain_resolver" "$F" && hit_b_ob=1
  grep -q "resolver-failover: parallel overseas DNS race" "$F" && hit_c=1

  AFTER=$(md5sum "$F" | cut -d' ' -f1)
  if [ "$BEFORE" != "$AFTER" ]; then
    echo "✅ 已打 resolver-failover 补丁 $F"
    grep -n "resolver-failover\|direct-dns-alt\|odns-" "$F" | sed 's/^/  /'
  else
    echo "::error::$F 未匹配到目标行，保持原样"
    RC=1
  fi

  [ "$hit_a" -ne 1 ]    && { echo "::error::Hunk A (direct-dns-alt 备用直连 DNS) 未命中 $F"; RC=1; }
  [ "$hit_b_ep" -ne 1 ] && { echo "::error::Hunk B1 (main-out endpoint domain_resolver) 未命中 $F"; RC=1; }
  [ "$hit_b_ob" -ne 1 ] && { echo "::error::Hunk B2 (main-out outbound domain_resolver) 未命中 $F"; RC=1; }
  [ "$hit_c" -ne 1 ]    && { echo "::error::Hunk C (evaluate/respond overseas DNS race) 未命中 $F"; RC=1; }
  if [ "$hit_a" -ne 1 ] || [ "$hit_b_ep" -ne 1 ] || [ "$hit_b_ob" -ne 1 ] || [ "$hit_c" -ne 1 ]; then
    echo "::error::$F 存在未命中锚点，请核对上游 generate_client.uc 是否重构"
  fi
done

exit "$RC"
