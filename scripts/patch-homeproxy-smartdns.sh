#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-smartdns.sh —— B 方案 SmartDNS 5334 统一递归引擎接入
#
# 背景：resolver-failover 之后，本机 DNS 仍由 sing-box 5333 承接（main-dns
#   race）。本补丁把本地 SmartDNS（绑 127.0.0.1:5334，回环，不碰 53/LAN/WAN）
#   作为可选的统一递归引擎接入：编译期编入 smartdns 主包，运行期由 UCI 开关
#   homeproxy.config.smartdns_enabled 控制是否切换；默认关，保持 5333 主路径。
#
# 已核实 sing-box 1.14.3 字段（option/dns.go）：DNS 服务器支持 type/tag/server/
#   server_port/detour/domain_resolver；server 为单 tag 标量，无解析器组/自动接力。
#
# 改动（generator UC 层）：
#   H1：声明运行期开关 smartdns_enabled（uci.get homeproxy.config）。
#   H2：追加 local-dns DNS 服务器（UDP 127.0.0.1:5334，direct-out 绕行）。
#   H3：main-out endpoint/outbound 的 domain_resolver 改为条件选择：
#       开关开 → local-dns；关 → 既有 direct-dns-alt（A 补丁备用直连 DNS）。
#
# 改动（init.d/homeproxy 层）：
#   I1：读取 smartdns_enabled 开关。
#   I2：开关开时，dnsmasq 注入的 redirect-dns.conf 上游由 #$dns_port(5333)
#       改写为 #5334；开关关则原样保留。注入 conf 由 homeproxy 启动时生成，
#       本补丁只在生成后按开关 sed 改写，不动 dnsmasq 本体与 LAN DHCP。
#
# 退出码口径（硬失败，同其余 homeproxy 补丁）：
#   包整体缺失：::warning:: 跳过，exit 0；已打补丁：幂等 exit 0；
#   锚点未命中 / awk 或 mv 失败 / 改写无变化 / hunk 标记未落产物：
#   ::error:: 记录，exit 1 中止构建。
# 用法: bash patch-homeproxy-smartdns.sh [openwrt_dir]
# =============================================================

set -u

RC=0

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

UCS=$(find package/feeds feeds package -name "generate_client.uc" -type f 2>/dev/null | sort -u)

if [ -z "$UCS" ]; then
  echo "::warning::未找到 generate_client.uc，跳过 smartdns 接入补丁"
else
  for F in $UCS; do
    if grep -q "smartdns-local-dns" "$F" 2>/dev/null; then
      echo "  $F smartdns 接入补丁已存在，跳过"
      continue
    fi

    # H3 依赖 A 补丁注入的 direct-dns-alt 解析器；缺失说明补丁顺序被打乱，硬失败
    if ! grep -q "direct-dns-alt" "$F" 2>/dev/null; then
      echo "::error::$F 缺少 direct-dns-alt（resolver-failover 未先应用），保持原样"
      RC=1
      continue
    fi

    if ! grep -q "const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support')" "$F" 2>/dev/null; then
      echo "::error::$F 未匹配到 UCI 变量声明锚点（上游可能已重构），保持原样"
      RC=1
      continue
    fi

    BEFORE=$(md5sum "$F" | cut -d' ' -f1)

    hit_h1=0; hit_h2=0; hit_h3=0

    AWK_UC="$(mktemp)"
    cat > "$AWK_UC" <<'AWK'
# H1：声明 smartdns 开关（紧跟 ipv6_support 声明行之后）
/^const ipv6_support = uci\.get\(uciconfig, ucimain, 'ipv6_support'\)/ {
  print
  print "const smartdns_enabled = uci.get(uciconfig, ucimain, 'smartdns_enabled') || '0'; /* smartdns-local-dns: B 方案统一递归引擎开关 */"
  hit_h1 = 1
  next
}

# H2：direct-dns-alt 服务器块闭合后追加 local-dns（UDP 127.0.0.1:5334）
/^[ \t]*tag: 'direct-dns-alt',/ { in_alt = 1 }
in_alt && /\}\);/ {
  print
  print ""
  print "\t/* smartdns-local-dns: local SmartDNS recursion engine on loopback 5334 */"
  print "\tpush(config.dns.servers, {"
  print "\t\ttag: 'local-dns',"
  print "\t\ttype: 'udp',"
  print "\t\tserver: '127.0.0.1',"
  print "\t\tserver_port: 5334,"
  print "\t\tdetour: self_mark ? 'direct-out' : null"
  print "\t});"
  in_alt = 0
  hit_h2 = 1
  next
}

# H3：main-out 解析器按开关在 local-dns 与 direct-dns-alt 间选择
/server: 'direct-dns-alt',/ {
  print "\t\tserver: (smartdns_enabled === '1') ? 'local-dns' : 'direct-dns-alt',"
  hit_h3 = 1
  next
}

