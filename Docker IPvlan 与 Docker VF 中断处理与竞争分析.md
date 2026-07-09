# Docker IPvlan 与 Docker VF 中断处理与竞争分析

## 文档目的

本文基于以下源码与现有仓库文档，分析 `Docker ipvlan` 与 `docker-sriov-plugin` 提供的 `VF` 模式在**中断处理**、`NAPI` 执行位置、`net_rx_action` 预算竞争，以及特定队列/绑核配置下的竞争形态差异。

分析依据主要包括：

- 内核源码：`/home/fsq/Desktop/kernel-src/linux-6.6.0-132.0.0.111.oe2403sp3.aarch64`
- 插件源码：`/home/fsq/Desktop/fsq/docker-sriov-plugin`
- 重点参考文件：
  - `driver/sriov.go`
  - `driver/driver.go`
  - `drivers/net/ipvlan/ipvlan_main.c`
  - `drivers/net/ipvlan/ipvlan_core.c`
  - `net/core/dev.c`

## 先说结论

1. `ipvlan` 子接口**没有独立硬中断**，也**没有独立 NAPI**。真正收包的是父设备 `PF`，真正触发中断的是 `PF` 队列，真正执行 `napi_poll()` 的也是 `PF` 的 NAPI。
2. `docker-sriov-plugin` 这里的 `VF` 模式，不是虚拟机场景里的 `VFIO/PCI passthrough`，而是把一个 **VF netdev** 分配给容器所在 `netns`。因此，IRQ/NAPI 仍由**宿主机内核**调度，但中断源、队列和 NAPI 实例属于该 `VF`，而不是共享 `PF`。
3. `ipvlan` 的竞争先发生在 **PF 硬件队列 + PF IRQ + PF NAPI + PF 所在 CPU 的 softirq budget** 上，之后才做软件分流。
4. `VF` 的竞争更靠后、更局部：先由硬件把流量分到不同 `VF` 的队列，再由各自 `VF` 的 IRQ/NAPI 处理；但如果多个 `VF` 的 IRQ 仍绑到同一批 CPU，上层依然会在 **同一组 CPU 的 `NET_RX softirq` 上竞争**。

## 一、`docker-sriov-plugin` 的 `VF` 实际语义

先把前提讲清楚，不然后面的竞争分析会直接跑偏。

在 `driver/sriov.go` 中，插件创建 endpoint 时会调用 `sriovnet.AllocateVf()` 或 `AllocateVfByMacAddress()` 分配一个 `VF`，然后把 `GetVfNetdevName()` 返回的设备名保存为 `endpoint.devName`。随后在 `driver/driver.go` 的 `Join()` 中，把这个 `SrcName` 返回给 Docker/libnetwork，后者把这个 `VF netdev` 放进容器 sandbox。

这意味着：

- 容器拿到的是一个**真实的 VF netdev**
- 它不再经过 `ipvlan`/`veth` 这种软件子接口做 RX 分流
- 但它也**不是**“容器拥有独立客体内核”的 VM passthrough
- 中断、NAPI、`NET_RX softirq` 仍由宿主机内核执行

因此，准确表述应该是：

> `docker-sriov-plugin` 给容器分配了独立 `VF netdev`、独立 `VF` 队列和独立 `VF` 中断源；但这些中断和 `NAPI` 仍发生在宿主机内核里。

## 二、`ipvlan` 的中断处理路径

### 2.1 关键源码点

`ipvlan` 创建 port 时，会在父设备上注册 `rx_handler`：

- `drivers/net/ipvlan/ipvlan_main.c`
- `netdev_rx_handler_register(dev, ipvlan_handle_frame, port)`

这说明 `ipvlan` 的接收路径不是“子接口自己收到中断”，而是：

1. `PF` 先收包
2. `PF` 驱动先做 `IRQ -> napi_schedule`
3. `PF` 的 `napi_poll()` 把 `skb` 推进协议栈
4. 在 `__netif_receive_skb_core()` 中，发现父设备挂了 `rx_handler`
5. 调用 `ipvlan_handle_frame()`
6. 再把包按地址查找结果交给对应 `ipvlan` 子接口

### 2.2 路径图

```text
外部流量
  -> PF 硬件 RX queue
  -> PF MSI-X/IRQ
  -> PF 驱动 ISR
  -> napi_schedule()
  -> net_rx_action()
  -> PF napi_poll()
  -> __netif_receive_skb_core()
  -> ipvlan_handle_frame()
  -> ipvlan_rcv_frame()
  -> skb->dev 改成 ipvlan 子接口
  -> 容器 netns 协议栈
  -> socket
```

### 2.3 这里真正共享了什么

在 `ipvlan` 场景里，多个容器共享的不只是父设备名义上的带宽，而是以下几层都共享：

1. **PF 硬件 RX queue 池**
2. **PF 的 IRQ 向量**
3. **PF 的 NAPI 实例**
4. **触发这些 NAPI 的 CPU 上的 `softnet_data`**
5. **该 CPU 当前这轮 `net_rx_action()` 的 `budget` 与 `time_limit`**

Linux 6.6 中 `net_rx_action()` 会读取：

- `netdev_budget`
- `netdev_budget_usecs`

然后在当前 CPU 的 `softnet_data.poll_list` 上轮询各 `NAPI`。如果 `budget <= 0` 或达到时间上限，就会结束本轮处理并递增 `time_squeeze`。

因此，在 `ipvlan` 场景里，竞争首先不是“容器 A 和容器 B 的 socket 竞争”，而是：

> 容器 A、B、C 的流量先在同一个 `PF` 队列集合、同一个 `PF NAPI` 集合、同一个 CPU 的 `NET_RX softirq` 预算里竞争。

## 三、`VF` 的中断处理路径

### 3.1 关键源码点

本仓库的 `VF` 分配逻辑见：

- `driver/sriov.go`
- `driver/driver.go`

VF 驱动的典型中断模型，可从内核中典型 `VF` 驱动实现看到：

