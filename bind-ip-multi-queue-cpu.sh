#!/bin/bash

set -euo pipefail

# 基于 bind-ip-queue-cpu.sh 的多 queue / CPU range 版本。
#
# 兼容旧配置：
#   --rule IP:QUEUE:CPU[:PORT]
#   配置文件每行：IP QUEUE CPU [PORT]
#
# --mode server 是默认值，语义与 bind-ip-queue-cpu.sh 一致：
#   RX：dst-ip(local/server) -> RX queue/RSS context -> IRQ CPU set
#   TX：src-ip(local/server) -> TX queue -> XPS CPU set
#
# --mode client 用于客户端侧复用同一份配置，IP 表示远端 server IP：
#   RX：src-ip(remote/server) -> RX queue/RSS context -> IRQ CPU set
#   TX：dst-ip(remote/server) -> TX queue -> XPS CPU set
#
# 新增扩展：
#   QUEUE 支持逗号和范围：5,6,8 或 5-8
#   CPU   支持 CPU set：18-21 或 18,20-23
#   CPU   支持按 queue 对齐的 CPU set 组：18-19/20-21
#
# 重要限制：
# - 单 queue 规则沿用旧脚本语义：RX ntuple action queue，TX tc queue_mapping。
# - 多 queue RX 规则使用 ethtool RSS context，让同一个 IP 的多个 flow
#   可在指定 queue 范围内散列。目标设备/驱动必须支持 RSS context。
# - tc skbedit queue_mapping 只能设置一个 TX queue；多 queue 规则不会创建
#   多条重复 TX filter，而是只配置目标 TX queue 的 XPS CPU mask。
SCRIPT_NAME=$(basename -- "$0")

DRY_RUN=0
DO_RX=1
DO_TX=1
DELETE_RULES=0
DISABLE_RPS=1
ENABLE_NTUPLE=1
STRICT_IRQ=1
SKIP_QUEUE_CHECK=0
DELETE_RSS_CONTEXTS=0
MODE="server"
RPS_FLOW_CNT=4096

DEV=""
CONFIG_FILE=""
LOCATION_BASE=500
PREF_BASE=500
RSS_CONTEXT_DRY_BASE=9000
RSS_CONTEXT_RESULT=""
RSS_CONTEXT_STATE_FILE=""
CLIENT_STATE_FILE=""

RAW_RULES=()
NORMALIZED_RULES=()
IRQ_MAPS=()
RSS_CONTEXT_MAPS=()
RSS_CONTEXT_CLEANUP_RECORDS=()
CONFIGURED_QUEUE_ORDER=()

declare -A CLIENT_STATE_RECORDED=()
declare -A QUEUE_CPUSET_BY_QUEUE=()
declare -A IRQ_BOUND_BY_QUEUE=()
declare -A XPS_SET_BY_QUEUE=()
declare -A RSS_CONTEXT_BY_QUEUES=()

