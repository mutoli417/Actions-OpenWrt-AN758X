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
- `scripts/patch-homeproxy-v6hybrid.sh`：编译树源码层补丁（混合双栈：海外 v4-only + 非 CN v6 兜底阻断 + 追加两台境外备用 DNS）
- `scripts/patch-homeproxy-resolver-failover.sh`：编译树源码层补丁（出站节点域名解析冗余：直连备用 DNS + main-out 显式解析器 3s 超时 + 境外查询三路 evaluate/respond+race 并行）
- `scripts/patch-homeproxy-smartdns.sh`：编译树源码层补丁（B 方案：local-dns 5334 服务器 + main-out 解析器/dnsmasq 上游按开关条件切换）
- `files/etc/config/smartdns`：B 方案 UCI 配置（默认 `enabled=0` 旁路关闭）
- `files/etc/smartdns/custom.conf`：节点域名 cn 直连护栏 + 双栈对齐 / 陈旧缓存护栏
- `files/sbin/smartdns-watchdog.sh`：5334 探活 / 状态记录 / 二级回滚（探活 cron 调用）
- `files/etc/uci-defaults/99-smartdns`：探活 cron 注册、脚本执行位与目录兜底

## 默认策略：混合双栈（国内 v4+v6 直连，海外仅 v4）

固件默认不整机关 IPv6，而是在生成器 `generate_client.uc` 打四处加固：

1. **DNS 全局策略 `ipv4_only`**：海外 / 未匹配域名只返回 A 记录，压制 AAAA；国内两条
   内置 DNS 规则显式 `prefer_ipv6`，按「规则 > 全局」优先级覆盖，国内域名保留 v4+v6。
2. **v6 兜底阻断（失败闭合）**：`route.rules` 注入 `logical and` 规则——`ip_version=6`
   且不在 `geoip-cn` 规则集 → `block-out`。写死海外 v6 的 App / P2P 漏网时不会回落直连。
   必须用 `logical` 包裹：扁平规则里 `ip_version` 会被 `rule_set`/`invert` 匹配语义吞掉，
   实测会误杀 v4 海外地址。
3. **境外备用 DNS（配置层无逐级自动转移）**：`config.dns.servers` 在 `main-dns`（TCP 8.8.8.8，detour
   `main-out`）之后追加 `main-dns-alt`（TCP 1.1.1.1）、`main-dns-alt2`（TCP 8.8.4.4），
   三项均 detour `main-out`、共用 `default-dns` 做域解析器；`final` 仍指向 `main-dns`。
   注意：sing-box 配置层**不做**按服务器顺序的自动逐级转移，这两台备用服务器默认不被
   任何规则引用；它们由 `resolver-failover` 补丁的 evaluate/respond+race 规则显式接入并行兜底。
   备用项与主项同属代理隧道，不引入 DNS 泄漏。仅非 custom 的主节点 / bypass 分支生效
   （与 `main-dns` 同一段 `if (!isEmpty(main_node))`）。
4. **锚点加固**：补丁脚本在 awk 写入后逐项 grep 三处 hunk 标记（`v6hybrid` A/B/C），
   任一未命中即在构建日志输出 `::error::` 指明缺失的 hunk，避免上游重构生成器后静默漏打。

兜底规则已经受海外 v6 真实流量验证：约 3 小时 soak + 40 连接并发压测，block-out 全 v6、
v4 误杀 0、国内 v6 直连、PID 稳定。已知残留：写死 v6 的 App 仍靠 nft 旁路链兜底；
UDP/QUIC v6 在 nft 层 reject，不走兜底；UDP v6 tproxy 计数器长期为 0。

## 出站节点域名解析冗余（resolver-failover 补丁）

针对主节点出站域名（如 `productandservice.infralinkplus.com`）在拨号前由
`route.default_domain_resolver`（china-dns）解析、直连 DNS 间歇丢包时 lookup deadline
连带 main-out 拨号失败的问题，生成器 `generate_client.uc` 注入三处加固：

- **直连备用 DNS（Hunk A）**：`config.dns.servers` 追加 `direct-dns-alt`（UDP
  223.5.5.5，detour direct-out）；119.29.29.29 TCP53 在本 WAN 间歇 RST/stall，UDP 直连实测稳定。
- **出站显式解析器（Hunk B）**：main-out 的 wireguard 端点与普通出站显式挂
  `domain_resolver` = `direct-dns-alt`，带 `timeout: 3s`（失败快速浮出便于重试）与
  ipv4_only 策略；节点域名解析从 china-dns 关键路径剥离，请求域名的国内外分流仍走
  `default_domain_resolver`，行为不变。
- **境外查询并行兜底（Hunk C）**：proxy-domain 境外查询接 evaluate/respond+race 三路
  并行（`main-dns` / `main-dns-alt` / `main-dns-alt2`），取首条 settled 有效响应；
  三台备用服务器由 v6hybrid 补丁定义，本补丁只补规则引用。

**配置边界（源码核实，sing-box 1.14.3 / master 一致）**：解析器仍是单 tag——
`Server` 为标量字符串，无第二解析器、解析器组或自动接力字段；`Lookup` 出错即返回，
不跨服务器重试；evaluate/respond 并行只覆盖规则驱动的入站查询，接不上出站内层解析。
本补丁只能在单 tag 内叠加直连上游（UDP/TCP）、显式超时与规则级并行，配不出解析器级多上游切换。

