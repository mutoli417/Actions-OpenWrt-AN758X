#!/usr/bin/env bash
# =============================================================
# patch-homeproxy-check-via-proxy.sh —— HomeProxy 连接检查改为经代理探测
#
#   背景：luci-app-homeproxy 后端 connection_check 在路由器本机直接
#     /usr/bin/wget --spider 探测目标站点，不带代理环境变量，也不被
#     tproxy/redirect 劫持进代理。本机直连 Google 被墙 → 界面恒显「谷歌失败」，
#     与代理出站是否正常无关（经 mixed 代理实测 Google/YouTube 均通）。
#
#   改动：仅在该 wget 命令前注入 https_proxy，让检查走本机 mixed 入站
#     127.0.0.1:5330（本固件 mixed_port 默认 5330，UCI 现状一致）。
#     百度/Google 两项都经 main-out 出站探测，反映真实代理链路：
#       代理正常 → 绿；代理/主节点故障 → 红。
#
#   最小侵入：只改命令字符串前缀，不新增 ucode import / UCI 读取逻辑，
#     避免后端 rpcd ucode 加载失败导致整页 RPC 不可用。
#
#   幂等：重复执行不会二次改动；包缺失 / 未匹配只警告跳过，不阻断构建。
#   用法: bash patch-homeproxy-check-via-proxy.sh [openwrt_dir]
# =============================================================

set -u

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

PROXY="http://127.0.0.1:5330"

# feeds install -a 后包索引在 package/feeds/<feed>/luci-app-homeproxy；
# 兼容核心仓库直放 feeds/ 的布局，find 自适应定位后端 ucode。
FILES=$(find package/feeds feeds -path "*luci-app-homeproxy/root/usr/share/rpcd/ucode/luci.homeproxy" -type f 2>/dev/null)

if [ -z "$FILES" ]; then
  echo "::warning::未找到 luci-app-homeproxy 后端 ucode，跳过连接检查走代理补丁"
  exit 0
fi

for F in $FILES; do
  if grep -q "https_proxy=${PROXY}" "$F"; then
    echo "  $F 连接检查已走代理，跳过"
    continue
  fi

  if ! grep -q '`/usr/bin/wget --spider -qT3' "$F"; then
    echo "::warning::$F 未匹配到本机直连 wget 检查，保持原样"
    continue
  fi

  BEFORE=$(md5sum "$F" | cut -d' ' -f1)

  # 只在反引号模板内、wget 命令前注入代理环境变量；保留 ${url} 与重定向原样。
  sed -i "s#\`/usr/bin/wget --spider -qT3#\`https_proxy=${PROXY} /usr/bin/wget --spider -qT3#" "$F"

  AFTER=$(md5sum "$F" | cut -d' ' -f1)

  if [ "$BEFORE" != "$AFTER" ]; then
    echo "✅ 已将 $F 连接检查改为经 mixed 代理 ${PROXY} 探测"
    # 复核：不应再存在未带代理前缀的直连 spider 检查
    if grep -n '`/usr/bin/wget --spider' "$F" | grep -v "https_proxy=${PROXY}"; then
      echo "::warning::$F 仍有未走代理的 wget spider 检查，见上方行号"
    else
      echo "  复核：连接检查 wget 均已带代理前缀"
    fi
  else
    echo "::warning::未匹配到 wget 检查内容，$F 保持原样"
  fi
done

exit 0