usage() {
	cat <<EOF
Usage:
  ./$SCRIPT_NAME --dev <netdev> --rule <ip:queues:cpus[:port]> [OPTIONS]
  ./$SCRIPT_NAME --dev <netdev> --config <file> [OPTIONS]
  ./$SCRIPT_NAME --dev <netdev> --delete-rules [OPTIONS]

Bind IPv4 TCP traffic for selected IPs to RX/TX queues and CPU ranges on a
multi-queue netdev.

Modes:
  --mode server (default)
    IP means local/server IP.
    RX: dst-ip[:dst-port] -> RX queue/RSS context -> IRQ CPU set
    TX: src-ip[:src-port] -> TX queue -> XPS CPU set

  --mode client
    IP means remote/server IP when this script runs on a client host.
    RX: src-ip[:src-port] -> RX queue/RSS context -> IRQ CPU set
    TX: dst-ip[:dst-port] -> TX queue -> XPS CPU set

Compatibility:
  Old bind-ip-queue-cpu.sh rules still work:
    --rule 10.0.0.11:5:18:6379
    config line: 10.0.0.11 5 18 6379

Extensions:
  QUEUES accepts a single queue, comma list, or range:
    5
    5,6,8
    5-8

  CPUS accepts a CPU set:
    18
    18-21
    18,20-23

  CPUS may also provide one CPU set per expanded queue, separated by /:
    --rule 10.0.0.11:5-6:18-19/20-21:6379
    # queue 5 -> CPUs 18-19, queue 6 -> CPUs 20-21

  If CPUS has one set and QUEUES has multiple queues, every queue uses the
  same CPU set:
    --rule 10.0.0.11:5-6:18-21:6379
    # queue 5 and queue 6 both bind to CPUs 18-21

For each rule, the script can:
  1. Server mode: disable RPS/RFS, unless --keep-rps is specified.
     Client mode: configure RPS/RFS for selected RX queues, unless --keep-rps
     is specified.
  2. Enable ethtool ntuple, unless --no-enable-ntuple is specified.
  3. Single queue RX: add/replace ntuple action QUEUE.
  4. Multi queue RX: create/reuse RSS context for QUEUES, then bind IP to it.
  5. Bind each RX queue IRQ to the requested CPU set.
  6. Single queue TX: add/replace tc skbedit queue_mapping QUEUE.
  7. Set each selected TX queue XPS mask to the requested CPU set.

Dependencies:
  Runtime: bash 4+, python3
  Apply mode: root, ethtool, tc, sysctl(procps)
  Kernel/device: multi-queue netdev; ethtool ntuple support; RSS context support
                 for multi queue RX; tc flower/skbedit/clsact support for
                 single queue TX mapping; writable /sys queue and /proc/irq
                 affinity files.
  Dry-run: does not require root, ethtool, tc, or sysctl.

Options:
  --dev DEV                       Target netdev, e.g. enp23s0f1np1
  --mode server|client            Match direction mode (default: server)
  --rule IP:QUEUES:CPUS[:PORT]    Add one mapping rule; can be repeated
  --config FILE                   Read mapping rules from file
                                  Format: IP QUEUES CPUS [PORT]
  --irq-map QUEUE:IRQ             Manually map a queue to an IRQ; repeatable
  --rss-context QUEUES:CTX        Reuse an existing RSS context for QUEUES
                                  QUEUES uses the same syntax as --rule
  --delete-rss-contexts           With --delete-rules, delete contexts supplied
                                  through --rss-context and contexts auto-created
                                  by previous runs recorded in RSS state
  --rss-context-state FILE        State file for auto-created RSS contexts
                                  (default: /run/${SCRIPT_NAME%.sh}.DEV.rss-contexts)
  --client-state FILE             State file used to restore client-mode sysfs
                                  settings changed by this script
                                  (default: /run/${SCRIPT_NAME%.sh}.DEV.client.state)
  --location-base N               Base location for ethtool ntuple rules (default: 500)
  --pref-base N                   Base pref for tc egress filters (default: 500)
  --rss-context-dry-base N        Synthetic context base in --dry-run (default: 9000)
  --rps-flow-cnt N                Per RX queue rps_flow_cnt in client mode
                                  when RPS/RFS is configured (default: 4096)
  --dry-run                       Print commands without executing
  --delete-rules                  Delete RX ntuple rules and TX egress filters
  --rx-only                       Configure RX side only
  --tx-only                       Configure TX side only
  --keep-rps                      Do not disable or configure RPS/RFS
  --no-enable-ntuple              Do not run ethtool -K DEV ntuple on
  --allow-missing-irq             Continue if RX queue IRQ cannot be discovered
  --skip-queue-check              Skip /sys queue existence checks; useful for dry-run
  -h, --help                      Show this help

Examples:
  ./$SCRIPT_NAME --dev enp23s0f1np1 --mode server --rule 10.0.0.11:5:18:6379 --dry-run

  ./$SCRIPT_NAME --dev enp23s0f1np1 --mode client --rule 10.0.0.11:5-6:18-21:6379 --dry-run

  ./$SCRIPT_NAME --dev enp23s0f1np1 --rule 10.0.0.11:5-6:18-19/20-21:6379

  cat ip-queue-cpu-range.txt
  # IP         QUEUES  CPUS            PORT
  10.0.0.11   5-6     18-21           6379
  10.0.0.12   7-8     22-23/24-25     6379
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
	local tools=(python3)
	local tool

	if [ "$DRY_RUN" -eq 0 ]; then
		tools+=(ethtool)
		tools+=(tc)
		if [ "$DELETE_RULES" -eq 0 ] || [ "$MODE" = "client" ]; then
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
				[ -n "$DEV" ] || die "--dev requires a value"
				;;
			--mode)
				shift
				MODE=${1:-}
				[ -n "$MODE" ] || die "--mode requires a value"
				;;
			--rule)
				shift
				[ -n "${1:-}" ] || die "--rule requires a value"
				RAW_RULES+=("$1")
				;;
			--config)
				shift
				CONFIG_FILE=${1:-}
				[ -n "$CONFIG_FILE" ] || die "--config requires a value"
				;;
			--irq-map)
				shift
				[ -n "${1:-}" ] || die "--irq-map requires a value"
				IRQ_MAPS+=("$1")
				;;
			--rss-context)
				shift
				[ -n "${1:-}" ] || die "--rss-context requires a value"
				RSS_CONTEXT_MAPS+=("$1")
				;;
			--delete-rss-contexts)
				DELETE_RSS_CONTEXTS=1
				;;
			--rss-context-state)
				shift
				RSS_CONTEXT_STATE_FILE=${1:-}
				[ -n "$RSS_CONTEXT_STATE_FILE" ] || die "--rss-context-state requires a value"
				;;
			--client-state)
				shift
				CLIENT_STATE_FILE=${1:-}
				[ -n "$CLIENT_STATE_FILE" ] || die "--client-state requires a value"
				;;
			--location-base)
				shift
				LOCATION_BASE=${1:-}
				[ -n "$LOCATION_BASE" ] || die "--location-base requires a value"
				;;
			--pref-base)
				shift
				PREF_BASE=${1:-}
				[ -n "$PREF_BASE" ] || die "--pref-base requires a value"
				;;
			--rss-context-dry-base)
				shift
				RSS_CONTEXT_DRY_BASE=${1:-}
				[ -n "$RSS_CONTEXT_DRY_BASE" ] || die "--rss-context-dry-base requires a value"
				;;
			--rps-flow-cnt)
				shift
				RPS_FLOW_CNT=${1:-}
				[ -n "$RPS_FLOW_CNT" ] || die "--rps-flow-cnt requires a value"
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
			--skip-queue-check)
				SKIP_QUEUE_CHECK=1
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

