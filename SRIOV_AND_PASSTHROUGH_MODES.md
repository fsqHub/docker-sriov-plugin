# docker-sriov-plugin 两种模式使用方法与差异

本文基于当前目录源码与 `README.md` 梳理 `docker-sriov-plugin` 的两种用户可见模式：`sriov` 和 `passthrough`。

需要先明确一个容易混淆的点：插件对 Docker 注册的 network driver 名称始终是 `sriov`，因为 `main.go` 中使用 `ServeUnix("sriov", 0)` 暴露插件 socket。两种模式不是两个不同的 Docker driver，而是通过 `docker network create -d sriov -o mode=...` 传入的网络选项决定。

## 基本启动方式

从镜像运行插件：

```bash
docker pull rdma/sriov-plugin

docker run \
  -v /run/docker/plugins:/run/docker/plugins \
  -v /etc/docker:/etc/docker \
  -v /var/run:/var/run \
  --net=host \
  --privileged \
  rdma/sriov-plugin
```

关键点：

- 插件需要 `--privileged`，因为它会操作主机网络设备、SR-IOV VF、sysfs 和 netlink。
- `/run/docker/plugins` 用于向 Docker 暴露 network plugin socket。
- `/etc/docker` 用于持久化网络配置。源码中的持久化目录是 `/etc/docker/mellanox/docker-sriov-plugin`。
- 插件启动时会读取已持久化的网络配置，并尝试重新创建内部网络状态。

创建 Docker 网络时必须提供 IPAM 信息。源码在 `CreateNetwork` 中要求 `IPv4Data` 非空，因此实际使用时应传 `--subnet`，必要时传 `--gateway`。

## 共同网络选项

| 选项 | 适用模式 | 含义 |
| --- | --- | --- |
| `netdevice` | `sriov`、`passthrough` | 必填。指定 PF、父设备或要直通的主机 netdevice。 |
| `mode` | `sriov`、`passthrough` | 可选。为空时源码默认使用 `sriov`。合法值只有 `sriov` 和 `passthrough`。 |
| `vlan` | 主要用于 `sriov` | 配置 VF VLAN offload。范围是 `0..4095`，其中 `0` 表示不设置 VLAN；同一 PF 上不能重复创建相同 VLAN 网络。 |
| `privileged` | 主要用于 `sriov` | `1` 表示 trusted VF，允许修改 L2 地址并关闭 spoof check；默认是非特权网络。 |
| `prefix` | `sriov`、`passthrough` | 容器内网卡名前缀，默认是 `eth`。 |
| `rocehoplimit` | 单端口 `sriov` | 源码支持但 README 未列出。范围是 `0..255`，用于设置 RoCE hop limit workaround。 |

## SR-IOV 模式

### 使用方法

`sriov` 是默认模式，可以省略 `-o mode=sriov`：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  mynet

docker run --net=mynet -itd --name=web nginx
```

显式写法：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  -o mode=sriov \
  mynet
```

使用 VLAN 做二层隔离：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  -o vlan=100 \
  customer1

docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  -o vlan=200 \
  customer2
```

创建 trusted/privileged 网络：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  -o vlan=100 \
  -o privileged=1 \
  customer1
```

为容器选择指定 MAC 对应的 VF：

```bash
docker run \
  --net=customer1 \
  --mac-address=<valid_mac_address_of_desired_vf> \
  -itd \
  --name=web \
  nginx
```

> 注意：按 MAC 选 VF 仅在单端口 SR-IOV 路径有效（源码走 `AllocateVfByMacAddress`）。多端口路径会忽略 `--mac-address`，无条件从可用 VF 列表尾部分配。

### 源码行为

创建网络时，`driver._CreateNetwork` 会根据 `mode` 选择 SR-IOV 分支。对 SR-IOV 模式，它还会先判断指定 `netdevice` 是否是多端口设备：

- 单端口设备使用 `sriovNetwork`。
- 多端口设备使用 `dpSriovNetwork`。

这是内部实现差异，不是用户侧第三种模式。

单端口 SR-IOV 路径的核心行为：

- 创建网络时调用 `SetPFLinkUp` 拉起 PF。
- 如果 PF 尚未启用 SR-IOV，则调用 `sriovnet.EnableSriov` 启用 SR-IOV。
- 初始化并配置 VF。
- 创建 endpoint 时从 PF 的 VF 池中分配一个 VF。
- 如果配置了 `vlan`，在 VF 上设置 VLAN。
- 根据 `privileged` 设置 VF trust 和 spoof check。
- 删除 endpoint 时释放 VF。
- 删除最后一个引用该 PF 的网络时禁用 SR-IOV，并移除 PF 状态。

多端口 SR-IOV 路径的核心差异：

- 创建网络时先调用 `IsSRIOVSupported` 读取 PF 的 `sriov_totalvfs`，为 `0` 时直接返回 `SRIOV is unsuppported` 并终止，不再继续发现 VF。
- 不主动调用 `sriovnet.EnableSriov`；它通过 `ibdev2netdev`（运行期执行 `/tmp/tools/ibdev2netdev`）和 sysfs 发现同一物理端口下已有的 VF netdevice。
- 如果发现到的子设备列表为空，会认为 SR-IOV 未启用并返回 `SRIOV is disabled`。
- endpoint 创建时从发现到的 VF netdevice 列表中弹出一个设备，删除 endpoint 时放回列表。
- 不支持按 MAC 选择 VF：`--mac-address` 仅单端口路径有效，多端口路径会忽略它并直接从列表尾部分配。

### 适用场景

