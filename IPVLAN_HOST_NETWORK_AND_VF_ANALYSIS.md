# 容器 ipvlan、host-network 与 VF 直通网络路径分析

本文基于以下源码目录分析：

- `/home/fsq/Desktop/kernel-src/linux-6.6.0-132.0.0.111.oe2403sp3.aarch64`
- `/home/fsq/Desktop/fsq/docker-sriov-plugin`

结论先行：

- `host-network` 是最接近主机普通进程的路径：容器进程直接运行在主机 network namespace 中，不创建容器专属虚拟网卡。
- `ipvlan` 会创建一个从属于父设备的虚拟 netdev。容器看到的是 `ipvlan` 子接口，实际出站最终仍切到父设备发送，入站需要在父设备收包路径上查找并转交给对应 `ipvlan` 子接口。
- VF 直通是把 SR-IOV VF 对应的真实 netdev 分配给容器。数据面走 VF 自己的 PCIe function、队列和 VF 驱动，不再通过主机 PF netdev 做软件转发。
- VF 直通性能不一定比物理机 PF 低。它可能接近 PF，甚至在隔离和队列独占场景下比经过主机虚拟网络层的方案更稳定；但单个 VF 通常受队列数、rate limit、offload 能力、MSI-X 向量数、NIC e-switch 策略和 PF 驱动配置限制，峰值能力不应默认等同于整块 PF。

## 三种网络的定位差异

| 网络形态 | 容器内看到的网卡 | 是否创建虚拟 netdev | 是否共享主机 network namespace | 数据面是否经过主机软件转发层 | 典型目标 |
| --- | --- | --- | --- | --- | --- |
| `host-network` | 主机原有网卡 | 否 | 是 | 否，按主机普通进程路径收发 | 最低软件开销，但无网络命名空间隔离 |
| `ipvlan` | `ipvlan` 子接口 | 是 | 否 | 是，经过 `ipvlan` 驱动和父设备 | 多容器共享一个父设备，减少 MAC 消耗 |
| VF 直通 | VF netdev | 否，VF 本身是真实 PCIe function 的 netdev | 否 | 通常否，数据面走 VF 队列和 NIC 硬件 | 高性能隔离、NFV、DPDK、RDMA |

需要注意：当前 `docker-sriov-plugin` 仓库并没有实现 Docker 原生 `ipvlan` 或 `host-network`。它实现的是 Docker network plugin，driver 名称为 `sriov`，内部有 `sriov` 与 `passthrough` 两种模式。

## host-network 处理路径

`host-network` 的关键不是某个特殊网卡驱动，而是容器进程不创建独立 network namespace。它直接使用主机 `init_net` 中已有的网络设备、路由表、iptables/nftables、端口空间和邻居表。

内核中主机初始网络命名空间对象是 `init_net`，定义在 `net/core/net_namespace.c`。容器使用 host network 时，收发包路径与主机普通进程基本一致：

出站路径：

```text
container process
  -> host netns socket/IP stack
  -> ip_output()
  -> ip_finish_output()
  -> ip_finish_output2()
  -> neigh_output()
  -> dev_queue_xmit()
  -> PF netdev driver ndo_start_xmit
  -> NIC
```

入站路径：

```text
NIC/PF driver RX
  -> netif receive path
  -> ip_rcv()
  -> NF_INET_PRE_ROUTING
  -> ip_rcv_finish()
  -> dst_input()
  -> host netns socket
  -> container process
```

源码依据：

- `net/core/net_namespace.c` 定义并导出 `init_net`。
- `net/ipv4/ip_output.c` 中 `ip_output()` 进入 `NF_INET_POST_ROUTING` 后调用 `ip_finish_output()`，最终在 `ip_finish_output2()` 走邻居输出。
- `net/core/dev.c` 中 `__dev_queue_xmit()` 选择发送队列、qdisc，并调用设备硬发送路径。
- `net/ipv4/ip_input.c` 中 `ip_rcv()` 进入 IPv4 接收路径，再调用 `ip_rcv_finish()`。

这种路径的软件层最少，但代价也明显：容器与主机共享端口、路由、防火墙和网卡视图，网络隔离弱，多个容器之间也没有独立 IP/MAC 命名空间边界。

## ipvlan 处理路径

`ipvlan` 是内核虚拟网络设备。创建 `ipvlan` 子接口时，内核会把子接口绑定到一个父设备 `phy_dev`，并注册新的 netdev。容器中的进程对 `ipvlan` 子接口发包，但真正出物理网卡时仍要落到父设备。

创建路径的核心点：

- `drivers/net/ipvlan/ipvlan_main.c` 中 `ipvlan->phy_dev = phy_dev`，说明子接口绑定父设备。
- 同一文件将 `ipvlan_start_xmit` 注册为 `.ndo_start_xmit`。
- `ipvlan_start_xmit()` 调用 `ipvlan_queue_xmit()`。

