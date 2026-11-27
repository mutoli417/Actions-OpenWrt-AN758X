#!/bin/sh
# =============================================================
# smartdns-watchdog.sh —— B 方案 SmartDNS 5334 探活 / 状态记录 / 二级回滚
#
# 由 99-smartdns uci-defaults 注册的 cron 周期调用。仅当
#   homeproxy.config.smartdns_enabled='1' 时动作；开关关闭直接退出。
#
# 探活判据：进程存活（pgrep -x smartdns）+ 回环 5334 UDP/TCP 在听
#   （/proc/net/udp 与 /proc/net/tcp 端口十六进制 14D6）。busybox nslookup
#   不支持 -port，本期不做功能级 DNS 查询；功能级命中率/上游成败计数留待
#   SmartDNS 日志/统计接入后补（见 enterprise 文档 §8.3 #14）。
#
# 状态记录：up / down / unknown + 翻转时间、pid、uptime 写入
#   /tmp/smartdns-watchdog.state，供 router_monitor.py 增量基线采集。
#
# 防误判（ignore-initial-down）：开机宽限 IGNORE_SECS 秒内不计 down、不回滚，
#   避免启动瞬态（smartdns / sing-box 未起）触发误回滚。
#
# 二级回滚：连续 FAIL_LIMIT 次失败后，把 dnsmasq 注入上游指回 5333
#   （main-dns race 回退通道）并重启 dnsmasq；置 rollback=1 后不再自动切回，
#   需人工排查后删除状态文件 rollback 标记复位。
#
# 一级降级（en 切备用上游 / 直连回退）：SmartDNS 组内并发剔除由进程内部完成；
#   本机无状态化事件钩子，本期不做上游自动联动（enterprise 文档 §6 #7 缺口）。
# =============================================================

TAG="smartdns-watchdog"
STATE=/tmp/smartdns-watchdog.state
PORT_HEX=14D6
IGNORE_SECS=120
FAIL_LIMIT=3

log() { logger -t "$TAG" "$*"; echo "$*"; }

enabled="$(uci -q get homeproxy.config.smartdns_enabled)"
[ "$enabled" = "1" ] || exit 0

[ -x /etc/init.d/smartdns ] || { log "smartdns 未安装，退出"; exit 0; }

# 开机宽限：/proc/uptime 首列为秒数
uptime_s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 9999)"
if [ "$uptime_s" -lt "$IGNORE_SECS" ]; then
	echo "state=ignored" > "$STATE.boot"
	exit 0
fi

port_listening() {
	grep -q ":$PORT_HEX" /proc/net/udp 2>/dev/null && return 0
	grep -q ":$PORT_HEX" /proc/net/tcp 2>/dev/null && return 0
	return 1
}

pid="$(pgrep -x smartdns | head -1)"
if [ -n "$pid" ] && port_listening; then
	state=up
else
	state=down
fi

prev="$(sed -n 's/^state=//p' "$STATE" 2>/dev/null)"
fails="$(sed -n 's/^fails=//p' "$STATE" 2>/dev/null)"
rollback="$(sed -n 's/^rollback=//p' "$STATE" 2>/dev/null)"
fails="${fails:-0}"
rollback="${rollback:-0}"

if [ "$state" = "up" ]; then
	fails=0
	[ "$prev" = "down" ] && log "SmartDNS 恢复 up（pid=$pid）"
else
	fails=$((fails + 1))
	log "SmartDNS 探测失败（pid=${pid:-none}，端口 5334 未监听），连续 $fails/$FAIL_LIMIT"
fi

{
	echo "state=$state"
	echo "fails=$fails"
	echo "rollback=$rollback"
	echo "pid=${pid:-}"
	echo "uptime=$uptime_s"
	echo "updated=$(date '+%Y-%m-%d %H:%M:%S')"
} > "$STATE"

# 二级回滚：连续失败超阈值且尚未回滚
if [ "$state" = "down" ] && [ "$fails" -ge "$FAIL_LIMIT" ] && [ "$rollback" != "1" ]; then
	conf="$(find /tmp -name redirect-dns.conf 2>/dev/null | head -1)"
	if [ -n "$conf" ] && grep -q "127.0.0.1#5334" "$conf"; then
		sed -i 's|server=127.0.0.1#5334|server=127.0.0.1#5333|' "$conf"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		log "二级回滚：dnsmasq 上游已指回 5333（$conf），待人工排查"
		rollback=1
		{
			echo "state=$state"
			echo "fails=$fails"
			echo "rollback=$rollback"
			echo "pid=${pid:-}"
			echo "uptime=$uptime_s"
			echo "updated=$(date '+%Y-%m-%d %H:%M:%S')"
		} > "$STATE"
	else
		log "未定位到 5334 注入 conf，跳过回滚改写"
	fi
fi

exit 0
