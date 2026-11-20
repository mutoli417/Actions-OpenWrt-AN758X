#!/bin/bash
# ================================================================
# diy-part.sh —— 合并原 diy-part1.sh / diy-part2.sh，按阶段参数调用。
# 用法: bash diy-part.sh <stage>
#   stage=1   阶段一：feeds install 之后拉取可选插件（原 diy-part1.sh）
#   stage=2   阶段二：defconfig 之前写 .config / uci-defaults / 加密（原 diy-part2.sh）
#   stage=all 两段顺序执行（仅本地调试；CI 两段时序被中间步骤隔开，须分阶段调用）
# ================================================================

STAGE="${1:-all}"

# ################ 阶段一（原 diy-part1.sh）：拉取可选插件 ################
if [ "$STAGE" = "1" ] || [ "$STAGE" = "all" ]; then
echo "=========================================="
echo "拉取可选插件 (diy-part.sh 阶段一)"
echo "=========================================="
PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# ---------------------------------------------------------
# 看门狗（WDT）源码树对齐（与 ponwrt fork 同源改动，幂等兜底）：
#   1) 打开 CONFIG_WATCHDOG_SYSFS：暴露 state/timeout/timeleft 等 sysfs 属性，
#      001 钳制补丁才能读到 max_timeout，避免 procd 30s 超硬件上限(~28s) 被 EINVAL。
#   2) procd 默认超时 30s -> 24s（硬件上限约 28s），双保险。
# 源头在 ponwrt fork 的 target config 与 procd patches；这里对 clone 下来的源码树
# 再注入一遍，保证 source=上游 pbs05/ponwrt 编译时同样生效。
# ---------------------------------------------------------
for sub in an7581 an7583 en7523; do
  wcfg="target/linux/airoha/$sub/config-6.18"
  [ -f "$wcfg" ] || continue
  if grep -q '^# CONFIG_WATCHDOG_SYSFS is not set' "$wcfg"; then
    sed -i 's/^# CONFIG_WATCHDOG_SYSFS is not set$/CONFIG_WATCHDOG_SYSFS=y/' "$wcfg"
  elif ! grep -q '^CONFIG_WATCHDOG_SYSFS=' "$wcfg"; then
    sed -i '/^CONFIG_WATCHDOG_CORE=y$/a CONFIG_WATCHDOG_SYSFS=y' "$wcfg"
  fi
done

mkdir -p package/system/procd/patches
cat > package/system/procd/patches/002-watchdog-default-timeout-24s.patch <<'WDT_PATCH'
diff --git a/watchdog.c b/watchdog.c
--- a/watchdog.c
+++ b/watchdog.c
@@ -31,5 +31,5 @@
 static struct uloop_timeout wdt_timeout;
 static int wdt_fd = -1;
-static int wdt_drv_timeout = 30;
+static int wdt_drv_timeout = 24;
 static int wdt_frequency = 5;
 static bool wdt_magicclose = false;
WDT_PATCH

# ---------------------------------------------------------
# 插件开关
# ⚠ 关掉某个开关，defconfig 会把 config 里对应的 =y 静默剔除 —— 两处必须一起改。
# ⚠ 标「只用 feeds」的，是本体（mosdns/smartdns）feeds 已有
#   同名包；第三方源再拉一份会让索引出现两个同名 Package，行为不可预期。
#   故只拷 luci 前端，本体一律用 feeds 的。
# 温度不走插件：autocore 的 /sbin/tempinfo 提供（见 files/sbin/tempinfo）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）
ADD_FLUENT=false       # luci-theme-fluent：Fluent 2 风格主题（已移除，默认皮肤 bootstrap，停止拉取）
ADD_FLUENT_LITE=false  # luci-theme-fluent-lite：轻量版（与 fluent 互斥，二选一）
ADD_FLUENT_DASH=false  # luci-mod-fluentdashboard：可选状态概览卡片
ADD_PASSWALL=false     # luci-app-passwall：已停用（无其他插件引用）；xray-core 随之一并不编入（sing-box 改由 HomeProxy 编入）
ADD_OPENCLASH=false    # luci-app-openclash：已停用（无其他插件引用）；依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=true        # luci-app-mosdns（本体只用 feeds 的 mosdns）
ADD_LUCKY=true         # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=true     # luci-app-tailscale（本体只用 feeds 的 tailscale）
ADD_OPENLIST=true      # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=true      # luci-app-smartdns（本体只用 feeds 的 smartdns）
ADD_EASYTIER=true      # luci-app-easytier（另需 kmod-tun + easytier 本体，Rust 编译较慢）
ADD_POWEROFF=true      # luci-app-poweroffdevice（关机）
ADD_OWQ_WOL=true       # luci-app-owq-wol（网络唤醒，依赖 etherwake）
ADD_WATCHDOG=true      # luci-app-watchdog（看门狗，包在子目录，需特殊处理）
ADD_TASKPLAN=true      # luci-app-taskplan（定时任务）
ADD_OAF=true           # luci-app-oaf（应用过滤，含内核模块，高风险）
ADD_LUCI_APP=true       # qwe-qaq/luci-app 仓库（monorepo）
                        #   ├─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
                        #   ├─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）
                        #   ├─ luci-app-igmpproxy    IGMP Proxy 组播代理 Web 界面
                        #   └─ luci-app-ledpanel    面板 LED 控制（系统 → 面板 LED）
                        #      ★仅 an4475-g2 的 config =y：灯位是这块板的 PCA9555 脚位
# 以下开关可被环境变量覆盖（: ${VAR:=默认}）；选「不拉私有仓库」时注入 ADD_FTTR=false
: "${ADD_FTTR:=true}"       # FTTR 全家桶总开关（下面的子开关都受它管）★仅 HM2004-DU
: "${ADD_FMCS:=true}"       # h3c-fmcs：Micro-OLT FPGA 内核驱动（kmod-h3c-fmcs）
: "${ADD_FTTR_TOOLS:=true}" # openwrt-fttr：fttrd 控制器 + fttrctl（Rust 包）
: "${ADD_FMCS_FW:=true}"    # h3c-fmcs-firmware：FPGA 比特流 FTTR_TOP.sbit
: "${ADD_FTTR_LUCI:=true}"  # luci-app-fttr：界面包（公开 CI 生成的 package 分支）
                            # （前三个来自 openwrt-fttr 私有仓库；界面包单独拉，见下方）

# FTTR 四件套只对 HM2004-DU 有意义（DEPENDS 带 @(TARGET_airoha_an7581)）。
# workflow 把 PROFILE 导出为环境变量，非 2004 机型直接跳过，不白花 clone 时间。
# ⚠ 不能默认成 h3c_hm2004-du：warm-cache.yml 也调本脚本却不设 PROFILE、也没有
#   私有仓库凭证，默认成 h3c 会去 clone 私有 feed 然后 "could not read Username"。
FTTR_PROFILE="${PROFILE:-none}"

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}
# =========================================================
# qwe-qaq/luci-app —— monorepo，四个 LuCI 插件：
#   luci-app-natmode / luci-app-pon-status / luci-app-igmpproxy / luci-app-ledpanel
# =========================================================
if [ "$ADD_LUCI_APP" = "true" ]; then
  LUCI_APP_URL="https://github.com/qwe-qaq/luci-app"
  LUCI_APP_TMP="$(mktemp -d)/luci-app"
  if ! clone "$LUCI_APP_URL" "$LUCI_APP_TMP" main; then
    echo "::error::qwe-qaq/luci-app 拉取失败，natmode / pon-status / igmpproxy / ledpanel 会被 defconfig 剔除"
    exit 1
  fi
  for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy luci-app-ledpanel; do
    if [ ! -f "$LUCI_APP_TMP/$p/Makefile" ]; then
      echo "::error::$LUCI_APP_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$LUCI_APP_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$p/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done
  rm -rf "$LUCI_APP_TMP"
