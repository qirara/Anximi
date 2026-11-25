# 与 Surfing (mihomo) 共存

以下内容已对照 Surfing v7.9.0（GitMetaio/Surfing，fork 为 qirara/Surfing）的脚本逐条核实，见文末「核实结果」。

## 两个模块各管什么

| | Surfing (mihomo) | Anximi |
|---|---|---|
| iptables 表 | `mangle`（TPROXY：`BOX_EXTERNAL`/`BOX_LOCAL`/`DIVERT`/`LOCAL_IP_V*`）、`nat`（REDIRECT 与 DNS 劫持：`CLASH_DNS_*`）；`filter` 里只有 `INPUT` 的 `BOX_INPUT_FILTER`（加固版另有 `BOX_LAN_GUARD`）和 `OUTPUT` 的 `SURF_BLOCK`（「UID 应用断网」） | 只用 `filter` |
| 自有链 | 如上 | `ANXIMI_OUT`（v4 + v6） |
| 挂载点 | `filter OUTPUT` 只有 `-I OUTPUT 1 -j SURF_BLOCK` | `filter OUTPUT` 第 1 条：`-j ANXIMI_OUT` |
| fwmark / ip rule / 路由表 | 用（mark `0x1000000`，表 2024） | **不用** |
| 匹配方式 | 按 UID/包名决定走不走代理 | `-m owner --uid-owner <uid> -j REJECT` |
| /system/etc/hosts | **会挂载**：开机和文件变动时把 `/data/adb/box_bll/clash/etc/hosts` bind mount 上去（安装时选了「挂载 hosts」） | 模块挂载；检测到 Surfing 的 hosts 时把拦截条目同步进去 |

### 为什么不冲突

本机发出的包依次经过 `raw → mangle → nat → filter` 的 `OUTPUT` 链：

1. Surfing 在 `mangle OUTPUT` 打标记（TPROXY 模式）或在 `nat OUTPUT` 改目的地址到本地端口（REDIRECT 模式）。
2. 然后包进入 `filter OUTPUT`，第 1 条就是 `ANXIMI_OUT`。这里看的是**发包进程的 UID**，与 Surfing 打没打标记、目的地址改没改都无关。
3. 被拦的 App → `REJECT`，连代理入口都到不了；其他 App 继续正常走 Surfing。

mihomo 进程本身以 root 或 system 身份运行（UID < 10000），Anximi 永远不会给 UID < 10000 加规则，所以不会断掉代理。

### 启动顺序

两者都在 `service.sh`（late_start）阶段运行。Anximi 等 `sys.boot_completed` 后再延迟 20 秒，只是为了减少同时抢 xtables 锁；所有 iptables 调用都带 `-w` 等锁。**谁先谁后结果都一样**，因为两边动的是不同的表。

Surfing 启停/重载时只删除自己的链，不会清空 `filter OUTPUT`。它的 `SURF_BLOCK` 和 Anximi 的 `ANXIMI_OUT` 都插到 `OUTPUT` 第 1 条，谁后插谁在前；两条链都只有 `REJECT`、没有 `ACCEPT`，所以先后不影响结果。看门狗（每 5 分钟 `iptables -C OUTPUT -j ANXIMI_OUT`）仍保留兜底。

### DNS

- Surfing 劫持 53 端口把 DNS 交给 mihomo（fake-ip）。Android 的系统解析器 (DnsResolver) **先查 `/system/etc/hosts`**，命中就不发 DNS 请求。
- 但 Surfing 会把自己的 hosts 文件 bind mount 到 `/system/etc/hosts`，**盖住** Anximi 模块挂载的 hosts。所以 Anximi 每次生成 hosts 时，只要 `/data/adb/box_bll/clash/etc/hosts` 存在，就把拦截条目写进该文件的 `# >>> Anximi … # <<< Anximi` 区块（原地写，Surfing 的 inotify 会实时重新挂载）。`hosts=0`、`anximi revert` 或卸载 Anximi 时只删这个区块，Surfing 自己的内容不动。
- system UID 的组件（安全中心、MIUI 守护进程、电量与性能等）iptables 不拦，它们的流量会进 mihomo，这时用下面的规则集在 mihomo 里 `REJECT` 补全。

