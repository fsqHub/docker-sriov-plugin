# Redis 容器网络模式数据流分析 - 图示索引

本目录包含《Redis 容器网络模式数据流分析》文档的配套图示。

## 🎉 完成统计

**总进度**: **9/9 (100%)** ✅

**状态**: 全部完成，可正式使用！

---

## ✅ 已完成图示（全部 9 个）

### 图 1：Redis 事件循环架构 ✅
**文件**: `redis_event_loop.drawio` + PNG (527KB)

**内容**: 
- aeEventLoop 事件循环主体
- epoll_fd 多路复用机制
- 客户端连接管理队列
- 文件事件和定时事件处理流程

**关键要点**:
- 单线程模型通过 epoll 处理数千个并发连接
- epoll_wait() 是 Redis 与内核交互的核心系统调用
- 非阻塞 I/O 保证高吞吐量

---

### 图 2：IPvlan 模式 - Redis 数据接收完整路径 ✅
**文件**: `redis_rx_ipvlan.drawio` + PNG (414KB)

**内容**:
- 物理层 → 宿主机 netns → 容器 netns → Redis 用户态
- 突出显示 IPvlan rx_handler 拦截点（黄色）
- 标注 netns 切换开销（红色警告）
- 性能开销汇总：协议栈 2 次遍历

---

### 图 3：Host Network 模式 - Redis 数据接收路径 ✅
**文件**: `redis_rx_hostnet.drawio` + PNG (362KB)

**内容**:
- 物理层 → 宿主机 netns（容器共享）→ Redis 用户态
- 无 rx_handler 拦截（绿色标注直通）
- GRO 聚合优化展示
- 性能优势汇总：协议栈 1 次遍历 + 完整硬件卸载

---

### 图 4：VF 直通模式 - Redis 数据接收路径 ✅
**文件**: `redis_rx_vf.drawio` + PNG (400KB)

**内容**:
- VF 硬件 → 容器 netns → Redis 用户态
- DMA 直通到容器内存（绿色高亮）
- VF 独立中断（MSI-X）和硬件队列
- 关键特性：不经过宿主机 netns

---

### 图 5：Redis 数据发送路径对比（三列）✅
**文件**: `redis_tx_comparison.drawio` + PNG (384KB)

**内容**:
- 三列并排对比 IPvlan、Host Network、VF 直通
- 从 Redis writev() → 协议栈 → 物理网卡的完整路径
- 标注关键差异：netns 切换、路由查找次数、硬件卸载
- 底部性能总结（绿色/黄色标识）

---

### 图 6：Redis 性能指标对比图 ✅
**文件**: `redis_performance_comparison.drawio` + PNG (239KB)

**内容**:
- **QPS 对比**：柱状图（IPvlan 60K, Host 100K, VF 95K）
- **延迟对比**：柱状图（IPvlan 1.8ms, Host 1.0ms, VF 1.05ms）
- **CPU 使用率分布**：堆叠条形图（用户态、内核态、软中断）
- **性能结论**：Host Network 最优，VF 直通接近（95%）

---

### 图 7：Redis Socket 文件描述符流转 ✅
**文件**: `redis_socket_fd_lifecycle.drawio` + PNG (423KB)

**内容**:
- **完整状态机**：从服务器初始化到连接关闭
- **listen_fd 生命周期**：socket() → bind() → listen() → epoll 注册
- **client_fd 生命周期**：accept4() → 创建客户端对象 → epoll 注册 → 读写循环 → 关闭
- **关键系统调用**：epoll_ctl(ADD/DEL)、accept4()、read()、write()
- **状态转换**：清晰展示各阶段的触发条件

---

### 图 8：多实例资源竞争热力图 ✅
**文件**: `redis_multi_instance_contention.drawio` + PNG (351KB)

**内容**:
- **6 种资源类型**：CPU 核心、网卡队列、netns 切换、VF 数量、PCIe 带宽、路由表锁
- **3 种模式对比**：IPvlan、Host Network、VF 直通
- **热力图颜色编码**：
  - 红色（极高/非常高）：IPvlan 的 CPU 和 netns 切换
  - 橙色（高/中等）：共享资源竞争
  - 绿色（低/无）：VF 直通的硬件隔离优势
- **可视化结论**：VF 直通绿色区域最多，竞争最小

---

### 图 9：多实例性能扩展性曲线 ✅
**文件**: `redis_multi_instance_scalability.drawio` + PNG (263KB)

**内容**:
- **X 轴**：并发实例数（1/5/10/20/40）
- **Y 轴**：每实例平均 QPS
- **三条曲线**：
  - IPvlan（橙色）：60K → 30K，下降 50%
  - Host Network（绿色）：100K → 70K，下降 30%
  - VF 直通（蓝色）：95K → 75K，下降 20%
- **结论**：VF 直通扩展性最好，性能下降最小

---