1. `pci_alloc_irq_vectors(..., PCI_IRQ_MSIX)`
2. `request_irq(...)`
3. 中断处理函数内 `napi_schedule_irqoff(...)`
4. 后续由 `net_rx_action()` 调用该 `VF` 的 `napi_poll()`

### 3.2 路径图

```text
外部流量
  -> NIC 按 VF / RSS 规则命中对应 VF RX queue
  -> 该 VF 的 MSI-X/IRQ
  -> VF 驱动 ISR
  -> napi_schedule_irqoff()
  -> net_rx_action()
  -> VF napi_poll()
  -> netif_receive_skb() / napi_gro_receive()
  -> 容器 netns 协议栈
  -> socket
```

### 3.3 `VF` 隔离了什么，没有隔离什么

`VF` 相比 `ipvlan`，前移了隔离边界：

- **已隔离**
  - 硬件 RX/TX queue
  - IRQ 来源
  - NAPI 实例
  - `skb` 不需要经过 `ipvlan rx_handler` 软件分流

- **未完全隔离**
  - 仍共享宿主机 CPU
  - 仍共享宿主机 `NET_RX softirq` 机制
  - 如果 IRQ affinity 重叠，仍共享同一批 `softnet_data`
  - 多个 `VF` 仍共享同一块 NIC ASIC、物理口与上行带宽

所以 `VF` 更准确的结论是：

> 它让竞争从“共享 PF 大池 + 软件分流”收缩成“每个 VF 自己的小池 + 可能重叠的 CPU softirq 竞争”。

## 四、两者在中断处理上的直接差异

| 维度 | `docker ipvlan` | `docker VF` |
| --- | --- | --- |
| 中断源 | `PF` 的 IRQ | 各 `VF` 的 IRQ |
| NAPI 实例 | `PF` 的 NAPI | 各 `VF` 自己的 NAPI |
| 硬件队列 | 容器共享 `PF` 队列池 | 每个 `VF` 拥有独立队列池 |
| 软件分流 | 需要 `ipvlan_handle_frame()` | 不需要 |
| 容器间争用 | 先在 `PF queue/IRQ/NAPI` 层争用 | 主要在共享 CPU/softirq 层争用 |
| 单容器最大并行度 | 取决于 `PF` 给到的整体队列池 | 受该 `VF` 队列数上限约束 |

## 五、举例说明：普通高负载场景

### 5.1 两个 `ipvlan` 容器同时打满

假设容器 A 与容器 B 都使用同一个 `PF` 的 `ipvlan` 网络，外部各自打入高 PPS 流量。

这时发生的是：

1. 两者的流量先一起进入 `PF` 的 RSS 队列池
2. `PF` 对应的若干 IRQ 被触发
3. 这些 IRQ 所在 CPU 执行 `PF napi_poll()`
4. `skb` 进入协议栈后才由 `ipvlan_handle_frame()` 决定分给 A 还是 B

结论：

- A 的流量高，会先占用 `PF queue`、`PF NAPI`、`PF CPU` 的预算
- B 会在 A 消耗掉部分 `budget/time_limit` 之后才得到处理机会
- 这类抖动会表现为某些 CPU 上 `time_squeeze` 快速增加，且两个容器常一起受影响

### 5.2 两个 `VF` 容器同时打满

假设容器 A 使用 `VF0`，容器 B 使用 `VF1`。

这时发生的是：

1. A 的流量先命中 `VF0` 的队列
2. B 的流量先命中 `VF1` 的队列
3. `VF0`、`VF1` 各自触发自己的 IRQ
4. 各自的 `NAPI` 独立进入 `poll_list`

如果 `VF0` 和 `VF1` 的 IRQ 绑在**不同 CPU**：

- 两者各自消耗对应 CPU 的 `net_rx_action()` 预算
- 干扰显著减小

如果 `VF0` 和 `VF1` 的 IRQ 绑在**同一批 CPU**：

- 仍会争用那几个 CPU 的 softirq 预算
- 但不再需要共享 `PF queue` 和 `ipvlan rx_handler` 分流层

在你后续给定的 `320` 核 / `40` 容器拓扑里，实际更接近“每个 `VF` 主要绑在自己容器所在 cluster 的第 `2` 个核”，因此更典型的问题不是多个 `VF` 互相抢同一批核，而是**单个 `VF` 的多个队列在本地单核上自我竞争**。下面第六节按这个修正后的前提展开。

## 六、重点场景分析：`320` 核、`40` 个容器、`PF 63` 队列 vs 每 `VF 9` 队列

下面按你修正后的前提重新分析。

### 6.1 场景假设

机器与部署方式如下：

1. 总共 `320` 个核
2. 每 `8` 个核为一个 `cluster`
3. 因此共有：

```text
320 / 8 = 40 个 cluster
```

4. 启动 `40` 个容器，每个容器独占一个 `cluster` 的前两个核
5. 对于第 `i` 个容器，可近似表示为：

```text
容器 i 使用 cluster i 的 CPU(8i) 和 CPU(8i+1)
```

6. 其中 `CPU(8i+1)` 是该 `cluster` 的第 `2` 个核，也是你用于网卡 IRQ / `NET_RX softirq` 的服务核

于是，系统里一共有 `40` 个“容器对应的服务核”：

```text
CPU 1, 9, 17, 25, ..., 313
```

在此基础上：

- `ipvlan` 场景：
  - 所有容器共享同一个 `PF`
  - `PF` 队列数为 `63`
  - 这 `63` 个 `PF IRQ/NAPI` 绑定到上述 `40` 个服务核
- `VF` 场景：
  - 每个容器独占一个 `VF`
  - 每个 `VF` 队列数为 `9`
  - 每个 `VF` 的中断队列都绑定到**对应容器所在 cluster 的第 `2` 个核**

