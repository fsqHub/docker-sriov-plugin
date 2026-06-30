#!/bin/bash

set -euo pipefail

# 在帮助信息中使用实际调用时的文件名，避免脚本被复制或重命名后
# usage 仍显示旧名称。
SCRIPT_NAME=$(basename -- "$0")

# 默认配置完整的 CPU 局部性闭环：
# RX：dst-ip -> RX queue -> IRQ CPU；TX：src-ip -> TX queue -> XPS CPU。
#
# 这些配置主要是运行态状态，不应视为网卡 down/up 后仍然稳定存在：
# - RX ntuple/flow director 规则由驱动和硬件规则表维护，部分驱动会在
#   netdev close/open、reset、firmware reload 或 channel 重建后清空或重排。
# - IRQ affinity 依赖当前 IRQ/vector 编号，down/up 或重建 queue 后 IRQ 可能
#   重新分配；irqbalance 也可能在脚本运行后再次覆盖 affinity。
# - RPS/RFS/XPS 写入 sysfs/procfs，通常不是持久配置；queue 重建、系统
#   网络管理组件或 sysctl 配置重放都可能改变这些值。
# - tc clsact/filter 属于内核 qdisc/filter 状态，普通 carrier down/up 不一定
#   删除，但接口被网络管理器重建、qdisc 被替换或驱动 reset 后仍需复查。
#
# 因此生产环境建议把本脚本挂到接口 up、驱动 reload、channel 调整、容器
# IP 变更之后执行，并用脚本末尾的 verification hints 校验实际状态。
DRY_RUN=0
DO_RX=1
DO_TX=1

# RPS/RFS 是软件收包分发层，可能覆盖硬件 ntuple + IRQ affinity
# 建立的 CPU 局部性。因此只要配置 RX 侧，默认先关闭 RPS/RFS。
DISABLE_RPS=1

# ethtool ntuple 是常见的硬件 RX flow steering 用户态接口。
# 不是所有驱动都支持该特性；如果目标设备不支持，或该特性已由
# 外部系统管理，可以使用 --no-enable-ntuple 跳过开启动作。
ENABLE_NTUPLE=1
STRICT_IRQ=1
DEV=""
CONFIG_FILE=""

# 使用确定性的规则 ID，保证重复运行时覆盖同一批规则，而不是不断
# 追加重复规则。若同一设备上还有其他手工维护的 ethtool/tc 规则，
# 可通过 --location-base / --pref-base 调整起始编号。
LOCATION_BASE=1000
PREF_BASE=1000

RULES=()
IRQ_MAPS=()

# 内部保护：
# - 同一个 queue 只能映射到同一个 CPU，否则 IRQ affinity 和 XPS 会被
#   后续规则覆盖，最终结果依赖规则顺序。
# - 多个 IP 可以共享同一 queue，但必须共享同一个 CPU。
declare -A QUEUE_CPU_BY_QUEUE=()
declare -A IRQ_BOUND_BY_QUEUE=()
declare -A XPS_SET_BY_QUEUE=()

