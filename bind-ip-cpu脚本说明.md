# bind-ip CPU / Queue 绑定脚本说明

本文说明仓库中按 IP 绑定网卡 queue、IRQ CPU 和 XPS 的相关脚本，重点说明每个脚本能配置什么、适用场景、配置格式和关键限制。

## 1. 脚本能力总览

| 脚本 | 主要用途 | RX 能力 | TX 能力 | 典型场景 |
|---|---|---|---|---|
| `bind-ip-queue-cpu.sh` | 原始单 queue 绑定脚本 | `dst-ip[:dst-port] -> 单 RX queue -> IRQ CPU` | `src-ip[:src-port] -> 单 TX queue -> XPS CPU` | 在 Redis server 侧把一个 IP 绑定到一个 queue / CPU |
| `bind-remote-ip-queue-cpu.sh` | 单 queue 双模式脚本 | `server` / `client` 模式切换匹配方向 | `server` / `client` 模式切换匹配方向 | server 侧和 client 侧复用同一份 IP 配置 |
| `bind-ip-multi-queue-cpu.sh` | 多 queue / CPU range 脚本 | 单 queue 用 ntuple `action`；多 queue 用 RSS context | 单 queue 可强制 `queue_mapping`；多 queue 只配置 XPS | 一个 IP 或一组 IP 需要分散到多个 RX queue / CPU |
| `bind-ip-queue-cpu.py` | Python 版单 queue 脚本 | 与单 queue shell 版同类 | 与单 queue shell 版同类 | 参数解析更清晰，适合作为后续扩展参考 |

`★ Insight ─────────────────────────────────────`
这些脚本本质上在配置三层东西：硬件/驱动 RX flow steering、IRQ affinity、TX XPS / tc queue_mapping。
RX 是否能进入多个 queue 主要取决于 RSS context；TX 是否能按 IP 进入多个 queue 不是 XPS 能单独保证的。
如果目标是“按 IP 严格隔离 queue 组”，RX 比 TX 更容易做到。
`─────────────────────────────────────────────────`

## 2. `bind-ip-queue-cpu.sh`

这是最基础的 server 侧单 queue 绑定脚本。

配置语义：

```text
IP QUEUE CPU [PORT]
```

等价规则：

```text
RX: dst-ip[:dst-port] -> RX queue -> IRQ CPU
TX: src-ip[:src-port] -> TX queue -> XPS CPU
```

示例：

```bash
./bind-ip-queue-cpu.sh --dev enp23s0f1np1 \
  --rule 10.0.0.11:5:18:6379 \
  --dry-run
```

适合场景：

- Redis server 侧运行。
- 每个 IP 只需要绑定到一个 RX queue。
- 希望 RX 中断和 TX XPS 都落在同一个 CPU。

关键限制：

- 不支持一个 IP 绑定多个 RX queue。
- 不支持 `--mode client`，配置 IP 默认表示本机 server IP。
- `--delete-rules` 只删除 RX ntuple 规则和 TX egress filter，不恢复 IRQ affinity、RPS/RFS、XPS。

## 3. `bind-remote-ip-queue-cpu.sh`

这是单 queue 双模式脚本，配置文件格式与 `bind-ip-queue-cpu.sh` 兼容。

配置语义：

```text
IP QUEUE CPU [PORT]
```

模式含义：

```text
--mode server
  IP 表示本机 server IP
  RX: dst-ip[:dst-port] -> RX queue -> IRQ CPU
  TX: src-ip[:src-port] -> TX queue -> XPS CPU

--mode client
  IP 表示远端 server IP
  RX: src-ip[:src-port] -> RX queue -> IRQ CPU
  TX: dst-ip[:dst-port] -> TX queue -> XPS CPU
```

示例：

```bash
# server 侧
./bind-remote-ip-queue-cpu.sh --dev enp23s0f1np1 \
  --mode server \
  --rule 10.0.0.11:5:18:6379

# client 侧，仍然使用 Redis server IP
./bind-remote-ip-queue-cpu.sh --dev enp23s0f1np1 \
  --mode client \
  --rule 10.0.0.11:5:18:6379
```

适合场景：

