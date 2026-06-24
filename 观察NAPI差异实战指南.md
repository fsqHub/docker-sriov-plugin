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
# 列 4: cpu_collision   - CPU 冲突次数
# 列 5: received_rps    - RPS 接收的数据包数
```

**实时监控 time_squeeze**：
```bash
# 持续监控（每秒刷新）
watch -n 1 'cat /proc/net/softnet_stat'

# 或者计算增量
while true; do
  echo "=== $(date) ==="
  awk '{print "CPU", NR-1, "time_squeeze:", "0x" $3}' /proc/net/softnet_stat | \
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

---

## 三、使用 eBPF 追踪 NAPI 处理

### 3.1 使用 bpftrace 追踪 napi_poll

**安装**：
```bash
# Ubuntu/Debian
sudo apt install bpftrace

# CentOS/RHEL
sudo yum install bpftrace
```

**追踪 NAPI poll 调用**：
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

**追踪 __napi_poll 的 budget 参数**：
```bash
# 追踪每次 poll 分配的 budget 值
sudo bpftrace -e '
kprobe:__napi_poll {
  $napi = (struct napi_struct *)arg0;
  $weight = $napi->weight;
  @budget_hist = hist($weight);
  @budget_avg = avg($weight);
}

interval:s:10 {
  print(@budget_hist);
  print(@budget_avg);
}
'
```

**追踪 net_rx_action 中的 budget 消耗**：
```bash
# 追踪全局 netdev_budget 的消耗情况
sudo bpftrace -e '
kprobe:net_rx_action {
  @start_time[tid] = nsecs;
}

kretprobe:net_rx_action {
  $elapsed = (nsecs - @start_time[tid]) / 1000;  // 微秒
  @duration_hist = hist($elapsed);
  delete(@start_time[tid]);
}
'
```

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

## 七、高级分析：内核追踪

### 7.1 使用 ftrace 追踪 NAPI 函数

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

### 7.2 使用 perf 分析软中断热点

```bash
# 采集 10 秒的软中断事件
sudo perf record -e 'irq:softirq_entry' -a -g sleep 10

# 查看报告
sudo perf report

# 查看调用栈（找到 net_rx_action）
sudo perf script
```

---

## 八、总结对比表

| 验证项 | IPvlan 模式 | VF 直通模式 | 验证命令 |
|-------|-----------|-----------|---------|
| **中断号** | 只有 PF 的中断 | 每个 VF 有独立中断 | `cat /proc/interrupts` |
| **NAPI 实例** | 无独立 NAPI（复用 PF） | 每个 VF 有独立 NAPI | `ls /sys/class/net/*/queues/` |
| **time_squeeze** | 某个 CPU 快速增长 | 各 CPU 缓慢增长且分散 | `cat /proc/net/softnet_stat` |
| **中断亲和性** | 共享 PF 的 CPU 绑定 | 各 VF 绑定到不同 CPU | `cat /proc/irq/*/smp_affinity_list` |
| **softirq 分布** | 集中在某个 CPU | 分散在多个 CPU | `cat /proc/softirqs \| grep NET_RX` |
| **设备类型** | DEVTYPE=ipvlan | DRIVER=ixgbevf | `cat /sys/class/net/*/uevent` |

---

## 九、实战案例：完整验证流程

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

```bash
# 查看当前 netdev_budget
sysctl net.core.netdev_budget
# 默认：300

# 查看 netdev_budget_usecs（软中断时间配额）
sysctl net.core.netdev_budget_usecs
# 默认：2000（微秒）

# 临时调整（测试用）
sudo sysctl -w net.core.netdev_budget=500
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
- softnet_stat 说明：https://www.kernel.org/doc/Documentation/networking/proc_net_softnet_stat.txt

---

**文档版本**：v1.0  
**创建日期**：2026-06-24  
**适用内核**：Linux 4.9+（推荐 5.x 或 6.x）