下面默认把“`VF 队列数为 9`”理解为 `9` 个会对应中断和 `NAPI` 的 `RX/combined queue`。如果你的网卡驱动把 `9` 解释成别的资源单位，结论方向不变，但细节数值需要按驱动实现再校正。

### 6.2 `ipvlan`：共享 `PF` 队列池，但服务核扩展到 `40` 个

这次和我上个版本最关键的区别是：  
不是“少数几个 cluster 服务核承接所有流量”，而是**40 个容器对应 40 个服务核一起承接 PF 流量**。

#### 1）队列与 CPU 的静态映射

`PF` 有 `63` 个队列，绑定到 `40` 个服务核，平均大约是：

```text
63 / 40 = 1.575
```

也就是：

- 大约 `23` 个服务核各承接 `2` 个 `PF queue`
- 大约 `17` 个服务核各承接 `1` 个 `PF queue`

从“每核挂几个 IRQ/NAPI”这个角度看，`ipvlan` 现在并不算重。

#### 2）真正的问题不是“每核几个队列”，而是“队列属于谁”

`PF` 的 `63` 个队列属于**整个 PF 的共享大池**，不是某个容器独占。

因此：

- 容器 A 的流量可以命中 `CPU 1` 上的 `PF queue`
- 也可以命中 `CPU 57` 上的 `PF queue`
- 还可以命中其他任意服务核上的 `PF queue`

换句话说，**队列与 CPU 是按 PF 维度绑定的，不是按容器维度绑定的**。

所以 `ipvlan` 虽然把 `63` 个队列分散到了 `40` 个服务核，但这些服务核处理的是：

- 多个容器的混合流量
- 多个容器共享的 `PF NAPI`
- 收包后还要经过 `ipvlan_handle_frame()` 软件分流

#### 3）容器之间会如何竞争

在这个场景里，`ipvlan` 的竞争不是“每个容器有自己的服务核”，而是：

> 每个容器都可能借用其他容器所在 cluster 的第 2 个核来处理自己的网络流量，同时也可能被其他容器借走自己的第 2 个核。

这会产生三类竞争：

1. **共享 PF 队列竞争**
   - 所有容器共用 `63` 个 `PF queue`
2. **共享服务核竞争**
   - 某个服务核上跑的 `PF NAPI` 可能同时服务多个容器
3. **共享软件分流竞争**
   - 该服务核上的 `PF napi_poll()` 拉包后，还要执行 `ipvlan_handle_frame()` 做分流

#### 4）`ipvlan` 的一个隐藏副作用：跨 cluster 的网络 CPU 借用

因为 `PF RSS` 不知道“容器属于哪个 cluster”，所以容器 A 的包很可能在容器 B 的服务核上完成 `IRQ -> NAPI -> socket 入队`。

这意味着：

- 网络处理 CPU 和应用线程 CPU 可能不在同一个 cluster
- 会出现跨 cluster 的 cache/唤醒/队列交接
- 容器 A 的热点流量会侵占其他容器的服务核

这在多实例线性度问题里很重要，因为它会把“一个热点容器的网络压力”扩散成“多个 cluster 的服务核都在替它干活”。

### 6.3 `VF`：每个容器 1 个 `VF`，每个 `VF` 的 `9` 个队列只绑本容器的第 `2` 个核

这个前提和上个版本完全不同。  
这里不是“所有 VF 共享同一批服务核”，而是：

> 每个容器的 `VF IRQ/NAPI` 只落在自己 cluster 的第 `2` 个核上。

也就是说，服务核与容器是一对一关系。

#### 1）`VF` 的静态映射

对于容器 `i`：

- 它有一个自己的 `VF_i`
- `VF_i` 有 `9` 个队列
- 这 `9` 个队列的 IRQ 都绑到 `CPU(8i+1)`

因此整个系统里会有：

```text
40 个 VF * 9 个队列 = 360 个 VF 队列
```

但这 `360` 个队列不是在 `40` 个服务核上混着跑，而是：

- 每个服务核只处理自己那个容器对应的 `9` 个 `VF queue`
- 不处理其他容器的 `VF queue`

#### 2）跨容器竞争大幅下降

这意味着 `VF` 模式下，至少在 CPU/softirq 这一层：

- 容器 A 的网络软中断只打在 `CPU(8A+1)`
- 不会跑到容器 B 的服务核上
- 容器 B 的网络软中断也不会反过来侵占容器 A 的服务核

所以和 `ipvlan` 相比，`VF` 的**跨容器 CPU 竞争**显著下降。

更准确地说：

> `VF` 把“跨容器争抢服务核”的问题，收缩成了“每个容器在自己的第 2 个核上自我竞争”。

#### 3）但 `VF` 会出现新的瓶颈：`9` 个队列压到 1 个核

你当前的绑核方式把每个 `VF` 的 `9` 个队列都绑到同一个核。  
这带来一个很重要的后果：

- 虽然有 `9` 个队列
- 但它们并没有转化成 `9` 个 CPU 并行处理点
- 它们最终都要在同一个 `CPU(8i+1)` 的 `softnet_data.poll_list` 上竞争

这会形成**单容器内的自我竞争**：

1. `9` 个 `VF NAPI` 都属于同一个容器
2. 都在同一个服务核上执行
3. 都共享这一核本轮 `net_rx_action()` 的 `budget/time_limit`

如果 `9` 个队列都同时有较高流量，这一核会很快成为瓶颈。

#### 4）为什么说这会成为硬瓶颈

Linux 6.6 默认：

- `netdev_budget = 300`
- `NAPI_POLL_WEIGHT = 64`

如果一个 `VF` 的 `9` 个队列都很活跃，那么同一轮 `net_rx_action()` 中，这 `9` 个 `NAPI` 的理论总 work 很容易超过一轮预算。

粗略地看：

```text
9 * 64 = 576 > 300
```

这不表示每轮一定真的跑满 `576`，但它说明：