- 希望同一份配置文件在 server 侧和 client 侧复用。
- 每个 IP 只需要一个 queue。
- client 侧配置文件中的 IP 仍然填写 Redis server IP。

关键限制：

- 仍然是单 queue 绑定。
- 不能让一个 IP 的多个 flow 在多个 RX queue 间散列。

## 4. `bind-ip-multi-queue-cpu.sh`

这是当前最适合复杂分组的脚本，支持一个 IP 绑定多个 queue，并支持 CPU range。

配置语义：

```text
IP QUEUES CPUS [PORT]
```

`QUEUES` 支持：

```text
5
5,6,8
5-8
```

`CPUS` 支持：

```text
18
18-21
18,20-23
18-19/20-21
```

当 `QUEUES` 是多个 queue 时：

```text
RX: IP -> RSS context -> 指定 RX queue 范围 -> IRQ CPU set
TX: 不创建多条 queue_mapping；只为这些 TX queue 设置 XPS CPU mask
```

示例：

```bash
./bind-ip-multi-queue-cpu.sh --dev enp23s0f1np1 \
  --mode server \
  --rule 10.0.0.11:5-8:18-25:6379 \
  --dry-run
```

关键能力：

- 支持 `--mode server|client`。
- 支持多个 IP 共享同一组 queue。
- 支持同一组 queue 绑定到同一个 CPU set。
- 支持按 queue 对齐的 CPU set，例如 `5-6:18-19/20-21`。
- 多 queue RX 通过 RSS context 实现，同一 IP 的多个 flow 可散列到指定 queue 范围。
- 自动创建的 RSS context 会记录到 state 文件，可配合 `--delete-rules --delete-rss-contexts` 清理。

关键限制：

- 多 queue RSS context 要求 queue 范围连续，例如 `0-15` 可以，`0,2,4` 不适合作为多 queue RSS context。
- 同一个 queue 不能在不同规则中绑定不同 CPU set。
- CX5 等网卡可新增 RSS context 数量有限，不能按大量 IP 独占 RSS context；应按 queue 组复用 RSS context。
- 多 queue TX 只通过 XPS 做 CPU 亲和引导，不能保证某个 IP 严格进入对应 TX queue 组。
- `tc skbedit queue_mapping` 一条规则只能指定一个 TX queue，不能像 RSS context 一样指定 TX queue range。

## 5. XPS 引导与严格 TX queue 绑定的区别

XPS 的输入是 CPU，不是 IP。

```text
CPU set -> 可选 TX queue mask
```

因此 XPS 表达的是：

```text
运行在这些 CPU 上的发包路径，倾向选择这些 TX queue。
```

严格 TX queue 绑定的输入是 packet match 条件：

```text
src_ip/dst_ip/port -> skbedit queue_mapping -> 单个 TX queue
```

二者区别：

| 维度 | 只用 XPS | 严格 TX queue 绑定 |
|---|---|---|
| 控制依据 | 当前发包 CPU | 报文字段，如 IP / port |
| 是否直接按 IP 分组 | 否，依赖线程和协议栈运行 CPU | 是 |
| 是否支持 queue range | XPS 可以给 CPU 配多个 TX queue | `queue_mapping` 只能指定单个 TX queue |
| 稳定性 | 受调度、线程亲和、NUMA 影响 | 对单 queue 强制性更强 |
| 当前多 queue 脚本支持 | 支持 | 多 queue 不支持严格 range |

如果 Redis 实例线程已经绑定到对应 NUMA CPU，XPS 可以比较接近“TX 跟随 IP 分组”的效果；如果应用线程可能跨 NUMA 调度，XPS 不能保证 IP 组严格走对应 TX queue 组。

## 6. 63 个 queue / 4 个 NUMA / 40 个 IP 的推荐配置

目标：

```text
63 个网卡 queue 均分到 4 个 NUMA
40 个 IP，每 10 个 IP 一组
每组 IP 由对应 NUMA 的 queue 组处理
每组 queue 的中断绑定到指定 CPU set
```

63 不能严格均分为 4 组，只能选择两种策略：