expand_number_spec() {
	local spec="$1"
	local name="$2"
	python3 - "$spec" "$name" <<'PY'
import sys

spec = sys.argv[1]
name = sys.argv[2]
values = set()

if not spec:
    raise SystemExit(f"error: {name} spec is empty")

for item in spec.split(","):
    item = item.strip()
    if not item:
        raise SystemExit(f"error: empty {name} item in {spec}")
    if "-" in item:
        start_s, end_s = item.split("-", 1)
        if not start_s.isdigit() or not end_s.isdigit():
            raise SystemExit(f"error: invalid {name} range: {item}")
        start = int(start_s)
        end = int(end_s)
        if start > end:
            raise SystemExit(f"error: invalid {name} range: {item}")
        values.update(range(start, end + 1))
    else:
        if not item.isdigit():
            raise SystemExit(f"error: invalid {name}: {item}")
        values.add(int(item))

for value in sorted(values):
    print(value)
PY
}

normalize_cpu_set() {
	local spec="$1"
	python3 - "$spec" <<'PY'
import sys

spec = sys.argv[1]
values = set()

if not spec:
    raise SystemExit("error: CPU set is empty")

for item in spec.split(","):
    item = item.strip()
    if not item:
        raise SystemExit(f"error: empty CPU item in {spec}")
    if "-" in item:
        start_s, end_s = item.split("-", 1)
        if not start_s.isdigit() or not end_s.isdigit():
            raise SystemExit(f"error: invalid CPU range: {item}")
        start = int(start_s)
        end = int(end_s)
        if start > end:
            raise SystemExit(f"error: invalid CPU range: {item}")
        values.update(range(start, end + 1))
    else:
        if not item.isdigit():
            raise SystemExit(f"error: invalid CPU: {item}")
        values.add(int(item))

ordered = sorted(values)
ranges = []
start = prev = ordered[0]
for value in ordered[1:]:
    if value == prev + 1:
        prev = value
        continue
    ranges.append(f"{start}-{prev}" if start != prev else str(start))
    start = prev = value
ranges.append(f"{start}-{prev}" if start != prev else str(start))
print(",".join(ranges))
PY
}