fi

# =========================================================
# FTTR 后端三件套 ★HM2004-DU 专属，源 qwe-qaq/openwrt-fttr（私有）
# ⚠ 必须用裸 URL：凭证由 workflow 的 GIT_ASKPASS 注入，拼 token 会被 clone 打进日志。
# ⚠ 该仓库是 feed 形态（根目录即包目录）。用户态 Rust 包已改名 openwrt-fttr，
#   但源目录可能是 fttr / fttr-tools / h3c-fttr-tools，故按候选名探测后统一拷成
#   package/custom/openwrt-fttr/，保证索引包名与 config 的 =y 对得上。
# ⚠ h3c-fmcs 是 KernelPackage，索引里叫 kmod-h3c-fmcs（校验里由 pkgname_of 映射）。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 仓库与分支由 workflow 注入，本地手工跑时回退到下面的默认值
  FTTR_FEED_URL="https://github.com/${PRIVATE_REPO:-LazuliKao/openwrt-fttr}"
  FTTR_FEED_BRANCH="${PRIVATE_REPO_BRANCH:-main}"
  FTTR_FEED_TMP="$(mktemp -d)/openwrt-fttr"
  if ! clone "$FTTR_FEED_URL" "$FTTR_FEED_TMP" "$FTTR_FEED_BRANCH"; then
    echo "::error::openwrt-fttr 拉取失败：${FTTR_FEED_URL} (分支 ${FTTR_FEED_BRANCH})，kmod-h3c-fmcs / openwrt-fttr / h3c-fmcs-firmware 会被 defconfig 剔除；luci-app-fttr 因依赖 +openwrt-fttr 也会被连带剔除"
    echo "        公开仓库失败=仓库/分支名不对；私有仓库缺凭证=优先查 GitHub App（PRIVATE_SOURCE_APP_ID / PRIVATE_SOURCE_APP_PRIVATE_KEY，App 要装到该仓库且 Contents: Read-only），回退才看 Secret PRIVATE_REPO_TOKEN 是否有效（PAT 需对该仓库有 Contents 读权限）"
    exit 1
  fi

  # openwrt-fttr 硬 include 了 feeds/packages/lang/rust/rust-package.mk，
  # 这个文件不在的话 dump 直接失败、包静默不进索引。
  # 与其等到 defconfig 把它剔掉才发现，不如在这里就报错退出。
  if [ "$ADD_FTTR_TOOLS" = "true" ] && [ ! -f feeds/packages/lang/rust/rust-package.mk ]; then
    echo "::error::未找到 feeds/packages/lang/rust/rust-package.mk，openwrt-fttr 无法索引"
    echo "        确认 packages feed 已 update + install；或把 ADD_FTTR_TOOLS 置为 false"
    exit 1
  fi

  # 用户态后端改名后源目录不稳定（fttr / fttr-tools / h3c-fttr-tools），
  # 逐个探测；拷进 package/custom 时统一用包名 openwrt-fttr。
  FTTR_TOOLS_SRC=""
  for cand in fttr fttr-tools h3c-fttr-tools openwrt-fttr; do
    if [ -f "$FTTR_FEED_TMP/$cand/Makefile" ]; then
      FTTR_TOOLS_SRC="$cand"
      break
    fi
  done
  if [ "$ADD_FTTR_TOOLS" = "true" ] && [ -z "$FTTR_TOOLS_SRC" ]; then
    echo "::error::openwrt-fttr 源目录未找到（依次试过 fttr / fttr-tools / h3c-fttr-tools / openwrt-fttr）"
    exit 1
  fi

  FTTR_FEED_PKGS=""
  [ "$ADD_FMCS" = "true" ]       && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs"
  [ "$ADD_FTTR_TOOLS" = "true" ] && FTTR_FEED_PKGS="$FTTR_FEED_PKGS $FTTR_TOOLS_SRC"
  [ "$ADD_FMCS_FW" = "true" ]    && FTTR_FEED_PKGS="$FTTR_FEED_PKGS h3c-fmcs-firmware"

  for p in $FTTR_FEED_PKGS; do
    if [ ! -f "$FTTR_FEED_TMP/$p/Makefile" ]; then
      echo "::error::$FTTR_FEED_TMP/$p/Makefile 不存在（上游改结构了？）"
      exit 1
    fi
    # 源目录名可能与包名不同，统一落到与 CONFIG_PACKAGE_ 一致的目录名
    case "$p" in
      fttr|fttr-tools|h3c-fttr-tools|openwrt-fttr) dst="openwrt-fttr" ;;
      *) dst="$p" ;;
    esac
    rm -rf "$PKG_DIR/$dst"
    cp -a "$FTTR_FEED_TMP/$p" "$PKG_DIR/$dst"
    echo "✅ 已拷贝: $p → $dst  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$dst/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done
  rm -rf "$FTTR_FEED_TMP"
fi

