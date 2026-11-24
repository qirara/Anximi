# Anximi — HyperOS/MIUI 隐私模块

一个 Magisk / KernelSU / APatch 通用模块：按分类、可逆地切断 HyperOS/MIUI 系统组件的广告、遥测、云控、安全云检测、AI 上传链路；在网络拦截之外，用 root 能力停掉本地采集；覆盖所有用户（机主、第二空间、Island 工作资料、双开空间）。

目标设备：POCO F9 Ultra（songyuan）欧版 HyperOS 3.0.3 / Android 16。国际版、EEA、国行都能用，清单里不存在的包会自动跳过。

> 安装后**不会自动改动任何东西**，直到你在 WebUI 里点「保存并应用」（或执行 `anximi apply`）。

## 能做什么

| 分类 | 例子 |
|---|---|
| 广告 | MSA (`com.miui.msa.global` / `com.miui.systemAdSolution`)、MAB、App Vault 负一屏、壁纸轮播、快应用、GetApps 推荐 |
| 遥测与统计 | `com.miui.analytics`、`com.miui.daemon`、MiSight、错误/崩溃上报、SIM 激活上报 |
| 云控 | Joyose、电量与性能 / 权限管理器 / MIUI SDK 的联网部分（核心包只断网不禁用） |
| 安全云检测 | 安全中心、安全扫描引擎 (guardprovider)、安装器安装时云扫描（只断网） |
| AI 与内容识别上传 | 传送门/Taplus、内容捕获、AI 通话/字幕、HyperAI 引擎、语音唤醒、扫一扫 |
| 小米账号与云服务 | 云备份/同步、云服务、XMSF 推送、查找设备、账号（默认不启用） |

每个分类可以任意组合这些手段：

| 手段 | 做了什么 | 怎么还原 |
|---|---|---|
| 网络拦截 | ① 模块 `/system/etc/hosts` 写入该分类的域名；② iptables `filter` 表自有链 `ANXIMI_OUT`，按 UID `REJECT`（每个用户的 UID 都会算进去）；③ 导出 mihomo 规则集 | 清空链和 hosts |
| 禁用 | `pm disable-user --user N` | `pm enable --user N` |
| 卸载 | `pm uninstall -k --user N`（APK 留在系统分区） | `pm install-existing --user N` |
| 限制后台/权限 | appops：`RUN_ANY_IN_BACKGROUND`、`RUN_IN_BACKGROUND`、`GET_USAGE_STATS`、`READ_CLIPBOARD`、`SYSTEM_ALERT_WINDOW`、MIUI 自启动 (10008) 设为 `ignore`；撤销已授予的敏感运行时权限（电话、定位、通讯录、通话记录、短信、相机、麦克风、媒体、通知、附近设备、活动识别…）；待机分组设为 `restricted` | 逐项写回记录的原值 |

另外还有：

- **系统设置项**（本地采集）：关闭 WLAN/蓝牙扫描、MIUI 体验计划/诊断日志上传、A-GPS、联网检测地址改为 Google、NTP 改为 `time.android.com`。应用前记录原值，还原时写回。
- **组件禁用**：对必须保留的包（比如安全中心）只禁用其中的上传/统计组件。WebUI 可以扫描某个包的组件并勾选。
- **单包覆盖**：跳过、强制包含（无视风险阈值）、只断网、断网+限制…
- **自定义**：自定义包、自定义拦截域名、放行域名。
- **发现**：列出本机上清单里还没有的小米系包，方便补充。
- **预设**：保守 / 推荐 / 激进。

## 安全设计

- **全部可逆**：每一项改动都写进 `/data/adb/anximi/state/applied.list`（含原值）。`apply` 是增量的：改配置后再应用，不再需要的改动会自动还原。「全部还原」或卸载模块会逐项恢复。
- **只接管自己做的改动**：包原本就是禁用的、权限原本就没授予的，不记录也不会在还原时动它。
- **核心包保护**：安全中心、权限管理器、电量与性能、安装器、设置、SystemUI、桌面、GMS/Play 等只允许断网，就算手动强制也不会被禁用或卸载。
- **不拦 system UID**：`uid < 10000`（比如 `com.miui.daemon`、`com.miui.securitycenter` 共享的 1000）不加 iptables 规则，否则整机断网。这些包只靠 hosts 和 mihomo 规则集，WebUI 概览页会列出来。
- **风险分级**：清单每个包标了 低/中/高 风险，默认只处理低风险；中、高风险（GetApps、Joyose、查找设备、小米账号…）需要调高阈值或单独「强制包含」。
- **防砖**：连续 3 次开机没能完成，下次开机会在 package 服务可用时自动全部还原并关闭开机应用，WebUI 会显示提示。KernelSU/Magisk 的安全模式（开机按住音量下）也能禁用模块，但禁用模块不会撤销已做的 `pm` 改动，需要进系统后执行还原。
- **开机自动应用**（可关）：补上新建用户（第二空间/Island）里的同款组件，系统更新后被恢复的禁用/卸载会重新执行，重建 iptables。

