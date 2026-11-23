#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-local-ruleset.sh —— HomeProxy 本地规则集 + jail 挂载 + 崩溃重试加固
#
#   背景：bypass_mainland_china 模式下，上游 homeproxy 默认把 geoip-cn /
#     geosite-cn / geosite-noncn 三个规则集配成 remote，开机由 main-out 联网
#     拉取 jsdelivr 名单。路由器直连 jsdelivr 优先走 IPv6，链路被重置时下载
#     0 字节；规则集缺失会让 sing-box 配置校验失败并进入崩溃循环，dnsmasq
#     又把 DNS 转发到已死的本地 5333，最终所有客户端能 ping IP 却打不开网页。
#
#   三项改动（与真机 overlay 加固一致，进编译源码后刷机不丢）：
#     1. generate_client.uc：三个内置规则集 remote → local，读取
#        $HP_DIR/ruleset/<tag>.srs 本地二进制快照；用户自定义规则集（uci
#        foreach 段）保持 remote 不动。
#     2. init.d/homeproxy：客户端实例 jail 补挂 $HP_DIR/ruleset/ 目录，
#        否则 ujail 隔离下 sing-box 读不到本地规则集。
#     3. 仅客户端实例（sing-box-c）procd respawn 放宽为 3600 10 10：
#        1 小时内最多崩溃 10 次、稳定 10 秒才算一次；服务器实例与 log-cleaner
#        维持裸 respawn 不变。
#
#   退出码口径（硬失败，及早暴露上游重构 / 写入异常）：
#     - 包整体缺失（find 无结果）：::warning:: 跳过，exit 0；
#     - 已打过补丁：幂等跳过，exit 0；
#     - 目标文件存在但锚点未命中 / awk 或 mv 失败 / 改写后无变化 / 残留
#       remote 下载地址：::error:: 记录，exit 1 中止构建。
#   用法: bash patch-homeproxy-local-ruleset.sh [openwrt_dir]
# =============================================================

set -u

RC=0

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

BUILTIN_TAGS="geoip-cn geosite-cn geosite-noncn"

# ---------- 1. generate_client.uc：remote 规则集改本地 ----------
UCS=$(find package/feeds feeds package -name "generate_client.uc" -type f 2>/dev/null | sort -u)

if [ -z "$UCS" ]; then
  echo "::warning::未找到 generate_client.uc，跳过本地规则集补丁"
else
  for F in $UCS; do
    if grep -q "ruleset/geoip-cn.srs" "$F" 2>/dev/null; then
      echo "  $F 规则集已本地化，跳过"
      continue
    fi
    if ! grep -q "type: 'remote'" "$F" 2>/dev/null; then
      echo "::error::$F 未匹配到 remote 规则集（上游可能已重构），保持原样"
      RC=1
      continue
    fi

    BEFORE=$(md5sum "$F" | cut -d' ' -f1)

    AWK_UC="$(mktemp)"
    cat > "$AWK_UC" <<'AWK'