SR-IOV 模式适合一块 PF 下有多个 VF、多个容器需要共享同一物理网卡资源池的场景。每个容器拿到独立 VF，具备更好的隔离和接近硬件的性能，适合 NFV、DPDK、RDMA、低延迟网络等场景。

## Passthrough 模式

### 使用方法

`passthrough` 必须显式传 `-o mode=passthrough`：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.1.0/24 \
  -o netdevice=ens2f0 \
  -o mode=passthrough \
  mynet

docker run --net=mynet -itd --name=web nginx
```

如果要让多个容器分别直通不同设备，需要为每个设备创建独立网络，例如：

```bash
docker network create \
  -d sriov \
  --subnet=194.168.10.0/24 \
  -o netdevice=ens2f0 \
  -o mode=passthrough \
  pt-net-0

docker network create \
  -d sriov \
  --subnet=194.168.20.0/24 \
  -o netdevice=ens2f1 \
  -o mode=passthrough \
  pt-net-1
```

### 源码行为

passthrough 模式的实现非常直接：

- 创建网络时只保存 `genericNetwork`，不会启用 SR-IOV，也不会发现或分配 VF。
- 创建 endpoint 时直接把 `netdevice` 指定的设备名作为 endpoint 的 `SrcName`。
- 同一个 passthrough network 只允许创建一个 endpoint；源码中如果该网络已有 endpoint，会返回 `supports only one device`。
- 删除 endpoint 和删除网络时没有 SR-IOV 资源释放逻辑。

这意味着 passthrough 模式的资源单位是“整个指定 netdevice”，而不是 VF 池。容器使用后，该设备会作为 Docker network plugin 返回的源接口进入容器网络命名空间；主机侧不能再把它当普通共享接口使用。

### 适用场景

passthrough 模式适合把某个现成 netdevice 原样交给单个容器的场景，例如：

- 直接把 bond 设备交给容器，避免额外虚拟层。
- InfiniBand IPoIB VF 已经作为 netdevice 存在，只想把这个 VF 直通给容器。
- 不希望插件负责 SR-IOV enable、VF 池管理和 VF 分配。

## 两种模式的核心差异

| 维度 | `sriov` | `passthrough` |
| --- | --- | --- |
| Docker driver 名称 | 都是 `-d sriov` | 都是 `-d sriov` |
| mode 选项 | 默认值，可省略 | 必须显式 `-o mode=passthrough` |
| `netdevice` 含义 | PF/父设备，作为 VF 资源池入口 | 要交给容器的具体 netdevice |
| 容器拿到的设备 | 一个分配出来的 VF netdevice | `netdevice` 指定的设备本体 |
| 单个 network 可支持容器数 | 取决于可用 VF 数量 | 只支持一个 endpoint |
| 是否自动启用 SR-IOV | 单端口路径会自动启用；多端口路径要求已有可发现 VF | 不会 |
| 是否管理 VF 分配和释放 | 会 | 不会 |
| VLAN offload | 支持，对 VF 设置 VLAN | 选项可传入但 passthrough 实现不使用 |
| privileged/trusted VF | 支持，影响 trust 与 spoof check | 选项可传入但 passthrough 实现不使用 |
| 删除网络影响 | 单端口路径：最后一个使用 PF 的网络删除时禁用 SR-IOV；多端口路径：仅清理内部状态，不禁用 SR-IOV | 无 SR-IOV 清理 |
| 典型用途 | 多容器共享 PF 的 VF 池，高性能隔离 | 单容器独占某个已有设备 |

## 使用建议

- 多容器、高性能隔离、需要 VLAN/anti-spoof/trusted VF 管控时，优先使用 `sriov`。
- 只想把一个已有 netdevice 原样交给一个容器时，使用 `passthrough`。
- 不要把 `-d sriov` 误解为一定启用 SR-IOV；它只是 Docker plugin driver 名称。是否走 SR-IOV 资源管理取决于 `mode`。
- `passthrough` 模式不要期望一个 Docker network 挂多个容器，源码明确限制一个 network 只能有一个 endpoint。
- 对 SR-IOV 模式，规划 VLAN 时要避免同一 PF 上重复使用相同 VLAN，否则创建网络会失败。
- 当前持久化结构主要保存 `Mode`、`Netdevice`、`Gateway`、`vlan` 和 `Privileged`。`prefix` 与 `rocehoplimit` 没有进入持久化结构：插件重启后的恢复路径（`BuildNetworkOptions`）不会重建这两项，也不会走补默认值逻辑，因此 `prefix` 会退化为空（容器网卡 `DstPrefix` 不再是默认 `eth`），`rocehoplimit` 的 RoCE workaround 在重启后失效。依赖这些选项时需要特别注意。

## 源码依据

- `main.go`：插件注册为 Docker network driver `sriov`。
- `driver/driver.go`：解析 `netdevice`、`mode`、`vlan`、`privileged`、`prefix`、`rocehoplimit` 等选项；默认 `mode=sriov`；按模式选择 `ptNetwork` 或 SR-IOV 网络实现。
- `driver/sriov.go`：单端口 SR-IOV 的 PF 初始化、VF 分配、VLAN、privileged、RoCE hop limit 和释放逻辑。
- `driver/dualport_sriov.go`、`driver/dualport_sriov_helpers.go`：多端口 SR-IOV 设备发现与 VF netdevice 分配逻辑。
- `driver/sriov_helpers.go`：`IsSRIOVSupported`、`SetPFLinkUp` 以及 VF VLAN / trust / spoofcheck 等 netlink 与 sysfs 封装。
- `driver/file_kv.go`：网络配置持久化路径与持久化字段。
- `README.md`：官方示例命令与两种模式的用户侧说明。