usage() {
	cat <<EOF
Usage:
  ./$SCRIPT_NAME --dev <netdev> --rule <ip:queue:cpu[:port]> [OPTIONS]
  ./$SCRIPT_NAME --dev <netdev> --config <file> [OPTIONS]

Bind IPv4 TCP traffic for selected IPs to specific RX/TX queues and CPUs on a
multi-queue netdev. The target device must support the features you enable,
typically ethtool ntuple for RX flow steering and tc flower/skbedit for TX
queue mapping.

For each rule, the script can:
  1. Disable RPS/RFS, unless --keep-rps is specified.
  2. Enable ethtool ntuple, unless --no-enable-ntuple is specified.
  3. Add/replace an RX ntuple rule: dst-ip[:dst-port] -> RX queue.
  4. Bind the RX queue IRQ to the requested CPU.
  5. Add/replace a tc egress rule: src-ip[:src-port] -> TX queue.
  6. Set XPS for the TX queue to the requested CPU.

Dependencies:
  Runtime: bash 4+, python3, awk, grep, sed
  Apply mode: root, ethtool, tc, sysctl(procps)
  Kernel/device: multi-queue netdev, ethtool ntuple support for RX steering,
                 tc flower/skbedit/clsact support for TX queue mapping,
                 writable /sys queue and /proc/irq affinity files
  Dry-run: does not require root, ethtool, tc, or sysctl

Options:
  --dev DEV                    Target netdev, e.g. enp23s0f1np1
  --rule IP:QUEUE:CPU[:PORT]   Add one mapping rule; can be repeated
  --config FILE                Read mapping rules from file
                               Format per line: IP QUEUE CPU [PORT]
                               Blank lines and lines starting with # are ignored
  --irq-map QUEUE:IRQ          Manually map a queue to an IRQ; can be repeated
                               Use this if automatic IRQ discovery is ambiguous
  --location-base N            Base location for ethtool ntuple rules (default: 1000)
  --pref-base N                Base pref for tc egress filters (default: 1000)
  --dry-run                    Print commands without executing
  --rx-only                    Configure RX side only
  --tx-only                    Configure TX side only
  --keep-rps                   Do not disable RPS/RFS
  --no-enable-ntuple           Do not run ethtool -K DEV ntuple on
  --allow-missing-irq          Continue if RX queue IRQ cannot be discovered
  -h, --help                   Show this help

Examples:
  ./$SCRIPT_NAME --dev enp23s0f1np1 --rule 10.0.0.11:5:18:6379 --dry-run

  ./$SCRIPT_NAME --dev enp23s0f1np1 --config ip-queue-cpu.txt

  cat ip-queue-cpu.txt
  # IP         QUEUE  CPU  PORT
  10.0.0.11   5      18   6379
  10.0.0.12   6      26   6379
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

warn() {
	echo "warning: $*" >&2
}

print_cmd() {
	printf '+'
	local arg
	for arg in "$@"; do
		printf ' %q' "$arg"
	done
	printf '\n'
}

run_cmd() {
	print_cmd "$@"
	if [ "$DRY_RUN" -eq 0 ]; then
		"$@"
	fi
}

run_shell() {
	local cmd="$1"
	printf '+ %s\n' "$cmd"
	if [ "$DRY_RUN" -eq 0 ]; then
		bash -c "$cmd"
	fi
}

require_root() {
	if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
		die "$SCRIPT_NAME must run as root; use --dry-run to inspect commands first"
	fi
}

require_tools() {
	local tools=(python3 awk grep sed)
	local tool

	# dry-run 应该能在未安装 ethtool/tc 的开发机上审查命令；
	# 只有真实修改系统配置时才强制要求这些工具存在。
	if [ "$DRY_RUN" -eq 0 ]; then
		tools+=(ethtool tc sysctl)
	fi

	for tool in "${tools[@]}"; do
		command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
	done
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--dev)
				shift
				DEV=${1:-}
				;;
			--rule)
				shift
				RULES+=("${1:-}")
				;;
			--config)
				shift
				CONFIG_FILE=${1:-}
				;;
			--irq-map)
				shift
				IRQ_MAPS+=("${1:-}")
				;;
			--location-base)
				shift
				LOCATION_BASE=${1:-}
				;;
			--pref-base)
				shift
				PREF_BASE=${1:-}
				;;
			--dry-run)
				DRY_RUN=1
				;;
			--rx-only)
				DO_RX=1
				DO_TX=0
				;;
			--tx-only)
				DO_RX=0
				DO_TX=1
				;;
			--keep-rps)
				DISABLE_RPS=0
				;;
			--no-enable-ntuple)
				ENABLE_NTUPLE=0
				;;
			--allow-missing-irq)
				STRICT_IRQ=0
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "unknown option: $1"
				;;
		esac
		shift
	done
}