出站路径可以简化为：

```text
container process
  -> container netns IP stack
  -> ipvlan netdev ndo_start_xmit
  -> ipvlan_start_xmit()
  -> ipvlan_queue_xmit()
  -> ipvlan_xmit_mode_l2() / ipvlan_xmit_mode_l3() / ipvlan_xmit_mode_l2e()
  -> local peer: dev_forward_skb()
  -> remote peer: skb->dev = phy_dev; dev_queue_xmit()
  -> parent PF driver
  -> NIC
```

入站路径可以简化为：

```text
NIC/PF driver RX
  -> parent device RX path
  -> ipvlan RX handler
  -> address lookup
  -> ipvlan_rcv_frame()
  -> skb->dev = ipvlan dev 或 dev_forward_skb(ipvlan dev)
  -> container netns IP stack
  -> container process
```

`ipvlan` 比 `bridge + veth` 少了一层 Linux bridge 和一对 veth，但它不是“无虚拟化开销”。源码中可以看到它仍要做 mode 分支、地址查找、本地转发判断、namespace crossing 处理，必要时还会 clone skb 或通过 `dev_forward_skb()` 注入另一张网卡的接收队列。

`net/core/dev.c` 对 `dev_forward_skb()` 的注释很关键：它用于把一个设备 `start_xmit` 中的 skb 注入另一张设备的接收队列，并且目标设备可能在另一个 namespace，所以要清理影响 namespace 隔离的信息。这正是 `ipvlan` 能在父设备与容器子接口之间转交 skb 的基础。

## VF 直通处理路径

VF 直通的核心是 SR-IOV：PF 通过 PCI SR-IOV capability 创建多个 VF，每个 VF 在内核中是独立 PCI device，通常由网卡 VF 驱动注册成独立 netdev。容器拿到的是这个 VF netdev，而不是 `ipvlan` 这类虚拟子接口。

### VF 是否是独立硬件设备

VF 不是一块独立的物理网卡，但在系统里通常表现为一个相对独立的 PCIe 设备。更准确地说，VF 的“独立”是 PCIe function 级别，不是整块 NIC 级别。

- 从 Linux PCI 设备模型看，每个 VF 会枚举成一个独立 `pci_dev`，`lspci` 通常能看到对应的 `Virtual Function`。
- 从网络设备模型看，VF 驱动通常会为每个 VF 注册独立 `netdev`，容器直通拿到的就是这个 VF netdev。
- 从硬件资源看，VF 有自己的 Tx/Rx queue、DMA ring、中断向量、MAC/VLAN 策略等资源切片。
- 从控制面看，VF 不完全自治。PF 仍可控制 VF 的创建、销毁、VLAN、trust、spoof check、rate limit、队列数等。
- 从物理层看，多个 VF 仍共享同一块 NIC ASIC、物理端口、PCIe 上行带宽、firmware 和 embedded switch。

所以，VF 是由 SR-IOV 硬件虚拟出来的 PCIe virtual function，是可被操作系统和容器当作独立设备使用的硬件资源实例；但它不是独立物理 NIC，而是 PF/NIC 硬件资源的受控切片。

内核 SR-IOV 基础路径：

- `drivers/pci/iov.c` 的 `sriov_numvfs_store()` 处理对 `sriov_numvfs` 的写入。
- `sriov_enable()` 配置 SR-IOV capability，并调用 `sriov_add_vfs()`。
- `pci_iov_add_virtfn()` 为每个 VF 分配 `pci_dev`，设置 `virtfn->is_virtfn = 1`、`virtfn->physfn = ...`，再加入 PCI bus。
- `pci_iov_sysfs_link()` 创建 PF 到 VF 的 `virtfnN` sysfs 链接，以及 VF 到 PF 的 `physfn` 链接。

本仓库 `docker-sriov-plugin` 的控制面路径：

```text
docker network create -d sriov -o netdevice=<PF> [-o mode=sriov]
  -> driver.CreateNetwork()
  -> parseNetworkOptions()
  -> _CreateNetwork()
  -> sriovNetwork.CreateNetwork()
  -> SetPFLinkUp()
  -> DiscoverVFs()
  -> sriovnet.EnableSriov() / sriovnet.GetPfNetdevHandle() / sriovnet.ConfigVfs()

docker run --net=<network>
  -> driver.CreateEndpoint()
  -> sriovNetwork.CreateEndpoint()
  -> sriovnet.AllocateVf() 或 AllocateVfByMacAddress()
  -> optional: SetVfVlan()
  -> SetVfPrivileged()
  -> 返回 VF netdev 名称
  -> Join() 返回 SrcName，Docker 将该设备放进容器 sandbox
```

对应源码：

