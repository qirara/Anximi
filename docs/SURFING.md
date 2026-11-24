# 与 Surfing (mihomo) 共存

Surfing 的 mihomo 节点配置还没写完，那边的项目进度在这里也读不到，所以下面是按 Surfing / box 类模块的通用做法设计的，**列出了所有假设**，配置写好后照「验证」一节检查一遍即可。

## 两个模块各管什么

| | Surfing (mihomo) | Anximi |
|---|---|---|
| iptables 表 | `mangle`（TPROXY + fwmark）或 `nat`（REDIRECT），可能还有 DNS 劫持 | 只用 `filter` |
| 自有链 | Surfing 自己的链（box 系通常叫 `BOX_*` 等） | `ANXIMI_OUT`（v4 + v6） |
| 挂载点 | `filter`/`OUTPUT` 以外的位置 | `filter`/`OUTPUT` 第 1 条：`-j ANXIMI_OUT` |
| fwmark / ip rule / 路由表 | 用 | **不用** |
| 匹配方式 | 按 UID/包名决定走不走代理 | `-m owner --uid-owner <uid> -j REJECT` |
| /system/etc/hosts | 不挂载（假设） | 挂载 |

### 为什么不冲突

本机发出的包依次经过 `raw → mangle → nat → filter` 的 `OUTPUT` 链：

1. Surfing 在 `mangle OUTPUT` 打标记（TPROXY 模式）或在 `nat OUTPUT` 改目的地址到本地端口（REDIRECT 模式）。
2. 然后包进入 `filter OUTPUT`，第 1 条就是 `ANXIMI_OUT`。这里看的是**发包进程的 UID**，与 Surfing 打没打标记、目的地址改没改都无关。
3. 被拦的 App → `REJECT`，连代理入口都到不了；其他 App 继续正常走 Surfing。

mihomo 进程本身以 root 或 system 身份运行（UID < 10000），Anximi 永远不会给 UID < 10000 加规则，所以不会断掉代理。

### 启动顺序

两者都在 `service.sh`（late_start）阶段运行。Anximi 等 `sys.boot_completed` 后再延迟 20 秒，只是为了减少同时抢 xtables 锁；所有 iptables 调用都带 `-w` 等锁。**谁先谁后结果都一样**，因为两边动的是不同的表。

如果 Surfing 重启时清空了 `filter OUTPUT`（box 系通常只删自己的规则，属于假设），Anximi 的看门狗每 5 分钟检查一次 `iptables -C OUTPUT -j ANXIMI_OUT`，丢了就补回。也可以在 Surfing 重启后手动执行 `anximi net-check`。

### DNS

- Surfing 劫持 53 端口把 DNS 交给 mihomo（fake-ip / redir-host）。Android 的系统解析器 (DnsResolver) **先查 `/system/etc/hosts`**，命中就不发 DNS 请求，所以 hosts 拦截在开了 Surfing 后依然有效。
- system UID 的组件（安全中心、MIUI 守护进程、电量与性能等）iptables 不拦，它们的流量会进 mihomo，这时用下面的规则集在 mihomo 里 `REJECT` 补全。

## 在 mihomo 里引用 Anximi 的规则集

每次 `apply` 都会生成：

- `/data/adb/anximi/export/anximi-domains.yaml`：`behavior: domain`，包含所有启用分类的域名，`+.` 通配会原样保留（比 hosts 覆盖面更广）。
- `/data/adb/anximi/export/anximi-process.yaml`：`behavior: classical`，`PROCESS-NAME,<包名>`，即所有启用了「网络拦截」的包。

新版 mihomo 只允许读取工作目录内的文件（`SAFE_PATHS`），所以在 WebUI「高级 → mihomo 规则集额外复制到」填 Surfing 的 mihomo 工作目录下的子目录，每次应用后会自动复制过去。**假设**该目录是 `/data/adb/box_bll/clash/rules`（Surfing 的常见路径，请按你的实际安装确认）。

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

## 假设清单

1. Surfing 只在 `mangle` / `nat` 表工作，不清空 `filter OUTPUT`。若它会清空，看门狗兜底。
2. mihomo 进程 UID < 10000（root 或 system）。
3. Surfing 不挂载 `/system/etc/hosts`。若挂载，两边会互相覆盖：把 Anximi 的 `hosts=0`，改用 mihomo 规则集。
4. Surfing 的 mihomo 工作目录是 `/data/adb/box_bll/clash`（只影响规则集复制路径，可在 WebUI 改）。