## 安装与使用

1. 从 GitHub Actions 的构建产物下载 `Anximi-*.zip`，或在仓库里 `sh build.sh` 打包。
2. 在 KernelSU / APatch / Magisk 管理器里安装，重启。
3. **KernelSU / APatch**：在模块列表点 Anximi 的 WebUI。**Magisk**：用 [WebUI X](https://github.com/MMRLApp/WebUI-X-Portable) 或 KsuWebUIStandalone 打开，或者用模块的「操作」按钮（音量+ 应用、音量- 还原），或在终端里用命令。
4. 选好分类与手段 →「保存并应用」。hosts 首次生成或开关 hosts 后需要重启一次。

命令行（root shell）：

```sh
anximi status            # 环境与状态
anximi apply             # 按配置应用（增量）
anximi revert            # 全部还原
anximi inventory         # 清单 + 安装情况 + 实际手段
anximi preset recommended
anximi components com.miui.securitycenter
anximi discover          # 清单外的小米系包
anximi export-mihomo     # 导出 mihomo 规则集
anximi log
```

配置都在 `/data/adb/anximi/`：`config.conf`、`packages.conf`、`custom.list`、`custom.hosts`、`allow.hosts`、`components.conf`。卸载模块会还原全部改动并删除该目录（日志复制到 `/data/local/tmp/anximi-uninstall.log`）。

## 与 Surfing (mihomo) 共存

详见 [docs/SURFING.md](docs/SURFING.md)。要点：Anximi 只在 `filter` 表 `OUTPUT` 链首插入一个跳到自有链 `ANXIMI_OUT` 的规则，**不使用 mangle / nat 表、fwmark、ip rule 或路由表**，不碰 DNS 劫持，因此与 Surfing 的 TPROXY / REDIRECT 透明代理互不干扰，两个模块的启动顺序也无所谓。被拦截的 App 连代理入口都到不了；mihomo 进程本身是 root/system UID，永远不会被拦。

## 区域自适应（国行 / 国际 / EEA）

规格书第 5 节没有附上，按以下理解实现，有出入请指出：

- 区域由 `ro.product.mod_device`（`*_eea_global` → EEA，`*_global` → 国际）、`ro.miui.build.region`、`ro.miui.region` 自动识别，也可在「高级」里手动指定。
- 清单同时收录国行与国际版的包名（例如 MSA：`com.miui.systemAdSolution` / `com.miui.msa.global`；负一屏：`com.miui.personalassistant` / `com.mi.globalminusscreen`；安装器：`com.miui.packageinstaller` / `com.miui.global.packageinstaller`），每条标了区域，本机没装的自动跳过，所以同一份配置在两种 ROM 上都能用。
- 域名清单同时包含国内与 `intl` / `india` / `rus` 节点；多拦不存在的域名没有副作用。
- 国行默认联网检测走 `connect.rom.miui.com`，「本地采集」里可以改成 Google 的地址（需要能访问 Google，有 Surfing 代理时没问题）。

## 已知限制与假设

- **包名与域名清单是种子列表**：整理自公开的 MIUI/HyperOS 去广告与精简资料，**没有在 POCO F9 Ultra HyperOS 3.0.3 上逐一抓包验证**。HyperOS 3 可能改了包名或域名。建议先用「推荐」预设，配合 `anximi discover` 和抓包（如 mihomo 连接日志）补充 `custom.list` / `custom.hosts`。
- MIUI 的部分设置键（体验计划、诊断日志）在 HyperOS 3 上可能已无作用；写入无害，还原时会删除。
- 「组件扫描」只能看到 `dumpsys package` 里出现的组件（带 intent-filter 的服务/接收器等），看不到全部。
- bpf 后端（`cmd connectivity set-package-networking-enabled`）是实验功能，只作用于用户 0，其余用户仍走 iptables。
- hosts 只对走系统解析器的请求有效；App 自带 DoH / 硬编码 IP 时只能靠 UID 拦截或 mihomo 规则。
- 和其他挂载 `/system/etc/hosts` 的模块（AdAway systemless hosts 等）会互相覆盖；此时把 `hosts=0`，并把 `/data/adb/anximi/export/hosts.txt` 导入那个工具。
- 禁用「查找设备」「小米账号」前，请确认设备已退出小米账号，避免激活锁问题。

## 开发

```sh
sh tests/run.sh dash           # 用模拟的 pm/appops/iptables… 跑 apply → 再 apply → 改配置 → revert 的端到端测试
sh tests/run.sh "busybox sh"
sh tests/run.sh mksh
sh build.sh                    # 打包到 out/
```

WebUI 可以直接用浏览器打开 `webroot/index.html` 预览（会进入模拟数据模式）。

许可证：GPL-3.0。
