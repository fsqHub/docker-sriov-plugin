# Redis benchmark VF NAPI CPU 扩散排查指南

## 1. 适用场景

本文用于排查以下现象：

```text
每个 redis-benchmark 绑定一个客户端 VF IP
每个 redis-benchmark 对应压测一个 redis-server 实例
每个 VF 有 8 个队列，VF IRQ 绑定到对应 8 个 CPU
redis-benchmark 进程也绑定到同一个 8 核 cluster
各 VF 的 RPS/RFS 为 0
/sys/class/net/<vf>/threaded 为 0

但使用 观察NAPI差异实战指南.md 的方法 6 / 6C 观察时：
  客户端收包按 dst-ip 看，单个客户端 IP 涉及 10-30+ 个 CPU
  客户端发包 TX completion 按 src-ip 看，单个客户端 IP 也涉及 10-30+ 个 CPU
```

这种情况下，不应继续只看 `ip -> cpu`。必须把维度扩展为：

```text
ip + dev + queue + cpu + comm
```

否则无法区分：

- 真实 VF NAPI 在 8 核 cluster 外运行
- skb 混入了其它 netdev / queue
- IRQ effective affinity 与配置认知不一致
- 方法 6 / 6C 的 IP 聚合口径过粗

`★ Insight ─────────────────────────────────────`
- `source IP bind`、`taskset`、`IRQ smp_affinity_list` 都不是完整闭环。
- 真正要证明隔离成立，必须同时证明 `skb->dev`、`queue_mapping`、`NAPI poll CPU`、`IRQ effective CPU` 都落在预期集合。
- 只看 `dst_ip/src_ip -> cpu`，最多说明协议栈或 TX completion 在这些 CPU 上执行过，不能证明是哪一个 VF 队列触发的。
`─────────────────────────────────────────────────`

## 2. 先确认测试前提

替换以下占位符：

```bash
VF=<vf>
CLIENT_IP=<client_ip>
SERVER_IP=<redis_server_ip>
```

确认绑定源 IP 后实际路由出口是目标 VF：

```bash
ip route get "$SERVER_IP" from "$CLIENT_IP"
```

预期输出中应包含：

```text
dev <vf> src <client_ip>
```

如果这里不是目标 VF，先修路由或策略路由。`redis-benchmark --client-ip` 只是对 socket 做 `bind(source_addr)`，不等于 `SO_BINDTODEVICE`。

确认 RPS/RFS 确实关闭：

```bash
for q in /sys/class/net/$VF/queues/rx-*; do
  echo "$q rps_cpus=$(cat $q/rps_cpus) rps_flow_cnt=$(cat $q/rps_flow_cnt)"
done
cat /proc/sys/net/core/rps_sock_flow_entries
```

确认 threaded NAPI 关闭：

```bash
cat /sys/class/net/$VF/threaded
```

预期为：

```text
0
```

确认 benchmark 线程实际运行 CPU：

```bash
ps -eLo pid,tid,psr,comm | grep redis-benchmark
```

`psr` 应落在目标 8 核 cluster 内。

## 3. 检查 IRQ affinity 是否真正生效

不要只看 `smp_affinity_list`，还要看 `effective_affinity_list`。

```bash
pci=$(basename "$(readlink -f /sys/class/net/$VF/device)")
grep -i "$pci" /proc/interrupts

for irq in $(grep -i "$pci" /proc/interrupts | awk -F: '{print $1}'); do
  echo "IRQ $irq smp=$(cat /proc/irq/$irq/smp_affinity_list) effective=$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null)"
done
```

如果 `effective_affinity_list` 已经超过目标 8 核，那么方法 6 / 6C 出现更多 CPU 是合理结果。常见原因：

- `irqbalance` 改写 affinity
- managed IRQ 限制导致写入值不是最终生效值
- 设备 down/up、driver reset、firmware reload 后 IRQ/vector 重建
- 只绑定了部分 completion IRQ，漏掉了同一 VF 的其它 vector

直接追踪 IRQ handler 实际在哪些 CPU 上触发：

```bash
sudo bpftrace -e '
tracepoint:irq:irq_handler_entry {
  @irq_cpu[str(args->name), args->irq, cpu] = count();
}

interval:s:3 {
  print(@irq_cpu);
  clear(@irq_cpu);
}
'
```

如果目标 VF 的 IRQ 已经出现在 8 核 cluster 外，先处理 IRQ affinity 问题，不要继续分析方法 6 / 6C。

## 4. 直接观察目标 VF 的 NAPI poll CPU

方法 6 / 6C 是 IP 维度。先用 `napi:napi_poll` 验证目标 VF 本身在哪些 CPU 上 poll。

```bash
sudo bpftrace -e '
tracepoint:napi:napi_poll /str(args->dev_name) == "<vf>"/ {
  @napi_cpu[str(args->dev_name), cpu] = count();
  @napi_work_cpu[str(args->dev_name), cpu] = sum(args->work);
}

interval:s:3 {
  print(@napi_cpu);
  print(@napi_work_cpu);
  clear(@napi_cpu);
  clear(@napi_work_cpu);
}
'
```

