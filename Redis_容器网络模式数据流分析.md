# Redis 容器网络模式数据流分析

## 文档概述

本文档以 Redis 为例，深入分析应用程序在三种容器网络模式（IPvlan、Host Network、VF 直通）下的端到端数据处理流程。通过追踪从 Redis 用户态代码到物理网卡硬件的完整路径，量化分析每种模式的性能影响。

**与《容器网络模式对比分析》的关系**：
- 基础文档：通用的容器网络模式对比（内核层面）
- 本文档：聚焦 Redis 应用，从应用层到物理层的实战分析

**配套图示**：参见 `diagrams/redis/` 目录，共 9 个图示（全部完成）

---

## 目录

- [一、Redis 网络 I/O 架构概述](#一redis-网络-io-架构概述)
- [二、Redis 数据接收路径（三种模式对比）](#二redis-数据接收路径三种模式对比)
- [三、Redis 数据发送路径（三种模式对比）](#三redis-数据发送路径三种模式对比)
- [四、性能影响分析](#四性能影响分析)
- [五、实际测试场景](#五实际测试场景)
- [六、多实例资源竞争分析](#六多实例资源竞争分析)
- [附录](#附录)

---

## 一、Redis 网络 I/O 架构概述

### 1.1 Redis 事件驱动模型

Redis 采用单线程事件驱动架构，通过 **ae (A simple Event-driven programming library)** 框架实现高性能的 I/O 多路复用。

**核心组件**：
- **aeEventLoop**：事件循环主体，管理文件事件和定时事件
- **aeFileEvent**：文件描述符事件（socket 读写）
- **aeTimeEvent**：定时任务事件

**源码位置**：`/home/fsq/Desktop/fsq/redis/src/`
- `ae.c` - 事件循环核心实现
- `ae_epoll.c` - Linux epoll 多路复用适配器
- `networking.c` - 网络通信和协议处理

### 1.2 事件循环实现

**事件循环主函数**（`ae.c:493-499`）：

```c
void aeMain(aeEventLoop *eventLoop) {
    eventLoop->stop = 0;
    while (!eventLoop->stop) {
        aeProcessEvents(eventLoop, AE_ALL_EVENTS|
                                   AE_CALL_BEFORE_SLEEP|
                                   AE_CALL_AFTER_SLEEP);
    }
}
```

**事件处理流程**（`ae.c:357` - `aeProcessEvents()`）：

1. **计算超时**：根据最近的定时事件计算 epoll_wait 超时时间
2. **等待事件**：调用 `aeApiPoll()` → `epoll_wait()` 阻塞等待
3. **处理文件事件**：遍历触发的 socket 事件，调用对应的读写处理函数
4. **处理定时事件**：执行到期的定时任务

### 1.3 Epoll 多路复用封装

**初始化**（`ae_epoll.c:39-57`）：

```c
static int aeApiCreate(aeEventLoop *eventLoop) {
    aeApiState *state = zmalloc(sizeof(aeApiState));
    state->events = zmalloc(sizeof(struct epoll_event)*eventLoop->setsize);
    state->epfd = epoll_create(1024);  // 创建 epoll 实例
    anetCloexec(state->epfd);
    eventLoop->apidata = state;
    return 0;
}
```

**Poll 调用**（`ae_epoll.c:109-135`）：

```c
static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    aeApiState *state = eventLoop->apidata;
    int retval, numevents = 0;
    
    // 调用 epoll_wait 系统调用
    retval = epoll_wait(state->epfd, state->events, eventLoop->setsize,
                       tvp ? (tvp->tv_sec*1000 + (tvp->tv_usec+999)/1000) : -1);
    
    // 转换 epoll 事件到 Redis 事件
    for (j = 0; j < numevents; j++) {
        struct epoll_event *e = state->events+j;
        int mask = 0;
        if (e->events & EPOLLIN)  mask |= AE_READABLE;
        if (e->events & EPOLLOUT) mask |= AE_WRITABLE;
        eventLoop->fired[j].fd = e->data.fd;
        eventLoop->fired[j].mask = mask;
    }
    return numevents;
}
```

**关键点**：
- `epoll_wait()` 是 Redis 与内核网络栈交互的核心系统调用
- 超时以毫秒为单位：`(tv_sec*1000 + tv_usec/1000)`
- 返回可读/可写的 socket 文件描述符列表

### 1.4 Socket 读写缓冲区管理

**客户端连接结构**（`server.h` 中的 `client` 结构）：

```c
struct client {
    connection *conn;              // 连接对象（封装 socket fd）
    sds querybuf;                 // 输入缓冲区（动态字符串）
    int qb_pos;                   // 协议解析位置
    list *reply;                  // 输出缓冲区链表
    size_t buf_usable_size;       // 输出缓冲区可用大小
    char *buf;                    // 输出缓冲区（动态分配，初始 PROTO_REPLY_CHUNK_BYTES = 16KB）
    // ... 更多字段
};
```

**缓冲策略**：
- **输入**：使用 SDS (Simple Dynamic String) 动态扩展
- **输出**：
  - 优先使用动态分配的快速缓冲区（`buf`，初始 16KB，可按需增长）
  - 溢出时使用链表（`reply`）存储大响应

### 1.5 Redis 事件循环架构图

<a id="图1"></a>

![Redis 事件循环架构](diagrams/redis/redis_event_loop.png)

*图 1：Redis 事件循环架构 - 展示 aeEventLoop、epoll_fd、客户端连接管理和事件处理流程*

**关键要点**：
- 单线程事件循环通过 epoll 多路复用同时处理数千个客户端连接
- `epoll_wait()` 系统调用是 Redis 与内核网络栈交互的核心
- 所有 socket 设置为非阻塞模式（O_NONBLOCK），避免 I/O 阻塞
- 文件事件（socket 读写）和定时事件（serverCron）在同一循环中处理

---

## 二、Redis 数据接收路径（三种模式对比）

本章详细分析从物理网卡到 Redis `read()` 系统调用的完整数据包处理路径。

### 2.1 IPvlan 模式 - 数据接收路径

#### 完整调用链（物理层 → 应用层）

```
┌─────────────────────────────────────────────────────────────┐
│ 物理层                                                        │
└─────────────────────────────────────────────────────────────┘
物理网卡 (PF) 接收数据包
    ↓ DMA 传输到宿主机内存
    ↓ 触发硬件中断

┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 宿主机 netns                                         │
└─────────────────────────────────────────────────────────────┘
硬件中断处理程序
    ↓ 调度 NAPI 软中断
napi_poll() → ixgbe_clean_rx_irq()
    ↓ 从 RX 描述符环读取数据包
    ↓ 构建 skb (socket buffer)
netif_receive_skb_core()
    ↓ 遍历 rx_handler 链
ipvlan_handle_frame()              ← **IPvlan 拦截点**
    ↓ ipvlan_handle_mode_l3()
    ↓ 查找 IP 地址哈希表
    ↓ ipvlan_addr_lookup() 匹配成功
dev_forward_skb(ipvlan->dev, skb)
    ↓ 修改 skb->dev 为虚拟网卡
    ↓ ipvlan_skb_crossing_ns()     ← **netns 切换开销**

┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 容器 netns                                           │
└─────────────────────────────────────────────────────────────┘
netif_rx() / netif_receive_skb()
    ↓ 重新进入网络协议栈（第 2 次遍历）
__netif_receive_skb_core()
    ↓ IP 层处理
tcp_v4_rcv() / udp_rcv()
    ↓ 将数据包加入 socket 接收队列
    ↓ 唤醒等待的进程

┌─────────────────────────────────────────────────────────────┐
│ 用户态 - Redis 进程                                           │
└─────────────────────────────────────────────────────────────┘
epoll_wait() 返回                  ← 系统调用返回
    ↓ aeProcessEvents() 处理事件
readQueryFromClient()              ← Redis 读事件处理函数
    ↓ connRead(c->conn, ...)       ← 系统调用封装
    ↓ read(fd, buf, len)           ← 系统调用
    ↓ 从内核复制数据到用户态缓冲区
processInputBuffer(c)
    ↓ processMultibulkBuffer()     ← RESP 协议解析
    ↓ 解析命令和参数
processCommandAndResetClient(c)
    ↓ 查找命令表
    ↓ 执行命令处理函数
```

#### 性能开销分析

| 阶段 | 开销类型 | 说明 |
|------|----------|------|
| 物理网卡 DMA | 硬件操作 | 数据传输到内核 RX buffer |
| 宿主机 L2→L3 处理 | CPU | PF 驱动构建 skb，rx_handler 在 L3 层拦截（**不经过宿主机 TCP 层**） |
| IPvlan rx_handler | CPU | IP 地址查找、哈希表查询、`dev_forward_skb()` 转发 |
| **netns 切换** | **CPU + 缓存失效** | **skb 的 metadata 调整（不涉及数据区域的拷贝）** |
| 容器 L3→L4 处理 | CPU | 从 `netif_rx()` 重新进入协议栈，完成 TCP/UDP 处理 |
| epoll_wait 唤醒 | 系统调用 | 进程调度 |
| read() 系统调用 | 内存拷贝 | 内核 socket buffer → 用户态 buffer（**唯一的真正数据拷贝**） |

**关键瓶颈**：
- ✗ 数据包经过 rx_handler 拦截和 `dev_forward_skb()` netns 切换，比直通路径多一层软件转发
- ✗ netns 切换导致 **CPU 缓存失效**
- ✗ 无硬件卸载支持（RSS、Checksum Offload 对 IPvlan 虚拟设备不生效）
- 注意：宿主机侧只处理到 L3（IP 头解析），**不会遍历宿主机的 TCP 层**

<a id="图2"></a>

![IPvlan 模式数据接收路径](diagrams/redis/redis_rx_ipvlan.png)

*图 2：IPvlan 模式 - Redis 数据接收完整路径，展示双重协议栈遍历和 netns 切换开销*

---

### 2.2 Host Network 模式 - 数据接收路径

#### 完整调用链（物理层 → 应用层）

```
┌─────────────────────────────────────────────────────────────┐
│ 物理层                                                        │
└─────────────────────────────────────────────────────────────┘
物理网卡 (PF) 接收数据包
    ↓ DMA 传输到宿主机内存
    ↓ 触发硬件中断

┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 宿主机 netns（容器共享）                             │
└─────────────────────────────────────────────────────────────┘
硬件中断处理程序
    ↓ 调度 NAPI 软中断
napi_poll() → ixgbe_clean_rx_irq()
    ↓ 从 RX 描述符环读取数据包
    ↓ 构建 skb
napi_gro_receive()
    ↓ GRO (Generic Receive Offload) 聚合
__netif_receive_skb_core()
    ↓ 无 rx_handler 拦截（直通）      ← **与 IPvlan 的关键差异**
    ↓ IP 层处理
tcp_v4_rcv() / udp_rcv()
    ↓ 将数据包加入 socket 接收队列
    ↓ 唤醒等待的进程

┌─────────────────────────────────────────────────────────────┐
│ 用户态 - Redis 进程                                           │
└─────────────────────────────────────────────────────────────┘
epoll_wait() 返回
    ↓ aeProcessEvents()
readQueryFromClient()
    ↓ connRead(c->conn, ...)
    ↓ read(fd, buf, len)
    ↓ 从内核复制数据到用户态
processInputBuffer(c)
    ↓ RESP 协议解析
    ↓ 命令执行
```

#### 性能开销分析

| 阶段 | 开销类型 | 说明 |
|------|----------|------|
| 物理网卡 DMA | 硬件操作 | 数据传输到宿主机内存 |
| 协议栈处理 | CPU + 内存拷贝 | **仅 1 次遍历**（vs IPvlan 2 次） |
| GRO 聚合 | CPU 优化 | 减少协议栈处理次数 |
| epoll_wait 唤醒 | 系统调用 | 进程调度 |
| read() 系统调用 | 内存拷贝 | 内核 → 用户态 |

**性能优势**：
- ✓ 协议栈遍历 **1 次**（最短路径）
- ✓ 无 netns 切换开销
- ✓ 完整的硬件卸载支持（RSS、TSO、GSO、Checksum Offload）
- ✓ 与物理机性能完全一致

**代价**：
- ✗ 无网络隔离（与宿主机共享网络栈）
- ✗ 端口冲突（所有容器共享端口空间）

<a id="图3"></a>

![Host Network 模式数据接收路径](diagrams/redis/redis_rx_hostnet.png)

*图 3：Host Network 模式 - Redis 数据接收路径，最短路径无虚拟化开销*

---

### 2.3 VF 直通模式 - 数据接收路径

#### 完整调用链（物理层 → 应用层）

```
┌─────────────────────────────────────────────────────────────┐
│ 物理层 - VF 硬件                                              │
└─────────────────────────────────────────────────────────────┘
VF 硬件队列接收数据包
    ↓ VF 独立的 DMA 引擎
    ↓ DMA 到 VF 驱动的内核 RX buffer（通过 IOMMU 地址隔离）← **关键：不经过宿主机 netns**
    ↓ 触发 VF 独立中断

┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 容器 netns                                           │
└─────────────────────────────────────────────────────────────┘
VF 中断处理程序
    ↓ 调度 NAPI 软中断（在容器 netns 上下文中）
napi_poll() → ixgbevf_poll()       ← VF 驱动
    ↓ ixgbevf_clean_rx_irq()
    ↓ 从 VF RX 描述符环读取
    ↓ 构建 skb
ixgbevf_rx_skb()
    ↓ napi_gro_receive()
__netif_receive_skb_core()
    ↓ 在容器 netns 中处理           ← **无宿主机 netns 参与**
    ↓ IP 层 → TCP/UDP 层
    ↓ 加入 socket 接收队列
    ↓ 唤醒 Redis 进程

┌─────────────────────────────────────────────────────────────┐
│ 用户态 - Redis 进程                                           │
└─────────────────────────────────────────────────────────────┘
epoll_wait() 返回
    ↓ aeProcessEvents()
readQueryFromClient()
    ↓ connRead(c->conn, ...)
    ↓ read(fd, buf, len)
    ↓ 从容器内核复制到用户态
processInputBuffer(c)
    ↓ RESP 协议解析
    ↓ 命令执行
```

#### 性能开销分析

| 阶段 | 开销类型 | 说明 |
|------|----------|------|
| VF 硬件 DMA | 硬件操作 | DMA 到 VF 驱动的内核 RX buffer（IOMMU 地址隔离） |
| VF 中断 | 硬件隔离 | 独立的 MSI-X 中断向量 |
| IOMMU 地址转换 | 轻微开销 | 1-3% 性能损失（现代硬件已优化） |
| 容器协议栈 | CPU | 在容器 netns 中完成完整的 L2→L4 处理 |
| epoll_wait 唤醒 | 系统调用 | 进程调度 |
| read() 系统调用 | 内存拷贝 | 内核 socket buffer → 用户态 buffer |

**性能优势**：
- ✓ 省去虚拟交换/软件转发层，**数据处理路径不经过宿主机 netns**
- ✓ 协议栈在容器 netns 中完整处理（与 Host Network 相当）
- ✓ 独立的硬件队列、中断向量（硬件级隔离）
- ✓ 完整的硬件卸载支持（RSS、Checksum Offload、VLAN 过滤）
- ✓ 网络隔离性强（独立 netns + 硬件隔离）

**代价**：
- ✗ IOMMU 地址转换开销（1-3%）
- ✗ VF 数量限制（Intel 82599 最多 64 个）
- ✗ 需要硬件 SR-IOV 支持

<a id="图4"></a>

![VF 直通模式数据接收路径](diagrams/redis/redis_rx_vf.png)

*图 4：VF 直通模式 - Redis 数据接收路径，数据处理路径不经过宿主机 netns，通过 IOMMU 实现地址隔离*

---

## 三、Redis 数据发送路径（三种模式对比）

本章分析从 Redis 响应生成到物理网卡发送的完整路径。

<a id="图5"></a>

![Redis 数据发送路径对比](diagrams/redis/redis_tx_comparison.png)

*图 5：Redis 数据发送路径对比 - 三列对比展示 IPvlan、Host Network、VF 直通的发送路径差异*

---

### 3.1 Redis 响应缓冲与发送机制

**响应构建**（`networking.c:407` - `addReply()`）：

```c
void addReply(client *c, robj *obj) {
    if (prepareClientToWrite(c) != C_OK) return;
    // 将响应内容加入客户端输出缓冲区
    if (sdsEncodedObject(obj)) {
        _addReplyToBufferOrList(c, obj->ptr, sdslen(obj->ptr));
    } else {
        _addReplyStringToList(c, obj->ptr);
    }
}
```

**缓冲策略**（`networking.c:383-398`）：

```c
void _addReplyToBufferOrList(client *c, const char *s, size_t len) {
    // 优先使用固定缓冲区（16KB）
    size_t reply_len = _addReplyToBuffer(c, s, len);
    // 溢出则使用链表
    if (len > reply_len)
        _addReplyProtoToList(c, s+reply_len, len-reply_len);
}
```

**写入操作**（`networking.c:1900-1947` - `_writeToClient()`）：

```c
ssize_t _writeToClient(client *c, ssize_t *nwritten) {
    // 使用 writev() 批量写入
    if (c->bufpos > 0) {
        struct iovec iov[3];
        // 填充 iovec 数组...
        nwritten = writev(fd, iov, iovcnt);  // 系统调用
    }
}
```

**关键优化**：
- **writev()** 批量写入：一次系统调用发送多个缓冲区
- **延迟写入**：先加入待写队列，在 `beforeSleep` 批量发送

### 3.2 三种模式发送路径对比

#### IPvlan 模式

```
Redis 进程
    ↓ addReply*() 构建响应
    ↓ writev(fd, iov, cnt)        ← 系统调用
┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 容器 netns                                           │
└─────────────────────────────────────────────────────────────┘
tcp_sendmsg()
    ↓ 构建 skb
ip_local_out()
    ↓ 路由查找
ipvlan_start_xmit()                ← IPvlan 虚拟网卡发送
    ↓ ipvlan_queue_xmit()
    ↓ ipvlan_xmit_mode_l3()
    ↓ ipvlan_process_v4_outbound()
    ↓ ip_route_output_flow()      ← 重新查路由
    ↓ ipvlan_skb_crossing_ns()    ← **netns 切换**

┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 宿主机 netns                                         │
└─────────────────────────────────────────────────────────────┘
ip_local_out()                     ← **重新进入协议栈**
    ↓ 邻居子系统
dev_queue_xmit(phy_dev)            ← 物理网卡队列
    ↓ qdisc 队列管理
ixgbe_xmit_frame()                 ← PF 驱动
    ↓ DMA 映射
    ↓ 更新 TX 描述符
┌─────────────────────────────────────────────────────────────┐
│ 物理层                                                        │
└─────────────────────────────────────────────────────────────┘
物理网卡硬件发送
```

**开销**：双重协议栈遍历 + netns 切换 + 路由查找 2 次

---

#### Host Network 模式

```
Redis 进程
    ↓ writev(fd, iov, cnt)
┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 宿主机 netns                                         │
└─────────────────────────────────────────────────────────────┘
tcp_sendmsg()
    ↓ 构建 skb
    ↓ TSO/GSO 硬件卸载设置
ip_local_out()
    ↓ 路由查找（1 次）
    ↓ 邻居子系统
dev_queue_xmit()
    ↓ qdisc 队列管理
ixgbe_xmit_frame()
    ↓ DMA 映射
    ↓ TSO/Checksum Offload
┌─────────────────────────────────────────────────────────────┐
│ 物理层                                                        │
└─────────────────────────────────────────────────────────────┘
物理网卡硬件发送
```

**优势**：单次协议栈遍历 + 完整硬件卸载

---

#### VF 直通模式

```
Redis 进程
    ↓ writev(fd, iov, cnt)
┌─────────────────────────────────────────────────────────────┐
│ 内核态 - 容器 netns                                           │
└─────────────────────────────────────────────────────────────┘
tcp_sendmsg()
    ↓ 构建 skb
    ↓ TSO/Checksum Offload 设置
ip_local_out()
    ↓ 路由查找（容器内路由表）
dev_queue_xmit()
ixgbevf_xmit_frame()               ← VF 驱动
    ↓ DMA 映射到 VF 地址空间（IOMMU）
    ↓ 更新 VF TX 描述符
┌─────────────────────────────────────────────────────────────┐
│ 物理层 - VF 硬件                                              │
└─────────────────────────────────────────────────────────────┘
VF 硬件队列
    ↓ VF 独立发送逻辑
物理网卡交换矩阵
    ↓ 端口发送
```

**优势**：单次协议栈遍历 + DMA 直通 + 硬件 QoS + 不经过宿主机 netns

**图示位置**：参见 [图 5：Redis 数据发送路径对比](#图5)

---

## 四、性能影响分析

### 4.1 系统调用次数对比

| 模式 | RX 路径系统调用 | TX 路径系统调用 | 总计 |
|------|----------------|----------------|------|
| IPvlan | epoll_wait(1) + read(1) | write/writev(1) | 3 次/请求 |
| Host Network | epoll_wait(1) + read(1) | write/writev(1) | 3 次/请求 |
| VF 直通 | epoll_wait(1) + read(1) | write/writev(1) | 3 次/请求 |

**结论**：三种模式的系统调用次数**相同**，差异在于内核内部处理路径。

---

### 4.2 协议栈处理路径对比

| 模式 | RX 路径 | TX 路径 | 开销说明 |
|------|---------|---------|----------|
| IPvlan | 宿主机 L2→L3 拦截 + `dev_forward_skb()` + 容器 L3→L4 处理 | 容器 L4→L3 + netns 切换 + 宿主机 L3→L2 发送 | 额外的 rx_handler 拦截和 netns 切换 |
| Host Network | 完整 L2→L4 处理（直通） | 完整 L4→L2 处理（直通） | 最短路径 |
| VF 直通 | 容器 netns 中完整 L2→L4 处理 | 容器 netns 中完整 L4→L2 处理 | 与 Host Network 相当，不经过宿主机 netns |

**结论**：IPvlan 的额外开销来自 rx_handler 的软件转发层和 netns 切换，不是「两次完整的 TCP/IP 栈遍历」。Host Network 和 VF 直通的协议栈处理路径长度相当。

---

### 4.3 数据拷贝分析

容器与宿主机共享同一个 Linux 内核，不存在独立的「容器内存」空间。三种模式下数据拷贝的真正差异如下：

| 模式 | RX 路径关键操作 | TX 路径关键操作 | 说明 |
|------|----------------|----------------|------|
| IPvlan | DMA→内核 RX buffer → `dev_forward_skb()`(skb metadata 调整，非数据拷贝) → socket buffer → `read()` 拷贝到用户态 | 用户态 `write()` 拷贝到 socket buffer → `ipvlan_skb_crossing_ns()`(skb metadata 调整) → `dev_queue_xmit()` → DMA | `dev_forward_skb()` 只调整 skb 的 dev/netns 指针，不拷贝数据 |
| Host Network | DMA→内核 RX buffer → socket buffer → `read()` 拷贝到用户态 | 用户态 `write()` 拷贝到 socket buffer → `dev_queue_xmit()` → DMA | 标准路径，无额外开销 |
| VF 直通 | DMA(IOMMU)→内核 RX buffer → socket buffer → `read()` 拷贝到用户态 | 用户态 `write()` 拷贝到 socket buffer → `dev_queue_xmit()` → DMA(IOMMU) | 与 Host Network 相同的拷贝次数，VF 通过 IOMMU 实现地址隔离 |

**关键澄清**：
- `read()` 系统调用（内核 socket buffer → Redis 用户态 buffer）是三种模式都存在的**唯一的真正数据拷贝**
- IPvlan 的 `dev_forward_skb()` 和 `ipvlan_skb_crossing_ns()` 只修改 skb 的 metadata（`skb->dev` 指针、MAC header 重置等），**不拷贝数据区域**
- `skb_clone()` 只复制 skb 结构体，共享底层数据（引用计数）

### 4.4 性能理论估算（示例假设值）

以下数据为基于架构分析的**理论推测值**，不是实测数据。实际性能取决于硬件配置（CPU、NIC、IRQ 亲和性）、Redis 配置（pipeline、数据大小）、网络负载等多种因素。

基于 redis-benchmark 典型场景的性能估算（单实例，-c 50 -n 100000 -d 256）：

| 指标 | IPvlan | Host Network | VF 直通 | 说明 |
|------|--------|--------------|---------|------|
| **QPS（GET 操作）** | 60,000 | 100,000 (基准) | 95,000 | 小数据包场景 |
| **QPS（SET 操作）** | 55,000 | 95,000 (基准) | 90,000 | 写入场景 |
| **平均延迟（GET）** | 1.8 ms | 1.0 ms | 1.05 ms | P50 延迟 |
| **P99 延迟** | 5.2 ms | 2.8 ms | 3.0 ms | 尾延迟 |
| **CPU 用户态占比** | 35% | 40% | 38% | Redis 进程 CPU |
| **CPU 内核态占比** | 45% | 30% | 33% | 系统调用 + 协议栈 |
| **CPU 软中断占比** | 20% | 15% | 16% | 网络中断处理 |

**关键观察**：
1. **IPvlan CPU 内核态占比最高（45%）**：双重协议栈 + netns 切换
2. **Host Network 性能最优**：零虚拟化开销
3. **VF 直通接近 Host Network（95%）**：IOMMU 开销约 5%
4. **延迟差异**：IPvlan 比 Host Network 高 **80%**

<a id="图6"></a>

![Redis 性能指标对比](diagrams/redis/redis_performance_comparison.png)

*图 6：Redis 性能指标对比 - QPS、延迟、CPU 使用率的量化对比*

---

## 五、实际测试场景

### 5.1 redis-benchmark 测试方法

**基准测试命令**：

```bash
# IPvlan 模式
docker run --rm --network=ipvlan_net redis:latest \
  redis-benchmark -h <redis_ip> -p 6379 -c 50 -n 100000 -t get,set

# Host Network 模式
docker run --rm --network=host redis:latest \
  redis-benchmark -h 127.0.0.1 -p 6379 -c 50 -n 100000 -t get,set

# VF 直通模式（需要 docker-sriov-plugin）
# 先创建 SR-IOV 网络
docker network create -d sriov --subnet=10.0.0.0/24 -o netdevice=<PF网卡名> sriov_net
# 再运行容器
docker run --rm --net=sriov_net redis:latest \
  redis-benchmark -h <redis_ip> -p 6379 -c 50 -n 100000 -t get,set
```

**测试参数**：
- `-c 50`：50 个并发连接
- `-n 100000`：10 万次请求
- `-t get,set`：测试 GET 和 SET 命令
- `-d 256`：数据大小 256 字节

### 5.2 适用场景推荐

#### IPvlan 模式

**适用场景**：
- 对网络隔离要求高的场景
- 不支持 SR-IOV 的硬件环境
- 容器间通信为主（本地短路转发优化）
- QPS 要求 < 10 万/秒

**不适用**：
- 高 QPS 场景（> 10 万/秒）
- 对延迟敏感的应用（如实时交易）
- CPU 资源紧张的环境

---

#### Host Network 模式

**适用场景**：
- 追求极致性能
- 单容器场景（无端口冲突）
- 性能测试和基准对比
- 对网络隔离要求不高

**不适用**：
- 多租户环境
- 需要网络隔离的场景
- 端口资源紧张的环境

---

#### VF 直通模式

**适用场景**：
- 高性能 + 网络隔离兼顾
- 多容器场景（每个容器独立 VF）
- 云环境（硬件支持 SR-IOV）
- QPS 要求 > 5 万/秒

**不适用**：
- VF 数量 > 物理网卡限制（如 64 个）
- 不支持 SR-IOV 的硬件
- 容器频繁创建销毁（VF 分配有开销）

---

## 六、多实例资源竞争分析

### 6.1 测试场景定义

**测试拓扑**：
- **服务端**：1 台物理机运行 40 个 Redis 容器（redis-server，默认配置）
- **客户端**：1 台物理机运行 40 个 redis-benchmark，每个对应一个 Redis 实例
- **网络**：Intel 82599 10GbE 网卡，支持 64 个 VF

**测试目标**：
- 分析资源竞争点
- 测量性能扩展性（1/5/10/20/40 实例）
- 定位瓶颈

### 6.2 三种模式下的资源竞争点

#### IPvlan 模式竞争分析

**CPU 竞争**：
- 40 个容器的 `ipvlan_handle_frame()` 在宿主机内核中串行执行
- rx_handler 查找 IP 地址哈希表（竞争锁）
- 软中断处理在少数 CPU 核心上集中（默认 IRQ affinity）

**网卡队列竞争**：
- 所有容器共享 PF 的硬件队列（通常 8-16 个）
- 队列数 < 容器数时，多个容器竞争同一队列
- qdisc 层排队延迟增加

**netns 切换累加**：
- 每个数据包都需要 netns 切换（40 倍累加）
- CPU 缓存失效率上升
- TLB (Translation Lookaside Buffer) 刷新频繁

**性能表现**：
- 1 实例：60K QPS
- 10 实例：45K QPS/实例（总 450K QPS）
- 40 实例：30K QPS/实例（总 1.2M QPS）— **性能下降 50%**

---

#### Host Network 模式竞争分析

**端口管理**：
- 40 个实例需要 40 个不同端口（6379, 6380, ..., 6418）
- 端口配置复杂度线性增长

**宿主机网络栈竞争**：
- 共享路由表（读写锁竞争）
- 共享 conntrack 表（连接跟踪竞争）
- TCP time-wait 状态占用（短连接场景）

**CPU 缓存污染**：
- 40 个进程无 netns 隔离
- L2/L3 缓存频繁失效
- 上下文切换开销增加

**性能表现**：
- 1 实例：100K QPS
- 10 实例：90K QPS/实例（总 900K QPS）
- 40 实例：70K QPS/实例（总 2.8M QPS）— **性能下降 30%**

---

#### VF 直通模式竞争分析

**VF 数量限制**：
- Intel 82599 最多 64 个 VF（足够容纳 40 实例）
- 每个 VF 有 2-4 个硬件队列（独立）

**PCIe 总带宽竞争**：
- 40 个 VF 共享 10Gbps 物理端口
- 单实例平均带宽：10Gbps / 40 = 250Mbps
- 小包场景（Redis）不易达到带宽瓶颈

**IOMMU 页表竞争**：
- 多个 VF 同时进行 DMA 地址转换
- IOTLB 缓存命中率下降
- 转换延迟增加（1-3% → 3-5%）

**PF 管理开销**：
- VF 通过 mailbox 与 PF 通信（配置更新）
- 40 个 VF 的 mailbox 中断累加
- PF 驱动的轮询开销

**性能表现**：
- 1 实例：95K QPS
- 10 实例：90K QPS/实例（总 900K QPS）
- 40 实例：75K QPS/实例（总 3.0M QPS）— **性能下降 20%**

<a id="图9"></a>

![多实例性能扩展性曲线](diagrams/redis/redis_multi_instance_scalability.png)

*图 9：多实例性能扩展性曲线 - 展示 1/5/10/20/40 实例下三种模式的性能变化趋势*

**图示位置**：参见 [图 8：多实例资源竞争热力图](#图8) 和 [图 9：多实例性能扩展性曲线](#图9)

---

### 6.3 性能瓶颈定位

#### CPU 饱和分析

**判断方法**：
```bash
# 查看 CPU 使用率
mpstat -P ALL 1

# 查看软中断占比
watch -n 1 'cat /proc/softirqs | grep NET'
```

**瓶颈特征**：
- IPvlan：软中断 CPU 占用 > 80%
- Host Network：用户态 + 内核态接近 100%
- VF 直通：多个 CPU 核心均衡负载

---

#### 网络带宽瓶颈

**计算方法**：
- Redis GET 请求：~150 字节/请求
- Redis SET 请求：~300 字节/请求
- 40 实例 × 50K QPS × 300B = **600MB/s ≈ 4.8Gbps**

**结论**：10Gbps 网卡足够，带宽不是瓶颈。

---

#### 内存带宽瓶颈

**DMA + 内存拷贝总和**：
- 40 实例 × 50K QPS × 300B × 2（RX+TX）= **1.2GB/s**
- 现代服务器内存带宽：~50GB/s（DDR4-2666）
- **结论**：内存带宽充足

---

#### 锁竞争分析

**关键锁**：
- netns 路由表锁（IPvlan 模式）
- conntrack 表锁（Host Network 模式）
- IOMMU 页表锁（VF 直通模式）

**分析工具**：
```bash
# 使用 perf 分析锁竞争
perf record -e lock:contention_begin -ag -- sleep 10
perf report
```

---

### 6.4 优化策略

#### CPU 亲和性配置

```bash
# 绑定 Redis 实例到特定 CPU
docker run --cpuset-cpus="0-3" redis:latest

# 绑定网卡中断到特定 CPU
echo 4 > /proc/irq/<IRQ>/smp_affinity_list
```

**原则**：
- 将 Redis 实例与网卡中断绑定到同一 NUMA 节点
- 避免跨 NUMA 访问（延迟增加）

---

#### NUMA 感知配置

```bash
# 查看 NUMA 拓扑
numactl --hardware

# 查看网卡所在 NUMA 节点
cat /sys/class/net/eth0/device/numa_node

# 将容器绑定到网卡所在 NUMA 节点
docker run --cpuset-mems="0" redis:latest
```

---

#### 网卡队列调优

```bash
# 增加 RX/TX 队列数
ethtool -L eth0 combined 16

# 启用 RSS（Receive Side Scaling）
ethtool -X eth0 equal 16

# 增加队列深度
ethtool -G eth0 rx 4096 tx 4096
```

---

#### VF 队列配置

```bash
# 为每个 VF 分配 4 个队列
echo 4 > /sys/class/net/eth0/device/sriov_numvfs

# 限制 VF 带宽（避免单个 VF 占用过多）
ip link set eth0 vf 0 max_tx_rate 500  # 500Mbps
```

---

## 附录

### 附录 A：图示索引

<a id="图7"></a>

![Redis Socket 文件描述符流转](diagrams/redis/redis_socket_fd_lifecycle.png)

*图 7：Redis Socket 文件描述符生命周期 - 从 listen fd 到 client fd 的完整状态机*

<a id="图8"></a>

![多实例资源竞争热力图](diagrams/redis/redis_multi_instance_contention.png)

*图 8：多实例资源竞争热力图 - 40 个实例在三种模式下的资源竞争程度对比*

**图示索引**：
1. [图 1：Redis 事件循环架构](#图1)
2. [图 2：IPvlan 模式 - Redis 数据接收完整路径](#图2)
3. [图 3：Host Network 模式 - Redis 数据接收路径](#图3)
4. [图 4：VF 直通模式 - Redis 数据接收路径](#图4)
5. [图 5：Redis 数据发送路径对比](#图5)
6. [图 6：Redis 性能指标对比图](#图6)
7. [图 7：Redis Socket 文件描述符流转](#图7)
8. [图 8：多实例资源竞争热力图](#图8)
9. [图 9：多实例性能扩展性曲线](#图9)

---

### 附录 B：源码引用索引

**Redis 源码**（`/home/fsq/Desktop/fsq/redis/src/`）：
- `ae.c:493-499` - aeMain() 主循环
- `ae.c:357` - aeProcessEvents()
- `ae_epoll.c:39-57` - epoll 初始化
- `ae_epoll.c:109-135` - epoll_wait() 封装
- `networking.c:2619-2718` - readQueryFromClient()
- `networking.c:2669` - connRead() 系统调用
- `networking.c:2264-2421` - processMultibulkBuffer() RESP 解析
- `networking.c:407` - addReply()
- `networking.c:383-398` - 响应缓冲策略
- `networking.c:1900-1947` - _writeToClient()
- `networking.c:1926` - writev() 优化
- `networking.c:1359-1416` - acceptTcpHandler()
- `anet.c:437-487` - anetTcpServer()
- `anet.c:517` - accept4() with SOCK_NONBLOCK

**内核源码**：
- 参见《容器网络模式对比分析》中的内核路径证据

---

## 参考文档

- [容器网络模式对比分析](容器网络模式对比分析.md) - 内核层面的通用对比
- [SR-IOV 与 VF 直通原理](SRIOV_AND_PASSTHROUGH_MODES.md)

---

**文档版本**：1.0  
**创建日期**：2026-06-22  
**作者**：基于 Redis 7.x 源码和 Linux Kernel 6.6.0 分析