- `driver/driver.go`：解析 `netdevice`、`mode` 等选项，默认 `mode=sriov`，并按模式选择 `sriovNetwork`、`dpSriovNetwork` 或 `ptNetwork`。
- `driver/sriov.go`：单端口 SR-IOV 路径，创建网络时启用/发现 VF，创建 endpoint 时分配 VF，并设置 VLAN、trusted/spoof check 等属性。
- `driver/dualport_sriov.go`：多端口设备路径，从已有 VF netdev 列表中分配和回收。
- `driver/sriov_helpers.go`：封装 `sriov_totalvfs`、`sriov_numvfs`、`virtfnN`、VF VLAN、trust、spoof check 等 sysfs/netlink 操作。

VF 直通的数据面路径：

```text
container process
  -> container netns IP stack
  -> VF netdev
  -> dev_queue_xmit()
  -> VF driver ndo_start_xmit
  -> VF PCIe Tx queue / DMA
  -> NIC embedded switch / wire
```

入站路径：

```text
wire / NIC embedded switch
  -> VF Rx queue / DMA
  -> VF driver NAPI
  -> VF netdev receive path
  -> container netns IP stack
  -> container process
```

这里 PF 仍然重要，但更多是控制面角色：启用 SR-IOV、创建 VF、配置 VF VLAN、trust、spoof check、rate limit、队列等策略。稳定转发时，容器流量通常**不再作为 skb 经过主机** PF netdev 的 `ipvlan`/bridge/veth **软件转发层**。

本插件还有一个容易混淆的 `passthrough` 模式：`mode=passthrough` 不分配 VF 池，也不自动启用 SR-IOV，而是把 `netdevice` 指定的现有 netdev 原样交给容器，并且一个 network 只允许一个 endpoint。这个模式可用于把已经存在的 VF netdev 或其他设备直接交给单个容器。

## 路径差异对比

| 维度 | `host-network` | `ipvlan` | VF 直通 |
| --- | --- | --- | --- |
| namespace | 共享主机 netns | 容器独立 netns | 容器独立 netns |
| netdev 类型 | 主机 PF/物理 netdev | `ipvlan` 虚拟 netdev | VF 真实 netdev |
| 出站最终设备 | PF | 父设备 `phy_dev` | VF 自己 |
| 中间软件层 | 最少 | `ipvlan` mode 分支、地址查找、本地转发、父设备发送 | 少，主要是 VF 驱动和通用协议栈 |
| 入站分发 | 主机协议栈直接收 | 父设备收包后按 `ipvlan` 地址/模式分发 | NIC/VF 队列直接进入 VF netdev |
| MAC/IP 隔离 | 弱，共享主机视图 | IP 隔离较好，通常共享父设备 MAC 语义 | 强，每个 VF 可有独立 MAC、VLAN、队列和硬件策略 |
| 性能上限 | 接近主机普通进程 | 通常优于 bridge/veth，但仍有虚拟 netdev 开销 | 通常接近硬件，取决于 VF 资源配置 |
| 管控能力 | 简单但隔离差 | 软件层集中管控 | PF/硬件侧策略管控 |

## VF 直通一定比物理机 PF 性能低吗？

不一定。

严格说，应该区分三种比较对象：

1. **单个 VF vs 整块 PF 的理论上限**：单个 VF 往往更弱。PF 通常拥有更多 Tx/Rx queue、更多 MSI-X vector、更完整的 offload 能力和更高的硬件资源配额。NIC 或驱动还可能给 VF 设置 rate limit、VLAN、spoof check、trust、RSS 队列数等限制。
2. **单个容器应用 vs 主机上同一个应用**：VF 不一定低。只要 VF 队列、NUMA、IRQ affinity、MTU、offload、RSS、CPU 绑核配置合理，单流或有限并发场景常能接近 PF 路径。
3. **VF 直通 vs `ipvlan`/bridge/veth 等虚拟网络方案**：VF 通常更有优势。它绕过了主机软件转发层，减少 skb 在虚拟设备之间转交、查表、clone、qdisc 和 netfilter 干预的机会。

所以正确结论是：**VF 直通不是天然低于 PF，而是 VF 可用硬件资源通常是 PF 的一个受控切片。**如果拿“一个 VF”对比“整块 PF 的全部队列和带宽”，VF 很可能低；如果对比“单个业务实例需要的一部分网卡能力”，VF 可能达到线速或接近 PF，并提供更好的隔离。

## 实践判断建议

- 追求最低软件路径且能接受无隔离：使用 `host-network`。
- 需要容器网络隔离，但想共享一个父设备且避免 veth/bridge 额外层：使用 `ipvlan`。
- 需要高吞吐、低延迟、硬件队列隔离、RDMA/DPDK/NFV 能力：优先使用 VF 直通。
- 做性能结论时不要只看网络模式名称，必须同时检查 VF 队列数、IRQ 分布、NUMA、offload、MTU、RSS、VF rate limit、PF/VF 驱动版本和 NIC e-switch 模式。
