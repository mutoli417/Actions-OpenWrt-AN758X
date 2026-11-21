#!/bin/sh
# =============================================================
# homeproxy-update-ruleset.sh —— 定时更新 HomeProxy 本地 sing-box 规则集
#
#   背景：固件内置的 3 个 .srs 是编译期静态快照，长期使用国内 / 境外分流
#     名单会慢慢过时。本脚本按周期重新下载并原子覆盖 /etc/homeproxy/ruleset/
#     下的 geoip-cn / geosite-cn / geosite-noncn，保持分流名单新鲜。
#
#   可靠性：
#     - 双 jsdelivr 镜像（fastly / cdn）依次尝试；直连失败再走本机 mixed
#       代理 127.0.0.1:5330 出站，绕开路由器本地 IPv6 链路被重置导致的
#       SSL EOF / 0 字节问题。
#     - 下载到临时文件，校验体积 >= 1000 字节且文件头为 SRS 魔数；任一
#       校验失败都不覆盖旧文件，保留可用规则集。
#     - 与现网文件逐字节比对，无变化不替换；确有变化才重启 homeproxy
#       加载新规则集。
#
#   由 /etc/uci-defaults/97-homeproxy-ruleset-cron 注册 crontab 周期执行，
#   也可手动：/sbin/homeproxy-update-ruleset.sh
# =============================================================

set -u

RULE_DIR="/etc/homeproxy/ruleset"
MIN_SIZE=1000
PROXY="http://127.0.0.1:5330"
LOG_TAG="homeproxy-ruleset"

log() {
	logger -t "$LOG_TAG" "$*"
	echo "$*"
}

# dl <url> <out_file>：优先 GNU/busybox wget，退回 uclient-fetch；-4 强制 IPv4，
# 绕开本机 IPv6 链路被重置导致的 SSL EOF / 0 字节。
dl() {
	url="$1"; out="$2"
	if command -v wget >/dev/null 2>&1; then
		wget -q -4 -T 15 -O "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
	fi
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -4 -T 15 -O "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
	fi
	return 1
}

# valid <file>：体积门槛 + SRS 魔数（53 52 53），拒绝 HTML/404 文本兜底页
valid() {
	f="$1"
	[ -s "$f" ] || return 1
	sz=$(wc -c < "$f")
	[ "$sz" -ge "$MIN_SIZE" ] || return 1
	[ "$(head -c 3 "$f")" = "SRS" ] || return 1
	return 0
}

mkdir -p "$RULE_DIR"
changed=0
failed=0

# update_one <文件名> <镜像1> <镜像2> ...
update_one() {
	name="$1"; shift
	tmp="$RULE_DIR/.$name.tmp"
	ok=0

	# 第一轮：直连各镜像
	for url in "$@"; do
		rm -f "$tmp"
		if dl "$url" "$tmp" && valid "$tmp"; then ok=1; break; fi
	done

	# 第二轮：直连不通时走本机 mixed 代理出站
	if [ "$ok" = 0 ]; then
		for url in "$@"; do
			rm -f "$tmp"
			if http_proxy="$PROXY" https_proxy="$PROXY" dl "$url" "$tmp" && valid "$tmp"; then
				ok=1; break
			fi
		done
	fi

	if [ "$ok" = 1 ]; then
		if [ -f "$RULE_DIR/$name" ] && cmp -s "$tmp" "$RULE_DIR/$name"; then
			log "$name 已是最新，无需更新"
		else
			mv -f "$tmp" "$RULE_DIR/$name"
			chmod 644 "$RULE_DIR/$name"
			# 保持与包内默认属主一致（sing-box:sing-box），便于 ujail 以该身份只读读取；
			# 属主不存在（homeproxy 包被裁）时静默放过，不阻断更新。
			chown sing-box:sing-box "$RULE_DIR/$name" 2>/dev/null || true
			log "$name 已更新（$(wc -c < "$RULE_DIR/$name") 字节）"
			changed=1
		fi
		rm -f "$tmp"
	else
		rm -f "$tmp"
		log "⚠ $name 更新失败，保留现有规则集"
		failed=1
	fi
}

update_one geoip-cn.srs \
	"https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs" \
	"https://cdn.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs"

update_one geosite-cn.srs \
	"https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs" \
	"https://cdn.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs"

update_one geosite-noncn.srs \
	"https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs" \
	"https://cdn.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs"

# 确有规则集变化才重启 homeproxy 重新加载；无变化不动服务
if [ "$changed" = 1 ]; then
	if [ -x /etc/init.d/homeproxy ]; then
		log "规则集有变化，重启 homeproxy 加载新名单"
		/etc/init.d/homeproxy restart >/dev/null 2>&1 || true
	fi
fi

if [ "$failed" = 1 ]; then
	log "部分规则集本轮更新失败，详见上方记录"
	exit 1
fi

exit 0