cpu_set_to_mask() {
	local spec="$1"
	python3 - "$spec" <<'PY'
import sys

spec = sys.argv[1]
values = set()
for item in spec.split(","):
    if "-" in item:
        start, end = (int(part) for part in item.split("-", 1))
        values.update(range(start, end + 1))
    else:
        values.add(int(item))

max_cpu = max(values)
words = [0] * (max_cpu // 32 + 1)
for cpu in values:
    words[cpu // 32] |= 1 << (cpu % 32)

parts = [f"{word:08x}" for word in reversed(words)]
while len(parts) > 1 and parts[0] == "00000000":
    parts.pop(0)
print(",".join(parts).lstrip("0") or "0")
PY
}

join_by_comma() {
	local IFS=,
	printf '%s\n' "$*"
}

load_config_rules() {
	[ -z "$CONFIG_FILE" ] && return 0
	[ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"

	local raw line ip queues cpus port
	while IFS= read -r raw || [ -n "$raw" ]; do
		line=${raw%%#*}
		# shellcheck disable=SC2086
		set -- $line
		[ $# -eq 0 ] && continue
		[ $# -ge 3 ] && [ $# -le 4 ] || die "invalid config line, expected: IP QUEUES CPUS [PORT]; got: $raw"
		ip=$1
		queues=$2
		cpus=$3
		port=${4:-}
		if [ -n "$port" ]; then
			RAW_RULES+=("$ip:$queues:$cpus:$port")
		else
			RAW_RULES+=("$ip:$queues:$cpus")
		fi
	done <"$CONFIG_FILE"
}

require_interface() {
	[ -n "$DEV" ] || die "--dev is required"
	[ -d "/sys/class/net/$DEV" ] || die "netdev not found: $DEV"
}

set_default_rss_context_state_file() {
	[ -n "$RSS_CONTEXT_STATE_FILE" ] && return 0
	RSS_CONTEXT_STATE_FILE="/run/${SCRIPT_NAME%.sh}.${DEV}.rss-contexts"
}

set_default_client_state_file() {
	[ -n "$CLIENT_STATE_FILE" ] && return 0
	CLIENT_STATE_FILE="/run/${SCRIPT_NAME%.sh}.${DEV}.client.state"
}

check_queue_exists() {
	local queue="$1"
	[ "$SKIP_QUEUE_CHECK" -eq 0 ] || return 0

	if [ "$DO_RX" -eq 1 ] && [ ! -d "/sys/class/net/$DEV/queues/rx-$queue" ]; then
		die "RX queue does not exist: /sys/class/net/$DEV/queues/rx-$queue"
	fi
	if [ "$DO_TX" -eq 1 ] && [ ! -d "/sys/class/net/$DEV/queues/tx-$queue" ]; then
		die "TX queue does not exist: /sys/class/net/$DEV/queues/tx-$queue"
	fi
}

check_queue_cpu_conflict() {
	local queue="$1"
	local cpuset="$2"
	local existing="${QUEUE_CPUSET_BY_QUEUE[$queue]:-}"

	# 一个 queue 最终只有一个 IRQ affinity 和一个 XPS mask。
	# 允许多个 queue 共享同一 CPU range，但不允许同一 queue 被重复写成
	# 不同 CPU range，否则最终状态会依赖规则顺序。
	if [ -n "$existing" ] && [ "$existing" != "$cpuset" ]; then
		die "queue $queue is mapped to multiple CPU ranges ($existing and $cpuset)"
	fi

	if [ -z "$existing" ]; then
		CONFIGURED_QUEUE_ORDER+=("$queue")
	fi
	QUEUE_CPUSET_BY_QUEUE[$queue]="$cpuset"
}

normalize_rule() {
	local rule="$1"
	local parts_count ip queue_spec cpu_spec port expanded_queues queues_csv
	local fields=()
	local queues=()
	local cpu_groups=()
	local normalized_cpu_groups=()
	local old_ifs

	IFS=: read -r -a fields <<<"$rule"
	parts_count=${#fields[@]}
	[ "$parts_count" -eq 3 ] || [ "$parts_count" -eq 4 ] || die "invalid rule, expected IP:QUEUES:CPUS[:PORT]: $rule"

	ip=${fields[0]}
	queue_spec=${fields[1]}
	cpu_spec=${fields[2]}
	port=${fields[3]:-}

	[ -n "$ip" ] || die "invalid rule, missing IP: $rule"
	[ -n "$queue_spec" ] || die "invalid rule, missing QUEUES: $rule"
	[ -n "$cpu_spec" ] || die "invalid rule, missing CPUS: $rule"

	validate_ipv4 "$ip" || die "invalid IPv4 address in rule: $rule"
	if [ -n "$port" ]; then
		validate_number "$port" "port"
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "port out of range in rule: $rule"
	fi

	expanded_queues=$(expand_number_spec "$queue_spec" "queue") || exit $?
	mapfile -t queues <<<"$expanded_queues"
	[ "${#queues[@]}" -gt 0 ] || die "rule has no queues: $rule"
	queues_csv=$(join_by_comma "${queues[@]}")

	if [[ "$cpu_spec" == *"/"* ]]; then
		IFS=/ read -r -a cpu_groups <<<"$cpu_spec"
		[ "${#cpu_groups[@]}" -eq "${#queues[@]}" ] || die "CPU group count must be 1 or match queue count in rule: $rule"
	else
		cpu_groups=("$cpu_spec")
	fi

	local group normalized
	for group in "${cpu_groups[@]}"; do
		normalized=$(normalize_cpu_set "$group") || exit $?
		normalized_cpu_groups+=("$normalized")
	done

	if [ "${#normalized_cpu_groups[@]}" -eq 1 ] && [ "${#queues[@]}" -gt 1 ]; then
		local first_group="${normalized_cpu_groups[0]}"
		normalized_cpu_groups=()
		for _ in "${queues[@]}"; do
			normalized_cpu_groups+=("$first_group")
		done
	fi

	local cpusets_joined
	old_ifs=$IFS
	IFS=';'
	cpusets_joined="${normalized_cpu_groups[*]}"
	IFS=$old_ifs

	printf '%s|%s|%s|%s\n' "$ip" "$queues_csv" "$cpusets_joined" "$port"
}

normalize_queue_spec_to_csv() {
	local queue_spec="$1"
	local expanded_queues
	local queues=()

	expanded_queues=$(expand_number_spec "$queue_spec" "queue") || exit $?
	mapfile -t queues <<<"$expanded_queues"
	[ "${#queues[@]}" -gt 0 ] || die "queue spec has no queues: $queue_spec"
	join_by_comma "${queues[@]}"
}

remember_rss_context_cleanup_record() {
	local queue_csv="$1"
	local ctx="$2"

	RSS_CONTEXT_CLEANUP_RECORDS+=("$queue_csv|$ctx")
}

prepare_rss_context_state_file() {
	[ "$DRY_RUN" -eq 0 ] || return 0

	local state_dir
	state_dir=$(dirname -- "$RSS_CONTEXT_STATE_FILE")
	mkdir -p "$state_dir"
	touch "$RSS_CONTEXT_STATE_FILE"
	[ -w "$RSS_CONTEXT_STATE_FILE" ] || die "RSS context state file is not writable: $RSS_CONTEXT_STATE_FILE"
}

record_auto_rss_context() {
	local queue_csv="$1"
	local ctx="$2"

	[ "$DRY_RUN" -eq 0 ] || return 0
	prepare_rss_context_state_file
	printf '%s %s\n' "$queue_csv" "$ctx" >>"$RSS_CONTEXT_STATE_FILE"
}

load_rss_context_state_records() {
	[ -f "$RSS_CONTEXT_STATE_FILE" ] || return 0

	local raw line queue_spec ctx queue_csv
	while IFS= read -r raw || [ -n "$raw" ]; do
		line=${raw%%#*}
		# shellcheck disable=SC2086
		set -- $line
		[ $# -eq 0 ] && continue
		[ $# -eq 2 ] || die "invalid RSS context state line, expected: QUEUES CTX; got: $raw"
		queue_spec=$1
		ctx=$2
		validate_number "$ctx" "RSS context"
		queue_csv=$(normalize_queue_spec_to_csv "$queue_spec")
		remember_rss_context_cleanup_record "$queue_csv" "$ctx"
	done <"$RSS_CONTEXT_STATE_FILE"
}

clear_rss_context_state_file() {
	[ "$DRY_RUN" -eq 0 ] || return 0
	[ -f "$RSS_CONTEXT_STATE_FILE" ] || return 0

	rm -f -- "$RSS_CONTEXT_STATE_FILE"
}

prepare_client_state_file() {
	[ "$MODE" = "client" ] || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0

	local state_dir
	state_dir=$(dirname -- "$CLIENT_STATE_FILE")
	mkdir -p "$state_dir"
	touch "$CLIENT_STATE_FILE"
	[ -w "$CLIENT_STATE_FILE" ] || die "client state file is not writable: $CLIENT_STATE_FILE"
}

client_state_has_record() {
	local kind="$1"
	local key="$2"

	[ -f "$CLIENT_STATE_FILE" ] || return 1
	awk -F '\t' -v kind="$kind" -v key="$key" '$1 == kind && $2 == key { found = 1 } END { exit found ? 0 : 1 }' "$CLIENT_STATE_FILE"
}

record_client_state() {
	local kind="$1"
	local key="$2"
	local value="$3"
	local record_key="$kind|$key"

	[ "$MODE" = "client" ] || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0
	[ -z "${CLIENT_STATE_RECORDED[$record_key]:-}" ] || return 0
	if client_state_has_record "$kind" "$key"; then
		CLIENT_STATE_RECORDED[$record_key]=1
		return 0
	fi

	prepare_client_state_file
	printf '%s\t%s\t%s\n' "$kind" "$key" "$value" >>"$CLIENT_STATE_FILE"
	CLIENT_STATE_RECORDED[$record_key]=1
}

record_file_state() {
	local kind="$1"
	local path="$2"
	local value

	[ "$MODE" = "client" ] || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0
	[ -e "$path" ] || return 0
	value=$(cat "$path")
	record_client_state "$kind" "$path" "$value"
}

record_sysctl_state() {
	local key="$1"
	local value

	[ "$MODE" = "client" ] || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0
	value=$(sysctl -n "$key" 2>/dev/null || true)
	[ -n "$value" ] || return 0
	record_client_state sysctl "$key" "$value"
}

record_clsact_created() {
	record_client_state clsact-created - 1
}

record_ntuple_state() {
	local value

	[ "$MODE" = "client" ] || return 0
	[ "$DRY_RUN" -eq 0 ] || return 0
	value=$(ethtool -k "$DEV" 2>/dev/null | awk '/^ntuple-filters:/ { print $2; exit }')
	case "$value" in
		on|off)
			record_client_state ntuple "$DEV" "$value"
			;;
	esac
}

restore_client_state() {
	[ "$MODE" = "client" ] || return 0
	[ -f "$CLIENT_STATE_FILE" ] || return 0

	local raw line kind key value
	while IFS= read -r raw || [ -n "$raw" ]; do
		line=${raw%%#*}
		[ -n "$line" ] || continue
		IFS=$'\t' read -r kind key value <<<"$line"
		[ -n "${kind:-}" ] && [ -n "${key:-}" ] || die "invalid client state line: $raw"
		case "$kind" in
			irq|xps|rps-cpus|rps-flow-cnt)
				if [ "$DRY_RUN" -eq 0 ] && [ ! -e "$key" ]; then
					warn "client state target no longer exists, skip restore: $key"
					continue
				fi
				run_shell "printf %s\\\\n $(printf '%q' "${value:-}") > $(printf '%q' "$key")"
				;;
			sysctl)
				run_cmd sysctl -w "$key=${value:-}"
				;;
			ntuple)
				case "${value:-}" in
					on|off)
						run_cmd ethtool -K "$DEV" ntuple "$value"
						;;
					*)
						die "invalid ntuple state value: ${value:-}"
						;;
				esac
				;;
			clsact-created)
				if [ "${value:-}" = "1" ]; then
					if [ "$DRY_RUN" -eq 1 ] || tc qdisc show dev "$DEV" | grep -q 'clsact'; then
						run_cmd tc qdisc del dev "$DEV" clsact
					else
						warn "clsact qdisc no longer exists on $DEV; skip delete"
					fi
				fi
				;;
			*)
				die "unknown client state kind: $kind"
				;;
		esac
	done <"$CLIENT_STATE_FILE"

	if [ "$DRY_RUN" -eq 0 ]; then
		rm -f -- "$CLIENT_STATE_FILE"
	fi
}

normalize_rss_context_maps() {
	local item queue_spec ctx queues_csv
	for item in "${RSS_CONTEXT_MAPS[@]}"; do
		IFS=: read -r queue_spec ctx <<<"$item"
		[ -n "${queue_spec:-}" ] && [ -n "${ctx:-}" ] || die "invalid --rss-context, expected QUEUES:CTX: $item"
		validate_number "$ctx" "RSS context"
		queues_csv=$(normalize_queue_spec_to_csv "$queue_spec")
		RSS_CONTEXT_BY_QUEUES[$queues_csv]="$ctx"
		if [ "$DELETE_RSS_CONTEXTS" -eq 1 ]; then
			remember_rss_context_cleanup_record "$queues_csv" "$ctx"
		fi
	done
}

normalize_rules() {
	local raw record queues_csv cpusets_joined port ip
	local queue_array=()
	local cpuset_array=()
	local i queue cpuset

	[ "${#RAW_RULES[@]}" -gt 0 ] || die "no rules specified; use --rule or --config"

	for raw in "${RAW_RULES[@]}"; do
		record=$(normalize_rule "$raw")
		NORMALIZED_RULES+=("$record")

		IFS='|' read -r ip queues_csv cpusets_joined port <<<"$record"
		IFS=, read -r -a queue_array <<<"$queues_csv"
		IFS=';' read -r -a cpuset_array <<<"$cpusets_joined"

		for i in "${!queue_array[@]}"; do
			queue=${queue_array[$i]}
			cpuset=${cpuset_array[$i]}
			check_queue_exists "$queue"
			check_queue_cpu_conflict "$queue" "$cpuset"
		done
	done
}

disable_rps_rfs() {
	[ "$DISABLE_RPS" -eq 1 ] || return 0
	[ "$DO_RX" -eq 1 ] || return 0

	echo "== Disabling RPS/RFS on $DEV =="
	if [ "$DRY_RUN" -eq 1 ]; then
		run_shell "for f in /sys/class/net/$DEV/queues/rx-*/rps_cpus; do [ -e \"\$f\" ] && echo 0 > \"\$f\"; done"
		run_shell "for f in /sys/class/net/$DEV/queues/rx-*/rps_flow_cnt; do [ -e \"\$f\" ] && echo 0 > \"\$f\"; done"
	else
		local f
		for f in /sys/class/net/"$DEV"/queues/rx-*/rps_cpus; do
			[ -e "$f" ] || continue
			record_file_state rps-cpus "$f"
			run_shell "printf %s\\\\n 0 > $(printf '%q' "$f")"
		done
		for f in /sys/class/net/"$DEV"/queues/rx-*/rps_flow_cnt; do
			[ -e "$f" ] || continue
			record_file_state rps-flow-cnt "$f"
			run_shell "printf %s\\\\n 0 > $(printf '%q' "$f")"
		done
	fi
	if [ -w /proc/sys/net/core/rps_sock_flow_entries ] || [ "$DRY_RUN" -eq 1 ]; then
		record_sysctl_state net.core.rps_sock_flow_entries
		run_cmd sysctl -w net.core.rps_sock_flow_entries=0
	else
		warn "cannot write /proc/sys/net/core/rps_sock_flow_entries; skip global RFS table reset"
	fi
}

configure_client_rps_rfs() {
	[ "$MODE" = "client" ] || return 0
	[ "$DISABLE_RPS" -eq 1 ] || return 0
	[ "$DO_RX" -eq 1 ] || return 0

	local queue cpuset mask rps_cpus_file rps_flow_cnt_file total_entries=0

	echo "== Configuring client RPS/RFS on $DEV =="
	total_entries=$((${#CONFIGURED_QUEUE_ORDER[@]} * RPS_FLOW_CNT))
	if [ "$total_entries" -gt 0 ]; then
		record_sysctl_state net.core.rps_sock_flow_entries
		run_cmd sysctl -w "net.core.rps_sock_flow_entries=$total_entries"
	fi

	for queue in "${CONFIGURED_QUEUE_ORDER[@]}"; do
		cpuset=${QUEUE_CPUSET_BY_QUEUE[$queue]}
		mask=$(cpu_set_to_mask "$cpuset")
		rps_cpus_file="/sys/class/net/$DEV/queues/rx-$queue/rps_cpus"
		rps_flow_cnt_file="/sys/class/net/$DEV/queues/rx-$queue/rps_flow_cnt"

		if [ "$DRY_RUN" -eq 0 ]; then
			[ -e "$rps_cpus_file" ] || die "RPS CPU mask file not found: $rps_cpus_file"
			[ -e "$rps_flow_cnt_file" ] || die "RPS flow count file not found: $rps_flow_cnt_file"
		fi

		echo "== Configuring client RPS/RFS: RX queue $queue -> CPUs $cpuset mask $mask flow_cnt $RPS_FLOW_CNT =="
		record_file_state rps-cpus "$rps_cpus_file"
		run_shell "echo $mask > $rps_cpus_file"
		record_file_state rps-flow-cnt "$rps_flow_cnt_file"
		run_shell "echo $RPS_FLOW_CNT > $rps_flow_cnt_file"
	done
}

enable_ntuple() {
	[ "$DO_RX" -eq 1 ] || return 0
	[ "$ENABLE_NTUPLE" -eq 1 ] || return 0

	echo "== Enabling ntuple on $DEV =="
	record_ntuple_state
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

bind_irq_cpuset() {
	local queue="$1"
	local cpuset="$2"
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

	if [ "$DRY_RUN" -eq 0 ] && [ ! -e "/proc/irq/$irq/smp_affinity_list" ]; then
		die "IRQ affinity file not found: /proc/irq/$irq/smp_affinity_list"
	fi
	echo "== Binding RX queue $queue IRQ $irq to CPUs $cpuset =="
	record_file_state irq "/proc/irq/$irq/smp_affinity_list"
	run_shell "echo $cpuset > /proc/irq/$irq/smp_affinity_list"
	IRQ_BOUND_BY_QUEUE[$queue]=1
}

is_contiguous_queue_csv() {
	local queue_csv="$1"
	local queues=()
	local prev="" queue
	IFS=, read -r -a queues <<<"$queue_csv"
	for queue in "${queues[@]}"; do
		if [ -n "$prev" ] && [ "$queue" -ne $((prev + 1)) ]; then
			return 1
		fi
		prev=$queue
	done
	return 0
}

first_queue_from_csv() {
	local queue_csv="$1"
	printf '%s\n' "${queue_csv%%,*}"
}

queue_count_from_csv() {
	local queue_csv="$1"
	local queues=()
	IFS=, read -r -a queues <<<"$queue_csv"
	printf '%s\n' "${#queues[@]}"
}

parse_new_rss_context() {
	python3 -c '
import re
import sys

text = sys.stdin.read()
numbers = re.findall(r"\b(\d+)\b", text)
if numbers:
    print(numbers[-1])
'
}

ensure_rss_context() {
	local queue_csv="$1"
	local existing="${RSS_CONTEXT_BY_QUEUES[$queue_csv]:-}"
	local count start ctx output

	if [ -n "$existing" ]; then
		RSS_CONTEXT_RESULT="$existing"
		return 0
	fi

	is_contiguous_queue_csv "$queue_csv" || die "multi-queue RSS context requires contiguous queues; got: $queue_csv"
	count=$(queue_count_from_csv "$queue_csv")
	start=$(first_queue_from_csv "$queue_csv")

	if [ "$DRY_RUN" -eq 1 ]; then
		ctx=$((RSS_CONTEXT_DRY_BASE + ${#RSS_CONTEXT_BY_QUEUES[@]}))
		echo "== Creating dry-run RSS context $ctx for queues $queue_csv =="
		print_cmd ethtool -X "$DEV" hfunc toeplitz context new
		print_cmd ethtool -X "$DEV" equal "$count" start "$start" context "$ctx"
		RSS_CONTEXT_BY_QUEUES[$queue_csv]="$ctx"
		RSS_CONTEXT_RESULT="$ctx"
		return 0
	fi

	echo "== Creating RSS context for queues $queue_csv on $DEV =="
	prepare_rss_context_state_file
	print_cmd ethtool -X "$DEV" hfunc toeplitz context new
	output=$(ethtool -X "$DEV" hfunc toeplitz context new)
	printf '%s\n' "$output"
	ctx=$(printf '%s\n' "$output" | parse_new_rss_context)
	[ -n "$ctx" ] || die "failed to parse new RSS context id from ethtool output"
	record_auto_rss_context "$queue_csv" "$ctx"
	remember_rss_context_cleanup_record "$queue_csv" "$ctx"

	run_cmd ethtool -X "$DEV" equal "$count" start "$start" context "$ctx"
	RSS_CONTEXT_BY_QUEUES[$queue_csv]="$ctx"
	RSS_CONTEXT_RESULT="$ctx"
}

configure_rx_rule() {
	local ip="$1"
	local queue_csv="$2"
	local port="$3"
	local loc="$4"
	local count ctx
	local queues=()
	local cmd
	local ip_field="dst-ip"
	local port_field="dst-port"

	if [ "$MODE" = "client" ]; then
		ip_field="src-ip"
		port_field="src-port"
	fi

	IFS=, read -r -a queues <<<"$queue_csv"
	count=${#queues[@]}

	if [ "$count" -eq 1 ]; then
		cmd=(ethtool -N "$DEV" flow-type tcp4 "$ip_field" "$ip")
		if [ -n "$port" ]; then
			cmd+=("$port_field" "$port")
		fi
		cmd+=(action "${queues[0]}" loc "$loc")

		echo "== Configuring RX ntuple ($MODE): $ip_field $ip${port:+:$port} -> queue ${queues[0]} loc $loc =="
		run_cmd "${cmd[@]}"
		return 0
	fi

	ensure_rss_context "$queue_csv"
	ctx="$RSS_CONTEXT_RESULT"
	cmd=(ethtool -N "$DEV" flow-type tcp4 "$ip_field" "$ip")
	if [ -n "$port" ]; then
		cmd+=("$port_field" "$port")
	fi
	cmd+=(context "$ctx" loc "$loc")

	echo "== Configuring RX ntuple ($MODE): $ip_field $ip${port:+:$port} -> RSS context $ctx queues $queue_csv loc $loc =="
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

delete_configured_rss_contexts() {
	if [ "$DELETE_RSS_CONTEXTS" -ne 1 ] && [ "$MODE" != "client" ]; then
		return 0
	fi

	load_rss_context_state_records

	local record queue_csv ctx seen_key
	declare -A seen_contexts=()
	for record in "${RSS_CONTEXT_CLEANUP_RECORDS[@]}"; do
		IFS='|' read -r queue_csv ctx <<<"$record"
		[ -n "$ctx" ] || continue
		seen_key="ctx-$ctx"
		[ -z "${seen_contexts[$seen_key]:-}" ] || continue
		echo "== Deleting RSS context $ctx for queues $queue_csv on $DEV =="
		run_cmd ethtool -X "$DEV" context "$ctx" delete
		seen_contexts[$seen_key]=1
	done

	clear_rss_context_state_file
}

delete_rules() {
	delete_rx_ntuple_rules
	delete_tx_egress_filters
	delete_configured_rss_contexts
	restore_client_state
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
		record_clsact_created
		run_cmd tc qdisc add dev "$DEV" clsact
	fi
}

configure_tx_rule() {
	local ip="$1"
	local queue_csv="$2"
	local port="$3"
	local pref="$4"
	local queues=()
	local cmd
	local ip_field="src_ip"
	local label="src-ip"
	local port_field="src_port"

	if [ "$MODE" = "client" ]; then
		ip_field="dst_ip"
		label="dst-ip"
		port_field="dst_port"
	fi

	IFS=, read -r -a queues <<<"$queue_csv"
	if [ "${#queues[@]}" -ne 1 ]; then
		echo "== Skipping TX tc queue_mapping for $label $ip${port:+:$port}: multi-queue rule uses XPS on queues $queue_csv =="
		return 0
	fi

	cmd=(tc filter replace dev "$DEV" egress protocol ip pref "$pref" flower "$ip_field" "$ip")
	if [ -n "$port" ]; then
		cmd+=("$port_field" "$port")
	fi
	cmd+=(ip_proto tcp action skbedit queue_mapping "${queues[0]}")

	echo "== Configuring TX tc filter ($MODE): $label $ip${port:+:$port} -> queue ${queues[0]} pref $pref =="
	run_cmd "${cmd[@]}"
}

configure_xps() {
	local queue="$1"
	local cpuset="$2"
	local mask

	if [ -n "${XPS_SET_BY_QUEUE[$queue]:-}" ]; then
		return 0
	fi

	mask=$(cpu_set_to_mask "$cpuset")
	echo "== Setting XPS: TX queue $queue -> CPUs $cpuset mask $mask =="
	record_file_state xps "/sys/class/net/$DEV/queues/tx-$queue/xps_cpus"
	run_shell "echo $mask > /sys/class/net/$DEV/queues/tx-$queue/xps_cpus"
	XPS_SET_BY_QUEUE[$queue]=1
}

print_verification_hint() {
	local pci

	pci=$(dev_pci_address || true)
	cat <<EOF

Verification hints:
  ethtool -n $DEV
  ethtool -x $DEV
  grep -i ${pci:-$DEV} /proc/interrupts
  cat /sys/class/net/$DEV/queues/rx-*/rps_cpus
  cat /sys/class/net/$DEV/queues/rx-*/rps_flow_cnt
  sysctl net.core.rps_sock_flow_entries
  tc -s filter show dev $DEV egress
  cat /sys/class/net/$DEV/queues/tx-*/xps_cpus
  ethtool -S $DEV | egrep 'rx|tx|queue|ch'

For multi-queue RX, verify that the device accepted the RSS context and that
queue counters grow only within the intended queue range.

Mode-specific match direction:
  server: RX dst-ip / TX src-ip
  client: RX src-ip / TX dst-ip
EOF
}

apply_rules() {
	if [ "$MODE" != "client" ]; then
		disable_rps_rfs
	fi
	enable_ntuple
	if [ "$DO_RX" -eq 1 ]; then
		delete_rx_ntuple_rules
	fi
	ensure_clsact
	if [ "$DO_TX" -eq 1 ]; then
		delete_tx_egress_filters
	fi

	local index=0
	local record ip queue_csv cpusets_joined port loc pref
	local queues=()
	local cpusets=()
	local i queue cpuset

	for record in "${NORMALIZED_RULES[@]}"; do
		IFS='|' read -r ip queue_csv cpusets_joined port <<<"$record"
		IFS=, read -r -a queues <<<"$queue_csv"
		IFS=';' read -r -a cpusets <<<"$cpusets_joined"
		loc=$((LOCATION_BASE + index))
		pref=$((PREF_BASE + index))

		if [ "$DO_RX" -eq 1 ]; then
			configure_rx_rule "$ip" "$queue_csv" "$port" "$loc"
			for i in "${!queues[@]}"; do
				queue=${queues[$i]}
				cpuset=${cpusets[$i]}
				bind_irq_cpuset "$queue" "$cpuset"
			done
		fi

		if [ "$DO_TX" -eq 1 ]; then
			configure_tx_rule "$ip" "$queue_csv" "$port" "$pref"
			for i in "${!queues[@]}"; do
				queue=${queues[$i]}
				cpuset=${cpusets[$i]}
				configure_xps "$queue" "$cpuset"
			done
		fi

		index=$((index + 1))
	done

	configure_client_rps_rfs
	print_verification_hint
}

main() {
	parse_args "$@"

	validate_mode
	validate_number "$LOCATION_BASE" "location-base"
	validate_number "$PREF_BASE" "pref-base"
	validate_number "$RSS_CONTEXT_DRY_BASE" "rss-context-dry-base"
	validate_number "$RPS_FLOW_CNT" "rps-flow-cnt"

	load_config_rules
	require_interface
	set_default_rss_context_state_file
	set_default_client_state_file
	require_root
	require_tools
	normalize_rss_context_maps

	if [ "$DELETE_RULES" -eq 1 ]; then
		delete_rules
		return 0
	fi

	normalize_rules
	apply_rules
}

main "$@"