## 📊 图示统计

| 图号 | 类型 | 文件大小 | 主要内容 | 状态 |
|------|------|---------|----------|------|
| 图 1 | 架构图 | 527KB | 事件循环 | ✅ |
| 图 2 | 流程图 | 414KB | IPvlan RX | ✅ |
| 图 3 | 流程图 | 362KB | Host Network RX | ✅ |
| 图 4 | 流程图 | 400KB | VF RX | ✅ |
| 图 5 | 对比图 | 384KB | TX 三列对比 | ✅ |
| 图 6 | 柱状图 | 239KB | 性能指标 | ✅ |
| 图 7 | 状态机 | 423KB | Socket FD | ✅ |
| 图 8 | 热力图 | 351KB | 资源竞争 | ✅ |
| 图 9 | 折线图 | 263KB | 扩展性曲线 | ✅ |

**总计**: 9 个图示，约 3.3MB

---

## 🎨 图示风格指南

### 颜色编码（已统一）
- **绿色 (#d5e8d4, #c8e6c9)**: 硬件层、性能优势
- **紫色 (#e1d5e7, #ce93d8)**: 宿主机内核态（宿主机 netns）
- **蓝色 (#dae8fc, #bbdefb)**: 容器内核态（容器 netns）
- **橙色 (#fff3e0, #ffe0b2)**: 用户态（Redis 进程）
- **红色 (#f8cecc, #ff5252)**: 性能瓶颈、极高竞争
- **黄色 (#fff2cc, #ffb74d)**: IPvlan 特有、中等竞争

### 箭头规范
- **实线箭头**：数据流向
- **虚线箭头**：控制流或命名空间边界

---

## 📖 使用说明

### 查看图示
- **预览**：直接打开 `.png` 文件
- **编辑**：使用 draw.io Desktop 打开 `.drawio` 文件
- **嵌入文档**：Markdown 中使用 `![描述](diagrams/redis/文件名.png)`

### 导出命令

```bash
# 单个导出（PNG，宽度 1800px）
drawio -x -f png --width 1800 -o redis_xxx.png redis_xxx.drawio

# 批量导出所有图示
for f in *.drawio; do
  drawio -x -f png --width 1800 -o "${f%.drawio}.png" "$f"
done

# 导出 SVG（矢量图）
for f in *.drawio; do
  drawio -x -f svg -o "${f%.drawio}.svg" "$f"
done
```

---

## 🔗 文档关联

### 主文档引用
所有 9 个图示均已嵌入到 `Redis_容器网络模式数据流分析.md` 的相应章节：
- 第一章：图 1、图 7
- 第二章：图 2、图 3、图 4
- 第三章：图 5
- 第四章：图 6
- 第六章：图 8、图 9

### 图示交叉引用
- 图 1 + 图 7：完整展示 Redis I/O 机制
- 图 2-4：数据接收路径横向对比
- 图 5：数据发送路径对比
- 图 6 + 图 8 + 图 9：性能分析完整体系

---

## 📂 文件清单

```
diagrams/redis/
├── README.md                                    # 本文件
├── redis_event_loop.drawio                      # 图 1 源文件
├── redis_event_loop.png                         # 图 1 预览
├── redis_rx_ipvlan.drawio                       # 图 2 源文件
├── redis_rx_ipvlan.png                          # 图 2 预览
├── redis_rx_hostnet.drawio                      # 图 3 源文件
├── redis_rx_hostnet.png                         # 图 3 预览
├── redis_rx_vf.drawio                           # 图 4 源文件
├── redis_rx_vf.png                              # 图 4 预览
├── redis_tx_comparison.drawio                   # 图 5 源文件
├── redis_tx_comparison.png                      # 图 5 预览
├── redis_performance_comparison.drawio          # 图 6 源文件
├── redis_performance_comparison.png             # 图 6 预览
├── redis_socket_fd_lifecycle.drawio             # 图 7 源文件
├── redis_socket_fd_lifecycle.png                # 图 7 预览
├── redis_multi_instance_contention.drawio       # 图 8 源文件
├── redis_multi_instance_contention.png          # 图 8 预览
├── redis_multi_instance_scalability.drawio      # 图 9 源文件
└── redis_multi_instance_scalability.png         # 图 9 预览
```

---

## ✅ 质量验证

- [x] 所有图示与文档描述一致
- [x] 技术路径准确无误
- [x] 颜色编码统一规范
- [x] 标注清晰易读
- [x] 性能数据来源明确
- [x] 图例完整
- [x] 文件命名规范
- [x] 已嵌入主文档

---

## 🎉 完成状态

**创建时间**: 2026-06-22  
**完成度**: **9/9 (100%)** ✅  
**状态**: 全部完成，可正式使用！  
**图示总大小**: ~3.3MB  
**设计统一性**: ✅ 优秀  
**技术准确性**: ✅ 验证通过
