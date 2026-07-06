#!/bin/bash

set -euo pipefail

# 双模式版本：
# 配置文件格式与 bind-ip-queue-cpu.sh 保持一致：
#   IP QUEUE CPU [PORT]
#
# --mode server 是默认值，语义与 bind-ip-queue-cpu.sh 一致：
#   RX：dst-ip(local/server) -> RX queue -> IRQ CPU
#   TX：src-ip(local/server) -> TX queue -> XPS CPU
#
# --mode client 用于客户端侧复用同一份配置文件，IP 表示远端 server IP：
#   RX：src-ip(remote/server) -> RX queue -> IRQ CPU
#   TX：dst-ip(remote/server) -> TX queue -> XPS CPU
SCRIPT_NAME=$(basename -- "$0")

DRY_RUN=0
DO_RX=1
DO_TX=1
DELETE_RULES=0
DISABLE_RPS=1
ENABLE_NTUPLE=1
STRICT_IRQ=1
MODE="server"
DEV=""
CONFIG_FILE=""

LOCATION_BASE=500
PREF_BASE=500

RULES=()
IRQ_MAPS=()

declare -A QUEUE_CPU_BY_QUEUE=()
declare -A IRQ_BOUND_BY_QUEUE=()
declare -A XPS_SET_BY_QUEUE=()

usage() {
	cat <<EOF
Usage:
  ./$SCRIPT_NAME --dev <netdev> --rule <ip:queue:cpu[:port]> [OPTIONS]
  ./$SCRIPT_NAME --dev <netdev> --config <file> [OPTIONS]
  ./$SCRIPT_NAME --dev <netdev> --delete-rules [OPTIONS]

Bind IPv4 TCP traffic for selected IPs to specific RX/TX queues and CPUs on a
multi-queue netdev. The rule/config format is compatible with
bind-ip-queue-cpu.sh.

Modes:
  --mode server (default)
    IP means local/server IP.
    RX: dst-ip[:dst-port] -> RX queue -> IRQ CPU
    TX: src-ip[:src-port] -> TX queue -> XPS CPU

  --mode client
    IP means remote/server IP when this script runs on a client host.
    RX: src-ip[:src-port] -> RX queue -> IRQ CPU
    TX: dst-ip[:dst-port] -> TX queue -> XPS CPU

For Redis:
  server mode: use the Redis server local IP in the IP field.
  client mode: use the Redis server remote IP in the same IP field.
  If PORT is omitted, all TCP traffic matching that IP direction is matched.
  If PORT is provided, use the Redis server port, e.g. 6379.

For each rule, the script can:
  1. Disable RPS/RFS, unless --keep-rps is specified.
  2. Enable ethtool ntuple, unless --no-enable-ntuple is specified.
  3. Add/replace an RX ntuple rule according to --mode.
  4. Bind the RX queue IRQ to the requested CPU.
  5. Add/replace a tc egress rule according to --mode.
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
  --mode server|client         Match direction mode (default: server)
  --rule IP:QUEUE:CPU[:PORT]   Add one mapping rule; repeatable
  --config FILE                Read mapping rules from file
                               Format per line: IP QUEUE CPU [PORT]
                               Blank lines and lines starting with # are ignored
  --irq-map QUEUE:IRQ          Manually map a queue to an IRQ; repeatable
  --location-base N            Base location for ethtool ntuple rules (default: 500)
  --pref-base N                Base pref for tc egress filters (default: 500)
  --dry-run                    Print commands without executing
  --delete-rules               Only delete RX ntuple rules and TX egress filters
  --rx-only                    Configure RX side only
  --tx-only                    Configure TX side only
  --keep-rps                   Do not disable RPS/RFS
  --no-enable-ntuple           Do not run ethtool -K DEV ntuple on
  --allow-missing-irq          Continue if RX queue IRQ cannot be discovered
  -h, --help                   Show this help

Examples:
  ./$SCRIPT_NAME --dev enp23s0f1np1 --mode server --rule 10.0.0.11:5:18 --dry-run

  ./$SCRIPT_NAME --dev enp23s0f1np1 --mode client --rule 10.0.0.11:5:18:6379 --dry-run

  ./$SCRIPT_NAME --dev enp23s0f1np1 --config ip-queue-cpu.txt

  cat ip-queue-cpu.txt
  # IP         QUEUE  CPU  PORT
  10.0.0.11    5      18   6379
  10.0.0.12    6      26   6379
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

	if [ "$DRY_RUN" -eq 0 ]; then
		tools+=(ethtool)
		tools+=(tc)
		if [ "$DELETE_RULES" -eq 0 ]; then
			tools+=(sysctl)
		fi
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
			--mode)
				shift
				MODE=${1:-}
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
			--delete-rules)
				DELETE_RULES=1
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

	# 与服务端脚本兼容：IP:QUEUE:CPU[:PORT]。
	# server 模式中 IP 是本机服务 IP；client 模式中 IP 是远端 server IP。
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