```text
策略 A：使用全部 63 个 queue
  NUMA0: queues 0-15    共 16 个
  NUMA1: queues 16-31   共 16 个
  NUMA2: queues 32-47   共 16 个
  NUMA3: queues 48-62   共 15 个

策略 B：只使用 60 个 queue
  NUMA0: queues 0-14    共 15 个
  NUMA1: queues 15-29   共 15 个
  NUMA2: queues 30-44   共 15 个
  NUMA3: queues 45-59   共 15 个
  queues 60-62 保留不用
```

推荐策略 A。原因是配置简单、使用全部队列，并且只需要 4 个 RSS context。

配置文件示例：

```text
# IP          QUEUES   CPUS       PORT
# NUMA0
10.0.0.1      0-15     0-7        6379
10.0.0.2      0-15     0-7        6379
10.0.0.3      0-15     0-7        6379
10.0.0.4      0-15     0-7        6379
10.0.0.5      0-15     0-7        6379
10.0.0.6      0-15     0-7        6379
10.0.0.7      0-15     0-7        6379
10.0.0.8      0-15     0-7        6379
10.0.0.9      0-15     0-7        6379
10.0.0.10     0-15     0-7        6379

# NUMA1
10.0.0.11     16-31    16-23      6379
10.0.0.12     16-31    16-23      6379
10.0.0.13     16-31    16-23      6379
10.0.0.14     16-31    16-23      6379
10.0.0.15     16-31    16-23      6379
10.0.0.16     16-31    16-23      6379
10.0.0.17     16-31    16-23      6379
10.0.0.18     16-31    16-23      6379
10.0.0.19     16-31    16-23      6379
10.0.0.20     16-31    16-23      6379

# NUMA2
10.0.0.21     32-47    32-39      6379
10.0.0.22     32-47    32-39      6379
10.0.0.23     32-47    32-39      6379
10.0.0.24     32-47    32-39      6379
10.0.0.25     32-47    32-39      6379
10.0.0.26     32-47    32-39      6379
10.0.0.27     32-47    32-39      6379
10.0.0.28     32-47    32-39      6379
10.0.0.29     32-47    32-39      6379
10.0.0.30     32-47    32-39      6379

# NUMA3
10.0.0.31     48-62    48-55      6379
10.0.0.32     48-62    48-55      6379
10.0.0.33     48-62    48-55      6379
10.0.0.34     48-62    48-55      6379
10.0.0.35     48-62    48-55      6379
10.0.0.36     48-62    48-55      6379
10.0.0.37     48-62    48-55      6379
10.0.0.38     48-62    48-55      6379
10.0.0.39     48-62    48-55      6379
10.0.0.40     48-62    48-55      6379
```

执行：

```bash
./bind-ip-multi-queue-cpu.sh --dev enp23s0f1np1 \
  --mode server \
  --config ip-queue-cpu-numa.txt \
  --dry-run
```

确认 dry-run 输出无误后再去掉 `--dry-run`。

该方案的实际效果：

```text
RX:
  每 10 个 IP 共享一个 RSS context
  每组 IP 的入站流量散列到对应 queue range
  对应 queue 的 IRQ 绑定到指定 CPU set

TX:
  每组 queue 设置 XPS CPU mask
  发包路径运行在对应 CPU set 时，会倾向使用对应 TX queue 组
但不会按 IP 严格强制进入该 TX queue range
```

### 6.1 客户端侧按 server IP 分组的大 CPU set 配置

如果配置文件类似下面这样：

```text
# server IP    QUEUES   CLIENT_NUMA_CPUS
# NUMA0
10.0.0.1       0-15     0-79
...
10.0.0.10      0-15     0-79

# NUMA1
10.0.0.11      16-31    80-159
...
10.0.0.20      16-31    80-159

# NUMA2
10.0.0.21      32-47    160-239
...
10.0.0.30      32-47    160-239

# NUMA3
10.0.0.31      48-62    240-319
...
10.0.0.40      48-62    240-319
```

应在客户端侧使用 `--mode client` 执行：

```bash
./bind-ip-multi-queue-cpu.sh --dev <client_netdev> \
  --mode client \
  --config ip-queue-cpu-client-numa.txt \
  --dry-run
```

确认输出无误后再去掉 `--dry-run`。

这类配置会让脚本做这些事情：