# =========================================================
# luci-app-fttr —— FTTR 管理界面（网络 → FTTR）★HM2004-DU 专属
# 源 LazuliKao/luci-app-fttr 的 package 分支（CI 产物，前端 JS 随包提交，
# 编译期不联网、无 hash 失效问题）。后端仍由上面的私有 feed 提供。
# ⚠ 该分支 orphan + force-push（每次只 1 个 commit），必须 --depth 1 重拉。
# ⚠ 上游 Makefile 漏了 "# call BuildPackage" 标记行。scan.mk 用文本 grep 找它
#   决定哪些 Makefile 进 FILELIST（不展开 include），缺了就不 DUMP、不进
#   tmp/.packageinfo，表现为「别的包全 ✅ 唯独它 ❌ 且无 dump.txt」。故下方幂等补。
# =========================================================
if [ "$ADD_FTTR" = "true" ] && [ "$ADD_FTTR_LUCI" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
  # 用独立变量名，不与 workflow 里指向「源码仓 main 分支」的 FTTR_LUCI_* 冲突
  FTTR_PKG_REPO="${FTTR_PKG_REPO:-LazuliKao/luci-app-fttr}"
  FTTR_PKG_BRANCH="${FTTR_PKG_BRANCH:-package}"
  FTTR_TMP="$(mktemp -d)/fttr"
  if ! clone "https://github.com/${FTTR_PKG_REPO}" "$FTTR_TMP" "$FTTR_PKG_BRANCH"; then
    echo "::error::luci-app-fttr 的 ${FTTR_PKG_BRANCH} 分支拉取失败，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
  # 分支根目录就该是完整包；顺手确认前端产物在，防止 CI 生成了空壳
  if [ ! -f "$FTTR_TMP/Makefile" ] || \
     [ ! -d "$FTTR_TMP/htdocs/luci-static/resources/view/fttr" ]; then
    echo "::error::$FTTR_TMP 不是完整 OpenWrt 包（缺 Makefile 或 htdocs/view/fttr）"
    exit 1
  fi

  rm -rf "$PKG_DIR/luci-app-fttr"
  cp -a "$FTTR_TMP" "$PKG_DIR/luci-app-fttr"
  rm -rf "$PKG_DIR/luci-app-fttr/.git"   # 别把克隆元数据带进源码树

  # scan.mk 只按文本 grep 'call BuildPackage' 收录 Makefile，luci.mk 里的真实
  # 调用不算（grep 不展开 include）。上游 CI 模板漏了这行标准注释，补回来：
  # 注释行对 make 无害，但缺了它整个包不会被索引。上游修好后自动跳过。
  FTTR_MK="$PKG_DIR/luci-app-fttr/Makefile"
  if ! grep -qE 'call[[:space:]]+(Build/DefaultTargets|BuildPackage|BuildContainer|BuildCompose|KernelPackage)' "$FTTR_MK"; then
    printf '\n# call BuildPackage - OpenWrt buildroot signature\n' >> "$FTTR_MK"
    echo "⚠ 已补 BuildPackage 扫描标记（上游 package 分支 Makefile 缺失）"
  fi

  echo "✅ 已拷贝: luci-app-fttr (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-fttr/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  rm -rf "$FTTR_TMP"
fi


# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 目录名决定包名（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），必须是
# luci-app-airoha-npu，否则 config 里的符号对不上。
# 源 luanmuc/luci-app-airoha-npu：自带 zh_Hans 翻译，无「根目录+同名子目录」坏结构。
if [ "$ADD_AIROHA_NPU" = "true" ]; then
  if ! clone https://github.com/luanmuc/luci-app-airoha-npu "$PKG_DIR/luci-app-airoha-npu" main; then
    echo "::error::luci-app-airoha-npu 拉取失败，后续 defconfig 会静默剔除该包"
    exit 1
  fi
  # 包名校验：Makefile 必须存在，否则 buildroot 扫不到这个包
  if [ ! -f "$PKG_DIR/luci-app-airoha-npu/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-app-airoha-npu/Makefile 不存在，包无法被索引"
    exit 1
  fi
  echo "   版本: $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-airoha-npu/Makefile" 2>/dev/null)"
  # po 必须改名 airoha-npu.po：luci.mk 按 po 主名生成 lmo，运行时按
  # LUCI_BASENAME(=airoha-npu) 查找，不改名则中文不生效。
  PODIR="$PKG_DIR/luci-app-airoha-npu/po"
  if [ -f "$PODIR/zh_Hans/luci-app-airoha-npu.po" ]; then
    # 确保 Language 头是 zh_Hans（上游头部缺该字段时 po2lmo 可能识别异常）
    grep -q '^"Language:' "$PODIR/zh_Hans/luci-app-airoha-npu.po" || \
      sed -i 's/^msgstr ""$/msgstr ""\n"Language: zh_Hans\\n"/' "$PODIR/zh_Hans/luci-app-airoha-npu.po"
    mv "$PODIR/zh_Hans/luci-app-airoha-npu.po" "$PODIR/zh_Hans/airoha-npu.po"
    echo "✅ po 改名: luci-app-airoha-npu.po -> airoha-npu.po（luci.mk 按 LUCI_BASENAME 查找）"
  fi
  if [ -f "$PODIR/es/luci-app-airoha-npu.po" ]; then
    mv "$PODIR/es/luci-app-airoha-npu.po" "$PODIR/es/airoha-npu.po"
  fi
  echo "   po/zh_Hans: $(ls -1 "$PODIR/zh_Hans/" 2>/dev/null | tr '\n' ' ')"
  # 健壮性补丁（本地随仓库分发的 patch-airoha-npu.py）：
  #   ① devmem 空值保护，避免读取失败返回空时 dash/ash 算术报错；
  #   ② PLL 等待增强：前后读回 PCW/CHG 一致性确认，异常 rollback。
  #   幂等；rpcd 格式变动导致正则未命中时降级 warning，不阻断构建。
  NPU_RPCD="$PKG_DIR/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu"
  if [ -f "$GITHUB_WORKSPACE/patch-airoha-npu.py" ]; then
    python3 "$GITHUB_WORKSPACE/patch-airoha-npu.py" "$NPU_RPCD" \
      || echo "::warning::NPU 健壮性补丁未命中，跳过（不阻断构建）"
  else
    echo "::warning::未找到 patch-airoha-npu.py，跳过 NPU 健壮性补丁"
  fi
fi

# --- passwall ---
# 源已从 xiaorouji 迁到 Openwrt-Passwall（旧地址 404）。
# ⚠ 只拷 luci-app-passwall 子目录：同仓的 xray-core/sing-box 等全与 feeds 同名。
if [ "$ADD_PASSWALL" = "true" ]; then
  PW_TMP="$(mktemp -d)/pw"
  if clone https://github.com/Openwrt-Passwall/openwrt-passwall "$PW_TMP" main \
     && [ -f "$PW_TMP/luci-app-passwall/Makefile" ]; then
    rm -rf "$PKG_DIR/luci-app-passwall"
    cp -r "$PW_TMP/luci-app-passwall" "$PKG_DIR/"
    echo "✅ 已拷贝: luci-app-passwall"
  else
    echo "::error::luci-app-passwall 拉取失败或结构变化"
  fi
  rm -rf "$PW_TMP"
fi
# --- openclash ---
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
fi
# --- mosdns ---
# ⚠ 只拷 luci-app-mosdns：仓库还带 mosdns 本体与 v2ray-geodata，均与 feeds 同名。
if [ "$ADD_MOSDNS" = "true" ]; then
  MD_TMP="$(mktemp -d)/mosdns"
  if clone https://github.com/sbwml/luci-app-mosdns "$MD_TMP" v5 \
     && [ -f "$MD_TMP/luci-app-mosdns/Makefile" ]; then
    rm -rf "$PKG_DIR/luci-app-mosdns" "$PKG_DIR/geo2txt"
    cp -r "$MD_TMP/luci-app-mosdns" "$PKG_DIR/"
    # geo2txt 是 luci-app-mosdns 的硬依赖（LUCI_DEPENDS 里 +geo2txt），
    # feeds 里没有同名包，必须一起拷进来，否则索引时报
    # "has a dependency on 'geo2txt', which does not exist"
    if [ -f "$MD_TMP/geo2txt/Makefile" ]; then
      cp -r "$MD_TMP/geo2txt" "$PKG_DIR/"
      echo "✅ 已拷贝: geo2txt（luci-app-mosdns 依赖）"
    else
      echo "::warning::mosdns 仓库里没有 geo2txt，luci-app-mosdns 会缺这个依赖"
    fi
    echo "✅ 已拷贝: luci-app-mosdns（本体用 feeds）"
  else
    echo "::error::luci-app-mosdns 拉取失败或结构变化"
  fi
  rm -rf "$MD_TMP"
fi
# --- lucky ---
if [ "$ADD_LUCKY" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-lucky "$PKG_DIR/luci-app-lucky" main
fi
# --- tailscale ---
if [ "$ADD_TAILSCALE" = "true" ]; then
  clone https://github.com/asvow/luci-app-tailscale "$PKG_DIR/luci-app-tailscale" main
fi
# --- openlist2 ---
if [ "$ADD_OPENLIST" = "true" ]; then
  clone https://github.com/sbwml/luci-app-openlist2 "$PKG_DIR/luci-app-openlist2" main
fi

# --- smartdns ---
# ⚠ 不拉 pymumu/smartdns 本体：与 feeds/packages/net/smartdns 同名。
if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
fi
# --- luci-theme-fluent ---
# ⚠ 包在仓库的 package/ 子目录下，不能直接 clone 到 package/custom，
#   必须把子目录拷出来，否则 buildroot 扫不到 Makefile
if [ "$ADD_FLUENT" = "true" ] || [ "$ADD_FLUENT_LITE" = "true" ] || [ "$ADD_FLUENT_DASH" = "true" ]; then
  FLUENT_TMP="$(mktemp -d)/fluent"
  clone https://github.com/LazuliKao/luci-theme-fluent "$FLUENT_TMP" main

  for p in luci-theme-fluent luci-theme-fluent-lite luci-mod-fluentdashboard; do
    case "$p" in
      luci-theme-fluent)        [ "$ADD_FLUENT" = "true" ] || continue ;;
      luci-theme-fluent-lite)   [ "$ADD_FLUENT_LITE" = "true" ] || continue ;;
      luci-mod-fluentdashboard) [ "$ADD_FLUENT_DASH" = "true" ] || continue ;;
    esac
    [ -d "$FLUENT_TMP/package/$p" ] || { echo "::error::$p 不存在"; continue; }
    rm -rf "$PKG_DIR/$p"
    cp -a "$FLUENT_TMP/package/$p" "$PKG_DIR/$p"
    echo "✅ 已拷贝: $p"
  done
  rm -rf "$FLUENT_TMP"
