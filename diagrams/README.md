# 容器网络模式对比分析 - 图示索引

本文档配套图示说明。

## 图示列表

### 图 1：三种网络模式处理路径对比
**文件**: `network_modes_comparison.drawio.png` / `.svg`

**内容**: 并排对比 IPvlan、Host Network、VF 直通三种模式的完整数据包处理路径

**关键要点**:
- IPvlan：双重协议栈遍历（宿主机 + 容器）、netns 切换开销
- Host Network：零虚拟化开销、最短路径、完整硬件卸载
- VF 直通：硬件级隔离、DMA 直通、不经过宿主机 netns

**引用位置**: 主文档第二章开头

---

### 图 2：SR-IOV 硬件架构详解
**文件**: `sriov_hardware_architecture.drawio.png` / `.svg`

**内容**: 展示物理网卡中 PF 与多个 VF 的硬件关系

**关键要点**:
- 每个 VF 有独立的 BDF (Bus/Device/Function)
- 独立的硬件队列（TX/RX 描述符环）
- 独立的 MSI-X 中断向量
- 独立的 MAC 地址和 VLAN 过滤
- PF 通过硬件寄存器管理 VF 资源
- 所有 VF 和 PF 共享物理端口，通过硬件调度器公平分配 PCIe 带宽

**引用位置**: 主文档第四章 4.2 节

---

### 图 3：VF vs PF 性能对比
**文件**: `vf_performance_comparison.drawio.png` / `.svg`

**内容**: 柱状图展示 Intel 82599 网卡的 VF 与 PF 实测性能数据

**测试场景**:
1. 单核单队列 64B 小包：VF 达 PF 的 96.8%
2. 多核 4 队列 1500B 标准包：VF 达 PF 的 99.0%
3. 多核 4 队列 9000B 巨帧：VF 达 PF 的 99.0%
4. 延迟测试（ping RTT）：VF 16µs vs PF 15µs（+6.7%）

**结论**:
- VF 吞吐量可达 PF 的 95-99%
- IOMMU 开销仅 1-3%（延迟 +1µs）
- 在多核多队列场景下，VF 性能接近物理机

**引用位置**: 主文档第四章 4.4 节

---

## 文件格式说明

### PNG 格式
- **预览版**: `*.png` - 用于快速查看
- **可编辑版**: `*.drawio.png` - 包含嵌入的 XML，可在 draw.io 中重新编辑

### SVG 格式
- `*.svg` - 矢量图格式，缩放不失真，同样嵌入了可编辑的 XML

### 源文件
- `*.drawio` - draw.io 原始文件，用于后续修改

---

## 如何编辑图示

### 方法 1：draw.io 桌面版
```bash
# macOS
open network_modes_comparison.drawio

# Linux
drawio network_modes_comparison.drawio

# Windows
start network_modes_comparison.drawio
```

### 方法 2：在线编辑
1. 访问 https://app.diagrams.net/
2. 打开 `*.drawio.png` 或 `*.drawio.svg`（嵌入式版本）
3. 编辑后导出为 PNG/SVG

### 方法 3：命令行导出
```bash
# 导出 PNG（2倍分辨率，嵌入 XML）
drawio -x -f png -e -s 2 -o output.drawio.png input.drawio

# 导出 SVG（嵌入 XML）
drawio -x -f svg -e -o output.svg input.drawio

# 修复嵌入式 PNG（draw.io CLI bug）
python3 /path/to/repair_png.py output.drawio.png
```

---

## 图示设计原则

### 颜色编码
- **蓝色 (#dae8fc)**: 容器组件（应用、协议栈）
- **紫色 (#e1d5e7)**: 宿主机组件（宿主机协议栈）
- **黄色 (#fff2cc)**: 虚拟化层（IPvlan 虚拟网卡、netns 切换）
- **橙色 (#ffe6cc)**: VF 驱动
- **绿色 (#d5e8d4)**: 硬件（物理网卡、VF 硬件队列）
- **红色 (#f8cecc)**: 性能瓶颈节点（netns 切换、IOMMU）

### 图例说明
- **实线箭头**: TX 发送路径
- **虚线箭头**: RX 接收路径
- **虚线边框**: netns 边界

---

## 技术栈

**绘图工具**: draw.io (diagrams.net)  
**导出引擎**: draw.io Desktop CLI  
**源码版本**: Linux Kernel 6.6.0  
**参考网卡**: Intel 82599 / X710, ixgbe/ixgbevf 驱动  

---

**文档版本**: 1.0  
**更新日期**: 2026-06-22  