```text
1. 读取配置文件，忽略空行和 # 注释行。
2. 将 40 个 server IP 分成 4 个 queue 组：
   10.0.0.1  - 10.0.0.10  -> queues 0-15
   10.0.0.11 - 10.0.0.20  -> queues 16-31
   10.0.0.21 - 10.0.0.30  -> queues 32-47
   10.0.0.31 - 10.0.0.40  -> queues 48-62
3. 将每组 queue 的 RX IRQ affinity 设置为对应 CPU set：
   queues 0-15  -> CPUs 0-79
   queues 16-31 -> CPUs 80-159
   queues 32-47 -> CPUs 160-239
   queues 48-62 -> CPUs 240-319
4. 在 `--mode client` 下，默认为配置中出现的 RX queue 配置 RPS/RFS：
   `rps_cpus` 使用对应 CPU set 的十六进制 mask，`rps_flow_cnt`
   默认使用 `4096`。
5. 默认开启 ntuple。
6. 删除当前设备上已有 RX ntuple rules 和 TX egress filters。
7. 为 4 个不同 queue range 创建或复用 4 个 RSS context。
8. 为每个 server IP 创建一条 RX ntuple 规则。
9. 为这些 TX queue 设置 XPS CPU mask。
```

因为这里使用 `--mode client`，IP 匹配方向是：

```text
RX:
  src-ip=<server IP> -> RSS context -> client RX queue range -> IRQ CPU set

TX:
  dst-ip=<server IP> -> 不做多 queue tc queue_mapping
  只通过 XPS 让运行在对应 CPU set 上的发包路径倾向使用对应 TX queue
```

如果配置行没有第四列 `PORT`，脚本不会加端口条件，实际匹配的是：

```text
RX: 来自该 server IP 的所有 TCP 包
TX: 发往该 server IP 的所有 TCP 包对应的 XPS queue 亲和
```

如果只希望 Redis 流量命中，应补第四列：

```text
10.0.0.1  0-15  0-79  6379
```

这类配置的作用是：

```text
RX 侧：
  将客户端收到的 server 回包按 server IP 分组导入对应 RX queue 组；
  同一组内不同 flow 通过 RSS context 在 queue range 内散列；
  这些 queue 的中断允许在对应 NUMA CPU set 上处理。

TX 侧：
  设置对应 TX queue 的 XPS CPU mask；
  如果客户端应用线程和协议栈发包路径运行在对应 NUMA CPU set，
  发包会倾向选择该 NUMA 对应的 TX queue 组。
```

需要注意：

- 这组配置只需要 4 个 RSS context，不是 40 个，因此适合 CX5 这类 RSS context 数量有限的网卡。
- `0-79` 这类大 CPU set 表示“允许这些 CPU 处理该 queue 的 IRQ”，不表示每个 queue 的中断会在 80 个 CPU 上均匀分布。
- 多 queue TX 不能严格按 server IP 强制进入对应 TX queue range；当前脚本只能通过 XPS 做 CPU 亲和引导。
- 如果客户端进程没有绑定到对应 NUMA CPU，TX 侧 XPS 效果会明显弱化。
- 如果系统启用了 `irqbalance`，它可能覆盖脚本写入的 IRQ affinity。

### 6.2 同一个 RX queue 的 skb 何时会被多个 CPU 处理

严格区分三件事：

```text
IRQ affinity:
  控制某个 IRQ 允许在哪些 CPU 上触发。

NAPI poll:
  通常跟随触发该 IRQ 的 CPU 执行，用于从 RX queue 拉包。

RPS/RFS:
  在软件层把 skb 分发到其他 CPU backlog，使后续 net_rx_action()
  可在其他 CPU 上继续处理。
```

因此，把某个 queue 的 IRQ affinity 写成 `0-79`，含义只是：

```text
该 queue 对应的 IRQ 允许被投递到 CPU 0-79。
```

它不表示：

```text
每个包都会均匀分配给 CPU 0-79。
```

在客户端执行上面的 `--mode client` 配置后，一个 queue 相关处理可能出现在多个 CPU 上，主要有这些情况：