- 当 `9` 个队列都活跃时
- 单个服务核的一轮 `NET_RX softirq` 很容易触发 `budget` 或 `time_limit` 约束
- `time_squeeze` 更可能在这个容器自己的第 `2` 个核上增长

所以 `VF` 在你这套绑核方式下的核心问题变成了：

> 它不是“容器之间互相抢第 2 个核”，而是“每个容器把自己的 9 个网络队列都压在自己的第 2 个核上，自身先撞上单核 softirq 上限”。

## 七、两种模式在这套拓扑下的竞争差异

### 7.1 `ipvlan`：跨容器共享，单容器可借用更多服务核

在 `ipvlan` 下：

- `PF 63` 队列跨 `40` 个服务核分布
- 单个容器的流量可以落到多个服务核
- 单个容器实际上可以“借用”其他容器的第 `2` 个核来获得更多网络处理能力

这有两个后果：

1. **单容器上限可能更高**
   - 因为它不只受自己 cluster 第 `2` 个核限制
   - 多流场景下，PF 的 RSS 可能把它的流打散到多个服务核
2. **多容器线性度更差**
   - 因为它借到的每一个服务核，本质上都是在侵占别的容器的网络 CPU

### 7.2 `VF`：跨容器隔离更强，但单容器被锁死在自己的服务核

在 `VF` 下：

- 每个容器的网络处理 CPU 几乎固定为自己的第 `2` 个核
- 容器 A 不能借用容器 B 的服务核
- 容器 B 也不会被容器 A 借走服务核

这同样有两个后果：

1. **多容器线性度更好**
   - 容器之间的 CPU 干扰显著下降
2. **单容器上限可能更早到顶**
   - 因为 `9` 个队列都压在自己这一个服务核上
   - 它不能像 `ipvlan` 那样靠 PF 队列池向外借 CPU

## 八、具体例子

### 8.1 例子一：一个热点容器，其他 39 个容器低负载

#### `ipvlan`

热点容器 H 打开大量连接和高 PPS 流量时：

- `PF RSS` 会把 H 的流量散到多个 `PF queue`
- 这些 `PF queue` 又分布在多个 cluster 的第 `2` 个核上

于是 H 不只吃掉自己 cluster 的服务核，还会吃掉其他容器的服务核。

表现通常是：

- 多个 cluster 的第 `2` 个核中断和 `NET_RX softirq` 都升高
- 低负载容器也会被牵连
- 某些并不热的容器会因为自己的第 `2` 个核被 H 借走而抖动

#### `VF`

热点容器 H 只有自己的 `VF_H`，且 `VF_H` 的 `9` 个队列都绑到 `CPU(8H+1)`。

结果是：

- H 基本只能把自己的第 `2` 个核打满
- 其他 39 个容器的第 `2` 个核不会被 H 抢走

表现通常是：

- H 的 `CPU(8H+1)` 上 `softirq`、`time_squeeze` 明显升高
- 其他容器相对稳定

这说明：  
`ipvlan` 更容易把热点扩散成全局干扰，`VF` 更容易把热点限制在局部。

### 8.2 例子二：40 个容器都均匀高负载

#### `ipvlan`

所有容器共用 `63` 个 `PF queue` 和 `40` 个服务核。

此时每个服务核虽然只挂 `1-2` 个 `PF queue`，但这些队列中的流量来自多个容器。  
结果是：

- 每个服务核都在跑“混合流量”
- 某个服务核一旦偏热，会同时影响多个容器
- 容器之间的线性度容易受队列分布和流量哈希偏斜影响

#### `VF`

每个容器的 `9` 个队列都只打自己的第 `2` 个核。

此时每个容器都形成了一个比较清晰的二核小岛：

- 第 `1` 个核和第 `2` 个核属于该容器
- 第 `2` 个核主要承担该容器的网络服务

这时线性度往往更容易做稳，因为：

- 容器 A 的网络软中断不会跑去容器 B 的服务核
- 干扰更接近“本容器内自我饱和”，而不是“容器之间相互拖累”

### 8.3 例子三：只看单容器峰值能力

这个例子最容易被误判。

#### `ipvlan`

虽然 `ipvlan` 是共享模式，但在你这套绑核下：

- 单个容器的流量可能借用多个 `PF queue`
- 这些 `PF queue` 又可能分布到多个服务核

所以单个热点容器有机会得到超过“一个第 `2` 个核”的网络处理能力。

#### `VF`

虽然每个容器有 `9` 个队列，但它们都绑到自己一个第 `2` 个核。  
这意味着：

- 队列变多了
- 但 CPU 并行度没有变多

所以在这种绑核策略下，**单容器极限峰值未必是 VF 更高**。  
很可能出现的情况是：

- `ipvlan` 单容器峰值更高
- `VF` 单容器更早撞上自己第 `2` 个核的 softirq 上限

但这不是因为 `VF` 硬件更差，而是因为：

> 你把 `VF` 的 9 个队列都收束到同一个服务核上，主动放弃了多核并行处理能力。

## 九、还要补看的一层：容器第 `2` 个核是否还跑应用线程

这里有个非常关键但容易被忽略的变量：

> 容器虽然“占据前两个核”，但如果应用线程也会运行在第 `2` 个核上，那么第 `2` 个核并不是真正专用于 IRQ/softirq。

这时两种模式都会出现**本地 CPU 竞争**：

- 用户态业务线程
- `NET_RX softirq`
- `ksoftirqd/N`

都可能在同一个第 `2` 个核上抢时间。

但两者影响仍不同：

- `ipvlan`：第 `2` 个核上可能还在替别的容器处理 `PF` 流量
- `VF`：第 `2` 个核主要只在替本容器处理 `VF` 流量

因此，如果你的目标是稳定比较 `ipvlan` 与 `VF` 的线性度，最好再区分两种子场景：

1. **第 `2` 个核允许容器业务线程运行**
2. **第 `2` 个核只留给 IRQ/softirq，不跑容器业务线程**

第二种方式更能看清纯网络侧的差异。

## 十、`ipvlan` 缓解方案