{ print }
AWK

    if ! awk -v hit_h1=0 -v hit_h2=0 -v hit_h3=0 -f "$AWK_UC" "$F" > "$F.tmp"; then
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

    grep -q "smartdns-local-dns: B 方案" "$F" && hit_h1=1
    grep -q "tag: 'local-dns'" "$F" && hit_h2=1
    grep -q "smartdns_enabled === '1') ? 'local-dns'" "$F" && hit_h3=1

    AFTER=$(md5sum "$F" | cut -d' ' -f1)
    if [ "$BEFORE" != "$AFTER" ]; then
      echo "✅ 已打 smartdns 接入补丁 $F"
    else
      echo "::error::$F 未匹配到目标行，保持原样"
      RC=1
    fi

    [ "$hit_h1" -ne 1 ] && { echo "::error::H1 (smartdns_enabled 开关声明) 未命中 $F"; RC=1; }
    [ "$hit_h2" -ne 1 ] && { echo "::error::H2 (local-dns 5334 服务器) 未命中 $F"; RC=1; }
    [ "$hit_h3" -ne 1 ] && { echo "::error::H3 (main-out 解析器条件选择) 未命中 $F"; RC=1; }
  done
fi

# ---------- init.d/homeproxy：dnsmasq 上游按开关改指 5334 ----------
INIT_CANDIDATES=$(find package/feeds feeds package -type f \( -name "homeproxy" -o -name "homeproxy.init" \) 2>/dev/null | sort -u)
INITS=""
for C in $INIT_CANDIDATES; do
  grep -q 'procd_open_instance "sing-box-c"' "$C" 2>/dev/null && INITS="$INITS $C"
done

if [ -z "$INITS" ]; then
  if [ -n "$UCS" ]; then
    echo "::error::未找到 homeproxy init 脚本（上游可能已重构），跳过 5334 上游改写"
    RC=1
  else
    echo "::warning::未找到 homeproxy init 脚本，跳过 5334 上游改写"
  fi
else
  for F in $INITS; do
    if grep -q "smartdns-5334" "$F" 2>/dev/null; then
      echo "  $F 5334 上游改写已加固，跳过"
      continue
    fi

    if ! grep -q 'config_get dns_port "infra" "dns_port" "5333"' "$F" 2>/dev/null; then
      echo "::error::$F 未匹配到 dns_port 锚点（上游可能已重构），保持原样"
      RC=1
      continue
    fi

    BEFORE=$(md5sum "$F" | cut -d' ' -f1)
    hit_i1=0; hit_i2=0

    AWK_INIT="$(mktemp)"
    cat > "$AWK_INIT" <<'AWK'
# I1：读取 smartdns_enabled 开关（紧跟 dns_port 读取行）
/^[ \t]*config_get dns_port "infra" "dns_port" "5333"/ {
  print
  print "\tlocal smartdns_enabled"
  print "\tconfig_get smartdns_enabled \"config\" \"smartdns_enabled\" \"0\""
  hit_i1 = 1
  next
}

# I2：dnsmasq 重启前，开关开则把注入上游从 #dns_port 改指 #5334
/^[ \t]*\/etc\/init\.d\/dnsmasq restart/ {
  print "\t# smartdns-5334: 开关开时 dnsmasq 上游改指本地 SmartDNS 5334；默认关，保持 5333 回退"
  print "\tif [ \"$smartdns_enabled\" = \"1\" ]; then"
  print "\t\tsed -i \"s|server=127.0.0.1#$dns_port|server=127.0.0.1#5334|\" \"$DNSMASQ_DIR/redirect-dns.conf\""
  print "\tfi"
  hit_i2 = 1
  print
  next
}

{ print }
AWK

    if ! awk -f "$AWK_INIT" "$F" > "$F.tmp"; then
      echo "::error::$F awk 生成临时文件失败"
      RC=1
      rm -f "$AWK_INIT" "$F.tmp"
      continue
    fi
    if ! mv "$F.tmp" "$F"; then
      echo "::error::$F 临时文件替换失败"
      RC=1
      rm -f "$AWK_INIT" "$F.tmp"
      continue
    fi
    # mktemp 临时文件不带执行位，mv 覆盖会丢掉 init 脚本 +x，补回
    chmod +x "$F"
    rm -f "$AWK_INIT"

    grep -q 'config_get smartdns_enabled "config" "smartdns_enabled"' "$F" && hit_i1=1
    grep -q "smartdns-5334" "$F" && hit_i2=1

    AFTER=$(md5sum "$F" | cut -d' ' -f1)
    if [ "$BEFORE" != "$AFTER" ]; then
      echo "✅ 已加固 $F：smartdns 开关读取 + 5334 上游条件改写"
    else
      echo "::error::init 未匹配到目标行，$F 保持原样"
      RC=1
    fi

    [ "$hit_i1" -ne 1 ] && { echo "::error::I1 (smartdns_enabled 读取) 未命中 $F"; RC=1; }
    [ "$hit_i2" -ne 1 ] && { echo "::error::I2 (5334 上游条件改写) 未命中 $F"; RC=1; }
  done
fi

exit "$RC"