- IRQ 投递 CPU 在不同时间发生迁移。例如 queue 0 的 IRQ affinity 是 `0-79`，长时间观察时，该 IRQ 可能先后在 CPU 3、CPU 18、CPU 52 上增长。
- `irqbalance` 改写了 IRQ affinity，导致同一个 queue 的 IRQ 处理 CPU 发生变化。
- 网卡 down/up、`ethtool -L`、driver reset、firmware reload 后，queue、channel、IRQ/vector 映射被重建。
- RPS/RFS 被开启。同一个 RX queue 收到的 skb 可被软件分发到多个 CPU backlog，后续 `net_rx_action()` 可能在多个 CPU 上执行。
- 观察点不是硬中断，而是软中断、TCP 栈、ksoftirqd 或应用线程。它们可能跨 CPU 运行，但不等价于同一个 IRQ 被多个 CPU 同时处理。

当前 `bind-ip-multi-queue-cpu.sh` 在 server 模式默认会关闭 RPS/RFS；
在 client 模式默认会按配置文件中的 queue / CPU set 主动配置 RPS/RFS。
如果显式使用 `--keep-rps`，脚本不会关闭也不会配置 RPS/RFS。

server 模式默认关闭时会写：

```text
rps_cpus = 0
rps_flow_cnt = 0
net.core.rps_sock_flow_entries = 0
```

client 模式默认配置后的预期是：

```text
server IP 组
  -> RSS context
  -> 某个 RX queue
  -> 该 queue 的 IRQ 在对应 CPU set 内触发
  -> NAPI 通常在触发 IRQ 的 CPU 上 poll
  -> RPS/RFS 将 skb 软件分发到同一 CPU set 内的 CPU backlog
```

如果看到同一个 queue 的 skb 稳定扩散到多个 CPU，应优先检查：

```bash
cat /sys/class/net/<dev>/queues/rx-*/rps_cpus
cat /sys/class/net/<dev>/queues/rx-*/rps_flow_cnt
sysctl net.core.rps_sock_flow_entries
systemctl status irqbalance
grep -i "$(basename "$(readlink -f /sys/class/net/<dev>/device)")" /proc/interrupts
```

### 6.3 希望同一个 queue 的 skb 可由多个 CPU 处理时的做法

如果目标同时包括：

```text
1. 4 组 server IP 分别绑定到 4 组 RX queue。
2. 4 组 RX queue 的 IRQ affinity 绑定到 4 组 NUMA CPU。
3. 当单个 CPU 处理不过来时，同一个 queue 的 skb 可以由同 NUMA 内其他 CPU 继续处理。
```

推荐组合是：

```text
RSS context:
  负责 server IP 组 -> RX queue 组。

IRQ affinity:
  负责 RX queue IRQ -> NUMA CPU set。

RPS/RFS:
  负责同一个 RX queue 收到的 skb -> 同 NUMA 内多个 CPU backlog。
```

关键点：**当前脚本在 `--mode client` 下已经内置 RPS/RFS 配置**。默认会按配置文件里的 queue / CPU set 自动写入：

```text
/sys/class/net/<dev>/queues/rx-N/rps_cpus
/sys/class/net/<dev>/queues/rx-N/rps_flow_cnt
net.core.rps_sock_flow_entries
```

默认每个 RX queue 的 `rps_flow_cnt` 是 `4096`，可通过 `--rps-flow-cnt` 调整。如果显式加 `--keep-rps`，脚本会保持 RPS/RFS 不变，也就不会满足“同一个 queue 的 skb 可由多个 CPU 处理”的目标。

示例流程：

```bash
# 直接用脚本配置 IP -> queue range、RSS context、IRQ affinity、XPS 和 RPS/RFS。
./bind-ip-multi-queue-cpu.sh --dev <client_netdev> \
  --mode client \
  --config ip-queue-cpu-client-numa.txt

# 如需调整每个 RX queue 的 flow 表大小：
./bind-ip-multi-queue-cpu.sh --dev <client_netdev> \
  --mode client \
  --config ip-queue-cpu-client-numa.txt \
  --rps-flow-cnt 8192
```

概念映射如下：

```text
queues 0-15  -> rps_cpus = CPUs 0-79   的 CPU mask
queues 16-31 -> rps_cpus = CPUs 80-159 的 CPU mask
queues 32-47 -> rps_cpus = CPUs 160-239 的 CPU mask
queues 48-62 -> rps_cpus = CPUs 240-319 的 CPU mask
```