下面给的是一份面向你当前拓扑的 `ipvlan` 缓解方案。  
它不依赖“测试环境就在本机”，重点是思路、实施顺序和验证方法。

### 10.1 目标先拆开

你这里的 `ipvlan` 问题其实有两个层次：

1. **全局共享竞争**
   - `40` 个容器共享同一个 `PF`
   - 热点容器会借用其他容器 cluster 的第 `2` 个核
2. **局部软中断压力**
   - 某些 `PF queue` 命中偏热
   - 某些服务核上的 `time_squeeze` 会先升高

所以缓解手段也要分优先级：

1. 先减少共享域
2. 再增强流量局部性
3. 再限制 noisy neighbor
4. 最后再调 `NAPI` / `softirq` 参数

顺序不能反。  
如果一开始就只调 `netdev_budget`，通常只是拖延瓶颈暴露时间，不会改变共享竞争本质。

### 10.2 方案一：缩小共享域

这是最有效的手段。

#### 做法

- 不要让 `40` 个容器全部挂同一个 `PF`
- 如果机器上有多个 `PF` / 多个物理 port，把容器拆组
- 例如：
  - `40` 个容器拆成 `4` 组
  - 每组 `10` 个容器
  - 每组绑定一个 `PF`

#### 为什么有效

`ipvlan` 的主要问题不是“每核挂了几个 `PF queue`”，而是**这些 queue 是全局共享的**。  
只要还是一个 `PF`，热点容器就有机会把自己的流量扩散到其他容器所在 cluster 的服务核上。

多 `PF` 分片后：

- 每个容器只和同组容器共享队列池
- 热点实例最多污染本组
- 干扰范围从 `40` 容器收缩到某个子集

#### 适用判断

如果你的硬件上有多个 `PF`，这一步优先级最高。  
没有多个 `PF` 时，后面的所有优化都只能算“尽量减轻共享”，不能从根上拆开共享域。

### 10.3 方案二：增强流量局部性，减少跨 cluster 借核

这是第二优先级。

#### 目标

让某个容器的流量尽量稳定落在少量固定 `PF queue` 上，而不是被 `PF RSS` 随机打散到很多 cluster 的第 `2` 个核上。

#### 可做手段

- 调整 `PF` 的 RSS indirection table
- 调整 RSS hash key / hash 字段
- 如果驱动支持，使用 ntuple / flow steering / flow director
- 对固定业务流，尽量让一类流命中固定 queue 集合

#### 预期收益

- 热点容器不再轻易借走大量其他 cluster 的服务核
- cache locality 更稳定
- 抖动范围更容易收敛到少数 queue 和少数服务核

#### 限制

`ipvlan` 做不到像 `VF` 那样“按容器硬件隔离 queue”。  
这里能做的是“让分布更可预测、更局部”，而不是“完全按容器切开”。

### 10.4 方案三：重新设计 IRQ 绑核策略

你当前的 `ipvlan` 绑法是：

- `PF 63` 个队列
- 全部分布到 `40` 个 cluster 的第 `2` 个核

这会带来一个副作用：

> 容器自己的第 `2` 个核，不仅要承接本容器网络流量，还可能在替别的容器处理 `PF` 流量。

#### 更稳的两种替代思路

**思路 A：专用网络核池**

- 从整机中抽出一批专门承接 `PF IRQ/softirq` 的 CPU
- 不把容器自己的第 `2` 个核当成全局 `PF` 服务核

效果：

- 避免容器之间互相借用第 `2` 个核
- 网络侧竞争更集中，更容易观测和限制

代价：

- 网络处理与应用线程的 locality 可能变差

**思路 B：按组绑定服务核**

- 不把 `63` 个 queue 全铺到 `40` 个容器的第 `2` 个核
- 而是按容器分组，只让一组容器共享一组服务核

效果：

- 比“全局共享 40 个服务核”更容易控制干扰范围
- 又比“全部收敛到少量专用核”更保留一些局部性

#### 不建议的做法

- 在不做分组的前提下，把所有容器第 `2` 个核都作为 `PF` 服务核

这会让热点容器天然拥有“向全局借核”的能力，对多实例线性度不友好。

### 10.5 方案四：把 noisy neighbor 先控住

`ipvlan` 共享场景里，热点实例不受控时，所有后续优化效果都会被抵消。

#### 可做手段

- 用 `tc` 做 ingress/egress shaping
- 按容器 IP / 子网做速率限制
- 对高 PPS 实例和普通实例做分组部署
- 把极端热点实例单独放到专属 `PF` 或更小共享域

#### 为什么重要

`ipvlan` 下最危险的不是“所有容器都差不多忙”，而是：

- 少数热点容器借用全局 `PF queue`
- 再借用全局服务核
- 把多个 cluster 的第 `2` 个核一起拖热

限速或隔离热点实例，本质上是在防止共享池被单点打穿。

### 10.6 方案五：调 `softirq` / `NAPI` 预算

这一层是调优，不是根治。

#### 可调参数

- `net.core.netdev_budget`
- `net.core.netdev_budget_usecs`
- 必要时 `net.core.netdev_max_backlog`

#### 适用场景

如果你已经确认：

- 共享域短期内没法拆
- RSS / IRQ 策略也已经尽量做了局部化
- 当前瓶颈表现为服务核上的 `time_squeeze` 快速增长

这时可以试着提高单轮 `net_rx_action()` 的处理能力。

#### 风险

- softirq 单轮运行更久
- 可能挤压用户态线程
- 某些情况下会把尾延迟拉长

因此这一步只能在前几步之后做，而且必须和 `softnet_stat`、`/proc/softirqs`、应用延迟一起看。

### 10.7 方案六：谨慎使用 RPS / XPS

#### RPS

如果硬件 RSS 不够理想，RPS 可以把协议栈处理继续分散到别的 CPU。  
但在你这个拓扑里，RPS 有明显副作用：

