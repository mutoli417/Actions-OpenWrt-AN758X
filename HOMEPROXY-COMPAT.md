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
- `files/etc/uci-defaults/96-dropbear-auth-key`：首启把内置 ed25519 **公钥**写入 `/etc/dropbear/authorized_keys`（刷机后免密 SSH 自动恢复；只含公钥，600 root:root，幂等追加）
- `files/etc/uci-defaults/97-homeproxy-ruleset-cron`：规则集更新 cron（周日 03:17）；首跑顺带兜底补回 `init.d/homeproxy`、`init.d/sing-box` 的执行位（防编译期补丁重写丢失 +x）
- `files/etc/uci-defaults/98-homeproxy-ipv6-off`：**可选**整机关 IPv6（默认不执行，开关 `disable_ipv6=1`）/ 过滤 AAAA / 关 LAN RA
- `files/etc/uci-defaults/98-homeproxy-weekly-restart`：周重启 cron 注册（默认关）
- `scripts/patch-homeproxy-local-ruleset.sh`：编译树源码层补丁（规则集本地化 / jail 挂载 / respawn）
- `scripts/patch-homeproxy-v6hybrid.sh`：编译树源码层补丁（混合双栈：海外 v4-only + 非 CN v6 兜底阻断）

## 默认策略：混合双栈（国内 v4+v6 直连，海外仅 v4）

固件默认不整机关 IPv6，而是在生成器 `generate_client.uc` 打两处补丁：

1. **DNS 全局策略 `ipv4_only`**：海外 / 未匹配域名只返回 A 记录，压制 AAAA；国内两条
   内置 DNS 规则显式 `prefer_ipv6`，按「规则 > 全局」优先级覆盖，国内域名保留 v4+v6。
2. **v6 兜底阻断（失败闭合）**：`route.rules` 注入 `logical and` 规则——`ip_version=6`
   且不在 `geoip-cn` 规则集 → `block-out`。写死海外 v6 的 App / P2P 漏网时不会回落直连。
   必须用 `logical` 包裹：扁平规则里 `ip_version` 会被 `rule_set`/`invert` 匹配语义吞掉，
   实测会误杀 v4 海外地址。

兜底规则已经受海外 v6 真实流量验证：约 3 小时 soak + 40 连接并发压测，block-out 全 v6、
v4 误杀 0、国内 v6 直连、PID 稳定。已知残留：写死 v6 的 App 仍靠 nft 旁路链兜底；
UDP/QUIC v6 在 nft 层 reject，不走兜底；UDP v6 tproxy 计数器长期为 0。

## 可选：整机关 IPv6（与混合双栈互斥）

国内家庭场景可选择彻底关 IPv6：代理节点为 IPv4 出站，若客户端经 v6 直连海外站点，流量
不进代理隧道，会从真实运营商 v6 出口泄漏；本机 v6 链路也曾出现被重置导致 0 字节下载。

该方案与混合双栈互斥（不再保留国内 v6 直连），默认不执行，由开关启用：

```sh
uci set homeproxy.config.disable_ipv6='1'
/etc/uci-defaults/98-homeproxy-ipv6-off   # 或重启后由 uci-defaults 自动套用
/etc/init.d/homeproxy restart
/etc/init.d/dnsmasq restart
```

开关为 `0` / 不存在时，defaults 直接退出，保持混合双栈。需要从整机关 v6 退回混合双栈：

```sh
uci set homeproxy.config.disable_ipv6='0'
uci set homeproxy.config.ipv6_support='1'
uci set dhcp.@dnsmasq[0].filter_aaaa='0'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='disabled'
uci commit homeproxy dhcp
/etc/init.d/homeproxy restart
/etc/init.d/dnsmasq restart
```