脚本内部会自动用 `cpu_set_to_mask` 将 CPU set 转换成 mask。例如：

```bash
source <(sed '/^main "\$@"$/d' ./bind-ip-multi-queue-cpu.sh)
cpu_set_to_mask 0-79
cpu_set_to_mask 80-159
cpu_set_to_mask 160-239
cpu_set_to_mask 240-319
```

等价于脚本自动写入这些配置：

```text
queues 0-15:
  rps_cpus     = mask(CPUs 0-79)
  rps_flow_cnt = 4096

queues 16-31:
  rps_cpus     = mask(CPUs 80-159)
  rps_flow_cnt = 4096

queues 32-47:
  rps_cpus     = mask(CPUs 160-239)
  rps_flow_cnt = 4096

queues 48-62:
  rps_cpus     = mask(CPUs 240-319)
  rps_flow_cnt = 4096

net.core.rps_sock_flow_entries = 258048
```

上面 `258048` 来自：

```text
63 queues * 4096 flow entries = 258048
```

也可以按实际连接数调小或调大。通常需要保证：

```text
net.core.rps_sock_flow_entries >= sum(rx-N/rps_flow_cnt)
```

这种方案的效果是：

```text
硬件/RSS 层：
  server IP 组仍然只进入对应 queue range。

IRQ/NAPI 层：
  queue IRQ 仍然限制在对应 NUMA CPU set 内。

RPS/RFS 层：
  同一个 queue 收到的 skb 可被分发到同 NUMA 内多个 CPU 处理。
```

但必须接受这些代价：

- RPS 不是严格的“某个 CPU 忙了才转移”的负载感知 fallback，而是基于 flow hash 和 CPU mask 的软件分发。
- RPS 会增加跨 CPU enqueue、IPI、cache miss 等开销，吞吐和延迟未必一定更好。
- 如果 CPU mask 跨 NUMA，可能把 skb 处理扩散到远端 NUMA，破坏局部性；因此建议 RPS mask 只包含对应 NUMA 的 CPU。
- 如果只是担心单个 CPU 处理不过来，更优先的做法通常是增加该 IP 组可使用的 RX queue 数量，而不是让少数 queue 依赖 RPS 扩散。
- `--keep-rps` 会跳过脚本内置 RPS/RFS 配置，仅保留系统当前已有的 RPS/RFS 状态。

## 7. 清理与重复执行

重新下发配置前建议先清理旧规则：

```bash
./bind-ip-multi-queue-cpu.sh --dev enp23s0f1np1 \
  --mode client \
  --delete-rules \
  --delete-rss-contexts
```

需要注意：

- `ntuple` 规则和 `tc filter` 规则仍按当前脚本逻辑直接删除。
- `--mode client --delete-rules` 会按 client state 恢复脚本记录过的 IRQ affinity、RPS/RFS、XPS、`ntuple` 开关和脚本新增的 `clsact`。
- 自动创建并记录到 RSS state 的 RSS context 会在 client 清理时删除；手工通过 `--rss-context` 传入的外部 context 只有显式加 `--delete-rss-contexts` 才会删除。
- 如果系统启用了 `irqbalance`，它可能在脚本执行后改写 IRQ affinity。

## 8. 验证建议

应用配置后至少验证这些项：

```bash
ethtool -n <dev>
ethtool -x <dev>
tc -s filter show dev <dev> egress
grep -i "$(basename "$(readlink -f /sys/class/net/<dev>/device)")" /proc/interrupts
cat /sys/class/net/<dev>/queues/rx-*/rps_cpus
cat /sys/class/net/<dev>/queues/rx-*/rps_flow_cnt
cat /sys/class/net/<dev>/queues/tx-*/xps_cpus
ethtool -S <dev> | egrep 'rx|tx|queue|ch'
```

判断配置是否真正生效，不要只看命令是否执行成功，应同时看：

- 目标 IP 压测时，对应 RX queue 计数是否增长。
- 对应 IRQ 行计数是否主要在目标 CPU set 上增长。
- RPS/RFS 是否仍然把 skb 扩散到非目标 CPU。
- Redis 线程是否绑定在对应 NUMA CPU，否则 TX 侧 XPS 效果会被削弱。