- 会进一步扩大“跨 cluster 借核”
- 可能让本来局部的流量处理扩散到更多 CPU

因此：

- 追求极限吞吐时，RPS 可以试
- 追求线性度和容器隔离时，RPS 要非常克制

#### XPS

XPS 更偏发送路径，可以改善发送时 CPU 到 TX queue 的映射。  
如果业务的发送侧也存在明显 queue 偏热，XPS 值得配套检查；但它对你当前最核心的 `ipvlan RX` 共享竞争，不是第一优先级。

### 10.8 方案七：避免第 `2` 个核同时承担最热应用线程

如果容器自己的第 `2` 个核既在跑：

- `PF IRQ`
- `NET_RX softirq`
- 该容器最热的业务线程

那你看到的瓶颈就会混在一起，难以判断到底是网络竞争还是应用竞争。

#### 建议

- 尽量让第 `2` 个核偏向网络服务
- 最热应用线程尽量放到第 `1` 个核或本 cluster 的其他核
- 至少不要让“最热用户态线程”和“全局 PF 服务核职责”叠在一起

这一步不会改变 `ipvlan` 的共享本质，但会让现象更干净，也更容易验证优化是否有效。

### 10.9 推荐实施顺序

按收益和风险排序，建议这样推进：

1. **先拆共享域**
   - 多 `PF` / 多分片
2. **再做流量局部化**
   - RSS / flow steering
3. **再改 IRQ 绑核策略**
   - 专用网络核池或按组共享
4. **再控热点容器**
   - `tc` / 分组 / 单独安置
5. **最后调 softirq 预算**
   - `netdev_budget` / `netdev_budget_usecs`
6. **RPS/XPS 放在最后试验**

### 10.10 如何验证是否真的缓解了竞争

不要求测试环境就在本机，也应该按下面的判断标准验证。

#### 如果优化有效，`ipvlan` 应该出现这些变化

1. **跨 cluster 借核减少**
   - 热点容器不再把很多别的 cluster 第 `2` 个核一起带热
2. **服务核热度更局部**
   - `/proc/interrupts` 和 `NET_RX softirq` 更集中在预期 queue / CPU 上
3. **`time_squeeze` 增长速度下降**
   - 尤其是不再出现很多无关容器一起被带热
4. **低负载容器稳定性变好**
   - 热点实例出现时，其他容器延迟和吞吐不再明显塌陷

#### 如果优化无效，通常会看到

- 热点容器仍然能把全局许多服务核带热
- `PF queue` 的热度仍严重偏斜且不可预测
- `time_squeeze` 只是从一个核转移到另一个核
- 调大 `netdev_budget` 后应用线程反而更饿

## 十一、Redis 压测下的 `net_rx_action()` 与请求节奏分析

本节补充一个更贴近实测的问题：

> 一台物理机启动 `40` 个 Redis 实例，另一台物理机通过直连 `PF` 对这 `40` 个实例分别压测时，单次 `net_rx_action()` 可能处理发往哪几个 Redis 实例的数据包？`redis-benchmark` 是否必须等 `redis-server` 返回数据后才继续发送请求？如果部分时间段内单次 `net_rx_action()` 的 `budget_used` 较少但没有超时，可能是什么原因？

分析 Redis 源码基于：

- `/home/fsq/Desktop/fsq/redis`
- 当前源码提交：`ab199cb5c`
- 重点文件：`src/redis-benchmark.c`、`src/networking.c`、`src/server.c`

### 11.1 单次 `net_rx_action()` 可能处理哪些 Redis 实例的数据包

先给结论：

> 单次 `net_rx_action()` 不按 Redis 实例、进程或端口分配 budget。它只处理**当前 CPU 的 `softnet_data.poll_list` 中已经被调度的 NAPI 实例**。因此，这一轮可能处理发往一个 Redis 实例的数据包，也可能处理发往多个 Redis 实例的数据包。

在两台物理机通过直连 `PF` 压测时，典型路径是：

```text
压测机 redis-benchmark 连接
  -> 直连链路
  -> 被测机 PF RX queue
  -> PF IRQ
  -> 当前 CPU 的 NET_RX softirq
  -> net_rx_action()
  -> PF NAPI poll
  -> 协议栈
  -> 目标 Redis 实例 socket
```

如果 `40` 个 Redis 实例监听在同一 IP 的不同端口，例如：

```text
host_ip:6379
host_ip:6380
...
host_ip:6418
```

网卡 RSS 通常会按五元组做 hash：

```text
src_ip, src_port, dst_ip, dst_port, protocol
```

因此，不同 Redis 实例因为 `dst_port` 不同，连接通常会被分散到不同 RX queue；但这不是“一实例一队列”，而是 hash 映射，可能多个实例落到同一个 RX queue，也可能同一个实例的多个 benchmark 连接因为 `src_port` 不同而分散到多个 RX queue。

所以某次 `net_rx_action()` 的实例归属更接近下面这种关系：

```text
CPU X 本轮 net_rx_action()
  -> poll RX queue 3
       -> Redis 6379 的部分连接
       -> Redis 6386 的部分连接
  -> poll RX queue 8
       -> Redis 6381 的部分连接
       -> Redis 6410 的部分连接
```

能被同一次 `net_rx_action()` 处理到的 Redis 实例，主要由这些因素决定：

1. **RSS hash 结果**
   - 不同 Redis 端口、不同 benchmark 客户端源端口会改变 hash。
2. **PF RX queue 数量**
   - queue 少于活跃连接/实例时，多个 Redis 实例必然共享 queue。
3. **IRQ affinity**
   - 多个 RX queue 如果绑定到同一个 CPU，就会共享这个 CPU 的 `net_rx_action()`。
4. **本轮 `poll_list` 内容**
   - 只有当前 CPU 本轮已经被调度的 NAPI 会被处理。
5. **流量到达时序**
   - 即使两个 Redis 的连接 hash 到同一 CPU，如果到达时间错开，也不一定落在同一次 `net_rx_action()`。

