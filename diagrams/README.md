# 图示索引

本目录包含了《Linux 内核网络知识汇编》文档的配套图示。所有图示均使用 draw.io 创建，包含可编辑的 `.drawio` 源文件和 PNG 导出文件。

## 图示列表

### 1. NAPI 机制相关

#### 1.1 NAPI 三种模式对比
- **文件**: `napi-three-modes.drawio.png`
- **源文件**: `napi-three-modes.drawio`
- **说明**: 对比 Docker IPvlan、Host Network、VF 直通三种模式下的 NAPI 架构，展示 NAPI 实例归属、Budget 配置和隔离机制
- **文档引用**: 内核网络知识.md § 1.6

#### 1.2 NAPI 状态机
- **文件**: `napi-state-machine.drawio.png`
- **源文件**: `napi-state-machine.drawio`
- **说明**: 展示 NAPI 从 IDLE → SCHED → POLL → COMPLETE 的完整状态转换流程，包括中断处理、软中断调度和 budget 判断逻辑
- **文档引用**: 内核网络知识.md § 1.4

### 2. 网络协议栈

#### 2.1 RX 路径（接收数据包）
- **文件**: `rx-path.drawio.png`
- **源文件**: `rx-path.drawio`
- **说明**: 完整的数据包接收路径，从硬件 DMA、硬中断处理、NAPI poll、协议栈处理到应用层读取，展示各层次的关键函数调用
- **文档引用**: 内核网络知识.md § 3.1

### 3. skb 数据结构

#### 3.1 skb 结构与内存布局
- **文件**: `skb-structure.drawio.png`
- **源文件**: `skb-structure.drawio`
- **说明**: 展示 `struct sk_buff` 的关键字段（指针、元数据）和内存布局（headroom、data、tailroom），以及 IPvlan 如何通过修改 metadata 实现零拷贝转发
- **文档引用**: 内核网络知识.md § 2.3

### 4. IPvlan 机制

#### 4.1 IPvlan rx_handler 数据包分发流程
- **文件**: `ipvlan-rx-handler.drawio.png`
- **源文件**: `ipvlan-rx-handler.drawio`
- **说明**: 详细展示 IPvlan 的 rx_handler 如何在协议栈入口拦截数据包、根据模式（L2/L3/L3S）查找目标设备、修改 skb 元数据并切换 netns
- **文档引用**: 内核网络知识.md § 4.1

### 5. SR-IOV 硬件架构（已存在）

#### 5.1 SR-IOV 硬件架构
- **文件**: `sriov_hardware_architecture.drawio.png`
- **说明**: SR-IOV PF/VF 硬件架构图

#### 5.2 网络模式对比
- **文件**: `network_modes_comparison.drawio.png`
- **说明**: 三种网络模式的整体对比

#### 5.3 VF 性能对比
- **文件**: `vf_performance_comparison.drawio.png`
- **说明**: VF 直通模式的性能优势

## 使用说明

### 查看图示
所有 `.drawio.png` 文件可以直接在图片查看器中打开，这些文件嵌入了完整的 draw.io XML，可以在 draw.io 中打开并编辑。

### 编辑图示
1. 使用 draw.io 桌面版打开 `.drawio` 或 `.drawio.png` 文件
2. 编辑后保存为 `.drawio` 格式
3. 导出为 PNG：
   ```bash
   drawio -x -f png -e -s 2 -o <输出文件>.drawio.png <输入文件>.drawio
   ```

### 导出命令示例
```bash
# 导出单个图示（嵌入 XML，2倍缩放）
drawio -x -f png -e -s 2 -o napi-three-modes.drawio.png napi-three-modes.drawio

# 批量导出所有图示
for file in *.drawio; do
  drawio -x -f png -e -s 2 -o "${file%.drawio}.drawio.png" "$file"
done
```

## 图示设计规范

### 颜色方案
- **蓝色** (#dae8fc / #6c8ebf): 硬件设备、核心组件
- **黄色** (#fff2cc / #d6b656): NAPI 实例、中间处理
- **绿色** (#d5e8d4 / #82b366): 容器、成功状态
- **橙色** (#ffe6cc / #d79b00): 关键路径、IPvlan 特有机制
- **紫色** (#e1d5e7 / #9673a6): 系统级资源、per-CPU 结构
- **红色** (#f8cecc / #b85450): 决策点、瓶颈提示

### 布局原则
- 自顶向下流程：硬件 → 驱动 → 协议栈 → 应用
- 使用泳道（swimlane）区分不同的执行上下文（硬中断、软中断、应用层）
- 使用动画箭头（`flowAnimation=1`）标识数据流动路径
- 关键概念使用加粗文本和高亮颜色

## 版本历史

- **v1.0** (2026-06-24): 初始版本，包含 NAPI、协议栈、skb、IPvlan 相关图示
- 新增 5 个核心图示，覆盖文档的主要技术点

## 相关文档

- 主文档: `../内核网络知识.md`
- 对比分析: `../容器网络模式对比分析.md`
- Redis 实战: `../Redis容器网络模式数据流分析.md`
