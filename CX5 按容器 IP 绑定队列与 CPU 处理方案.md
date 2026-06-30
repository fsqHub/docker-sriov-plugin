# CX5 按容器 IP 绑定队列与 CPU 处理方案

## 1. 背景与目标

在 Redis 容器压测中，如果观测到单个 `dst-ip` 的入站 TCP 包被 `10-20` 个 CPU 的 `net_rx_action()` 处理，通常说明该容器实例的连接被 RSS 或软件分发机制散到了多个 RX queue / CPU 上。

更准确地说，这不是“一个中断队列被很多 CPU 同时处理”，而是：

```text
同一个容器 IP 的不同 TCP flow
  -> 被 RSS / flow steering / RPS / RFS 分散到多个 RX queue 或 CPU
  -> 多个 CPU 进入 net_rx_action()
  -> 同一个 Redis 实例的收包处理缺少 CPU 局部性
```

如果目标是让某个容器实例尽量由指定 CPU 处理网络收发，需要分别处理 RX 和 TX：

```text
RX：dst-ip -> 指定 RX queue -> 指定 IRQ CPU -> 指定 net_rx_action CPU
TX：src-ip -> 指定 TX queue -> 指定 XPS CPU / TX completion 相关 CPU
```

## 2. 推荐方案总览

假设：

- PF 设备为 `<pf>`，例如 `enp23s0f1np1`
- 容器 Redis IP 为 `10.0.0.11`
- 希望该实例主要由 CPU `18` 处理
- 希望使用 RX/TX queue `5`

推荐闭环如下：

```text
入站请求包：
client -> PF
  -> ethtool ntuple: dst-ip 10.0.0.11 -> RX queue 5
  -> RX queue 5 IRQ affinity -> CPU 18
  -> net_rx_action() 在 CPU 18 上处理

出站回包：
Redis container -> PF
  -> tc egress: src-ip 10.0.0.11 -> queue_mapping 5
  -> TX queue 5 XPS -> CPU 18
```

同时建议显式关闭或限制 RPS/RFS：

```text
硬件 ntuple 只决定“先进哪个 RX queue”
RPS/RFS 仍可能在软件层把 skb 转发到其他 CPU backlog
```

本仓库已提供配套脚本：

```bash
./bind-ip-queue-cpu.sh --dev <pf> --rule 10.0.0.11:5:18:6379 --dry-run
./bind-ip-queue-cpu.py --dev <pf> --rule 10.0.0.11:5:18:6379 --dry-run
```

两者功能一致：shell 版适合直接在测试机上快速执行；Python 版参数解析和错误处理更清晰，适合后续扩展批量配置逻辑。

批量配置文件格式：

```text
# IP         QUEUE  CPU  PORT
10.0.0.11   5      18   6379
10.0.0.12   6      26   6379
```

执行前建议先使用 `--dry-run` 检查将要执行的 `ethtool`、`tc`、IRQ affinity、RPS/RFS 和 XPS 配置命令。

## 3. RX：用 ntuple 把特定 dst-ip 打到指定 RX queue

先确认 CX5 PF 是否支持 ntuple / rxnfc：

```bash
ethtool -k <pf> | grep ntuple
ethtool -n <pf>
```

开启 ntuple：

```bash
ethtool -K <pf> ntuple on
```

按容器 IP 指定 RX queue：

```bash
ethtool -N <pf> flow-type tcp4 dst-ip 10.0.0.11 action 5
```

如果 Redis 端口固定，建议加入端口，避免同 IP 上其他 TCP 服务混入：

```bash
ethtool -N <pf> flow-type tcp4 dst-ip 10.0.0.11 dst-port 6379 action 5
```

查看规则：

```bash
ethtool -n <pf>
```

然后把 RX queue `5` 对应的 IRQ 绑到 CPU `18`。

先找 IRQ：

```bash
grep -i <pf> /proc/interrupts
```

再绑定：

```bash
echo 18 > /proc/irq/<irq_of_rx_queue_5>/smp_affinity_list
```

验证中断是否集中到目标 CPU：

```bash
watch -n 1 'grep -i <pf> /proc/interrupts'
```

## 4. TX：按容器 src-ip 指定 TX queue，并用 XPS 绑定 CPU

Redis server 回包时，对外发包的源 IP 是容器 IP。因此可以在 egress 方向按 `src_ip` 设置 `skb->queue_mapping`。

添加 `clsact`：

```bash
tc qdisc add dev <pf> clsact
```

按源 IP 指定 TX queue：

```bash
tc filter add dev <pf> egress protocol ip flower \
  src_ip 10.0.0.11 ip_proto tcp \
  action skbedit queue_mapping 5
```

如果只希望 Redis 端口回包命中，可加源端口：

