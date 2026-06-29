# 观察 Docker 网络模式下 NAPI 差异的实战指南

## 文档概述

本文档提供实用的命令和方法，帮助你在运行的 Linux 系统中直接观察 Docker IPvlan、Host Network、VF 直通三种网络模式下 NAPI 机制的差异，特别是 NAPI 实例归属和 Budget 隔离情况。

**目标**：
- 验证 IPvlan 模式下容器共享 PF 的 NAPI 实例
- 验证 VF 直通模式下每个容器有独立的 NAPI 实例
- 观察 Budget 竞争和隔离的实际效果

---

## 目录

- [一、查看 NAPI 实例和中断](#一查看-napi-实例和中断)
- [二、观察 softnet_data 统计](#二观察-softnet_data-统计)
- [三、使用 eBPF 追踪 NAPI 处理](#三使用-ebpf-追踪-napi-处理)
- [四、查看网卡队列和中断亲和性](#四查看网卡队列和中断亲和性)
- [五、实时负载对比测试](#五实时负载对比测试)
- [六、验证 NAPI 注册情况](#六验证-napi-注册情况)
- [七、NAPI 参数调优](#七napi-参数调优)
- [八、高级分析：内核追踪](#八高级分析内核追踪)
- [九、总结对比表](#九总结对比表)
- [十、实战案例：完整验证流程](#十实战案例完整验证流程)

---

## 一、查看 NAPI 实例和中断

### 1.1 查看网卡的中断号

**目的**：验证 IPvlan 没有独立中断，VF 有独立中断。

```bash
# 查看所有网络设备的中断
cat /proc/interrupts | grep -E "eth|ixgbe|mlx"

# 输出示例（物理网卡 PF）：
# 123:  1234567  IR-PCI-MSI 1234567-edge  ixgbe-TxRx-0
# 124:  1234568  IR-PCI-MSI 1234568-edge  ixgbe-TxRx-1

# 查看某个网卡的 MSI-X 中断
ls -la /sys/class/net/eth0/device/msi_irqs/
```

**IPvlan 模式预期**：
```bash
# IPvlan 虚拟设备没有 MSI-X 中断
ls /sys/class/net/ipvlan0/device/msi_irqs/
# ls: cannot access '/sys/class/net/ipvlan0/device/msi_irqs/': No such file or directory
```

**VF 直通模式预期**：
```bash
# VF 有独立的 MSI-X 中断
ls /sys/class/net/eth1/device/msi_irqs/
# 输出：125  126  127  128  (VF 的独立中断号)
```

### 1.2 查看中断统计

```bash
# 实时监控中断计数变化
watch -n 1 'cat /proc/interrupts | grep -E "eth|ixgbe" | head -20'
```

**关键观察**：
- **IPvlan**：只能看到父设备（PF）的中断计数增加，IPvlan 虚拟设备不在列表中
- **VF 直通**：每个 VF 有独立的中断行，计数独立增加

---

## 二、观察 softnet_data 统计

### 2.1 查看 per-CPU 软中断统计

**目的**：观察每个 CPU 处理网络数据包的情况，验证 Budget 竞争。

```bash
# 查看所有 CPU 的软中断统计
cat /proc/net/softnet_stat

# 输出格式（每行代表一个 CPU）：
# 列 1: processed       - 处理的数据包总数
# 列 2: dropped         - 丢弃的数据包数
# 列 3: time_squeeze    - budget 耗尽次数（关键指标）
# 列 4-9: 历史占位字段，Linux 6.6 当前输出为 0
# 列 10: received_rps   - RPS 接收的数据包数
# 列 11: flow_limit_count
# 列 12: input_qlen + process_qlen
# 列 13: CPU index
# 列 14: input_qlen
# 列 15: process_qlen
```

**列定义参考来源**：当前 Linux 6.6 的 `/proc/net/softnet_stat` 输出由 `net/core/net-procfs.c` 中的 `softnet_seq_show()` 生成，可对照 `/home/fsq/Desktop/kernel-src/linux-6.6.0-132.0.0.111.oe2403sp3.aarch64/net/core/net-procfs.c:177` 附近的 `seq_printf()` 参数顺序。该实现中第 4-9 列为历史占位 `0`，`received_rps` 是第 10 列。

**实时监控 time_squeeze**：
```bash
# 持续监控（每秒刷新）
watch -n 1 'cat /proc/net/softnet_stat'

# 或者计算增量
while true; do
  echo "=== $(date) ==="
  awk '{print "CPU", NR-1, "time_squeeze:", $3}' /proc/net/softnet_stat | \
    while read line; do
      printf "%s (decimal: %d)\n" "$line" $((16#$(echo $line | awk '{print $NF}')))
    done
  sleep 1
done
```

**预期差异**：

| 场景 | IPvlan（3 容器高负载） | VF 直通（3 容器高负载） |
|------|----------------------|----------------------|
| **time_squeeze** | 某个 CPU 的值快速增长<br>（如 CPU0: 1000 → 5000） | 各 CPU 的值增长缓慢且分散<br>（CPU0: 100, CPU1: 120, CPU2: 110） |
| **原因** | 多个容器的流量在同一 CPU 竞争 300 budget | 每个 VF 的中断绑定到不同 CPU，各自独立消耗 budget |

### 2.2 解读 time_squeeze

```bash
# time_squeeze 的含义：
# net_rx_action() 执行时，budget 耗尽（≤0）或超时，但 poll_list 中还有 NAPI 实例未处理

# 计算 time_squeeze 增长率
cat /proc/net/softnet_stat | awk '{
  cpu = NR - 1
  squeeze = strtonum("0x" $3)
  printf "CPU %2d: time_squeeze = %8d\n", cpu, squeeze
}'
```

**budget 或时间配额耗尽后的行为**：

- 本轮 `net_rx_action()` 停止继续 poll，不会在同一轮软中断里无限处理网络包。
- 未处理完的 NAPI 不会直接丢弃；内核会把未完成的 `list`、`repoll` 以及期间新调度进来的 `sd->poll_list` 合并回当前 CPU 的 `softnet_data.poll_list`。
- 如果 `softnet_data.poll_list` 仍非空，内核会再次触发 `NET_RX_SOFTIRQ`，下一轮继续处理；后续可能继续在当前上下文运行，也可能被推给 `ksoftirqd/N`（tid 便会发生变化）。
- `time_squeeze` 会递增，这是观察 budget 或时间窗口频繁耗尽的关键指标。

`★ Insight ─────────────────────────────────────`
- `time_squeeze` 不是丢包数，而是“本轮软中断没能在预算内处理完”的次数。
- 偶发增长说明内核在做软中断限流；持续快速增长通常意味着 RX 路径处理能力追不上包到达速度。
- 长期积压可能进一步表现为延迟升高、`ksoftirqd` 占用升高、`/proc/net/softnet_stat` dropped 增长、网卡 ring drop 或协议层重传。
`─────────────────────────────────────────────────`

---

## 三、使用 eBPF 追踪 NAPI 处理

### 3.1 使用 bpftrace 追踪 napi_poll

下面几个**周期性输出直方图**的示例，统一改成“每 10 秒输出 1 次，默认输出 3 次后自动退出”。如需调整输出次数，修改脚本中的 `@max_rounds` 即可。

**安装**：
```bash
# Ubuntu/Debian
sudo apt install bpftrace

# CentOS/RHEL
sudo yum install bpftrace
```

**追踪 各进程 NAPI poll 调用次数**：看进程忙不忙
```bash
# 统计每个进程调用 napi_poll 的次数
sudo bpftrace -e '
kprobe:napi_poll {
  @calls[comm] = count();
}

interval:s:5 {
  print(@calls);
  clear(@calls);
}
'
```

**追踪 每次__napi_poll 的 budget 参数**：看进程一次干多少活
```bash
# 追踪每次 poll 分配的 budget 值
sudo bpftrace -e '
BEGIN {
  @max_rounds = 3;
  @round = 0;
}

kprobe:__napi_poll {
  $napi = (struct napi_struct *)arg0;
  $weight = $napi->weight;
  @budget_hist = hist($weight);
  @budget_avg = avg($weight);
}

interval:s:10 {
  // 每 10 秒输出一次，累计输出 3 次后自动退出
  print(@budget_hist);
  print(@budget_avg);

  clear(@budget_hist);
  clear(@budget_avg);

  @round = @round + 1;
  if (@round >= @max_rounds) {
    exit();
  }
}

END {
  clear(@budget_hist);
  clear(@budget_avg);
  clear(@round);
  clear(@max_rounds);
}
'
```

**追踪 每次 net_rx_action 的执行时间和 budget 消耗**：
```bash
# 方法 1：追踪每次 net_rx_action 获取到的总 budget 和时间配额
sudo bpftrace -e '
BEGIN {
  printf("Tracing net_rx_action entry budget...\n");
  printf("Press Ctrl+C to stop\n\n");
}

kprobe:net_rx_action {
  // 读取 net/core/dev.c 中 net_rx_action() 入口使用的全局包数和时间配额
  $budget = *(int32 *)kaddr("netdev_budget");
  $usecs = *(uint32 *)kaddr("netdev_budget_usecs");

  printf("[%s] cpu=%d comm=%s netdev_budget=%d netdev_budget_usecs=%u\n",
         strftime("%H:%M:%S", nsecs), cpu, comm, $budget, $usecs);

  @budget_seen[$budget, $usecs] = count();
}

interval:s:10 {
  print(@budget_seen);
  clear(@budget_seen);
}
'

# 方法 2：追踪每次 net_rx_action 执行时间（微秒）
sudo bpftrace -e '
BEGIN {
  @max_rounds = 3;
  @round = 0;
}

kprobe:net_rx_action {
  @start_time[tid] = nsecs;
}

kretprobe:net_rx_action {
  $elapsed = (nsecs - @start_time[tid]) / 1000;  // 微秒
  @duration_hist = hist($elapsed);
  delete(@start_time[tid]);
}

interval:s:10 {
  // 每 10 秒输出一次，累计输出 3 次后自动退出
  print(@duration_hist);
  clear(@duration_hist);

  @round = @round + 1;
  if (@round >= @max_rounds) {
    exit();
  }
}

END {
  clear(@start_time);
  clear(@duration_hist);
  clear(@round);
  clear(@max_rounds);
}
'

# 方法 3：估算每次 net_rx_action 内累计的 napi_poll work（非严格 budget 上限）
sudo bpftrace -e '
BEGIN {
  @max_rounds = 3;
  @round = 0;
}

kprobe:net_rx_action {
  // 初始化本次软中断的累计消耗
  @budget_used[tid] = 0;
}

kretprobe:napi_poll {
  // 获取返回值（实际处理的包数）并累加到当前软中断的总消耗
  $consumed = retval;
  if ($consumed > 0 && @budget_used[tid] >= 0) {
    @budget_used[tid] += $consumed;
  }
}

kretprobe:net_rx_action {
  // 将本次软中断的总消耗记录到直方图
  if (@budget_used[tid] > 0) {
    @budget_hist = hist(@budget_used[tid]);
  }
  delete(@budget_used[tid]);
}

interval:s:10 {
  // 每 10 秒输出一次，累计输出 3 次后自动退出
  print(@budget_hist);
  clear(@budget_hist);

  @round = @round + 1;
  if (@round >= @max_rounds) {
    exit();
  }
}

END {
  clear(@budget_used);
  clear(@budget_hist);
  clear(@round);
  clear(@max_rounds);
}
'

# 方法 4：统计每次 net_rx_action 实际消耗的 budget 和时间配额直方图（推荐）
sudo bpftrace -e '
BEGIN {
  printf("Tracing per net_rx_action budget/time histograms...\n");
  printf("Will print every 3 seconds and stop after 3 interval prints by default\n\n");
  @max_rounds = 3;
  @round = 0;
}

kprobe:net_rx_action {
  // 统计本采样窗口内 net_rx_action() 被调用的次数
  @rx_action_count++;

  // net_rx_action 在单个 CPU 的软中断上下文中运行，用 cpu 作为本轮窗口 key
  @active[cpu] = 1;
  @start_ns[cpu] = nsecs;
  @budget_used[cpu] = 0;
  @polls[cpu] = 0;
  @entry_budget[cpu] = *(int32 *)kaddr("netdev_budget");
  @entry_usecs[cpu] = *(uint32 *)kaddr("netdev_budget_usecs");
}

tracepoint:napi:napi_poll /@active[cpu]/ {
  // args->work 是本次 NAPI poll 实际处理的包数
  @budget_used[cpu] += args->work;
  @polls[cpu]++;
}

kretprobe:net_rx_action /@active[cpu]/ {
  $elapsed_us = (nsecs - @start_ns[cpu]) / 1000;
  $work = @budget_used[cpu];
  $budget = @entry_budget[cpu];
  $usecs = @entry_usecs[cpu];

  // 每次 net_rx_action() 返回时，只更新分布，不逐次打印明细
  @budget_used_hist = hist($work);
  @elapsed_us_hist = hist($elapsed_us);
  @polls_per_rx_hist = hist(@polls[cpu]);

  if ($usecs > 0) {
    @time_used_pct_hist = hist($elapsed_us * 100 / $usecs);
    if ($elapsed_us >= $usecs) {
      @time_exhausted = count();
    }
  }

  if ($work >= $budget) {
    @budget_exhausted = count();
  }

  delete(@active[cpu]);
  delete(@start_ns[cpu]);
  delete(@budget_used[cpu]);
  delete(@polls[cpu]);
  delete(@entry_budget[cpu]);
  delete(@entry_usecs[cpu]);
}

interval:s:3 {
  // 每 3 秒输出一次，累计输出 3 次后自动退出
  printf("\n=== net_rx_action budget/time histograms ===\n");
  print(@rx_action_count);
  print(@budget_used_hist);
  print(@elapsed_us_hist);
  print(@time_used_pct_hist);
  print(@polls_per_rx_hist);
  print(@budget_exhausted);
  print(@time_exhausted);

  clear(@rx_action_count);
  clear(@budget_used_hist);
  clear(@elapsed_us_hist);
  clear(@time_used_pct_hist);
  clear(@polls_per_rx_hist);
  clear(@budget_exhausted);
  clear(@time_exhausted);

  @round = @round + 1;
  if (@round >= @max_rounds) {
    exit();
  }
}

END {
  clear(@rx_action_count);
  clear(@active);
  clear(@start_ns);
  clear(@budget_used);
  clear(@polls);
  clear(@entry_budget);
  clear(@entry_usecs);
  clear(@budget_used_hist);
  clear(@elapsed_us_hist);
  clear(@time_used_pct_hist);
  clear(@polls_per_rx_hist);
  clear(@budget_exhausted);
  clear(@time_exhausted);
  clear(@round);
  clear(@max_rounds);
}
'

# 方法 5：按 PF/VF 设备统计 net_rx_action 触达次数和处理 CPU
sudo bpftrace -e '
BEGIN {
  printf("Tracing net_rx_action by NAPI device and CPU...\n");
  printf("Will print every 3 seconds and stop after 3 interval prints by default\n\n");
  @max_rounds = 3;
  @round = 0;
}

kprobe:net_rx_action {
  // net_rx_action 本身没有设备参数，只能先记录当前 CPU 正在处理 softirq 窗口
  @active[cpu] = 1;

  // 为每个 CPU 上的 net_rx_action 生成递增序号，用来区分同 CPU 上不同轮次
  @rx_seq[cpu]++;

  // 统计 3 秒窗口内每个 CPU 进入 net_rx_action() 的总次数
  @rx_action_total[cpu] = count();
}

tracepoint:napi:napi_poll /@active[cpu]/ {
  // napi_poll tracepoint 暴露 dev_name、work、budget，可用于把 softirq 窗口归因到 PF/VF 设备
  $dev = str(args->dev_name);
  $seq = @rx_seq[cpu];

  /*
   * 同一次 net_rx_action 可能多次 poll 同一设备。
   * 这里按 dev,cpu 对每轮 net_rx_action 只计 1 次，表示“这轮触达过该设备”。
   */
  if (@seen[cpu, $dev] != $seq) {
    @rx_action_by_dev_cpu[$dev, cpu] = count();
    @seen[cpu, $dev] = $seq;
  }

  // 观察 3 秒窗口内某设备由哪些 CPU 处理过；看 key 即可得到 CPU 集合
  @dev_seen_on_cpu[$dev, cpu] = count();

  // 辅助判断：同一设备在各 CPU 上的 NAPI poll 次数、RX work 和传入 poll 的 budget
  @napi_poll_by_dev_cpu[$dev, cpu] = count();
  @work_by_dev_cpu[$dev, cpu] = sum(args->work);
  @budget_by_dev_cpu[$dev, cpu] = sum(args->budget);
}

kretprobe:net_rx_action /@active[cpu]/ {
  delete(@active[cpu]);
}

interval:s:3 {
  printf("\n=== net_rx_action total by CPU ===\n");
  print(@rx_action_total);

  printf("\n=== net_rx_action touched device by dev,cpu ===\n");
  print(@rx_action_by_dev_cpu);

  printf("\n=== device handled by CPUs in this window ===\n");
  print(@dev_seen_on_cpu);

  printf("\n=== napi_poll count by dev,cpu ===\n");
  print(@napi_poll_by_dev_cpu);

  printf("\n=== RX work by dev,cpu ===\n");
  print(@work_by_dev_cpu);

  printf("\n=== NAPI budget passed to poll by dev,cpu ===\n");
  print(@budget_by_dev_cpu);

  clear(@rx_action_total);
  clear(@rx_action_by_dev_cpu);
  clear(@dev_seen_on_cpu);
  clear(@napi_poll_by_dev_cpu);
  clear(@work_by_dev_cpu);
  clear(@budget_by_dev_cpu);

  @round = @round + 1;
  if (@round >= @max_rounds) {
    exit();
  }
}

END {
  clear(@active);
  clear(@rx_seq);
  clear(@seen);
  clear(@rx_action_total);
  clear(@rx_action_by_dev_cpu);
  clear(@dev_seen_on_cpu);
  clear(@napi_poll_by_dev_cpu);
  clear(@work_by_dev_cpu);
  clear(@budget_by_dev_cpu);
  clear(@round);
  clear(@max_rounds);
}
'

# 方法 6：追踪 time_squeeze 事件（通过 /proc 对比）
# 注意：bpftrace 无法直接访问 softnet_data 结构体的 time_squeeze 字段
# 建议使用 shell 脚本配合 bpftrace：
bash -c '
# 记录初始 time_squeeze 值
cat /proc/net/softnet_stat | awk "{print \$3}" > /tmp/squeeze_before.txt

# 运行追踪（持续 10 秒）
timeout 10 sudo bpftrace -e "
kprobe:net_rx_action {
  @rx_calls = count();
}
" > /tmp/bpf_trace.txt 2>&1

# 记录结束后的 time_squeeze 值
cat /proc/net/softnet_stat | awk "{print \$3}" > /tmp/squeeze_after.txt

# 计算差值
paste /tmp/squeeze_before.txt /tmp/squeeze_after.txt | awk "{
  before = strtonum(\"0x\" \$1);
  after = strtonum(\"0x\" \$2);
  delta = after - before;
  printf \"CPU %d: time_squeeze delta = %d\\n\", NR-1, delta;
  total += delta;
} END {
  print \"Total time_squeeze events:\", total;
}"

# 显示 rx_action 调用次数
grep "@rx_calls" /tmp/bpf_trace.txt
'

# 方法 7：统计每次 net_rx_action 和 napi_poll 次数（快速粗略观测）
sudo bpftrace -e '
BEGIN {
  printf("Monitoring NAPI budget consumption...\n");
  printf("Press Ctrl+C to stop\n\n");
}

kprobe:net_rx_action {
  @rx_action_count++;
}

kprobe:napi_poll {
  @napi_poll_count++;
}

interval:s:5 {
  $rx = @rx_action_count;
  $polls = @napi_poll_count;

  printf("[%s] rx_action: %d, napi_poll: %d\n",
         strftime("%H:%M:%S", nsecs),
         $rx, $polls);
         
  if ($rx > 0) {
    printf("  avg_polls_per_rx: %d\n", $polls / $rx);
  }
  
  clear(@rx_action_count);
  clear(@napi_poll_count);
}
'
```

**说明**：
- **方法 1**：在 `net_rx_action` 入口读取 `netdev_budget` 和 `netdev_budget_usecs` 全局变量，确认每次软中断拿到的初始包数和时间配额
- **方法 2**：测量 `net_rx_action` 的执行时间，间接反映处理负载
- **方法 3**：用 `kretprobe:napi_poll` 累计返回值来估算本轮软中断处理的 work，总数可能超过 `netdev_budget`
- **方法 4**：用 `cpu` 限定本轮 `net_rx_action()` 窗口，并通过 `tracepoint:napi:napi_poll` 累计 `args->work`，周期性输出 `net_rx_action()` 调用次数、实际 budget 消耗、实际耗时、时间配额占比和 poll 次数直方图
- **方法 5**：按 `napi:napi_poll` 的 `dev_name` 把 `net_rx_action()` 触达过的 PF/VF 设备归因到具体 CPU，观察每个设备在 3 秒窗口内由哪些 CPU 处理、触达过多少轮软中断、累计多少 RX work
- **方法 6**：追踪 `time_squeeze` 事件，检测 budget 耗尽或超时（需要访问内核结构体，可能受限）
- **方法 7**：统计 `net_rx_action` 和 `napi_poll` 的调用次数，计算平均每次软中断调用多少次 poll（最简单可靠）

**关于方法 4 中 `budget_used=0` 的解释**：
- `budget_used=0` 表示本轮 `net_rx_action()` 窗口里，`napi:napi_poll` tracepoint 暴露的 `args->work` 累加值为 0；它只说明没有发生可计入 RX budget 扣减的 work。
- 这不等价于“没有网络活动”，也不等价于“当前一定在发包”。它可能来自发包方向的 TX completion、RX ring 暂时无包、目标 VF 的 NAPI poll 没落在当前窗口、低流量空轮询、threaded NAPI/busy poll 路径未被当前窗口覆盖，或脚本统计了非目标设备导致 0 值被放大。
- Docker VF 直通场景下，如果 `budget_used` 大多为 0，应优先确认流量方向和目标 VF 的 RX 计数。只有同时看到目标 VF 的 TX 计数增长、RX work 很少，才可以把“主要在处理发包/TX completion”作为合理解释之一。
- 因此，方法 4 更适合观察“单轮软中断是否消耗 RX budget”，不适合单独判断“VF 是否有发包活动”。判断发包应结合 `ethtool -S <vf_netdev>` 的 TX/RX 计数或按 `args->dev_name` 过滤目标 VF 的 NAPI tracepoint。

`★ Insight ─────────────────────────────────────`
- `netdev_budget` 是 `net_rx_action()` 入口读取的总包数配额；脚本读的是入口初始值，不是循环执行后剩余的局部 `budget`。
- `netdev_budget_usecs` 是同一轮软中断的时间窗口，和包数配额共同决定本轮 NAPI poll 何时让出 CPU。
- 方法 3 的累计值不是严格上限：`net_rx_action()` 先执行一次 `napi_poll()`，再扣减并判断 `budget <= 0`，所以默认 `netdev_budget=300`、`napi->weight=64` 时，单轮可能出现 `320` 这类正常超限值。
- 如果方法 3 出现 `1k-2k`，通常不是单轮 `netdev_budget` 真的放大，而是 `tid` 归集、kprobe 丢事件、softirq/ksoftirqd 执行上下文或其他 NAPI poll 路径混入，导致多轮 poll work 被累加到同一个桶。
- 方法 4 的统计口径更接近源码：`net_rx_action()` 在当前 CPU 运行期间，`napi:napi_poll` tracepoint 暴露的 `work` 就是本轮从全局包数 budget 中扣减的实际处理量；`elapsed_us_hist` 和 `time_used_pct_hist` 可直接观察本轮实际时间消耗及其相对 `netdev_budget_usecs` 的占比。
- `budget_used=0` 的核心含义是“没有 RX budget 消耗”，不是“没有收发包动作”；发包方向的 TX completion 只是其中一种可能。
- 如果 `kaddr()` 报符号不可见，优先检查 `/proc/kallsyms` 权限、`kernel.kptr_restrict` 和 bpftrace 是否具备 root 权限。
`─────────────────────────────────────────────────`

**推荐使用方法 4**，因为：
- 能用直方图同时观察单轮 `net_rx_action()` 的实际包数消耗和时间消耗分布
- 同时输出采样窗口内 `net_rx_action()` 调用次数，便于区分“软中断触发很多但 RX work 很少”和“软中断本身就很少触发”
- 使用 `cpu` 关联软中断执行窗口，比用 `tid` 归集更贴近 per-CPU `softnet_data` 模型
- `tracepoint:napi:napi_poll` 直接提供 `work` 字段，比从 `kretprobe:napi_poll` 反推更清晰

**需要观察 PF/VF 设备与 CPU 关系时，使用方法 5**：
- `@rx_action_total[cpu]` 表示 3 秒窗口内每个 CPU 进入 `net_rx_action()` 的总次数
- `@rx_action_by_dev_cpu[dev,cpu]` 表示某设备在某 CPU 上被多少轮 `net_rx_action()` 触达过；同一轮里同一设备多次 poll 只计 1 次
- `@dev_seen_on_cpu[dev,cpu]` 用来回答“3 秒内某设备被哪些 CPU 处理过”，看 key 即可得到 CPU 集合
- `@napi_poll_by_dev_cpu[dev,cpu]`、`@work_by_dev_cpu[dev,cpu]`、`@budget_by_dev_cpu[dev,cpu]` 用来辅助判断该设备在对应 CPU 上的 poll 次数、RX work 和 poll budget 规模
- 注意：同一次 `net_rx_action()` 可能触达多个设备，所以按设备维度求和可能大于 `@rx_action_total`，不能把它理解为严格所有权

**快速粗略观察可使用方法 7**，因为：
- 不依赖内核数据结构（更可靠）
- 输出清晰易懂
- 可以看出 budget 的利用情况（polls_per_rx 越高，说明 budget 利用越充分）

### 3.2 使用 bcc 工具追踪

```bash
# 安装 bcc-tools
sudo apt install bpfcc-tools  # Ubuntu
sudo yum install bcc-tools    # CentOS

# 追踪软中断延迟
sudo softirqs-bpfcc -d 10
# 查看 NET_RX 列，IPvlan 模式下会显示更高的延迟
```

---

## 四、查看网卡队列和中断亲和性

### 4.1 查看网卡队列数

```bash
# 查看当前队列配置
ethtool -l eth0

# 输出示例：
# Channel parameters for eth0:
# Pre-set maximums:
# RX:             8
# TX:             8
# Combined:       8
# Current hardware settings:
# RX:             8
# TX:             8
# Combined:       8
```

**IPvlan 模式**：IPvlan 虚拟设备不支持 ethtool 查询
```bash
ethtool -l ipvlan0
# Cannot get device channel parameters: Operation not supported
```

**VF 直通模式**：每个 VF 有独立的队列配置
```bash
ethtool -l eth1  # VF 设备
# 通常 VF 的队列数少于 PF（如 2-4 个）
```

### 4.2 查看中断亲和性（IRQ affinity）

```bash
# 查看所有 eth0 相关中断的 CPU 亲和性
for irq in $(cat /proc/interrupts | grep eth0 | awk -F: '{print $1}'); do
  echo "IRQ $irq: CPU $(cat /proc/irq/$irq/smp_affinity_list)"
done

# 输出示例：
# IRQ 123: CPU 0
# IRQ 124: CPU 1
# IRQ 125: CPU 2
```

**VF 直通模式的关键验证**：
```bash
# 假设有 3 个 VF，分别是 eth1, eth2, eth3
# 它们的中断应该绑定到不同的 CPU

# VF0 (eth1) 的中断
cat /proc/interrupts | grep eth1
# 125:  123456  IR-PCI-MSI-edge  eth1-TxRx-0

cat /proc/irq/125/smp_affinity_list
# 输出：0  （绑定到 CPU0）

# VF1 (eth2) 的中断
cat /proc/interrupts | grep eth2
# 130:  234567  IR-PCI-MSI-edge  eth2-TxRx-0

cat /proc/irq/130/smp_affinity_list
# 输出：1  （绑定到 CPU1）
```

### 4.3 查看 RSS（Receive Side Scaling）配置

```bash
# 查看 RSS 哈希配置
ethtool -x eth0

# 输出示例：
# RX flow hash indirection table for eth0 with 8 RX ring(s):
#     0:      0     1     2     3     4     5     6     7
#     8:      0     1     2     3     4     5     6     7
# ...
```

**关键差异**：
- **IPvlan**：所有容器共享 PF 的 RSS 配置
- **VF 直通**：每个 VF 有独立的 RSS 配置

---

## 五、实时负载对比测试

### 5.1 测试环境准备

**场景设置**：
- 3 个容器同时运行高网络负载（如 iperf3 服务端）
- 从外部客户端同时向 3 个容器发送大量数据

**Docker 启动命令**：

```bash
# IPvlan 模式（3 个容器）
docker run -d --name ipvlan1 --network ipvlan_net --ip 192.168.1.11 nginx
docker run -d --name ipvlan2 --network ipvlan_net --ip 192.168.1.12 nginx
docker run -d --name ipvlan3 --network ipvlan_net --ip 192.168.1.13 nginx

# VF 直通模式（3 个容器，需要 SR-IOV 配置）
docker run -d --name vf1 --device /dev/vfio/0 nginx
docker run -d --name vf2 --device /dev/vfio/1 nginx
docker run -d --name vf3 --device /dev/vfio/2 nginx
```

### 5.2 实时监控脚本

**多指标监控脚本**：
```bash
#!/bin/bash
# monitor_napi.sh - 实时监控 NAPI 相关指标

echo "开始监控 NAPI 指标..."
echo "按 Ctrl+C 停止"

while true; do
  clear
  echo "=== $(date) ==="
  echo ""
  
  # 1. 软中断统计
  echo "--- softnet_stat (time_squeeze) ---"
  awk '{
    cpu = NR - 1
    squeeze = strtonum("0x" $3)
    printf "CPU %2d: time_squeeze = %8d\n", cpu, squeeze
  }' /proc/net/softnet_stat
  
  echo ""
  
  # 2. 网络中断计数
  echo "--- Network Interrupts (top 5) ---"
  cat /proc/interrupts | grep -E "eth|ixgbe" | head -5
  
  echo ""
  
  # 3. 每个 CPU 的软中断（NET_RX）
  echo "--- NET_RX Softirq per CPU ---"
  cat /proc/softirqs | grep NET_RX
  
  echo ""
  
  # 4. CPU 使用率
  echo "--- CPU Usage (si = softirq) ---"
  mpstat -P ALL 1 1 | grep -E "CPU|Average"
  
  sleep 2
done
```

**运行监控**：
```bash
chmod +x monitor_napi.sh
./monitor_napi.sh
```

### 5.3 负载生成

**在客户端机器上运行**：
```bash
# 使用 iperf3 生成大量流量
# 同时向 3 个容器发送数据

# 终端 1
iperf3 -c 192.168.1.11 -t 60 -P 4

# 终端 2
iperf3 -c 192.168.1.12 -t 60 -P 4

# 终端 3
iperf3 -c 192.168.1.13 -t 60 -P 4
```

### 5.4 预期观察结果

**IPvlan 模式下**：
```
CPU  0: time_squeeze =     5234  ← 快速增长
CPU  1: time_squeeze =      123
CPU  2: time_squeeze =       89
CPU  3: time_squeeze =       76

mpstat 输出：
CPU    %usr   %sys   %soft   %idle
  0    5.2   12.3   35.6    46.9  ← 软中断占用高
  1    2.1    3.4    8.2    86.3
  2    1.8    2.9    6.5    88.8
```

**VF 直通模式下**：
```
CPU  0: time_squeeze =      456  ← 增长缓慢
CPU  1: time_squeeze =      478
CPU  2: time_squeeze =      492
CPU  3: time_squeeze =       12

mpstat 输出：
CPU    %usr   %sys   %soft   %idle
  0    3.2    8.1   18.4    70.3  ← 负载分散
  1    3.5    8.3   19.2    69.0
  2    3.1    7.9   18.8    70.2
```

---

## 六、验证 NAPI 注册情况

### 6.1 通过 sysfs 查看队列

```bash
# 物理网卡 PF 有队列目录
ls /sys/class/net/eth0/queues/
# 输出：rx-0  rx-1  rx-2  rx-3  tx-0  tx-1  tx-2  tx-3

# IPvlan 虚拟设备没有队列目录
ls /sys/class/net/ipvlan0/queues/
# ls: cannot access '/sys/class/net/ipvlan0/queues/': No such file or directory

# VF 有独立的队列
ls /sys/class/net/eth1/queues/
# 输出：rx-0  rx-1  tx-0  tx-1
```

### 6.2 查看网络设备类型

```bash
# 查看设备类型和驱动
cat /sys/class/net/eth0/device/uevent
# 输出：
# DRIVER=ixgbe
# PCI_SLOT_NAME=0000:03:00.0

cat /sys/class/net/ipvlan0/uevent
# 输出：
# DEVTYPE=ipvlan  ← 虚拟设备，无物理驱动

cat /sys/class/net/eth1/device/uevent
# 输出：
# DRIVER=ixgbevf  ← VF 驱动
# PCI_SLOT_NAME=0000:03:10.0
```

### 6.3 使用 ip 命令查看设备信息

```bash
# 查看网络设备详细信息
ip -d link show

# IPvlan 设备输出：
# 4: ipvlan0@eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
#     link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff
#     ipvlan mode l3 bridge  ← 标识为 ipvlan 模式

# VF 设备输出：
# 5: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
#     link/ether 11:22:33:44:55:66 brd ff:ff:ff:ff:ff:ff
#     vf 0 MAC 11:22:33:44:55:66  ← 标识为 VF
```

---

## 七、NAPI 参数调优

### 7.1 理解 NAPI weight 与 netdev_budget

#### 关键区别

| 参数 | 作用范围 | 默认值 | 可调整性 | 修改方式 |
|------|---------|-------|---------|---------|
| **napi->weight** | 单个 NAPI 实例单次 poll() 的最大数据包数 | 64 | 驱动层设定 | 需重新编译驱动/内核 |
| **netdev_budget** | 单次软中断的总数据包配额（所有 NAPI 实例共享） | 300 | 运行时可调 | `sysctl -w net.core.netdev_budget=<值>` |

**两者关系**：

```c
// 内核源码逻辑
static void net_rx_action(struct softirq_action *h)
{
    int budget = READ_ONCE(netdev_budget);  // 全局配额 300
    
    for (;;) {
        struct napi_struct *n = ...;
        int work = napi_poll(n, &repoll);   // 单个 NAPI 的 weight=64
        budget -= work;                      // 从全局扣除实际处理数
        
        if (budget <= 0) break;              // 全局耗尽就停止
    }
}
```

**重要结论**：
- ✅ 调整 `netdev_budget` **不会修改** `napi->weight` 的值
- ✅ `netdev_budget` 决定单次软中断能处理多少轮 NAPI poll
- ✅ `napi->weight` 决定每轮 poll 最多处理多少个数据包

### 7.2 查看和调整 netdev_budget

```bash
# 查看当前值
sysctl net.core.netdev_budget
sysctl net.core.netdev_budget_usecs

# 临时调整（立即生效，重启失效）
sudo sysctl -w net.core.netdev_budget=600
sudo sysctl -w net.core.netdev_budget_usecs=4000

# 永久调整（写入配置文件）
echo "net.core.netdev_budget = 600" | sudo tee -a /etc/sysctl.conf
echo "net.core.netdev_budget_usecs = 4000" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 验证修改效果
sysctl net.core.netdev_budget
```

### 7.3 观察当前 NAPI weight 值

```bash
# 方法 1：使用 bpftrace 追踪
sudo bpftrace -e '
kprobe:__napi_poll {
  $napi = (struct napi_struct *)arg0;
  @weight[comm] = hist($napi->weight);
}

interval:s:10 {
  print(@weight);
  clear(@weight);
}
'

# 方法 2：通过驱动源码查看
grep -r "netif_napi_add" /path/to/driver/source/
# 输出示例：
# netif_napi_add(adapter->netdev, &q_vector->napi, ixgbe_poll);
# 默认 weight 由 include/linux/netdevice.h 中的 NAPI_POLL_WEIGHT=64 提供
```

### 7.4 修改 NAPI weight（高级）

#### 方法 1：修改驱动源码

```bash
# 1. 定位驱动源码
cd /usr/src/linux-headers-$(uname -r)/drivers/net/ethernet/intel/ixgbe/

# 2. 修改 NAPI 注册代码
# 找到类似这样的代码：
# netif_napi_add(adapter->netdev, &q_vector->napi, ixgbe_poll);
# 如果确实要为该驱动自定义 weight，可改为：
# netif_napi_add_weight(adapter->netdev, &q_vector->napi, 
#                       ixgbe_poll, 128);  // 增大到 128

# 3. 重新编译和加载驱动
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
sudo rmmod ixgbe
sudo insmod ixgbe.ko

# 4. 验证修改
sudo bpftrace -e 'kprobe:__napi_poll { $napi = (struct napi_struct *)arg0; printf("weight=%d\n", $napi->weight); }' | head -5
```

#### 方法 2：修改内核默认值

```bash
# 修改内核头文件
sudo vim /usr/src/linux/include/linux/netdevice.h
# 找到：#define NAPI_POLL_WEIGHT 64
# 改为：#define NAPI_POLL_WEIGHT 128

# 重新编译内核（耗时较长）
cd /usr/src/linux
make -j$(nproc)
sudo make modules_install
sudo make install
sudo reboot
```

### 7.5 调优场景和建议

#### 场景 1：IPvlan 多容器，time_squeeze 频繁

**问题表现**：
```bash
# 某个 CPU 的 time_squeeze 快速增长
cat /proc/net/softnet_stat
# CPU 0: 00012345 00000000 00005678 ...  ← 第3列快速增长
```

**解决方案（推荐）**：
```bash
# 增大 netdev_budget
sudo sysctl -w net.core.netdev_budget=600

# 或增大时间配额
sudo sysctl -w net.core.netdev_budget_usecs=4000

# 实时观察效果
watch -n 1 'cat /proc/net/softnet_stat'
```

**为什么有效**：
- 允许单次软中断处理更多数据包
- 减少因 budget 耗尽导致的 time_squeeze

#### 场景 2：低延迟应用

**需求**：减少网络处理延迟

**解决方案**：
```bash
# 减小 netdev_budget
sudo sysctl -w net.core.netdev_budget=150

# 减小中断合并延迟
ethtool -C eth0 rx-usecs 10
```

**权衡**：
- ✅ 降低延迟
- ❌ 可能降低吞吐量
- ❌ 增加 CPU 使用率

#### 场景 3：高吞吐量场景

**需求**：最大化网络吞吐量

**解决方案**：
```bash
# 增大 netdev_budget 和时间配额
sudo sysctl -w net.core.netdev_budget=1000
sudo sysctl -w net.core.netdev_budget_usecs=8000

# 启用更多网卡队列
ethtool -L eth0 combined 16
```

**权衡**：
- ✅ 提高吞吐量
- ❌ 可能增加延迟
- ❌ 占用更多 CPU 时间

#### 场景 4：VF 直通模式优化

**通常不需要调整**：VF 已有独立 NAPI 实例，默认配置即可

**如需优化**：
```bash
# 调整 VF 的中断合并参数
ethtool -C eth1 rx-usecs 20 rx-frames 32

# 绑定 VF 中断到特定 CPU（提高缓存命中率）
echo 2 > /proc/irq/<VF_IRQ>/smp_affinity_list  # 绑定到 CPU 2
```

### 7.6 调优效果验证

```bash
# 1. 记录调优前的基准数据
cat /proc/net/softnet_stat > /tmp/before.txt
cat /proc/softirqs | grep NET_RX > /tmp/softirq_before.txt

# 2. 施加负载（运行 60 秒）
iperf3 -c <target> -t 60 -P 8 &

# 3. 调整参数
sudo sysctl -w net.core.netdev_budget=600

# 4. 记录调优后的数据
sleep 60
cat /proc/net/softnet_stat > /tmp/after.txt
cat /proc/softirqs | grep NET_RX > /tmp/softirq_after.txt

# 5. 对比 time_squeeze 增长
paste <(awk '{print $3}' /tmp/before.txt) <(awk '{print $3}' /tmp/after.txt) | \
  awk '{printf "CPU %d: before=%d after=%d delta=%d\n", NR-1, strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$2)-strtonum("0x"$1)}'
```

---

## 八、高级分析：内核追踪

### 8.1 使用 ftrace 追踪 NAPI 函数

```bash
# 启用 function_graph tracer
echo function_graph > /sys/kernel/debug/tracing/current_tracer

# 设置追踪的函数
echo 'napi_poll' > /sys/kernel/debug/tracing/set_ftrace_filter
echo '__napi_poll' >> /sys/kernel/debug/tracing/set_ftrace_filter
echo 'net_rx_action' >> /sys/kernel/debug/tracing/set_ftrace_filter

# 启用追踪
echo 1 > /sys/kernel/debug/tracing/tracing_on

# 运行 5 秒
sleep 5

# 停止追踪
echo 0 > /sys/kernel/debug/tracing/tracing_on

# 查看结果
cat /sys/kernel/debug/tracing/trace | head -100
```

### 8.2 使用 perf 分析软中断热点

```bash
# 采集 10 秒的软中断事件
sudo perf record -e 'irq:softirq_entry' -a -g sleep 10

# 查看报告
sudo perf report

# 查看调用栈（找到 net_rx_action）
sudo perf script
```

---

## 九、总结对比表

| 验证项 | IPvlan 模式 | VF 直通模式 | 验证命令 |
|-------|-----------|-----------|---------|
| **中断号** | 只有 PF 的中断 | 每个 VF 有独立中断 | `cat /proc/interrupts` |
| **NAPI 实例** | 无独立 NAPI（复用 PF） | 每个 VF 有独立 NAPI | `ls /sys/class/net/*/queues/` |
| **time_squeeze** | 某个 CPU 快速增长 | 各 CPU 缓慢增长且分散 | `cat /proc/net/softnet_stat` |
| **中断亲和性** | 共享 PF 的 CPU 绑定 | 各 VF 绑定到不同 CPU | `cat /proc/irq/*/smp_affinity_list` |
| **softirq 分布** | 集中在某个 CPU | 分散在多个 CPU | `cat /proc/softirqs \| grep NET_RX` |
| **设备类型** | DEVTYPE=ipvlan | DRIVER=ixgbevf | `cat /sys/class/net/*/uevent` |

---

## 十、实战案例：完整验证流程

### 步骤 1：准备环境
```bash
# 启动 3 个 IPvlan 容器
docker network create -d ipvlan --subnet=192.168.1.0/24 -o parent=eth0 ipvlan_net
docker run -d --name ipvlan1 --network ipvlan_net --ip 192.168.1.11 nginx
docker run -d --name ipvlan2 --network ipvlan_net --ip 192.168.1.12 nginx
docker run -d --name ipvlan3 --network ipvlan_net --ip 192.168.1.13 nginx
```

### 步骤 2：记录基准值
```bash
# 记录初始 time_squeeze 值
cat /proc/net/softnet_stat > /tmp/baseline.txt
```

### 步骤 3：施加负载
```bash
# 从外部客户端向 3 个容器发送流量（每个 10Gbps）
# 运行 60 秒
```

### 步骤 4：观察 time_squeeze 增长
```bash
# 实时监控
watch -n 1 'paste <(echo "CPU") <(seq 0 $(nproc --all)) <(cat /proc/net/softnet_stat | awk "{print \$3}")'
```

### 步骤 5：对比 VF 模式
```bash
# 切换到 VF 直通模式，重复步骤 1-4
# 观察 time_squeeze 的增长速度显著降低
```

---

## 附录

### A. 常用 sysctl 参数

#### A.1 查看和调整参数

```bash
# 查看当前 netdev_budget（单次软中断的总数据包配额）
sysctl net.core.netdev_budget
# 默认：300

# 查看 netdev_budget_usecs（软中断时间配额）
sysctl net.core.netdev_budget_usecs
# 默认：2000（微秒）

# 临时调整（测试用）
sudo sysctl -w net.core.netdev_budget=500
sudo sysctl -w net.core.netdev_budget_usecs=4000

# 永久生效（写入 /etc/sysctl.conf）
echo "net.core.netdev_budget = 500" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

#### A.2 NAPI weight 与 netdev_budget 的区别

**关键概念**：

| 参数 | 作用 | 默认值 | 修改方式 |
|------|-----|-------|---------|
| **napi->weight** | 单个 NAPI 实例单次 poll() 的最大数据包数 | 64 | 驱动层设定，需重新编译 |
| **netdev_budget** | 单次软中断的总数据包配额（所有 NAPI 实例共享） | 300 | sysctl 随时调整 |

**两者关系示例**：

```bash
# 假设 PF 有 4 个 NAPI 实例，weight 都是 64
# 单次软中断最多处理：min(4 * 64, 300) = 300 个数据包

# 如果增大 netdev_budget 到 500
sudo sysctl -w net.core.netdev_budget=500
# 单次软中断最多处理：min(4 * 64, 500) = 256 个数据包
# （每个 NAPI 实例最多处理 64 个，4 轮后共 256 个）
```

**重要结论**：
- **调整 `netdev_budget` 不会修改 `napi->weight`**
- `netdev_budget` 决定软中断能运行多少轮
- `napi->weight` 决定每轮处理多少个包

#### A.3 如何调整 NAPI weight

**方法 1：修改驱动源码（需重新编译）**

```bash
# 1. 获取驱动源码
git clone <kernel-source>
cd drivers/net/ethernet/intel/ixgbe/

# 2. 修改 NAPI 注册代码
vim ixgbe_main.c
# Linux 6.6 的 ixgbe/ixgbevf 当前使用 netif_napi_add()
# 默认 weight 来自 include/linux/netdevice.h 中的 NAPI_POLL_WEIGHT=64
# 若要自定义该驱动的 weight，可将对应调用改为 netif_napi_add_weight(..., ixgbe_poll, 128)

# 3. 重新编译驱动
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules

# 4. 加载新驱动
sudo rmmod ixgbe
sudo insmod ixgbe.ko
```

**方法 2：修改内核默认值（需重新编译内核）**

```bash
# 修改内核头文件
vim include/linux/netdevice.h
# 找到 #define NAPI_POLL_WEIGHT 64
# 改为 #define NAPI_POLL_WEIGHT 128

# 重新编译内核
make -j$(nproc)
make modules_install
make install
```

**方法 3：观察当前 weight 值**

```bash
# 虽然不能运行时修改，但可以通过追踪观察当前值
sudo bpftrace -e '
kprobe:__napi_poll {
  $napi = (struct napi_struct *)arg0;
  printf("NAPI weight: %d\n", $napi->weight);
}
' | head -20
```

#### A.4 调整建议

**场景 1：IPvlan 多容器高负载，time_squeeze 频繁**

```bash
# 方案 1：增大 netdev_budget（推荐）
sudo sysctl -w net.core.netdev_budget=600
# 效果：允许单次软中断处理更多数据包，减少 time_squeeze

# 方案 2：增大 time_budget
sudo sysctl -w net.core.netdev_budget_usecs=4000
# 效果：允许软中断运行更长时间

# 验证效果
watch -n 1 'cat /proc/net/softnet_stat | awk "{print \$3}"'
```

**场景 2：低延迟要求**

```bash
# 减小 netdev_budget
sudo sysctl -w net.core.netdev_budget=150
# 效果：减少单次软中断的处理时间，降低延迟
```

**场景 3：VF 直通模式性能优化**

```bash
# VF 已经有独立的 NAPI 实例，通常不需要调整
# 如果仍需优化，可以调整 VF 的中断合并参数
ethtool -C eth1 rx-usecs 10  # 减少中断合并延迟
```

### B. 故障排查

**问题 1**：time_squeeze 一直为 0
- **原因**：网络负载太低，budget 从未耗尽
- **解决**：增加负载或降低 netdev_budget

**问题 2**：无法查看 VF 的队列
- **原因**：VF 可能未正确配置或驱动未加载
- **解决**：检查 `lspci | grep Virtual` 和 `dmesg | grep -i sriov`

**问题 3**：eBPF 工具报错
- **原因**：内核版本过低或未启用 BPF
- **解决**：升级内核（≥4.9）或检查 `CONFIG_BPF=y`

### C. 参考资料

- Linux 内核文档：`Documentation/networking/scaling.txt`
- NAPI 源码：`net/core/dev.c`
- softnet_stat 当前列定义：`net/core/net-procfs.c:softnet_seq_show()`（Linux 6.6 可见 `net-procfs.c:177` 的 `seq_printf()` 字段顺序）
- softnet_stat 历史说明：https://www.kernel.org/doc/Documentation/networking/proc_net_softnet_stat.txt

---

**文档版本**：v1.0  
**创建日期**：2026-06-24  
**适用内核**：Linux 4.9+（推荐 5.x 或 6.x）
