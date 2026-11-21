# HomeProxy / sing-box 版本配对与维护说明

## 当前实测配套版本（本固件）

- sing-box `1.14.3-r1`（aarch64_cortex-a53，go1.27.4）
- luci-app-homeproxy `26.322.27443~8724b54`
- 代理模式：`redirect_tproxy`，分流模式 `bypass_mainland_china`

## 升级铁律

1. **homeproxy 与 sing-box 必须从同一 ImmortalWrt feed 配套升级**，禁止单独把 sing-box 升到新版本。
2. 背景：homeproxy 的 `generate_client.uc` 生成的 DNS 配置仍使用 legacy 字段（address filter
   fields、`strategy` DNS rule action）。sing-box `1.14.0` 已标记弃用，**`1.16.0` 移除**。
   单独升 sing-box 到 1.16 而 homeproxy 未跟进，会出现配置解码失败、服务起不来（上游 issue
   `#632` 同类版本错配）。
3. 升级后校验：
   - `sing-box check -c /var/run/homeproxy/sing-box-c.json`
   - `/etc/init.d/homeproxy status` 应为 `running`
   - `logread | grep sing-box` 无 `decode config` / `unknown field` 报错
4. 先看 homeproxy release notes / commit，确认已适配目标 sing-box 版本，再动固件。

## 已知上游问题与本机对应措施

| 上游问题 | 现象 | 本机措施 |
|---|---|---|
| 规则集开机联网下载失败（IPv6 链路重置 → 0 字节 → 崩溃循环，DNS 转发到已死 5333） | 客户端能 ping IP 打不开网页 | 三个内置规则集改本地 `.srs` 快照；客户端 jail 补挂 `ruleset/`；客户端 respawn 放宽 `3600 10 10`；周更脚本刷新名单 |
| 长时间运行内存上涨 / OOM（`#585`） | 运行数天后 RSS 升高、可能 OOM | 可选每周兜底重启（`homeproxy.config.weekly_restart=1`，默认关）；观察 RSS 曲线 |
| DNS 泄漏（`#357`） | 海外域名经国内 DNS 解析被污染 | DNS 全量走 dnsmasq:53 → sing-box:5333，海外域名走代理 DNS |
| TUN 模式崩溃（`#379`） | 切 TUN 后服务短时间退出 | 本机用 `redirect_tproxy`，未使用 TUN |
| 节点 TLS 证书校验失败（`#344`） | 订阅节点连不上 | 全局 `allow_insecure=0`；个别节点级 `tls_insecure=1` 需人工复核 |

## 本地文件落点（files/ 覆盖层 + scripts/ 补丁）

- `files/etc/homeproxy/ruleset/*.srs`：编译期静态快照（geoip-cn / geosite-cn / geosite-noncn）
- `files/sbin/homeproxy-update-ruleset.sh`：规则集周更（双镜像 + 代理兜底 + SRS 魔数校验）
- `files/sbin/homeproxy-weekly-restart.sh`：可选每周兜底重启
- `files/etc/uci-defaults/97-homeproxy-ruleset-cron`：规则集更新 cron（周日 03:17）
- `files/etc/uci-defaults/98-homeproxy-ipv6-off`：默认关 IPv6 / 过滤 AAAA / 关 LAN RA
- `files/etc/uci-defaults/98-homeproxy-weekly-restart`：周重启 cron 注册（默认关）
- `scripts/patch-homeproxy-local-ruleset.sh`：编译树源码层补丁（规则集本地化 / jail 挂载 / respawn）

## 默认关闭 IPv6 的理由与恢复双栈

国内家庭场景默认关 IPv6：代理节点为 IPv4 出站，若客户端经 v6 直连海外站点，流量不进代理
隧道，会从真实运营商 v6 出口泄漏，网站看到国内地址、代理失效；同时本机 v6 链路曾出现被
重置导致 0 字节下载的问题。

需要恢复双栈时：

```sh
uci set homeproxy.config.ipv6_support='1'
uci set dhcp.@dnsmasq[0].filter_aaaa='0'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='disabled'
uci commit homeproxy dhcp
/etc/init.d/homeproxy restart
/etc/init.d/dnsmasq restart
```

恢复后仍存在海外 v6 直连泄漏风险，建议 DNS 策略保持 `prefer_ipv4`。