```bash
tc filter add dev <pf> egress protocol ip flower \
  src_ip 10.0.0.11 src_port 6379 ip_proto tcp \
  action skbedit queue_mapping 5
```

再设置 TX queue `5` 的 XPS CPU。`xps_cpus` 使用十六进制 CPU mask，不是 CPU 编号。CPU `18` 对应 mask 为 `1 << 18 = 0x40000`：

```bash
echo 40000 > /sys/class/net/<pf>/queues/tx-5/xps_cpus
```

验证：

```bash
cat /sys/class/net/<pf>/queues/tx-5/xps_cpus
tc -s filter show dev <pf> egress
```

注意：TX completion 仍由驱动/NAPI/队列设计决定，通常与对应 TX/RX completion queue、中断向量和驱动实现有关。上述配置主要约束发送选择的 TX queue 与发包 CPU 局部性，不能保证所有 TX completion 都严格只在一个 CPU 上出现。

## 5. ntuple 是否会自动禁用 RPS/RFS

结论：

> 不会。硬件 flow steering / ntuple 不会自动禁用 RPS 或 RFS。它只决定 skb 首先落到哪个硬件 RX queue；进入协议栈前后，RPS/RFS 仍可能根据 per-queue `rps_cpus`、`rps_flow_cnt` 和全局 `rps_sock_flow_entries` 把 skb 转发到其他 CPU 的 backlog。

源码依据如下。

### 5.1 RPS/RFS 在 netif_receive_skb 路径中独立执行

Linux 6.6 的 `net/core/dev.c` 中，`netif_rx_internal()` 和 `__netif_receive_skb_core()` 附近都会在 `CONFIG_RPS` 打开时调用 `get_rps_cpu()`：

```c
if (static_branch_unlikely(&rps_needed)) {
    cpu = get_rps_cpu(skb->dev, skb, &rflow);
    if (cpu >= 0) {
        ret = enqueue_to_backlog(skb, cpu, &rflow->last_qtail);
        ...
    }
}
```

`netif_receive_skb_list_internal()` 对 GRO/listified skb 也会逐个调用 `get_rps_cpu()`：

```c
list_for_each_entry_safe(skb, next, head, list) {
    int cpu = get_rps_cpu(skb->dev, skb, &rflow);
    if (cpu >= 0) {
        skb_list_del_init(skb);
        enqueue_to_backlog(skb, cpu, &rflow->last_qtail);
    }
}
```

这说明即使硬件已经把包放到某个 RX queue，只要该 queue 配了 RPS/RFS，skb 仍可能被软件转发到其他 CPU。

### 5.2 get_rps_cpu() 只看 RPS/RFS 配置，不关心该 skb 是否来自 ntuple

`get_rps_cpu()` 会先根据 skb 记录的 RX queue 找到对应 `rxqueue`：

```c
if (skb_rx_queue_recorded(skb)) {
    u16 index = skb_get_rx_queue(skb);
    rxqueue += index;
}
```

然后读取：

```c
flow_table = rcu_dereference(rxqueue->rps_flow_table);
map = rcu_dereference(rxqueue->rps_map);
if (!flow_table && !map)
    goto done;
```

也就是说，只要这个 RX queue 上存在 `rps_map` 或 `rps_flow_table`，RPS/RFS 逻辑仍然会执行。源码里没有“如果 skb 是 ntuple 命中的，就自动跳过 RPS/RFS”的判断。

### 5.3 RFS_ACCEL 甚至可能继续调用驱动做动态硬件 steering

在 `set_rps_cpu()` 中，如果启用了 `CONFIG_RFS_ACCEL`，并且设备具备 `NETIF_F_NTUPLE`，内核还可能调用驱动的 `ndo_rx_flow_steer()`：

```c
if (!skb_rx_queue_recorded(skb) || !dev->rx_cpu_rmap ||
    !(dev->features & NETIF_F_NTUPLE))
    goto out;

rxq_index = cpu_rmap_lookup_index(dev->rx_cpu_rmap, next_cpu);
...
rc = dev->netdev_ops->ndo_rx_flow_steer(dev, skb, rxq_index, flow_id);
```

对 mlx5 驱动来说，`net_device_ops` 中实现了：

```c
.ndo_rx_flow_steer = mlx5e_rx_flow_steer,
```

`mlx5e_rx_flow_steer()` 位于 `drivers/net/ethernet/mellanox/mlx5/core/en_arfs.c`，会根据 skb flow key 创建或更新 aRFS 硬件规则，将 flow 导向目标 RX queue。

这不是“自动禁用 RPS/RFS”，而是相反：

```text
RFS 发现应用最后在哪个 CPU recvmsg
  -> 选择 next_cpu
  -> RFS_ACCEL 调 mlx5e_rx_flow_steer()
  -> 动态下发硬件 flow steering
```