fi

if [ "$ADD_EASYTIER" = "true" ]; then
  clone https://github.com/EasyTier/luci-app-easytier "$PKG_DIR/luci-app-easytier" main
fi
if [ "$ADD_POWEROFF" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-poweroffdevice "$PKG_DIR/luci-app-poweroffdevice" master
fi
if [ "$ADD_OWQ_WOL" = "true" ]; then
  clone https://github.com/isalikai/luci-app-owq-wol "$PKG_DIR/luci-app-owq-wol" main
fi
if [ "$ADD_TASKPLAN" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-taskplan "$PKG_DIR/luci-app-taskplan" main
fi
# --- watchdog ---
# ⚠ 仓库是 monorepo：根目录无 Makefile，luci-app-watchdog/（前端）与
#   watchdog/（本体）是两个包，前者依赖 +watchdog，两个都要拷。
#   只拷前端时索引会报 "has a dependency on 'watchdog', which does not exist"。
if [ "$ADD_WATCHDOG" = "true" ]; then
  WD_TMP="$(mktemp -d)/wd"
  if clone https://github.com/sirpdboy/luci-app-watchdog "$WD_TMP" main; then
    for p in luci-app-watchdog watchdog; do
      [ -f "$WD_TMP/$p/Makefile" ] || { echo "::warning::$p 不存在（上游改结构了？）"; continue; }
      rm -rf "$PKG_DIR/$p"
      cp -r "$WD_TMP/$p" "$PKG_DIR/"
      echo "✅ 已拷贝: $p"
    done
  else
    echo "::error::luci-app-watchdog 拉取失败"
  fi
  rm -rf "$WD_TMP"
fi
if [ "$ADD_OAF" = "true" ]; then
  clone https://github.com/destan19/OpenAppFilter "$PKG_DIR/OpenAppFilter" master
  for p in luci-app-oaf open-app-filter oaf; do
    cp -r "$PKG_DIR/OpenAppFilter/$p" "$PKG_DIR/" 2>/dev/null
  done
  rm -rf "$PKG_DIR/OpenAppFilter"
fi
# ---------------------------------------------------------
# 校验：开关为 true 的包必须拉到，否则 defconfig 会静默剔除
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi
# natmode / pon-status / igmpproxy 来自 qwe-qaq/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status luci-app-igmpproxy; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done
# ---------------------------------------------------------
# 补回 libffi —— python3 的 _ctypes 硬性需要 ffi.h
# CPython 3.11 起删了 --with-system-ffi，_ctypes 永远 #include <ffi.h>，而
# ponwrt 与 immortalwrt/packages 的 libffi 目录都已不存在，编到 _ctypes.c 才报
# "ffi.h: No such file"。这里从 immortalwrt 基座取现成包定义（自带 InstallDev，
# 会把 ffi.h / libffi.pc 装进 staging_dir），再给 python3 补构建依赖。
# ⚠ 必须放在 prepare-tmpinfo 之前，目录才能被扫进索引、PKG_BUILD_DEPENDS 才生效。
# ---------------------------------------------------------
FFI_DIR="package/custom/libffi"
if [ ! -d "$FFI_DIR" ]; then
  echo "--- 补回 libffi（python3 _ctypes 依赖，源码树中缺失）---"
  mkdir -p "$FFI_DIR"
  if curl -fsSL --retry 3 --max-time 60 \
       https://raw.githubusercontent.com/immortalwrt/immortalwrt/master/package/libs/libffi/Makefile \
       -o "$FFI_DIR/Makefile"; then
    echo "✅ 已补回 libffi ($(grep -m1 '^PKG_VERSION' "$FFI_DIR/Makefile" 2>/dev/null))"
  else
    echo "::error::libffi 包定义下载失败 —— python3 的 _ctypes 会因缺 ffi.h 编译失败"
    rm -rf "$FFI_DIR"
  fi
else
  echo "已存在，跳过: $FFI_DIR"
fi

# python3 只声明了 libffi/host，target 侧没声明，补一条确保 libffi 先编译
PY3MK="feeds/packages/lang/python/python3/Makefile"
if [ -f "$PY3MK" ] && ! grep -q 'PKG_BUILD_DEPENDS:=bluez libffi' "$PY3MK"; then
  sed -i 's|^PKG_BUILD_DEPENDS:=bluez|PKG_BUILD_DEPENDS:=bluez libffi|' "$PY3MK"
  echo "✅ python3 已补 libffi 构建依赖（PKG_BUILD_DEPENDS，保证先编 libffi）"
fi

# ---------------------------------------------------------
# 清理重复嵌套目录：根目录一份 + 同名子目录又一份时，feeds 会把两层都当独立包，
# 内层 dump 失败会中断整个 custom feed 的索引，导致所有包符号都不存在。
# ---------------------------------------------------------
echo "--- 检查重复嵌套目录 ---"
# ⚠ 判据必须含「根目录也有 Makefile」：lucky / openlist2 / easytier / taskplan /
#   poweroffdevice 的根目录没有 Makefile，同名子目录才是唯一那份包，只看
#   「有同名子目录」会把真包删掉。
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -f "$d/Makefile" ] && [ -d "$d/$n" ] && [ -f "$d/$n/Makefile" ]; then
    rm -rf "$d/$n"
    echo "✅ 已移除重复嵌套目录: $n/$n"
  fi
done
# ---------------------------------------------------------
# 让新包进入索引
# ⚠ 判据是 tmp/.packageinfo，不是 package/feeds/custom。
# prepare-tmpinfo 直接扫 package/ 树（scan.mk: find -L package -maxdepth 5），
# custom/<pkg>/Makefile 深度 3 本来就会被扫到，不需要注册 feed；旧 src-link
# custom feed 反而会让同一批 Makefile 被扫两遍、行为随扫描顺序漂移。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  # 强制重建索引：只删 tmp/.packageinfo 不够，scan_unchanged 会拿
  # tmp/info/.scan-*.stamp 比 mtime 跳过扫描，故 stamp 与 .files* 清单一起删。
  # cache 恢复的 tmp/ 与 cp -a 都保留旧 mtime，新 Makefile 可能比 stamp 还旧，
  # 故删完再统一 touch 一遍 package/custom（否则表现为「别的包都 ✅ 唯独它缺席」）。
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/info/.files* 2>/dev/null
  rm -f tmp/.config-package.in tmp/.config-target.in
  find "$PKG_DIR" -type f -exec touch {} + 2>/dev/null || true
  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make prepare-tmpinfo OPENWRT_BUILD= V=s 2>&1 | tail -60
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "::error::prepare-tmpinfo 执行失败，索引不会更新（见上方输出）"
    exit 1
  fi
  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  # 目录名 ≠ 包名（Makefile 显式写了 PKG_NAME / KernelPackage）：
  # open-app-filter→appfilter、oaf→kmod-oaf，按目录名查必然查不到，属误报。
  pkgname_of() {
    case "$1" in
      open-app-filter) echo "appfilter" ;;
      oaf)             echo "kmod-oaf" ;;
      h3c-fmcs)        echo "kmod-h3c-fmcs" ;;
      *)               echo "$1" ;;
    esac
  }

  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")

    # 无根 Makefile = monorepo 容器（lucky / openlist2 / easytier / taskplan /
    # poweroffdevice / watchdog），真正的包在同名子目录里，逐个查
    if [ ! -f "$d/Makefile" ]; then
      found=0
      # 直接对 glob 迭代，不拼字符串再分词 —— 拼了就得依赖 IFS 分词，
      # 换个 shell（zsh 默认不拆）行为就变
      for sd in "$d"/*/Makefile; do
        [ -f "$sd" ] || continue
        found=1
        sn="$(basename "$(dirname "$sd")")"
        if grep -qx "Package: $sn" tmp/.packageinfo 2>/dev/null; then
          echo "  ✅ $n → $sn"
        else
          echo "  ❌ $n → $sn —— tmp/.packageinfo 里查不到"
          INDEX_MISS="$INDEX_MISS $sn"
          for f in "logs/package/$sn/dump.txt" "logs/package/custom/$sn/dump.txt"; do
            [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
          done
        fi
      done
      [ "$found" = 1 ] || echo "  -  $n（无 Makefile，跳过）"
      continue
    fi

    pn="$(pkgname_of "$n")"
    if grep -qx "Package: $pn" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n${pn:+$([ "$pn" != "$n" ] && echo " → $pn")}"
    else
      echo "  ❌ $n（包名 $pn）—— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $pn"
      # 真实错误在这里（scan.mk 落盘路径 logs/<SCAN_DIR>/<相对目录>/dump.txt）
      DUMP_SHOWN=0
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; DUMP_SHOWN=1; }
      done
      # scan.mk 压根没落 dump.txt（缓存跳过扫描时常见）：直接单包 dump 一次，
      # 把 Makefile 解析错误打出来，避免「查不到但日志里没有任何线索」。
      if [ "$DUMP_SHOWN" -eq 0 ]; then
        echo "===== 直接 dump: make $d/dump V=s ====="
        make "$d/dump" V=s 2>&1 | tail -40
      fi
    fi
  done
  echo "------------------------------------------"
  echo "luci.mk: $([ -f feeds/luci/luci.mk ] && echo '✓' || echo '✗ 缺失（luci app 无法解析）')"
  echo "tmp/.packageinfo 包总数: $(grep -c '^Package: ' tmp/.packageinfo 2>/dev/null || echo 0)"
  echo "=========================================="
  # 必装插件（config 里是 =y 的那几个）必须进索引，否则 defconfig 会静默剔除
  REQUIRED=""
  [ "$ADD_AIROHA_NPU" = "true" ] && REQUIRED="$REQUIRED luci-app-airoha-npu"
  if [ "$ADD_LUCI_APP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status luci-app-igmpproxy"
  fi

  # 与 configs/*.config 里 =y 的包一一对应；没进索引的会被 defconfig 静默剔除。
  [ "$ADD_FLUENT"    = "true" ] && REQUIRED="$REQUIRED luci-theme-fluent"
  [ "$ADD_OPENCLASH" = "true" ] && REQUIRED="$REQUIRED luci-app-openclash"
  [ "$ADD_PASSWALL"  = "true" ] && REQUIRED="$REQUIRED luci-app-passwall"
  [ "$ADD_MOSDNS"    = "true" ] && REQUIRED="$REQUIRED luci-app-mosdns"
  [ "$ADD_LUCKY"     = "true" ] && REQUIRED="$REQUIRED luci-app-lucky"
  [ "$ADD_TAILSCALE" = "true" ] && REQUIRED="$REQUIRED luci-app-tailscale"
  [ "$ADD_OPENLIST"  = "true" ] && REQUIRED="$REQUIRED luci-app-openlist2"
  [ "$ADD_SMARTDNS"  = "true" ] && REQUIRED="$REQUIRED luci-app-smartdns"
  [ "$ADD_EASYTIER"  = "true" ] && REQUIRED="$REQUIRED luci-app-easytier"
  [ "$ADD_POWEROFF"  = "true" ] && REQUIRED="$REQUIRED luci-app-poweroffdevice"
  [ "$ADD_OWQ_WOL"   = "true" ] && REQUIRED="$REQUIRED luci-app-owq-wol"
  [ "$ADD_WATCHDOG"  = "true" ] && REQUIRED="$REQUIRED luci-app-watchdog"
  [ "$ADD_TASKPLAN"  = "true" ] && REQUIRED="$REQUIRED luci-app-taskplan"
  [ "$ADD_OAF"       = "true" ] && REQUIRED="$REQUIRED luci-app-oaf"
  true
  if [ "$ADD_FTTR" = "true" ] && [ "$FTTR_PROFILE" = "h3c_hm2004-du" ]; then
    # KernelPackage 生成的包名带 kmod- 前缀，索引里写的是 kmod-h3c-fmcs
    if [ "$ADD_FMCS" = "true" ]; then
      REQUIRED="$REQUIRED kmod-h3c-fmcs"
    fi
    if [ "$ADD_FMCS_FW" = "true" ]; then
      REQUIRED="$REQUIRED h3c-fmcs-firmware"
    fi
    if [ "$ADD_FTTR_TOOLS" = "true" ]; then
      REQUIRED="$REQUIRED openwrt-fttr"
    fi
    if [ "$ADD_FTTR_LUCI" = "true" ]; then
      REQUIRED="$REQUIRED luci-app-fttr"
    fi
    # luci-app-fttr → openwrt-fttr → kmod-h3c-fmcs，链条上任一节缺失，
    # defconfig 都会静默剔掉整条 FTTR。前者多为缺 rust-package.mk，
    # 后者受 @(TARGET_airoha_an7581) 限制。
    if [ "$ADD_FTTR_TOOLS" = "true" ] &&
       ! grep -qx "Package: openwrt-fttr" tmp/.packageinfo 2>/dev/null; then
      echo "::error::openwrt-fttr 不在包索引里（luci-app-fttr 的后端，Rust 包）"
      echo "        多半是缺 rust feed：确认 feeds.conf 里有 packages，且"
      echo "        ./scripts/feeds install 装到了 lang/rust。"
      echo "        不需要 FTTR 就把 diy-part.sh 阶段一 的 ADD_FTTR 改成 false。"
      exit 1
    fi
    if [ "$ADD_FMCS" = "true" ] &&
       ! grep -qx "Package: kmod-h3c-fmcs" tmp/.packageinfo 2>/dev/null; then
      echo "::error::kmod-h3c-fmcs 不在包索引里（openwrt-fttr 依赖它）"
      echo "        DEPENDS 是 @(TARGET_airoha_an7581)：非该 target 时包不会进索引。"
      echo "        不需要 FTTR 就把 diy-part.sh 阶段一 的 ADD_FTTR 改成 false。"
      exit 1
    fi
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第三方插件"
fi
echo "🎉 diy-part.sh 阶段一 执行完毕"
fi

# ################ 阶段二（原 diy-part2.sh）：默认值 / 时区 / WiFi / 版本 / 加密 ################
if [ "$STAGE" = "2" ] || [ "$STAGE" = "all" ]; then
set -euo pipefail

echo "=========================================="
echo "默认值定制：时区 + 5G WiFi (diy-part.sh 阶段二)"
echo "=========================================="

# =============================================================
# 可配置：无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
# 2.4G WiFi 参数
WIFI_24G_COUNTRY="${WIFI_24G_COUNTRY:-CN}"
WIFI_24G_CHANNEL="${WIFI_24G_CHANNEL:-auto}"

# 5G WiFi 参数
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"

# 可由 workflow 的 fw_author 输入项覆盖（经 env 注入）；本地单独跑时默认 qwe
FW_AUTHOR="${FW_AUTHOR:-qwe}"

echo "配置：2.4G country=$WIFI_24G_COUNTRY channel=$WIFI_24G_CHANNEL"
echo "配置：5G country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE fallback=$WIFI_5G_FALLBACK"
echo "配置：FW_AUTHOR=$FW_AUTHOR"

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "ℹ️ 未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
# B-M2: 原脚本只写时区，覆盖了仓库自带 99-timezone-cn 里的 NTP 服务器与
#   dnsmasq 重绑定白名单。这里合并完整内容：时区 + NTP + rebind_domain 白名单。
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
# 默认时区：Asia/Shanghai (CST-8)
# NTP：阿里云主用，cn.pool 备用；dnsmasq 重绑定白名单放行 NTP 时间源与联网检测域

# 时区
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI

# NTP 服务器（先清默认列表再写入）
uci -q set system.ntp='timeserver'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='ntp.aliyun.com'
uci -q add_list system.ntp.server='cn.pool.ntp.org'
uci -q set system.ntp.enabled='1'
uci -q commit system

# dnsmasq 重绑定保护白名单：放行 NTP 时间源与系统联网检测域，避免被误判为 DNS rebind
uci -q delete dhcp.@dnsmasq[0].rebind_domain
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/ntp.org.cn/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/aliyun.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/tencent.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/tencentyun.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/time.edu.cn/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/ntp.org/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/ntsc.ac.cn/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/apple.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/windows.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/cloudflare.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/msftncsi.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/msftconnecttest.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/microsoft.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/gstatic.com/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/gnome.org/'
uci -q add_list dhcp.@dnsmasq[0].rebind_domain='/mozilla.net/'
uci -q commit dhcp

exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区/NTP/重绑定白名单脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包 + libffi（python3 _ctypes 需要）
#   ⚠ 这里写入 .config 的项会被 workflow 的 Configure 步骤用 >> 追加、
#     make defconfig 展开后保留。Configure 里还有一道安全网重新启用
#     zoneinfo-asia / libffi / iw，防止 configs/${SOC}.config 里
#     的 `is not set` 覆盖这里的设置。
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  # 亚洲时区数据库（中国时区需要）
  echo "CONFIG_PACKAGE_zoneinfo-asia=y" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"

  sed -i '/^CONFIG_PACKAGE_libffi=/d; /^# CONFIG_PACKAGE_libffi is not set/d' .config
  # python3 _ctypes 需要 ffi.h / libffi.pc
  echo "CONFIG_PACKAGE_libffi=y" >> .config
  echo "✅ libffi 已加入 .config"
fi

# ---------------------------------------------------------
# 4. 5G WiFi：CN / auto / HE160
# ---------------------------------------------------------

# ---- 4a. 编译期：改 detect 脚本默认值（best effort） ----
DETECT_SCRIPT=""
for cand in \
  "package/kernel/mac80211/files/lib/wifi/mac80211.sh" \
  "package/kernel/mac80211/files/lib/wifi/mac80211.uc" \
  "package/network/services/hostapd/files/lib/wifi/mac80211.sh"; do
  [ -f "$cand" ] && { DETECT_SCRIPT="$cand"; break; }
done

if [ -n "$DETECT_SCRIPT" ]; then
  sed -i "s/option channel '36'/option channel 'auto'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='36'/option channel='auto'/g" "$DETECT_SCRIPT"
  echo "✅ detect 脚本默认信道 -> auto ($DETECT_SCRIPT)"
else
  echo "ℹ️ 未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-cn <<UCEOF
#!/bin/sh
# 无线 WiFi 默认值：2.4G/5G 国家码 CN、5G 信道 auto、频宽 160MHz
# 由 diy-part.sh 阶段二 生成（编译期常量注入）

COUNTRY_24G='$WIFI_24G_COUNTRY'
CHANNEL_24G='$WIFI_24G_CHANNEL'
COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-config "\$@"; }

if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80[+]80 MHz' || return 1
	return 0
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1

	if [ "\$is5g" = "1" ]; then
		ht="\$HTMODE"
		phy="\$(uci -q get wireless.\$dev.phy 2>/dev/null)"
		if [ -n "\$phy" ] && ! support_160 "\$phy"; then
			ht="\$FALLBACK"
			log "\$dev：未检测到 160MHz 能力，回落为 \$ht"
		fi
		uci -q set wireless.\$dev.country="\$COUNTRY"
		uci -q set wireless.\$dev.channel="\$CHANNEL"
		uci -q set wireless.\$dev.htmode="\$ht"
		log "\$dev (5G): country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
	else
		uci -q set wireless.\$dev.country="\$COUNTRY_24G"
		uci -q set wireless.\$dev.channel="\$CHANNEL_24G"
		log "\$dev (2.4G): country=\$COUNTRY_24G channel=\$CHANNEL_24G"
	fi
	changed=1
done

# B-L11: 不再硬编码覆盖 SSID（保留首次开机生成或用户自定义的 SSID）；
#   country_ie 不是标准 UCI 选项，已移除（国家码 country 已足够）。

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-cn
echo "✅ uci-defaults WiFi 脚本已写入"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    # 无线命令行工具（160MHz 能力检测需要）
    echo "CONFIG_PACKAGE_iw=y" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细
# ---------------------------------------------------------
if [ -f files/sbin/cpuusage ]; then chmod +x files/sbin/cpuusage; fi
if [ -f files/sbin/tempinfo ]; then chmod +x files/sbin/tempinfo; fi

SCRIPT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
PATCH_CPUUSAGE="$SCRIPT_DIR/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "ℹ️ 未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

# ========== 全面隐藏固件版本信息 ==========
RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

if [ -f "$RELEASE_TPL" ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" "$RELEASE_TPL"
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" "$RELEASE_TPL"
  echo "✅ openwrt_release 模板版本字段已清空"
fi

if [ -f "$OSREL_TPL" ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" "$OSREL_TPL"
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" "$OSREL_TPL"
  echo "✅ os-release 模板版本字段已清空"
fi

if [ -f "package/base-files/files/etc/openwrt_version" ]; then
  echo -n "" > package/base-files/files/etc/openwrt_version
  echo "✅ openwrt_version 已清空"
fi

BANNER="package/base-files/files/etc/banner"
if [ -f "$BANNER" ]; then
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" "$BANNER" || true
  echo "✅ banner 版本号行已清理（保留 ASCII art）"
fi

# apk 软件包源：默认中科大 USTC，双路径兼容
# B-H2: targets 子目录（an7581/an7583…）与架构（aarch64_cortex-a53…）不再写死，
#   从已加载的 .config 推导；读不到再回退 an7581 / aarch64_cortex-a53，避免 7583 机型套错源。
APK_SUBTARGET="$(grep -m1 '^CONFIG_TARGET_SUBTARGET=' .config 2>/dev/null | cut -d= -f2 | tr -d '\"')" || true
APK_SUBTARGET="${APK_SUBTARGET:-an7581}"
APK_ARCH="$(grep -m1 '^CONFIG_TARGET_ARCH_PACKAGES=' .config 2>/dev/null | cut -d= -f2 | tr -d '\"')" || true
APK_ARCH="${APK_ARCH:-aarch64_cortex-a53}"
echo "  apk targets=airoha/${APK_SUBTARGET} arch=${APK_ARCH}"

mkdir -p files/etc/apk/repositories.d

cat > files/etc/apk/repositories.d/distfeeds.list <<EOF
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/${APK_SUBTARGET}/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/telephony
EOF

cat > files/etc/apk/repositories <<EOF
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/targets/airoha/${APK_SUBTARGET}/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/base
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/luci
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/packages
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/routing
https://mirrors.ustc.edu.cn/immortalwrt/snapshots/packages/${APK_ARCH}/telephony
EOF

echo "✅ apk 软件包源默认 -> USTC snapshots（完整 6 个源，双路径兼容）"

# 后台菜单不显示"NAS"字样
# B-L9: package/feeds 下全是符号链接，grep -r 不跟随会空转；改扫 feeds/luci 真实源码目录。
grep -rl "NAS" feeds/luci --include='*.lua' 2>/dev/null \
  | while IFS= read -r f; do
      sed -i "s/_('NAS')/_(' ')/g; s/'NAS'/' '/g" "$f" || true
    done || true

# 强制禁用 passwall 系列（兜底）
# passwall 已由 ADD_PASSWALL=false 源头停用；xray-core 作为其内核一并强制禁用。
# sing-box 不再随 passwall 禁用：现作为 HomeProxy 内核编入（见 release.config）。
echo "🔒 强制禁用 passwall 系列..."
if [ -f ".config" ]; then
  for pkg in luci-app-passwall luci-app-passwall2 luci-i18n-passwall-zh-cn xray-core; do
    sed -i "/$pkg/d" .config 2>/dev/null || true
    echo "# CONFIG_PACKAGE_$pkg is not set" >> .config || true
  done
  echo "✅ .config 已强制禁用 passwall 系列包"
fi

# ========== IPTV 相关菜单统一移到「网络」菜单下 ==========
# ⚠ 原代码用 package/feeds/luci（符号链接目录，grep -r 不跟随），实际无效。
#   改用 feeds/luci（真实源码目录），清理才会生效。
echo "🔍 调整 IPTV 相关菜单位置..."
IPTV_MENU_PACKAGES="igmpproxy rtp2httpd"
for pkg in $IPTV_MENU_PACKAGES; do
  grep -rl "$pkg" feeds/luci --include="*.json" 2>/dev/null | while IFS= read -r f; do
    if grep -q '"parent"' "$f" 2>/dev/null; then
      old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 已调整 $pkg 菜单: $old_parent -> network ($f)"
    fi
  done || true
done || true

grep -rl "igmpproxy\|rtp2httpd" feeds/luci --include="*.json" 2>/dev/null | while IFS= read -r f; do
  if grep -q '"parent"' "$f" 2>/dev/null; then
    old_parent=$(grep -o '"parent":\s*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"parent":\s*"//;s/"//' || echo "unknown")
    if [ "$old_parent" != "network" ]; then
      sed -i 's/"parent":\s*"[^"]*"/"parent": "network"/g' "$f" || true
      echo "✅ 兜底调整: $old_parent -> network ($f)"
    fi
  fi
done || true

echo "✅ IPTV 相关菜单位置调整完成"

# ========== 全面隐藏固件版本信息（多层面） ==========
# ⚠ package/feeds 下全是符号链接，grep -r 不跟随；改用 feeds/ 真实目录。
echo "🔍 搜索 LuCI 状态页固件版本行文件..."
grep -rl "Firmware Version" feeds --include="*.js" 2>/dev/null | while IFS= read -r f; do
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (JS) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true

grep -rl "Firmware Version" feeds --include="*.htm" --include="*.lua" 2>/dev/null | while IFS= read -r f; do
  line_num=$(grep -n "Firmware Version" "$f" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
  if [ -n "$line_num" ]; then
    sed -i "${line_num}d" "$f" || true
    echo "✅ 已从 $f (模板) 中删除固件版本行 (第 $line_num 行)"
  fi
done || true

echo "🔍 隐藏 LuCI 页脚版本信息..."
grep -rl "Powered by" feeds/luci --include="*.htm" --include="*.js" 2>/dev/null | while IFS= read -r f; do
  sed -i "s/LuCI Master [0-9.-]*/LuCI/g" "$f" || true
  sed -i "s/OpenWrt SNAPSHOT r[0-9a-f-]*/OpenWrt/g" "$f" || true
  echo "✅ 已从 $f 中清理页脚版本号"