BEGIN {
  n = split("geoip-cn geosite-cn geosite-noncn", T, " ")
  for (i = 1; i <= n; i++) B[T[i]] = 1
}
skip > 0 { skip--; next }
/type: 'remote'/ { inremote = 1; next }
inremote && /tag: '/ {
  tag = $0
  sub(/^[^']*'/, "", tag)
  sub(/'.*$/, "", tag)
  inremote = 0
  if (tag in B) {
    ind = $0
    sub(/[^ \t].*$/, "", ind)
    printf "%stype: 'local',\n", ind
    printf "%stag: '%s',\n", ind, tag
    printf "%sformat: 'binary',\n", ind
    printf "%spath: HP_DIR + '/ruleset/%s.srs'\n", ind, tag
    skip = 3   # 原 format / url / download_detour 三行不再输出
    next
  }
  print
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

    AFTER=$(md5sum "$F" | cut -d' ' -f1)
    if [ "$BEFORE" != "$AFTER" ]; then
      echo "✅ 已将 $F 三个内置规则集改为本地 .srs"
      if grep -n "fastly.jsdelivr.net" "$F" | grep -E "geoip-cn|geosite-cn|geosite-noncn"; then
        echo "::error::$F 仍残留内置规则集 remote 下载地址，见上方行号"
        RC=1
      else
        echo "  复核：内置规则集已无 remote 下载地址"
      fi
    else
      echo "::error::未匹配到内置 remote 规则集，$F 保持原样"
      RC=1
    fi
  done
fi

# ---------- 2/3. init.d/homeproxy：jail 挂 ruleset + 客户端 respawn 放宽 ----------
# 上游包内 init 文件名可能是 homeproxy / homeproxy.init，按内容标记（客户端实例名）定位。
INIT_CANDIDATES=$(find package/feeds feeds package -type f \( -name "homeproxy" -o -name "homeproxy.init" \) 2>/dev/null | sort -u)
INITS=""
for C in $INIT_CANDIDATES; do
  grep -q 'procd_open_instance "sing-box-c"' "$C" 2>/dev/null && INITS="$INITS $C"
done

if [ -z "$INITS" ]; then
  if [ -n "$UCS" ]; then
    echo "::error::未找到 homeproxy init 脚本（上游可能已重构），跳过 jail 挂载 / respawn 补丁"
    RC=1
  else
    echo "::warning::未找到 homeproxy init 脚本，跳过 jail 挂载 / respawn 补丁"
  fi
else
  for F in $INITS; do
    if grep -q 'procd_add_jail_mount "$HP_DIR/ruleset/"' "$F" 2>/dev/null \
       && grep -q "respawn 3600 10 10" "$F" 2>/dev/null; then
      echo "  $F jail 挂载与 respawn 已加固，跳过"
      continue
    fi

    BEFORE=$(md5sum "$F" | cut -d' ' -f1)

    AWK_INIT="$(mktemp)"
    cat > "$AWK_INIT" <<'AWK'
BEGIN { inst = ""; mount_added = 0 }
/procd_open_instance "sing-box-c"/ { inst = "c" }
/procd_open_instance "sing-box-s"/ { inst = "s" }
/procd_open_instance "log-cleaner"/ { inst = "lc" }

# 客户端 jail：在非 rw 的 certs 挂载后补挂 ruleset 目录
# （服务器实例用的是 procd_add_jail_mount_rw "$HP_DIR/certs/"，不会命中本规则）
!mount_added && /^[ \t]*procd_add_jail_mount "\$HP_DIR\/certs\/"$/ {
  print
  ind = $0
  sub(/[^ \t].*$/, "", ind)
  print ind "procd_add_jail_mount \"$HP_DIR/ruleset/\""
  mount_added = 1
  next
}

# 仅客户端实例放宽崩溃重试；服务器实例 / log-cleaner 保持裸 respawn
inst == "c" && /^[ \t]*procd_set_param respawn[ \t]*$/ {
  ind = $0
  sub(/[^ \t].*$/, "", ind)
  print ind "procd_set_param respawn 3600 10 10"
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
    # mktemp 临时文件不带执行位，mv 覆盖会丢掉 init 脚本 +x，补回防止打包成 644
    chmod +x "$F"
    rm -f "$AWK_INIT"

    AFTER=$(md5sum "$F" | cut -d' ' -f1)
    if [ "$BEFORE" != "$AFTER" ]; then
      echo "✅ 已加固 $F：jail 挂载 ruleset，客户端 respawn 3600 10 10"
      # 复核：服务器实例与 log-cleaner 仍应是裸 respawn
      if grep -n "procd_set_param respawn" "$F" | grep -v "3600 10 10"; then
        echo "  复核：其余实例保持裸 respawn"
      fi
    else
      echo "::error::init 未匹配到目标行，$F 保持原样"
      RC=1
    fi
  done
fi

exit "$RC"