因此，不能从“有 40 个 Redis 实例”直接推出“单次 `net_rx_action()` 会处理 40 个实例”。更严谨的判断方法是：

```text
Redis 实例端口 / benchmark 连接
  -> RSS hash / RX queue
  -> IRQ affinity
  -> CPU softirq
  -> 当前 CPU 本轮 poll_list
```

### 11.2 `redis-benchmark` 是否等待 Redis 返回后才继续发送请求

结论要分默认模式和 pipeline 模式：

> 默认 `-P 1` 时，`redis-benchmark` 的**单个 client** 基本是“发出 1 条请求，等收到 1 个 reply 后，再复用连接发送下一条请求”。但整个 benchmark 有多个并发 client，所以整体上仍然会持续有请求在飞。

> 如果使用 `-P N`，单个 client 会先连续发送 `N` 条 pipeline 请求，然后等待这 `N` 个 reply 都被消费完，再进入下一轮发送。

源码依据如下。

`redis-benchmark.c` 中 client 结构记录了 pending reply 数：

```c
int pending; /* Number of pending requests (replies to consume) */
```

创建 client 时，会按 `config.pipeline` 把同一条命令复制到输出 buffer 中：

```c
for (j = 0; j < config.pipeline; j++)
    c->obuf = sdscatlen(c->obuf,cmd,len);

c->pending = config.pipeline+c->prefix_pending;
```

写路径 `writeHandler()` 把 `obuf` 写完后，删除 `AE_WRITABLE`，改成等待 `AE_READABLE`：

```c
aeDeleteFileEvent(el,c->context->fd,AE_WRITABLE);
aeCreateFileEvent(el,c->context->fd,AE_READABLE,readHandler,c);
```

读路径 `readHandler()` 会持续消费 reply，每消费一个 benchmark reply 就：

```c
c->pending--;
if (c->pending == 0) {
    clientDone(c);
    break;
}
```

`clientDone()` 中如果 keepalive 开启，会 `resetClient(c)`，重新注册写事件：

```c
if (config.keepalive) {
    resetClient(c);
}
```

`resetClient()` 又把 pending 重置为 pipeline，并重新注册 `writeHandler`：

```c
aeCreateFileEvent(el,c->context->fd,AE_WRITABLE,writeHandler,c);
c->written = 0;
c->pending = config.pipeline;
```

这说明：

1. **单个 client 不会无限制连续发送**
   - 它最多保持 `config.pipeline` 个未完成请求。
2. **默认 `pipeline=1` 时，单个 client 是一问一答节奏**
   - 等一个 reply 被读到后才进入下一轮写。
3. **整体压测不是严格一问一答**
   - 默认 `config.numclients = 50`，多个 client 并发执行。
4. **提高 `-P` 会显著改变请求到达形态**
   - 从“小批次一问一答”变成“每连接批量灌入 N 条请求，再等 N 个回复”。

Redis server 侧也符合这个模型。`readQueryFromClient()` 从 socket 读入 query buffer 后调用 `processInputBuffer()`，后者循环解析并执行完整命令；命令执行产生 reply 后进入 client 输出缓冲区。server 在 `beforeSleep()` 中调用 `handleClientsWithPendingWritesUsingThreads()` / `handleClientsWithPendingWrites()` 把 pending reply 写回 socket。

所以，对压测流量节奏的关键影响是：

```text
redis-benchmark 单 client 的 pipeline 深度
  -> 同一连接上允许未完成的请求数
  -> 请求包到达 Redis server 的突发度
  -> Redis server 处理和回包节奏
  -> 下一轮请求是否继续发出
```

### 11.3 为什么 `budget_used` 较少但没有超时

如果观测到某些 3 秒窗口内：

```text
net_rx_action() 调用次数存在
budget_used 总数或单次分布偏小
time_exhausted 没有明显增加
```

这通常不表示异常。它更可能说明：

> 本轮 `net_rx_action()` 被调度了，但当前 CPU 上可处理的 RX work 本来就不多；它是正常处理完退出，而不是因为 `netdev_budget_usecs` 超时退出。

常见原因如下。

#### 原因一：`redis-benchmark` 默认请求节奏不是无限灌包

默认 `pipeline=1` 时，每个 benchmark client 收到 reply 后才进入下一轮发送。即使总共有多个并发 client，请求流量也会被 Redis server 的处理速度、回包速度、客户端读 reply 的速度共同节流。

这会导致内核看到的 RX 请求包不是持续满 ring，而是很多短 burst：

```text
client 发送请求
  -> Redis 处理
  -> Redis 回包
  -> benchmark 收到 reply
  -> client 再发下一条
```

如果 Redis 处理或回包路径成为节奏源，`net_rx_action()` 经常会被唤醒后只清理少量 RX 包，然后正常退出。

#### 原因二：当前 CPU 只负责部分 RX queue

`budget_used` 是当前 CPU 本轮 `net_rx_action()` 的统计，不是整机所有队列的总和。RSS 可能把 40 个 Redis 实例的连接分散到多个 RX queue 和多个 CPU。

因此某个 CPU 上看到低 `budget_used`，可能只是因为活跃流量落在其他 queue/CPU 上。

判断时要同时看：

```text
/proc/interrupts
ethtool -S <pf>
每队列 rx_packets / rx_bytes
方法 4 的 @rx_action_count 与 @budget_used_hist
```

#### 原因三：同一轮 poll 的 RX ring 本来就不满

NAPI 被调度不代表 RX ring 一定堆满。中断合并、流量突发间隔、TCP ACK clock、Redis 请求响应节奏，都会让一次 poll 只清理很少的包。

这种情况下：

```text
budget_used 小
elapsed_us 小
time_exhausted 不增加
```

是合理组合。

#### 原因四：发包方向和 TX completion 不消耗 RX budget