done || true

grep -rl "OpenWrt" feeds/luci --include="*.htm" 2>/dev/null | while IFS= read -r f; do
  sed -i "/OpenWrt.*SNAPSHOT/d; /OpenWrt.*[0-9]/d" "$f" || true
done || true

echo "🔍 清空 LuCI 版本变量..."
grep -rl "luciversion" feeds/luci --include="*.js" 2>/dev/null | while IFS= read -r f; do
  sed -i "s/var luciversion = .*/var luciversion = '';/g" "$f" || true
  sed -i "s/luciversion = .*||.*/luciversion = '';/g" "$f" || true
done || true

# ========== EIP93 NPU 硬件加密优化 ==========
echo "🔍 优化 EIP93 NPU 硬件加密调用..."
# B-L8: 不再无条件写 /etc/modules.d/zz-eip93（模块在不支持的机型上会在开机时报错），
#   改由下面的 uci-defaults 脚本先确认模块存在 / 已加载，再决定是否 modprobe。

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/90-eip93-npu-optimize <<'EOF'
#!/bin/sh
log() {
  logger -t eip93-npu "$@"
  echo "[eip93-npu] $@"
}

# B-L8: 收窄匹配范围，只认 EIP93 / 硬件加密模块，避免裸匹配 "crypto" 命中内核通用 crypto 子系统。
HW_MOD_RE='eip93|crypto_hw|crypto-hw'