如果你同时手工配置 ntuple，又开启 RFS/aRFS，动态规则可能让实际 RX queue 选择变复杂。因此做“容器 IP -> 固定 CPU”的确定性实验时，应该先显式关闭 RPS/RFS。

## 6. 建议显式关闭或限制 RPS/RFS

查看当前 RPS：

```bash
cat /sys/class/net/<pf>/queues/rx-*/rps_cpus
cat /sys/class/net/<pf>/queues/rx-*/rps_flow_cnt
sysctl net.core.rps_sock_flow_entries
```

如果目标是验证硬件 ntuple + IRQ affinity 的效果，建议先全部关闭：

```bash
for f in /sys/class/net/<pf>/queues/rx-*/rps_cpus; do
  echo 0 > "$f"
done

for f in /sys/class/net/<pf>/queues/rx-*/rps_flow_cnt; do
  echo 0 > "$f"
done

sysctl -w net.core.rps_sock_flow_entries=0
```

关闭后再验证：

```bash
cat /sys/class/net/<pf>/queues/rx-*/rps_cpus
cat /sys/class/net/<pf>/queues/rx-*/rps_flow_cnt
sysctl net.core.rps_sock_flow_entries
```

如果不想完全关闭，也至少要把目标 RX queue 的 `rps_cpus` 限制在同一个 cluster 内，避免包被转发到其他 cluster。

## 7. 验证方法

建议按以下顺序验证。

### 7.1 验证硬件队列命中

```bash
ethtool -S <pf> | egrep 'rx.*5|ch.*5|queue.*5'
```

不同 mlx5 版本统计项名称不完全一致，重点看目标 queue 的 `rx_packets/rx_bytes` 是否随目标 Redis IP 压测增长。

### 7.2 验证 IRQ CPU

```bash
watch -n 1 'grep -i <pf> /proc/interrupts'
```

目标 queue 的 IRQ 应主要增长在指定 CPU。

### 7.3 验证 net_rx_action CPU

使用 `观察NAPI差异实战指南.md` 的方法 6：

```text
@dst_ip_handled_by_cpu[dst,cpu]
@cpu_handled_dst_ip[cpu,dst]
```

期望结果是目标 `dst-ip` 涉及的 CPU 集合明显收敛。例如从 `10-20` 个 CPU 降到 `1-2` 个 CPU。

如果仍然分散，按顺序排查：

1. ntuple 规则是否命中正确 queue
2. 目标 queue IRQ affinity 是否正确
3. RPS/RFS 是否仍然开启
4. 是否存在多个 PF queue / 多路径 / bond / team
5. Redis 流量是否实际走 IPv6、隧道、XDP、TC redirect 或非预期设备

### 7.4 验证 TX queue

```bash
tc -s filter show dev <pf> egress
ethtool -S <pf> | egrep 'tx.*5|queue.*5'
cat /sys/class/net/<pf>/queues/tx-5/xps_cpus
```

如果 `tc` filter 计数增长，但 TX queue 统计不增长，要检查：

1. filter 是否挂在正确设备
2. 出口 skb 的 `src_ip` 是否确实是容器 IP
3. 是否有 ipvlan/macvlan/veth/bridge 导致实际 egress 设备不是 PF
4. qdisc 或驱动是否重写了 queue mapping

## 8. PF 共享方案与 VF 方案的取舍

在共享 PF 上按 40 个容器 IP 配置 steering 是可行的，但维护成本较高：

- 每个容器 IP 需要一条或多条 ntuple 规则
- 每个目标 queue 需要绑定 IRQ affinity
- TX 侧还要配置 tc filter 和 XPS
- RPS/RFS 必须显式收敛，否则会破坏 CPU 局部性

如果规则数量、队列数量或驱动能力允许，PF steering 可以作为验证手段。

但如果目标是长期稳定隔离，优先考虑每个容器分配独立 VF：

```text
每个容器一个 VF
  -> VF 自己的 RX/TX queue
  -> VF 自己的 IRQ/NAPI
  -> VF IRQ/XPS 绑定到容器所在 cluster
```

VF 方案比共享 PF 上的 40 组规则更接近硬件层面的隔离，也更容易解释和维护。

## 9. 最终建议

对当前 Redis 多容器压测，建议按这个顺序做实验：

1. 保持当前 PF 共享拓扑，先关闭 RPS/RFS。
2. 为少量 Redis 容器 IP 配置 ntuple：`dst-ip -> RX queue`。
3. 将对应 RX queue IRQ 绑到容器所在 cluster 的服务核。
4. 用方法 6 观察 `dst-ip -> CPU` 集合是否明显收敛。
5. 再补 TX 侧 `tc skbedit queue_mapping + XPS`。
6. 如果效果明显，再扩展到 40 个容器；如果规则维护复杂或队列不足，转向 VF 隔离方案。
