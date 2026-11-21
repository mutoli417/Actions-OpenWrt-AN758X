#!/bin/sh
# =============================================================
# homeproxy-weekly-restart.sh —— 每周低峰期重启 HomeProxy，作为长时间
# 运行内存上涨 / 连接僵死的兜底（上游有运行数天后内存泄漏、OOM 的报告）。
#
# 由 98-homeproxy-weekly-restart 注册的 crontab 调用。默认关闭，需在 UCI 开启：
#   uci set homeproxy.config.weekly_restart='1' && uci commit homeproxy
#
# 仅在 homeproxy 已安装且设为开机自启时执行；重启后校验进程存活，失败写日志。
# =============================================================

TAG="homeproxy-weekly"
log() { logger -t "$TAG" "$*"; echo "$*"; }

[ -x /etc/init.d/homeproxy ] || { log "homeproxy 未安装，退出"; exit 0; }
/etc/init.d/homeproxy enabled 2>/dev/null || { log "homeproxy 未设为开机自启，跳过重启"; exit 0; }

rss_kb() {
	pid="$(pgrep -x sing-box | head -1)"
	[ -n "$pid" ] && awk '/VmRSS/ {print $2}' /proc/"$pid"/status 2>/dev/null
}

before="$(rss_kb)"
log "计划重启 HomeProxy（重启前 sing-box RSS=${before:-?} kB）"

/etc/init.d/homeproxy restart >/dev/null 2>&1 || { log "重启命令返回非零"; exit 1; }

sleep 5
if /etc/init.d/homeproxy status 2>/dev/null | grep -qi running; then
	after="$(rss_kb)"
	log "HomeProxy 重启完成，当前 RSS=${after:-?} kB"
else
	log "警告：重启后未检测到 running 状态"
	exit 1
fi

exit 0