i=0
while [ $i -lt 5 ]; do
  if [ -d "/sys/class/crypto" ] || lsmod 2>/dev/null | grep -qE "$HW_MOD_RE"; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if lsmod 2>/dev/null | grep -qE "$HW_MOD_RE"; then
  log "✅ EIP93 硬件加密驱动已加载"
  if [ -d "/sys/class/crypto" ]; then
    hw_algs=$(ls /sys/class/crypto/ 2>/dev/null | grep -i "aes\|des\|sha" | head -5)
    log "硬件加速算法: $hw_algs"
  fi
  if [ -r "/proc/crypto" ]; then
    hw_count=$(grep -c "driver" /proc/crypto 2>/dev/null || echo 0)
    log "内核加密算法总数: $hw_count"
  fi
else
  log "⚠️  EIP93 驱动未加载，尝试手动加载..."
  # 先确认模块在 /lib/modules 里存在，不存在则不强行 modprobe。
  if [ -n "$(find /lib/modules -name 'crypto-hw-eip93.ko*' 2>/dev/null | head -1)" ]; then
    modprobe crypto-hw-eip93 2>/dev/null || true
    sleep 1
  fi
  if lsmod 2>/dev/null | grep -qE "$HW_MOD_RE"; then
    log "✅ 手动加载 EIP93 成功"
  else
    log "⚠️  EIP93 驱动加载失败，使用软件加密（可能此硬件不支持）"
  fi