将 `<vf>` 替换成目标 VF 名称。

结果解释：

- 只出现目标 8 核：VF NAPI poll 本身没有扩散，方法 6 / 6C 的 IP 统计大概率混入了其它 dev/queue。
- 出现 10-30+ CPU：目标 VF 的 NAPI 确实在更多 CPU 上执行，继续查 IRQ effective affinity、ksoftirqd、busy poll 和设备 queue/vector 映射。

同时观察 `comm`：

```bash
sudo bpftrace -e '
tracepoint:napi:napi_poll /str(args->dev_name) == "<vf>"/ {
  @napi_comm_cpu[str(args->dev_name), comm, cpu] = count();
}

interval:s:3 {
  print(@napi_comm_cpu);
  clear(@napi_comm_cpu);
}
'
```

如果出现大量 `ksoftirqd/N`，说明软中断处理被推迟到了对应 CPU 的 `ksoftirqd`。它仍应与触发 CPU 集合一致；如果 `N` 超过目标 8 核，说明 NAPI/softirq 的实际执行 CPU 已经扩散。

## 5. 用 ip + dev + queue + cpu + comm 拆开方法 6 / 6C

下面脚本用于确认单个 IP 是否混入多个设备或多个 queue。

```bash
sudo bpftrace -e '
kprobe:tcp_v4_rcv {
  $skb = (struct sk_buff *)arg0;
  $iph = (struct iphdr *)($skb->head + $skb->network_header);
  $ver_ihl = *(uint8 *)$iph;

  if (($ver_ihl >> 4) == 4) {
    $rxq = $skb->queue_mapping;
    if ($rxq > 0) {
      $rxq = $rxq - 1;
    }

    @rx_dst_dev_q_cpu[
      ntop($iph->daddr),
      str($skb->dev->name),
      $rxq,
      cpu,
      comm
    ] = count();
  }
}

kprobe:mlx5e_consume_skb {
  $skb = (struct sk_buff *)arg1;
  $iph = (struct iphdr *)($skb->head + $skb->network_header);
  $ver_ihl = *(uint8 *)$iph;

  if (($ver_ihl >> 4) == 4 && $iph->protocol == 6) {
    @txc_src_dev_q_cpu[
      ntop($iph->saddr),
      str($skb->dev->name),
      $skb->queue_mapping,
      cpu,
      comm
    ] = count();
  }
}

interval:s:3 {
  print(@rx_dst_dev_q_cpu);
  print(@txc_src_dev_q_cpu);
  clear(@rx_dst_dev_q_cpu);
  clear(@txc_src_dev_q_cpu);
}
'
```

注意：

- RX 方向 `skb->queue_mapping` 记录的是 `rx_queue + 1`，脚本里减 1 后输出。
- TX 方向 `skb->queue_mapping` 是 TX queue mapping，不能减 1。
- 客户端收 Redis 响应时看 `rx_dst_dev_q_cpu[client_ip, dev, rxq, cpu, comm]`。
- 客户端发 Redis 请求时看 `txc_src_dev_q_cpu[client_ip, dev, txq, cpu, comm]`。

结果解释：

| 现象 | 说明 | 下一步 |
|------|------|--------|
| 同一 IP 出现多个 `dev` | 流量或脚本混入其它设备 | 先修路由、策略路由或给脚本加 `dev` 过滤 |
| `dev` 正确，但 queue 超过 8 个 | 实际队列数或 queue mapping 与预期不一致 | 查 `ethtool -l/-S`、XPS、RSS、ntuple |
| `dev` 正确，queue 只有 8 个，但 CPU 超过 8 个 | 目标 VF NAPI/softirq 确实跨出 cluster | 查 IRQ effective affinity、ksoftirqd、busy poll |
| `napi:napi_poll` 只有 8 个 CPU，但该脚本有 10-30+ CPU | IP 抓取点混入非目标路径，或 `skb->dev` 在协议栈后期已变化 | 对脚本加 `dev`、端口、进程维度过滤 |

## 6. 检查 queue 数、XPS 和实际 TX queue

确认 VF 实际 queue 数：

```bash
ethtool -l $VF
ls /sys/class/net/$VF/queues/rx-* | wc -l
ls /sys/class/net/$VF/queues/tx-* | wc -l
```

检查 XPS：

```bash
for q in /sys/class/net/$VF/queues/tx-*; do
  echo "$q xps_cpus=$(cat $q/xps_cpus)"
done
```

如果 XPS 的 CPU mask 覆盖目标 8 核之外，TX queue 选择可能被放大。`netdev_pick_tx()` 会优先走 XPS，再 fallback 到 skb hash。即使 benchmark 绑核，XPS 配置仍应与目标 cluster 对齐。