**依赖与退出码**：Hunk C 必须在 v6hybrid 补丁之后应用（缺 `main-dns-alt2` 直接硬失败）。
脚本幂等；包整体缺失 warning 跳过 exit 0；锚点未命中 / awk 或 mv 失败 / 改写后无变化 /
hunk 标记未落产物 → `::error::` 记录并 exit 1 中止构建。

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

## B 方案：SmartDNS 5334 统一递归引擎（默认旁路关闭，可选接入）

在不替换 HomeProxy / sing-box 内核的前提下，把本地 SmartDNS 作为可选的多上游
递归引擎接入。默认 `homeproxy.config.smartdns_enabled=0`，dnsmasq 上游仍指 5333
main-dns race，运行行为与加固前一致；启用后才把引导解析与运行时查询切到 5334。

### 架构与边界

- SmartDNS 绑 `127.0.0.1:5334`（UDP+TCP，仅回环），不监听 53、不绑 LAN/WAN；
  dnsmasq 仍占 53 承接 LAN 终端。`auto_set_dnsmasq=0`，不走上游包自带的 dnsmasq
  改写 / 重启逻辑。
- 分组：`cn`（223.5.5.5 / 119.29.29.29 / 116.116.116.116 直连国内公共 DNS）；
  `en`（DoH 1.1.1.1 / dns.google，默认直连；socks5 `127.0.0.1:5330` 备用通道已在
  `proxy_server` 声明，需挂备用通道时对应 server 段 `option use_proxy '1'`）。
- 引导死锁护栏：节点域名 `productandservice.infralinkplus.com` 在 `custom.conf`
  显式归 cn 直连组，绝不走经代理的上游；实测三台国内公共 DNS 均返回 155.254.101.x
  健康中继池。
- 包选择：feeds `smartdns` 主包（C 构建，依赖 libopenssl，无 aarch64 架构锁）；
  `smartdns-ui` 子包（Rust/node 宿主构建）不编入。

### 接线（编译期补丁 `patch-homeproxy-smartdns.sh`）

- UC：追加 `local-dns`（UDP 127.0.0.1:5334，direct-out 绕行）；main-out 端点 /
  出站 `domain_resolver` 按开关条件选择：开 → `local-dns`，关 → `direct-dns-alt`
  （resolver-failover 补丁的直连备用 DNS）。
- init.d/homeproxy：读取 `homeproxy.config.smartdns_enabled`；开关开时把 dnsmasq
  注入的 `redirect-dns.conf` 上游由 `#5333` 改写为 `#5334`，关则原样保留。
- 启动顺序：smartdns `START=19` 先于 homeproxy / sing-box `START=99`。

### 启用 / 回滚

启用：

```sh
uci set smartdns.@smartdns[0].enabled='1' && uci commit smartdns
/etc/init.d/smartdns enable && /etc/init.d/smartdns start
uci set homeproxy.config.smartdns_enabled='1' && uci commit homeproxy
/etc/init.d/homeproxy restart
```

回滚（5334 故障一键退回 5333 race）：

```sh
uci set homeproxy.config.smartdns_enabled='0' && uci commit homeproxy
/etc/init.d/homeproxy restart
# 必要时停用 smartdns：/etc/init.d/smartdns stop && /etc/init.d/smartdns disable
```

### 探活与降级（阶段 2）

- `files/sbin/smartdns-watchdog.sh`：cron 每 5 分钟探活（进程存活 + 回环 5334
  UDP/TCP 端口在听），状态 `up/down/unknown` 与翻转时间、pid、uptime 写
  `/tmp/smartdns-watchdog.state`，供监控增量基线采集。开机 120s 宽限期不计 down
  （ignore-initial-down），避免启动瞬态误回滚。连续 3 次失败触发二级回滚：dnsmasq
  上游指回 5333 并重启 dnsmasq，置 `rollback=1` 后不自动切回，待人工排查。
- 一级降级（en 切备用上游 / 直连回退）：SmartDNS 组内并发剔除由进程内部完成；
  本机无状态化事件钩子，本期不做上游自动联动（能力缺口见 enterprise 文档 §6 #7）。
- 连接保持：urltest 组切换是否中断存量会话由 `interrupt_exist_connections` 控制，
  生成器已从 UCI `urltest_interrupt_exist_connections` 读取；默认保持既有连接，
  新连接走新选中节点。

### 待 soak 验证 / 已知缺口

- DoT 8.8.8.8:853 真机 TLS 握手与证书链未验证，本期未编入 en 组；待装包后实测。
- 5334 单点故障影响面、两级缓存命中率、常驻 RSS/CPU、上游失败计数待上线 soak；
  超预算动作顺序：先减 en 上游，再降 cache-size，仍超则回滚 B 方案。
- 功能级 DNS 查询探测未接入（busybox nslookup 不支持 `-port`）；探活仅判进程 + 端口。
- nftset 回填：当前 `bypass_mainland_china` 由 sing-box rule_set 分类，不依赖 dnsmasq
  nftset；gfwlist / proxy 模式下的集合停更风险未在本机路由模式触发。