fi

if command -v openssl >/dev/null 2>&1; then
  engines=$(openssl engine 2>/dev/null | grep -i "eip\|hw\|crypto" || echo "")
  if [ -n "$engines" ]; then
    log "OpenSSL 硬件引擎: $engines"
  fi
fi

log "EIP93 NPU 优化完成"
exit 0
EOF
chmod +x files/etc/uci-defaults/90-eip93-npu-optimize
echo "✅ EIP93 NPU 优化脚本已写入"

# ========== 运存（内存）容量优化（不牺牲网络速度） ==========
echo "🔍 优化运存占用（确保网络高速）..."
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/93-memory-optimize <<'EOF'
#!/bin/sh
log() {
  logger -t mem-optimize "$@"
  echo "[mem-optimize] $@"
}

sleep 3

log "优化日志占用（不影响网络）..."
uci -q set system.@system[0].log_size='64'
uci -q set system.@system[0].log_buffer_size='16'

log "优化内核参数..."
# ⚠ dirty_ratio / dirty_background_ratio 的有效范围是 0-100（百分比）。
#   原先写的 1000 / 500 会被内核拒绝，无任何效果。
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true

# B-L6: 不再设置 uhttpd.main.no_log='1' —— 关闭 Web 审计日志会丢失后台访问记录，
#   保留 uhttpd 默认日志；内存占用由上面的 log_size / log_buffer_size 控制。