建议临时收敛 XPS：

```bash
# 示例：把每个 tx queue 的 xps_cpus 只设置为目标 cluster mask
for q in /sys/class/net/$VF/queues/tx-*; do
  echo <cluster_cpu_mask> > $q/xps_cpus
done
```

`<cluster_cpu_mask>` 使用十六进制 CPU mask，例如 CPU `8-15` 对应具体 mask 需按机器 CPU 编号计算。

## 7. 检查 busy poll / deferred IRQ 影响

确认是否启用了 busy poll 相关 sysctl：

```bash
sysctl net.core.busy_poll
sysctl net.core.busy_read
```

确认设备是否启用软件 IRQ coalescing / NAPI defer：

```bash
cat /sys/class/net/$VF/gro_flush_timeout 2>/dev/null
cat /sys/class/net/$VF/napi_defer_hard_irqs 2>/dev/null
```

如果这些值非 0，NAPI 处理时机和上下文可能与简单的 `IRQ -> softirq -> napi_poll` 模型不完全一致。排查阶段建议先关掉或统一配置，再观察 CPU 集合是否收敛。

## 8. 最小闭环验证顺序

建议按这个顺序排查，不要跳步：

1. `ip route get <server> from <client_ip>` 确认出口 VF。
2. `rps_cpus/rps_flow_cnt/rps_sock_flow_entries` 确认 RPS/RFS 为 0。
3. `/sys/class/net/<vf>/threaded` 确认为 0。
4. `ps -eLo pid,tid,psr,comm` 确认 benchmark 线程只在目标 cluster。
5. `/proc/irq/<irq>/effective_affinity_list` 确认 IRQ 真实生效 CPU。
6. `tracepoint:irq:irq_handler_entry` 确认 IRQ 实际 CPU。
7. `tracepoint:napi:napi_poll` 确认目标 VF NAPI poll CPU。
8. `ip + dev + queue + cpu + comm` 脚本确认方法 6 / 6C 是否混入其它 dev/queue。
9. 若仍扩散，检查 XPS、busy poll、NAPI defer、设备 reset 后 IRQ/vector 是否重建。

## 9. 常见结论

### 9.1 IRQ CPU 已扩散

表现：

```text
irq_handler_entry 中目标 VF IRQ 出现在 8 核之外
effective_affinity_list 也不是目标 8 核
```

处理：

- 停止或配置 `irqbalance`
- 重新写入所有目标 VF completion IRQ 的 affinity
- 设备 reset / down up 后重新绑定
- 确认没有漏绑 VF 的其它 completion vector

### 9.2 NAPI CPU 已扩散，但 IRQ CPU 没扩散

表现：

```text
irq_handler_entry 只有 8 核
napi:napi_poll 出现 10-30+ CPU
```

处理：

- 确认 `threaded=0`
- 查看是否有 busy poll / defer hard IRQ
- 查看 `comm` 是否为 `ksoftirqd/N`
- 查是否有同一 NAPI 被其它路径调度

### 9.3 NAPI CPU 没扩散，但方法 6 / 6C 扩散

表现：

```text
napi:napi_poll 对目标 VF 只有 8 核
方法 6 / 6C 按 IP 看有 10-30+ CPU
```

处理：

- 不要继续使用纯 `ip -> cpu` 口径下结论
- 使用 `ip + dev + queue + cpu + comm`
- 必要时增加端口维度，区分 Redis 实例与其它 TCP 流量
- 对 bpftrace 脚本增加 `skb->dev->name == "<vf>"` 过滤

### 9.4 dev/queue 混入

表现：

```text
同一 client_ip 出现多个 dev
或同一 dev 下 queue 数超过预期
```

处理：

- 修路由或 source policy routing
- 确认 VF IP 是否只配置在一个 netdev
- 确认 `redis-benchmark --client-ip` 没有因重连或错误路径静默失败
- 用 `ss -tnp` 确认连接本地地址

```bash
ss -tnp | grep redis-benchmark
```

## 10. 最终判断标准

只有同时满足下面条件，才能说“该 VF/IP 的网络处理被限制在目标 8 核 cluster”：

```text
1. ip route get 显示目标 client_ip 走目标 VF
2. RPS/RFS 为 0
3. threaded NAPI 为 0
4. redis-benchmark 线程只在目标 8 核运行
5. 目标 VF IRQ effective affinity 只包含目标 8 核
6. irq_handler_entry 中目标 VF IRQ 只出现在目标 8 核
7. napi:napi_poll 中目标 VF 只出现在目标 8 核
8. ip + dev + queue + cpu + comm 中目标 IP 只对应目标 dev、目标 queue 和目标 8 核
```

如果第 7 步成立但第 8 步不成立，问题在观测口径或流量混入。  
如果第 7 步不成立，问题在 IRQ/NAPI 实际执行路径，不在 Redis 或 source IP 绑定本身。