Redis server 处理完请求后会向 benchmark 发送 reply。对被测机来说，这部分是发送路径。驱动 NAPI poll 里可能处理 TX completion，但 TX completion 不计入 RX budget 扣减。

因此，某个窗口里网络活动并不少，但如果主要是：

```text
Redis server -> benchmark reply
TX completion
少量新请求进入
```

方法 4 看到的 `budget_used` 仍可能偏低。

#### 原因五：Redis 命令数不等于 RX budget 数

`budget_used` 统计的是 NAPI poll 返回的 `work`，也就是用于扣减 RX budget 的网络收包 work。它不等于：

- Redis 命令数
- Redis 请求数
- TCP 连接数
- Redis 实例数

一个 skb 中可能携带多个 Redis 命令，也可能一个命令跨多个 TCP segment。GRO、TSO/GSO、MSS、请求大小、pipeline 深度都会改变“命令数”和“网络包数”的比例。

所以，Redis 层 QPS 很高，不必然意味着单次 `net_rx_action()` 的 `budget_used` 一定高。

#### 原因六：Redis server 侧事件循环会把处理节奏拉散

Redis server 从 socket 读请求后，会在 `processInputBuffer()` 中解析并执行完整命令；reply 进入输出缓冲区，再由 pending write 机制写回客户端。40 个 Redis 实例分别是 40 个用户态进程，它们的调度、CPU 绑定、输出写回都会影响下一轮 benchmark 请求何时到来。

如果 Redis 进程、网络 softirq、benchmark 端读写之间形成了交替节奏，内核 RX 侧就可能表现为：

```text
很多 net_rx_action() 调用
每次处理少量包
没有触发 time_limit
整体吞吐仍然存在
```

### 11.4 对实测现象的判断框架

当看到“单次 `net_rx_action()` 的 `budget_used` 较少但没有超时”时，不要直接判断为内核 budget 不够。建议按下面顺序定位：

1. **先看请求模型**
   - `redis-benchmark` 是否使用默认 `-P 1`
   - `-c` 并发 client 数是多少
   - 是否每个 Redis 实例单独一个 benchmark 进程，还是一个 benchmark 打多个端口
2. **再看 RX queue 分布**
   - 目标 Redis 连接是否集中到少数 RX queue
   - `/proc/interrupts` 中哪些 CPU 在处理 PF IRQ
3. **再看方法 4 输出**
   - `@rx_action_count` 高但 `budget_used` 低：软中断被频繁触发，但每次 RX work 少
   - `@rx_action_count` 低且 `budget_used` 低：当前 CPU 本来就没多少 RX 工作
   - `budget_used` 高且 `time_exhausted` 高：才更像 softirq 预算/时间窗口压力
4. **最后对照 Redis 层**
   - Redis 实例 CPU 是否跑满
   - `redis-benchmark -P` 增大后 `budget_used` 是否明显增加
   - server 端 `tx/rx` 计数是否说明主要时间在回包而不是收请求

### 11.5 本问题的结论

1. 单次 `net_rx_action()` 可能处理发往一个或多个 Redis 实例的数据包，实际集合由 RSS hash、RX queue、IRQ affinity 和本轮 `poll_list` 决定。
2. `redis-benchmark` 默认 `-P 1` 下，单个 client 是“发 1 个请求，等 1 个 reply 后再发下一轮”；但多个 client 并发，所以整体仍有并行请求。
3. 使用 `-P N` 后，单个 client 会先发 N 个请求，再等 N 个回复都消费完后进入下一轮。
4. `budget_used` 较少但未超时，通常表示本轮 RX work 少且正常处理完成；它更可能来自请求节奏、RSS/IRQ 分布、TX completion、Redis 事件循环节奏或包/命令比例，而不是 `netdev_budget_usecs` 限制。
5. 判断是否真的存在 softirq budget 压力，应同时看 `budget_used_hist`、`elapsed_us_hist`、`time_used_pct_hist`、`@rx_action_count`、每队列统计和 Redis 进程 CPU。

## 十二、最终结论

在你修正后的拓扑下，结论应该改成下面这样：

1. **`ipvlan`**
   - `PF 63` 队列分布在 `40` 个服务核上，平均每核只有 `1-2` 个 `PF queue`
   - 但这些队列属于共享 `PF` 大池，不按容器隔离
   - 单个容器可以借用其他容器的第 `2` 个核来处理自己的网络流量
   - 所以它的特点是：
     - 单容器峰值可能更高
     - 跨容器干扰更强
     - 线性度更容易被热点容器拖坏

2. **`VF`**
   - 每个容器独占一个 `VF`
   - 每个 `VF` 的 `9` 个队列都绑到本容器自己的第 `2` 个核
   - 几乎消除了“容器 A 借走容器 B 服务核”的问题
   - 但也把每个容器的网络处理能力锁死在自己的那个服务核上
   - 所以它的特点是：
     - 跨容器隔离更强
     - 多容器线性度通常更好
     - 单容器更容易先撞上本地单核 softirq 上限

3. **这套绑核策略下，`VF` 的主要竞争不是容器间竞争，而是容器内竞争**
   - `9` 个 `VF queue`
   - `1` 个服务核
   - `1` 份该 CPU 本轮 `net_rx_action()` 的 `budget/time_limit`

4. **这套绑核策略下，`ipvlan` 的主要竞争不是“单容器队列不够”，而是全局共享竞争**
   - 共享 `PF queue`
   - 共享 `PF IRQ/NAPI`
   - 共享 `PF` 软件分流
   - 共享其他容器的第 `2` 个核

一句话总结：

> 在 `320` 核、`40` 容器、每容器一个 `cluster` 前两个核的拓扑下，`ipvlan` 更像“共享 63 个 PF 队列并向全局 40 个服务核借力”，而 `VF` 更像“每个容器带着自己的 9 个队列守着自己的第 2 个核自我消化”。前者更容易冲高单容器峰值但更容易互相拖累，后者更容易做稳线性度但更容易先碰到单容器本地单核瓶颈。
