# B 仓库配置追加顺序根因规范补丁

- 仓库：`mutoli417/Actions-OpenWrt-AN758X`（默认分支 `main`）
- 基线提交：`ed560850dbe58f1dd157af94df58a201e811fafc`
- 改动文件：`.github/workflows/build-ponwrt.yml`、`diy-part2.sh`
- 触发现象：编译起步报 `WARNING: your configuration is out of sync. Please run make menuconfig, oldconfig or defconfig!`

## 根因

工作流有两次 `make defconfig`：

1. Configure 步骤（基线 L683）第一次展开；
2. Validate 步骤经 `scripts/defconfig.sh`（基线 L800）第二次、也就是最后一次展开。

第二次 defconfig 之后，工作流又在基线 L808–817 把强制包先删后加写回 `.config`，
此后没有再跑 kconfig 同步。编译起步 `make world` 检测到 `.config` 比 `auto.conf`
新，便打出 out-of-sync 警告。该告警非致命，编译会继续，但属于配置顺序不规范。

## 规范做法（本补丁）

原则：所有强制选择必须在**最后一次 defconfig 之前**写入 `.config`，由 kconfig
一次性解析依赖与符号；defconfig 之后不再手改 `.config`。

### 改动 1：Configure 步骤删除第一次 defconfig 后的强制追加

移除基线 L685–713、L726–731 的四组事后追加：

- `zoneinfo-asia libffi iw` 安全网；
- `luci-app-airoha-npu luci-app-pon-status luci-app-natmode`；
- `firewall4 kmod-nft-fullcone luci-mod-status airoha-ponctl jsonfilter rpcd-mod-file`；
- `luci-app-ssr-plus xray-core sing-box`；
- `luci-app-iptv luci-i18n-iptv-zh-cn`。

Argon 菜单隐藏、版本信息搜索等非 `.config` 操作保留不动。

### 改动 2：Validate 步骤在最后一次 defconfig 之前写入合并清单

在 `bash scripts/defconfig.sh` 之前插入合并后的强制包清单（幂等：先删旧行/
`is not set` 行，再追加 `=y`），共 20 个包：

```
zoneinfo-asia libffi iw
luci-app-airoha-npu luci-app-pon-status luci-app-natmode
firewall4 kmod-nft-fullcone luci-mod-status airoha-ponctl jsonfilter rpcd-mod-file
luci-app-ssr-plus
luci-app-iptv luci-i18n-iptv-zh-cn
nlbwmon luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn luci-lib-chartjs mesh11sd
```

> `xray-core` / `sing-box` 不进强制清单：
> - sing-box 不是 SSR Plus+ 的后端依赖，helloworld feed 也不提供；
> - xray-core 由 `luci-app-ssr-plus` 的 `INCLUDE_Xray` 条件依赖在 defconfig 时
>   自动带入，单独强制 `=y` 属冗余，缺依赖时还会被静默剔除。

### 改动 3：删除 Validate 步骤 defconfig 之后的追加循环

移除基线 L802–817 的「defconfig 后补一次强制配置」循环，并同步改写步骤头注释。

### 改动 4：ccache 选择前移到最后一次 defconfig 之前

`CONFIG_CCACHE` 是 kconfig 符号（`config/Config-devel.in`，挂在 `DEVEL` 菜单下）。
两个 SoC 基座 config 均已 `CONFIG_DEVEL=y`，符号有效。补丁在 Validate 步骤、
defconfig 之前按 `USE_CCACHE=true` 写入 `CONFIG_CCACHE=y`；后续 `Setup ccache`
步骤只负责确认/补装 ccache 二进制，不再回写 `.config`，仅在二进制补装失败的
错误路径才把 ccache 关闭。

### 改动 5：剔除诊断区分两类根因（OPT_MISS 硬校验 + 强制清单非阻断）

- `OPT_MISS` 状态插件被剔除时，校验先查 `tmp/.packageinfo`：
  - **未进入包索引**：clone/拷贝/feed 缺失（对照 diy-part1.sh）；
  - **已索引但被 defconfig 剔除**：依赖或条件不满足，并打印该包的 `Depends:` 行。
  报错文案同步指向上述分类，不再一律归结为 clone 失败。
- 强制清单其余包另做一轮**非阻断**检查：被 defconfig 剔除时只打 `::warning::`，
  同样区分「未索引 / 已索引被剔」并打印 Depends，便于首跑定位，不 `exit 1`。