validate_number() {
	local value="$1"
	local name="$2"
	[[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer: $value"
}

validate_ipv4() {
	local ip="$1"
	python3 - "$ip" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

normalize_rule() {
	local rule="$1"
	local ip queue cpu port

	# 命令行规则格式保持紧凑，便于重复传入多个 --rule：
	#   IP:QUEUE:CPU[:PORT]
	# 可选 PORT 会同时用于 RX dst-port 和 TX src-port。
	IFS=: read -r ip queue cpu port <<<"$rule"
	[ -n "${ip:-}" ] || die "invalid rule, missing IP: $rule"
	[ -n "${queue:-}" ] || die "invalid rule, missing queue: $rule"
	[ -n "${cpu:-}" ] || die "invalid rule, missing CPU: $rule"

	validate_ipv4 "$ip" || die "invalid IPv4 address in rule: $rule"
	validate_number "$queue" "queue"
	validate_number "$cpu" "cpu"
	if [ -n "${port:-}" ]; then
		validate_number "$port" "port"
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "port out of range in rule: $rule"
	fi

	printf '%s:%s:%s:%s\n' "$ip" "$queue" "$cpu" "${port:-}"
}

load_config_rules() {
	[ -z "$CONFIG_FILE" ] && return 0
	[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"

	local line ip queue cpu port
	while IFS= read -r line || [ -n "$line" ]; do
		# 配置文件使用空白分隔字段，便于对齐大量 IP/queue/CPU 表。
		# 支持行尾注释，方便记录实例名或用途。
		line=${line%%#*}
		# shellcheck disable=SC2086
		set -- $line
		[ $# -eq 0 ] && continue
		[ $# -ge 3 ] || die "invalid config line, expected: IP QUEUE CPU [PORT]; got: $line"
		ip=$1
		queue=$2
		cpu=$3
		port=${4:-}
		RULES+=("$ip:$queue:$cpu:$port")
	done <"$CONFIG_FILE"
}

cpu_to_mask() {
	local cpu="$1"
	python3 - "$cpu" <<'PY'
import sys

cpu = int(sys.argv[1])
if cpu < 0:
    raise SystemExit("CPU must be non-negative")

words = [0] * (cpu // 32 + 1)
words[cpu // 32] = 1 << (cpu % 32)

parts = [f"{word:08x}" for word in reversed(words)]
while len(parts) > 1 and parts[0] == "00000000":
    parts.pop(0)
print(",".join(parts).lstrip("0") or "0")
PY
}

require_interface() {
	[ -n "$DEV" ] || die "--dev is required"
	[ -d "/sys/class/net/$DEV" ] || die "netdev not found: $DEV"
}

check_queue_exists() {
	local queue="$1"
	if [ "$DO_RX" -eq 1 ] && [ ! -d "/sys/class/net/$DEV/queues/rx-$queue" ]; then
		die "RX queue does not exist: /sys/class/net/$DEV/queues/rx-$queue"
	fi
	if [ "$DO_TX" -eq 1 ] && [ ! -d "/sys/class/net/$DEV/queues/tx-$queue" ]; then
		die "TX queue does not exist: /sys/class/net/$DEV/queues/tx-$queue"
	fi
}

check_queue_cpu_conflict() {
	local queue="$1"
	local cpu="$2"
	local existing="${QUEUE_CPU_BY_QUEUE[$queue]:-}"

	# 本脚本中单个 queue 只有一个 IRQ affinity 目标和一个 XPS CPU mask。
	# 如果允许同一 queue 对应多个 CPU，最终配置会依赖规则顺序，因此
	# 必须在修改主机状态前失败退出。
	if [ -n "$existing" ] && [ "$existing" != "$cpu" ]; then
		die "queue $queue is mapped to multiple CPUs ($existing and $cpu); use one queue per CPU-local instance"
	fi

	QUEUE_CPU_BY_QUEUE[$queue]="$cpu"
}

disable_rps_rfs() {
	[ "$DISABLE_RPS" -eq 1 ] || return 0
	[ "$DO_RX" -eq 1 ] || return 0

	# 硬件 steering 只决定包进入哪个 RX queue。RPS/RFS 在后续收包路径
	# 中仍可能把 skb 放入其他 CPU 的 backlog，从而破坏
	# “queue -> IRQ CPU -> net_rx_action CPU” 的局部性。
	echo "== Disabling RPS/RFS on $DEV =="
	run_shell "for f in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do [ -e \"\$f\" ] && echo 0 > \"\$f\"; done"
	run_shell "for f in /sys/class/net/$DEV/queues/rx-*/rps_flow_cnt; do [ -e \"\$f\" ] && echo 0 > \"\$f\"; done"
	if [ -w /proc/sys/net/core/rps_sock_flow_entries ] || [ "$DRY_RUN" -eq 1 ]; then
		run_cmd sysctl -w net.core.rps_sock_flow_entries=0
	else
		warn "cannot write /proc/sys/net/core/rps_sock_flow_entries; skip global RFS table reset"
	fi
}

enable_ntuple() {
	[ "$DO_RX" -eq 1 ] || return 0
	[ "$ENABLE_NTUPLE" -eq 1 ] || return 0

	# 这里通过 ethtool 尽力开启 ntuple。有些驱动会把 ntuple 暴露为
	# 固定状态或完全不支持；如果 steering 已由其他机制配置，可使用
	# --no-enable-ntuple 跳过。
	echo "== Enabling ntuple on $DEV =="
	run_cmd ethtool -K "$DEV" ntuple on
}

irq_from_manual_map() {
	local queue="$1"
	local item q irq
	for item in "${IRQ_MAPS[@]}"; do
		IFS=: read -r q irq <<<"$item"
		if [ "$q" = "$queue" ]; then
			printf '%s\n' "$irq"
			return 0
		fi
	done
	return 1
}

find_irq_for_queue() {
	local queue="$1"

	if irq_from_manual_map "$queue"; then
		return 0
	fi

	# IRQ 名称是驱动相关的。这里的启发式匹配覆盖常见 mlx5 命名和
	# 按 queue 编号命名的通用形式；生产环境中如果命名规则明确，
	# 优先使用 --irq-map 显式指定。
	#
	# 注意：queue 编号和下面命令取出的 IRQ 列表不是稳定的按序映射：
	#   cat /proc/interrupts | grep "$NIC_PCI" | awk -F ':' '{print $1}'
	# 该命令只表示“这个 PCI function 当前有哪些 IRQ/vector”，其中可能
	# 包含 async/PTP/其他 completion vector。CX5/mlx5e 常见情况下 RX queue
	# 会落到对应 channel/completion vector，但不能假设第 N 个 IRQ 就是
	# queue N；需要结合 IRQ 名称、目标 queue 统计增长，或直接用 --irq-map。
	awk -v dev="$DEV" -v q="$queue" '
		BEGIN {
			# 常见 mlx5 名称包括 <dev>-<n>、<dev>-rx-<n>、
			# <dev>-TxRx-<n>、mlx5_comp<n>@pci:<dev> 等。
			pat1 = dev ".*(^|[^0-9])" q "([^0-9]|$)"
			pat2 = "mlx5.*(^|[^0-9])" q "([^0-9]|$)"
		}
		$0 ~ dev && $0 ~ pat1 {
			sub(":", "", $1)
			print $1
			exit
		}
		$0 ~ pat2 {
			sub(":", "", $1)
			print $1
			exit
		}
	' /proc/interrupts
}

bind_irq_cpu() {
	local queue="$1"
	local cpu="$2"
	local irq

	if [ -n "${IRQ_BOUND_BY_QUEUE[$queue]:-}" ]; then
		return 0
	fi

	irq=$(find_irq_for_queue "$queue" || true)
	if [ -z "$irq" ]; then
		if [ "$STRICT_IRQ" -eq 1 ]; then
			die "failed to discover IRQ for $DEV queue $queue; pass --irq-map $queue:<irq> or --allow-missing-irq"
		fi
		warn "failed to discover IRQ for $DEV queue $queue; skip IRQ affinity"
		return 0
	fi

	[ -e "/proc/irq/$irq/smp_affinity_list" ] || die "IRQ affinity file not found: /proc/irq/$irq/smp_affinity_list"
	echo "== Binding RX queue $queue IRQ $irq to CPU $cpu =="
	run_shell "echo $cpu > /proc/irq/$irq/smp_affinity_list"
	IRQ_BOUND_BY_QUEUE[$queue]=1
}

configure_rx_rule() {
	local ip="$1"
	local queue="$2"
	local port="$3"
	local loc="$4"
	local cmd=(ethtool -N "$DEV" flow-type tcp4 dst-ip "$ip" action "$queue" loc "$loc")

	# RX 规则匹配进入本机的流量。对服务端场景，服务 IP 通常是目的 IP；
	# 可选端口用于把匹配范围收窄到具体 TCP 服务。
	if [ -n "$port" ]; then
		cmd=(ethtool -N "$DEV" flow-type tcp4 dst-ip "$ip" dst-port "$port" action "$queue" loc "$loc")
	fi

	echo "== Configuring RX ntuple: dst-ip $ip${port:+:$port} -> queue $queue loc $loc =="
	run_cmd "${cmd[@]}"
}

ensure_clsact() {
	[ "$DO_TX" -eq 1 ] || return 0

	# clsact 提供 egress hook，且不替换现有 root qdisc。
	# 如果已存在，可以安全复用。
	echo "== Ensuring clsact qdisc on $DEV =="
	if [ "$DRY_RUN" -eq 1 ]; then
		print_cmd tc qdisc add dev "$DEV" clsact
		printf '# ignore "File exists" if clsact already exists\n'
		return 0
	fi

	if ! tc qdisc show dev "$DEV" | grep -q 'clsact'; then
		run_cmd tc qdisc add dev "$DEV" clsact
	fi
}

configure_tx_rule() {
	local ip="$1"
	local queue="$2"
	local port="$3"
	local pref="$4"
	local cmd=(tc filter replace dev "$DEV" egress protocol ip pref "$pref" flower src_ip "$ip" ip_proto tcp action skbedit queue_mapping "$queue")

	# TX 规则匹配离开本机的流量。对服务端回包，服务 IP 通常是源 IP；
	# queue_mapping 会在驱动发送 skb 前选择 TX queue。
	if [ -n "$port" ]; then
		cmd=(tc filter replace dev "$DEV" egress protocol ip pref "$pref" flower src_ip "$ip" src_port "$port" ip_proto tcp action skbedit queue_mapping "$queue")
	fi

	echo "== Configuring TX tc filter: src-ip $ip${port:+:$port} -> queue $queue pref $pref =="
	run_cmd "${cmd[@]}"
}

configure_xps() {
	local queue="$1"
	local cpu="$2"
	local mask

	if [ -n "${XPS_SET_BY_QUEUE[$queue]:-}" ]; then
		return 0
	fi

	# xps_cpus 需要十六进制 CPU mask，而不是 CPU 列表。
	# 转换逻辑放在脚本内，配置文件就可以继续使用普通 CPU 编号。
	mask=$(cpu_to_mask "$cpu")
	echo "== Setting XPS: TX queue $queue -> CPU $cpu mask $mask =="
	run_shell "echo $mask > /sys/class/net/$DEV/queues/tx-$queue/xps_cpus"
	XPS_SET_BY_QUEUE[$queue]=1
}

print_verification_hint() {
	cat <<EOF

Verification hints:
  ethtool -n $DEV
  grep -i $DEV /proc/interrupts
  cat /sys/class/net/$DEV/queues/rx-*/rps_cpus
  cat /sys/class/net/$DEV/queues/rx-*/rps_flow_cnt
  sysctl net.core.rps_sock_flow_entries
  tc -s filter show dev $DEV egress
  ethtool -S $DEV | egrep 'rx|tx|queue|ch'

Use 方法 6 in 观察NAPI差异实战指南.md to confirm dst-ip -> CPU set convergence.
EOF
}

main() {
	parse_args "$@"
	load_config_rules
	require_interface
	require_root
	require_tools

	[ "${#RULES[@]}" -gt 0 ] || die "no rules specified; use --rule or --config"

	local normalized=()
	local rule
	for rule in "${RULES[@]}"; do
		normalized+=("$(normalize_rule "$rule")")
	done

	local ip queue cpu port
	for rule in "${normalized[@]}"; do
		IFS=: read -r ip queue cpu port <<<"$rule"
		check_queue_exists "$queue"
		check_queue_cpu_conflict "$queue" "$cpu"
	done

	disable_rps_rfs
	enable_ntuple
	ensure_clsact

	local index=0
	local loc pref
	for rule in "${normalized[@]}"; do
		IFS=: read -r ip queue cpu port <<<"$rule"
		loc=$((LOCATION_BASE + index))
		pref=$((PREF_BASE + index))

		if [ "$DO_RX" -eq 1 ]; then
			configure_rx_rule "$ip" "$queue" "$port" "$loc"
			bind_irq_cpu "$queue" "$cpu"
		fi

		if [ "$DO_TX" -eq 1 ]; then
			configure_tx_rule "$ip" "$queue" "$port" "$pref"
			configure_xps "$queue" "$cpu"
		fi

		index=$((index + 1))
	done

	print_verification_hint
}

main "$@"
