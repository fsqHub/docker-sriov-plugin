#!/bin/bash
# redis-server-whole-rss-xps.sh
# 配置 Redis 容器的网卡 RSS/XPS 软中断亲和性
# 确保每个容器实例的网卡中断均匀分配到不同 CPU 核心

# ========== 配置参数 ==========
# 网卡所属的 NUMA 节点（影响 CPU 核心选择范围）
NIC_NUMA=1
# 目标网卡设备名
NIC="enp24s0f1np1"
# 新增：每个客户端实例占用的CPU核心数
CLIENT_CPUS=8
# 网卡 PCI 地址（用于查找对应的中断号）
# NIC_PCI="0000:18:00.1" # 不需要
# 定义服务端服务器ip
serverid=141.61.10.5
# # Redis 容器名称前缀（用于筛选目标容器）
# CONTAINER_PREFIX="redis-docker-ipvlan"
# # Redis 安装目录（存放 iplist.txt）
REDIS_DIR="/home/fsq/redis-7.0.15"
# IP 列表文件路径（每行一个容器 IP）
IPLIST_FILE="$REDIS_DIR/iplist.txt"

# 脚本和配置输出目录
BASE_DIR="/home/fsq/redis-test"
# 网卡多队列绑定脚本路径
RSS_XSS_SCRIPT="$BASE_DIR/bind-ip-multi-queue-cpu.sh"
# 生成的 IP-QUEUE-CPU 映射配置文件
RSS_XSS_CONFIG="$BASE_DIR/ip-queue-cpus.txt"  # client端文件要重新生成，逻辑不一样

# ========== 核心函数 ==========
# rrs_xps_bind - 计算并配置每个容器的网卡中断亲和性
# 使用方式：
#   1. 确保 iplist.txt 中包含所有容器 IP（每行一个）
#   2. 确保容器名称以 $CONTAINER_PREFIX- 开头
#   3. 直接执行脚本：bash redis-server-whole-rss-xps.sh
#   4. 或在其他脚本中调用函数：rrs_xps_bind
rrs_xps_bind() {

    systemctl stop irqbalance
    
    # 通过SSH读取远程文件到本地数组
	mapfile -t IP_ARRAY < <(ssh root@$serverid "cat $IPLIST_FILE")
    # 统计符合条件的容器数量
    local ins_num=${#IP_ARRAY[@]}
    if [[ -z "$ins_num" ]];then
        echo "未在Server侧 ${IPLIST_FILE}中读取到IP"
    fi
    
    # 清空旧配置文件
    rm -rf $RSS_XSS_CONFIG

    local index=0
    local container_ip=""
    local container_irq_queue=0
    local bind_cpu=0
    ethtool -L $NIC combined 127 

    echo "开始计算 IP QUEUE CPU(s) 列表..."
    
    # 遍历每个容器，计算其应绑定的 CPU 核心
    for ((index = 0; index < $ins_num; index++)); do
        container_ip="${IP_ARRAY[$index]}"
        # container_irq_queue="${irq[$index]}"
        container_irq_queue="$((index * 2 + 1)),$((index * 2 + 2))" # 直接按顺序分配 queue，从1开始
        
        # 根据模式判断核的起始位置和NUMAID
		if [[ "$ins_num" == 1 ]]; then
			NUMAID=$NIC_NUMA
			cpus_start=$(($NUMAID * 80))
			cpus_end=$((cpus_start + CLIENT_CPUS - 1))
		else
			# multi模式下从0开始分配
			cpus_start=$((index * 8))
			cpus_end=$((cpus_start + CLIENT_CPUS - 1))
			# 根据 CPU 核心号算出归属的 NUMA 节点（0-79为numa0，80-159为numa1）
			NUMAID=$((cpus_start / 80))
		fi
        bind_cpu=$(printf "%d-%d" $cpus_start $cpus_end)
        
        # 输出配置到文件并打印
        echo "$container_ip $container_irq_queue $bind_cpu" | tee -a $RSS_XSS_CONFIG
    done
    echo "所有IP QUEUE CPU(s) 列表计算完成"
    # 根据参数决定是否执行 dry-run 模式
    if [[ "$1" == "--dry-run" ]]; then
        bash $RSS_XSS_SCRIPT --dev $NIC --config $RSS_XSS_CONFIG --mode client --dry-run
    else
        bash $RSS_XSS_SCRIPT --dev $NIC --config $RSS_XSS_CONFIG --mode client
    fi
}

# 直接执行函数（如作为独立脚本使用）
# 用法：bash redis-server-whole-rss-xps.sh [--dry-run]
rrs_xps_bind "$@"