uci -q commit system
log "内存优化配置已提交（不影响网络速度）"

if [ -r /proc/meminfo ]; then
  mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  log "内存状态: 总 ${mem_total}KB, 可用 ${mem_available}KB"
fi

log "运存优化完成（网络性能优先）"
exit 0
EOF
chmod +x files/etc/uci-defaults/93-memory-optimize
echo "✅ 运存优化脚本已写入（不牺牲网络速度）"

# ========== 首启清空版本信息（双重保险） ==========
cat > files/etc/uci-defaults/98-hide-version <<'EOF'
#!/bin/sh
log() {
  logger -t hide-version "$@"
  echo "[hide-version] $@"
}

if [ -f /etc/openwrt_release ]; then
  sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE=''/g" /etc/openwrt_release
  sed -i "s/^DISTRIB_REVISION=.*/DISTRIB_REVISION=''/g" /etc/openwrt_release
  log "已清空 /etc/openwrt_release"
fi

if [ -f /usr/lib/os-release ]; then
  sed -i "s/^OPENWRT_RELEASE=.*/OPENWRT_RELEASE=\"\"/g" /usr/lib/os-release
  sed -i "s/^VERSION=.*/VERSION=\"\"/g" /usr/lib/os-release
  log "已清空 /usr/lib/os-release"
fi

if [ -f /etc/openwrt_version ]; then
  echo -n "" > /etc/openwrt_version
  log "已清空 /etc/openwrt_version"
fi

log "清理 LuCI 状态页版本信息..."
for f in /usr/lib/lua/luci/controller/status.lua \
         /usr/lib/lua/luci/view/status/index.htm \
         /www/luci-static/resources/view/status/index.js; do
  if [ -f "$f" ]; then
    sed -i "/Firmware Version/d; /固件版本/d" "$f" 2>/dev/null || true
    log "已清理 $f"
  fi
done

if [ -f /etc/banner ]; then
  sed -i "/SNAPSHOT r[0-9]/d; /OpenWrt [0-9]/d; /ImmortalWrt [0-9]/d; /PonWrt SNAPSHOT/d" /etc/banner 2>/dev/null || true
  log "已清理 /etc/banner"
fi

log "版本信息隐藏完成（三重保险）"
exit 0
EOF
chmod +x files/etc/uci-defaults/98-hide-version
echo "✅ 版本隐藏 uci-defaults 脚本已写入（双重保险）"

# 加密脚本：用 $GITHUB_WORKSPACE 绝对路径 —— cwd 是 openwrt 源码树，
# 相对路径会指向 $BUILD_ROOT/openwrt/scripts/，找不到用户自备的脚本。
# 用 subshell 把 set -u 崩溃隔离在子进程，主脚本不受影响。
# 末尾 || true：本文件开头 set -euo pipefail，source 的子脚本里任何
# 步骤返回非 0 都会让这里当场退出。加密是可选增强，不该搞挂构建。
_crypto_sh="${GITHUB_WORKSPACE:-$(dirname "$0")}/scripts/diy-part2-crypto.sh"
if [ -f "$_crypto_sh" ]; then
  ( . "$_crypto_sh" ) || true
fi

# 7. 强制确保状态插件配置正确（防止被意外剔除）
# ⚠ 用精确锚定 /^CONFIG_PACKAGE_$pkg[= ]/d，避免误删包含子串的注释行。
#   workflow 的 Validate 步骤也做了同样的强制，这里作为本地单独跑时的兜底。
echo "🔒 强制确保状态插件配置..."
if [ -f ".config" ]; then
  for pkg in luci-app-airoha-npu luci-app-pon-status luci-app-natmode; do
    sed -i "/^CONFIG_PACKAGE_${pkg}[= ]/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
    echo "CONFIG_PACKAGE_$pkg=y" >> .config || true
  done
  echo "✅ 状态插件配置已强制确保"
fi

# 8. 强制确保 HomeProxy 及其内核（防止被意外剔除，或被兜底禁用段回写 not set）
echo "🔒 强制确保 HomeProxy 配置..."
if [ -f ".config" ]; then
  for pkg in luci-app-homeproxy luci-i18n-homeproxy-zh-cn sing-box; do
    sed -i "/^CONFIG_PACKAGE_${pkg}[= ]/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
    echo "CONFIG_PACKAGE_$pkg=y" >> .config || true
  done
  echo "✅ HomeProxy 配置已强制确保"
fi

echo "🎉 diy-part.sh 阶段二 执行完毕 (author=$FW_AUTHOR)"
fi