### 改动 6：剥除 SSR Plus+ 的 kcptun-client 条件依赖（消 1 条 WARNING）

首跑 Validate 的 11 条 WARNING 中，1 条为：

```
luci-app-ssr-plus/Makefile 依赖 'kcptun-client'（不存在）
```

根因：`diy-part2.sh` 原正则 `s/+kcptun-client//g` 只匹配字面 `+kcptun-client`，
而 Makefile 里是**条件依赖**写法：

```
+PACKAGE_$(PKG_NAME)_INCLUDE_Kcptun:kcptun-client
```

正则匹配不到 `:kcptun-client` 片段，剥除失效。补丁把 sed 改为同时剥条件片段与字面形式：

```sh
sed -i -e 's/+PACKAGE_[^:[:space:]]*:kcptun-client//g' \
       -e 's/+kcptun-client//g' "$SSR_MAKEFILE"
```

kcptun 后端默认关闭（`INCLUDE_Kcptun=n`），剥除该条件依赖不影响 SSR 本体与其他后端。

### 改动 7：摘除 qt6quick / qt6svg 目录（消 10 条 qt6 WARNING）

首跑 10 条为 `video/qt6quick`、`video/qt6svg` 依赖 `qt6base-*`（不存在）。
源码 `feeds.conf.default` 自带 `src-git video https://github.com/openwrt/video.git`。
该 feed 虽全是 GUI / 游戏 / 多媒体库（wayland、gtk、qt5/qt6、mesa、sdl、games），
但 `packages` 的 `gst1-plugins-base` 依赖 `libmesa / libwayland / libgraphene`，
这三个库正由 video feed 提供，因此**保留 feed**，只摘掉缺 qt6base 子包的 quick/svg 两个目录。

补丁在 diy-part1 之后单独一步删除对应索引目录：

```sh
rm -rf package/feeds/video/qt6quick package/feeds/video/qt6svg
```

⚠ 时机必须在 diy-part1 **之后**：diy-part1.sh 末尾还会再跑一次
`./scripts/feeds install -a`，若在首次 feeds 步骤里删，符号链接会被这次 install
重建，告警依旧。因此删除动作放在 diy-part1 步骤之后、defconfig 之前。

这样 qt6quick/qt6svg 缺 qt6base 的告警从根上消除，同时 mesa/wayland/graphene 仍在，
gst1-plugins-base 不再缺库；`packages / luci / routing / telephony / pon_drivers / pon_userspace` 等其他 feed 不受影响。

## 校验口径

- `MISSING`（PON 核心链路，缺包直接 `exit 1`）与 `OPT_MISS`（状态插件，缺包报错）
  仍在最后一次 defconfig 之后读取 `.config`。
- 规范后：源码树/feeds 里不存在、或依赖不满足而被 defconfig 静默剔除的包，
  会被上述校验如实上报，而不是事后把 `=y` 写回 `.config` 让校验「看起来通过」。
- 基座依赖已覆盖：`luci-base`、`rpcd-mod-file`、`jsonfilter`、`firewall4`、
  `kmod-nft-fullcone`、`luci-mod-status`、`nftables-json`、`uhttpd` 等均在基座
  config 中启用；diy-part1.sh 已把三个自定义插件 Makefile 里的多余依赖去掉。

## 注意

1. **建议试编译验证**：规范前事后追加只保证 grep 看到 `=y`，并不保证包真正编入；
   规范后 defconfig 会按真实依赖解析。首次按本补丁构建时，留意 Validate 的
   `MISSING` / `OPT_MISS`、强制清单非阻断警告与 defconfig WARNING 汇总，确认
   20 个强制包均被接受。
2. **xray-core / sing-box**：不进强制清单。sing-box 与 SSR Plus+ 无依赖关系、
   helloworld feed 也不提供；xray-core 由 SSR Plus+ 的 `INCLUDE_Xray` 条件依赖
   自动带入。若首跑诊断显示 xray-core 被剔，按其 Depends 行补依赖即可；二者均不
   在 `MISSING`/`OPT_MISS` 阻断清单内，不打断构建。
3. 本补丁基于远端 `ed560850` 基线生成，仅含本次顺序规范涉及的工作流文件；
   此前本地另存的未推送改动不在本包内。