## 在 mihomo 里引用 Anximi 的规则集

每次 `apply` 都会生成：

- `/data/adb/anximi/export/anximi-domains.yaml`：`behavior: domain`，包含所有启用分类的域名，`+.` 通配会原样保留（比 hosts 覆盖面更广）。
- `/data/adb/anximi/export/anximi-process.yaml`：`behavior: classical`，`PROCESS-NAME,<包名>`，即所有启用了「网络拦截」的包。

新版 mihomo 只允许读取工作目录内的文件（`SAFE_PATHS`）。Surfing 的 mihomo 以 `-d /data/adb/box_bll/clash` 启动，所以规则集要放到 `/data/adb/box_bll/clash/rules`。「mihomo 规则集额外复制到」留空时，只要该目录存在就自动复制过去；填 `-` 表示不复制。

qirara/Surfing 加固版的默认 `config.yaml` 已经引用了下面两个规则集（并在安装时放好占位文件），不用手动加。上游 Surfing 需要自己加，注意上游模块更新时如果选「使用新默认配置」会覆盖你的 `config.yaml`。

```yaml
rule-providers:
  anximi-domains:
    type: file
    behavior: domain
    format: yaml
    path: ./rules/anximi-domains.yaml
  anximi-process:
    type: file
    behavior: classical
    format: yaml
    path: ./rules/anximi-process.yaml

rules:
  # 放在最前面，先于任何 DIRECT / 代理规则
  - RULE-SET,anximi-domains,REJECT
  - RULE-SET,anximi-process,REJECT
  # ……你的其他规则
```

注意：

- 规则集只是**补充**。即使 mihomo 没引用它们，Anximi 的 hosts + iptables 也会照常工作；反过来 Surfing 关掉后 Anximi 也不受影响。
- `PROCESS-NAME` 需要 mihomo 开启进程匹配（`find-process-mode: strict` 或 `always`）。共享 UID 1000 的系统组件无法按包名区分，只能靠域名规则集。
- 如果你在 Surfing 里用「黑/白名单按包名决定是否代理」，Anximi 拦截的包放进哪边都可以，反正它们在 `filter` 表就被拒绝了。
- Anximi 的 hosts 列表也导出为 `/data/adb/anximi/export/hosts.txt`。

## 验证

```sh
# 1. Anximi 的跳转在 filter OUTPUT 第一条，Surfing 的规则仍在 mangle/nat
iptables -w -S OUTPUT | head -3
iptables -w -S ANXIMI_OUT
iptables -w -t mangle -S | head
iptables -w -t nat -S | head

# 2. 被拦的 App 计数在涨，其他 App 正常走代理
iptables -w -L ANXIMI_OUT -v -n

# 3. hosts 生效（Surfing 开着时也应解析到 0.0.0.0）
ping -c1 data.mistat.xiaomi.com

# 4. 关掉再打开 Surfing 后跳转还在（或 5 分钟内被看门狗补回）
anximi status | grep ipt_hooked
```

## 核实结果（Surfing v7.9.0）

1. ✅ 不清空 `filter OUTPUT`：`destroy_all_rules` 只删自己的链。`filter` 里另有 `INPUT` 的 `BOX_INPUT_FILTER` 和 `OUTPUT` 的 `SURF_BLOCK`，与 `ANXIMI_OUT` 互不影响。
2. ✅ mihomo 以 `root:net_admin`（UID 0）运行，`box_user_group` 可改，但不会落到 ≥ 10000。
3. ❌ 原假设「Surfing 不挂载 hosts」不成立：`Surfing_service.sh` / `box.inotify` 会 bind mount 自己的 hosts。已改为同步到 Surfing 的 hosts 文件（见上文 DNS 一节）。`anximi status` 的 `surfing_hosts=` 显示同步了多少条。
4. ✅ 工作目录是 `/data/adb/box_bll/clash`，规则目录 `./rules` 已存在；现在自动识别。
5. ✅ Surfing 默认 `find-process-mode: always`，`PROCESS-NAME` 规则可用。
6. 注意：卸载 Surfing 会 `rm -rf /data/adb/box_bll`，不影响 Anximi（数据在 `/data/adb/anximi`）。