validate_mode() {
	case "$MODE" in
		server|client)
			return 0
			;;
		*)
			die "invalid --mode: $MODE; expected server or client"
			;;
	esac
}

load_config_rules() {
	[ -z "$CONFIG_FILE" ] && return 0
	[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"

	local line ip queue cpu port
	while IFS= read -r line || [ -n "$line" ]; do
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

	if [ -n "$existing" ] && [ "$existing" != "$cpu" ]; then
		die "queue $queue is mapped to multiple CPUs ($existing and $cpu); use one queue per CPU-local instance"
	fi

	QUEUE_CPU_BY_QUEUE[$queue]="$cpu"
}

disable_rps_rfs() {
	[ "$DISABLE_RPS" -eq 1 ] || return 0
	[ "$DO_RX" -eq 1 ] || return 0

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

dev_pci_address() {
	local device_path pci

	device_path=$(readlink -f "/sys/class/net/$DEV/device" 2>/dev/null || true)
	[ -n "$device_path" ] || return 1
	pci=$(basename -- "$device_path")
	[[ "$pci" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || return 1
	printf '%s\n' "$pci"
}

find_irq_for_queue() {
	local queue="$1"
	local pci

	if irq_from_manual_map "$queue"; then
		return 0
	fi

	pci=$(dev_pci_address || true)
	awk -v dev="$DEV" -v q="$queue" -v pci="$pci" '
		function irq_no(line, parts) {
			split(line, parts, ":")
			gsub(/^[ \t]+|[ \t]+$/, "", parts[1])
			return parts[1]
		}
		BEGIN {
			pci_pat = pci
			gsub(/\./, "[.]", pci_pat)
			mlx5_comp_pci = "mlx5_comp" q "@pci:" pci_pat "([^0-9A-Za-z_.:-]|$)"
			dev_queue = dev ".*(^|[^0-9])" q "([^0-9]|$)"
			mlx5_comp_any = "mlx5_comp" q "@pci:"
		}
		pci != "" && $0 ~ mlx5_comp_pci {
			print irq_no($0)
			exit
		}
		$0 ~ dev && $0 ~ dev_queue {
			print irq_no($0)
			exit
		}
		pci == "" && $0 ~ mlx5_comp_any {
			print irq_no($0)
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
	local ip_field="dst-ip"
	local port_field="dst-port"
	local cmd

	if [ "$MODE" = "client" ]; then
		ip_field="src-ip"
		port_field="src-port"
	fi

	# server 模式匹配进入本机服务 IP 的请求包；client 模式匹配来自远端
	# server IP 的响应包。
	cmd=(ethtool -N "$DEV" flow-type tcp4 "$ip_field" "$ip" action "$queue" loc "$loc")
	if [ -n "$port" ]; then
		cmd=(ethtool -N "$DEV" flow-type tcp4 "$ip_field" "$ip" "$port_field" "$port" action "$queue" loc "$loc")
	fi

	echo "== Configuring RX ntuple ($MODE): $ip_field $ip${port:+:$port} -> queue $queue loc $loc =="
	run_cmd "${cmd[@]}"
}

delete_rx_ntuple_rules() {
	echo "== Deleting all existing RX ntuple rules on $DEV =="
	run_shell "ethtool -n $(printf '%q' "$DEV") | grep 'Filter:' | awk '{print \$2}' | while read -r loc; do echo \"Deleting rule with location \$loc\"; ethtool -N $(printf '%q' "$DEV") delete \"\$loc\"; done"
}

delete_tx_egress_filters() {
	echo "== Deleting all existing TX egress filters on $DEV =="
	run_shell "tc filter show dev $(printf '%q' "$DEV") egress 2>/dev/null | awk '/pref / {print \$5}' | sort -u | while read -r pref; do echo \"Deleting egress filter with pref \$pref\"; tc filter del dev $(printf '%q' "$DEV") egress pref \"\$pref\"; done"
}

delete_rules() {
	delete_rx_ntuple_rules
	delete_tx_egress_filters
}

ensure_clsact() {
	[ "$DO_TX" -eq 1 ] || return 0

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
	local ip_field="src_ip"
	local label="src-ip"
	local port_field="src_port"
	local cmd

	if [ "$MODE" = "client" ]; then
		ip_field="dst_ip"
		label="dst-ip"
		port_field="dst_port"
	fi

	# server 模式匹配本机服务 IP 发出的回包；client 模式匹配发往远端
	# server IP 的请求包。
	cmd=(tc filter replace dev "$DEV" egress protocol ip pref "$pref" flower "$ip_field" "$ip" ip_proto tcp action skbedit queue_mapping "$queue")
	if [ -n "$port" ]; then
		cmd=(tc filter replace dev "$DEV" egress protocol ip pref "$pref" flower "$ip_field" "$ip" "$port_field" "$port" ip_proto tcp action skbedit queue_mapping "$queue")
	fi

	echo "== Configuring TX tc filter ($MODE): $label $ip${port:+:$port} -> queue $queue pref $pref =="
	run_cmd "${cmd[@]}"
}

configure_xps() {
	local queue="$1"
	local cpu="$2"
	local mask

	if [ -n "${XPS_SET_BY_QUEUE[$queue]:-}" ]; then
		return 0
	fi

	mask=$(cpu_to_mask "$cpu")
	echo "== Setting XPS: TX queue $queue -> CPU $cpu mask $mask =="
	run_shell "echo $mask > /sys/class/net/$DEV/queues/tx-$queue/xps_cpus"
	XPS_SET_BY_QUEUE[$queue]=1
}

print_verification_hint() {
	local pci

	pci=$(dev_pci_address || true)
	cat <<EOF

Verification hints:
  ethtool -n $DEV
  grep -i ${pci:-$DEV} /proc/interrupts
  cat /sys/class/net/$DEV/queues/rx-*/rps_cpus
  cat /sys/class/net/$DEV/queues/rx-*/rps_flow_cnt
  sysctl net.core.rps_sock_flow_entries
  tc -s filter show dev $DEV egress
  cat /sys/class/net/$DEV/queues/tx-*/xps_cpus
  ethtool -S $DEV | egrep 'rx|tx|queue|ch'

Mode-specific match direction:
  server: RX dst-ip / TX src-ip
  client: RX src-ip / TX dst-ip
EOF
}

main() {
	parse_args "$@"
	validate_mode
	load_config_rules
	require_interface
	require_root
	require_tools

	if [ "$DELETE_RULES" -eq 1 ]; then
		delete_rules
		return 0
	fi

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
	if [ "$DO_RX" -eq 1 ]; then
		delete_rx_ntuple_rules
	fi
	ensure_clsact
	if [ "$DO_TX" -eq 1 ]; then
		delete_tx_egress_filters
	fi

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
