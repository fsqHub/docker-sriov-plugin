#!/usr/bin/env python3

import argparse
import ipaddress
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Rule:
    ip: str
    queue: int
    cpu: int
    port: int | None = None


class Binder:
    # 本脚本写入的是网卡、驱动和内核的运行态状态，不能把它们当成
    # down/up 后一定保留的持久配置：
    # - ethtool ntuple/flow director 规则可能在 netdev close/open、reset、
    #   firmware reload 或 channel 重建后被驱动清空或重新组织。
    # - IRQ affinity 绑定当前 IRQ/vector 编号；down/up 或 queue 重建后 IRQ
    #   可能重新分配，irqbalance 也可能再次覆盖 affinity。
    # - RPS/RFS/XPS 写入 sysfs/procfs，queue 重建、网络管理组件或 sysctl
    #   配置重放都可能改写这些值。
    # - tc clsact/filter 在普通 carrier down/up 后不一定消失，但接口被
    #   网络管理器重建、qdisc 被替换或驱动 reset 后仍需复查。
    #
    # 因此生产环境应在接口 up、驱动 reload、channel 调整、容器 IP 变更
    # 之后重新执行脚本，并按 print_verification_hint() 给出的命令校验。
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.dev = args.dev
        self.do_rx = not args.tx_only
        self.do_tx = not args.rx_only
        self.queue_cpu: dict[int, int] = {}
        self.irq_bound: set[int] = set()
        self.xps_set: set[int] = set()
        self.irq_maps = self._parse_irq_maps(args.irq_map)

    def run_cmd(self, cmd: list[str]) -> None:
        print("+ " + shlex.join(cmd))
        if not self.args.dry_run:
            subprocess.run(cmd, check=True)

    def run_shell(self, cmd: str) -> None:
        print("+ " + cmd)
        if not self.args.dry_run:
            subprocess.run(cmd, shell=True, check=True)

    def require_tools(self) -> None:
        tools = ["python3"]

        # dry-run 用于在开发机审查命令，不强制要求目标机才有的工具。
        if not self.args.dry_run:
            tools.append("ethtool")
            tools.append("tc")
            if not self.args.delete_rules:
                tools.append("sysctl")

        for tool in tools:
            if shutil.which(tool) is None:
                raise SystemExit(f"error: missing required tool: {tool}")

    def require_root(self) -> None:
        if not self.args.dry_run and os.geteuid() != 0:
            raise SystemExit("error: this script must run as root; use --dry-run to inspect commands first")

    def require_interface(self) -> None:
        if not Path(f"/sys/class/net/{self.dev}").is_dir():
            raise SystemExit(f"error: netdev not found: {self.dev}")

    def validate_rules(self, rules: list[Rule]) -> None:
        if not rules:
            raise SystemExit("error: no rules specified; use --rule or --config")

        for rule in rules:
            self._check_queue_exists(rule.queue)
            self._check_queue_cpu_conflict(rule.queue, rule.cpu)

    def apply(self, rules: list[Rule]) -> None:
        self.disable_rps_rfs()
        self.enable_ntuple()
        if self.do_rx:
            self.delete_rx_ntuple_rules()
        self.ensure_clsact()
        if self.do_tx:
            self.delete_tx_egress_filters()

        for index, rule in enumerate(rules):
            loc = self.args.location_base + index
            pref = self.args.pref_base + index

            if self.do_rx:
                self.configure_rx_rule(rule, loc)
                self.bind_irq_cpu(rule.queue, rule.cpu)

            if self.do_tx:
                self.configure_tx_rule(rule, pref)
                self.configure_xps(rule.queue, rule.cpu)

        self.print_verification_hint()

    def delete_rules(self) -> None:
        # 单独清理模式：删除 RX ntuple 和 TX egress filter，但不修改
        # RPS/RFS、IRQ affinity 或 XPS。
        self.delete_rx_ntuple_rules()
        self.delete_tx_egress_filters()

    def delete_rx_ntuple_rules(self) -> None:
        # 动态读取当前设备上的所有 ntuple Filter location 并删除。
        # 这样即使 loc 不是 location-base + index，或者规则由上次运行、
        # 手工命令、驱动重排产生，也能在新增规则前清理干净。
        print(f"== Deleting all existing RX ntuple rules on {self.dev} ==")
        locations = self.get_ntuple_rule_locations()
        if not locations:
            print(f"== No RX ntuple rules found on {self.dev} ==")
            return

        for loc in locations:
            print(f"== Deleting RX ntuple rule loc {loc} on {self.dev} ==")
            self.run_cmd(["ethtool", "-N", self.dev, "delete", str(loc)])

    def delete_tx_egress_filters(self) -> None:
        # 动态读取当前 egress filter 的 pref 并删除，避免 pref-base 改变后
        # 旧 TX queue_mapping 规则残留。
        print(f"== Deleting all existing TX egress filters on {self.dev} ==")
        prefs = self.get_tx_egress_filter_prefs()
        if not prefs:
            print(f"== No TX egress filters found on {self.dev} ==")
            return

        for pref in prefs:
            print(f"== Deleting TX egress filter pref {pref} on {self.dev} ==")
            self.run_cmd(["tc", "filter", "del", "dev", self.dev, "egress", "pref", str(pref)])

    def get_ntuple_rule_locations(self) -> list[str]:
        cmd = ["ethtool", "-n", self.dev]
        print("+ " + shlex.join(cmd))
        if self.args.dry_run:
            return []

        result = subprocess.run(cmd, check=True, text=True, capture_output=True)
        return parse_ntuple_rule_locations(result.stdout)

    def get_tx_egress_filter_prefs(self) -> list[str]:
        cmd = ["tc", "filter", "show", "dev", self.dev, "egress"]
        print("+ " + shlex.join(cmd))
        if self.args.dry_run:
            return []

        result = subprocess.run(cmd, check=False, text=True, capture_output=True)
        if result.returncode != 0:
            return []
        return parse_tc_egress_filter_prefs(result.stdout)

    def disable_rps_rfs(self) -> None:
        if not self.args.disable_rps or not self.do_rx:
            return

        # 硬件 steering 只决定包进入哪个 RX queue。RPS/RFS 后续仍可能
        # 把 skb 放入其他 CPU backlog，因此默认关闭以保持 CPU 局部性。
        print(f"== Disabling RPS/RFS on {self.dev} ==")
        self.run_shell(
            f'for f in /sys/class/net/{self.dev}/queues/rx-*/rps_cpus; '
            'do [ -e "$f" ] && echo 0 > "$f"; done'
        )
        self.run_shell(
            f'for f in /sys/class/net/{self.dev}/queues/rx-*/rps_flow_cnt; '
            'do [ -e "$f" ] && echo 0 > "$f"; done'
        )
        self.run_cmd(["sysctl", "-w", "net.core.rps_sock_flow_entries=0"])

    def enable_ntuple(self) -> None:
        if not self.do_rx or not self.args.enable_ntuple:
            return

        # ntuple 是否可开启取决于驱动。若目标设备不支持，用户可使用
        # --no-enable-ntuple，改由外部系统提前配置 steering。
        print(f"== Enabling ntuple on {self.dev} ==")
        self.run_cmd(["ethtool", "-K", self.dev, "ntuple", "on"])

    def ensure_clsact(self) -> None:
        if not self.do_tx:
            return

        # clsact 提供 egress hook，不替换现有 root qdisc。
        print(f"== Ensuring clsact qdisc on {self.dev} ==")
        if self.args.dry_run:
            self.run_cmd(["tc", "qdisc", "add", "dev", self.dev, "clsact"])
            print('# ignore "File exists" if clsact already exists')
            return

        result = subprocess.run(
            ["tc", "qdisc", "show", "dev", self.dev],
            check=True,
            text=True,
            capture_output=True,
        )
        if "clsact" not in result.stdout:
            self.run_cmd(["tc", "qdisc", "add", "dev", self.dev, "clsact"])

    def configure_rx_rule(self, rule: Rule, loc: int) -> None:
        # RX 规则匹配进入本机的流量；服务端 IP 通常是目的 IP。
        cmd = ["ethtool", "-N", self.dev, "flow-type", "tcp4", "dst-ip", rule.ip]
        if rule.port is not None:
            cmd.extend(["dst-port", str(rule.port)])
        cmd.extend(["action", str(rule.queue), "loc", str(loc)])

        suffix = f":{rule.port}" if rule.port is not None else ""
        print(f"== Configuring RX ntuple: dst-ip {rule.ip}{suffix} -> queue {rule.queue} loc {loc} ==")
        self.run_cmd(cmd)

    def configure_tx_rule(self, rule: Rule, pref: int) -> None:
        # TX 规则匹配离开本机的流量；服务端回包的服务 IP 通常是源 IP。
        cmd = [
            "tc", "filter", "replace", "dev", self.dev, "egress",
            "protocol", "ip", "pref", str(pref), "flower",
            "src_ip", rule.ip,
        ]
        if rule.port is not None:
            cmd.extend(["src_port", str(rule.port)])
        cmd.extend(["ip_proto", "tcp", "action", "skbedit", "queue_mapping", str(rule.queue)])

        suffix = f":{rule.port}" if rule.port is not None else ""
        print(f"== Configuring TX tc filter: src-ip {rule.ip}{suffix} -> queue {rule.queue} pref {pref} ==")
        self.run_cmd(cmd)

    def bind_irq_cpu(self, queue: int, cpu: int) -> None:
        if queue in self.irq_bound:
            return

        irq = self.find_irq_for_queue(queue)
        if irq is None:
            if self.args.strict_irq:
                raise SystemExit(
                    f"error: failed to discover IRQ for {self.dev} queue {queue}; "
                    f"pass --irq-map {queue}:<irq> or --allow-missing-irq"
                )
            print(f"warning: failed to discover IRQ for {self.dev} queue {queue}; skip IRQ affinity", file=sys.stderr)
            return

        irq_file = Path(f"/proc/irq/{irq}/smp_affinity_list")
        if not irq_file.exists() and not self.args.dry_run:
            raise SystemExit(f"error: IRQ affinity file not found: {irq_file}")

        print(f"== Binding RX queue {queue} IRQ {irq} to CPU {cpu} ==")
        self.run_shell(f"echo {cpu} > /proc/irq/{irq}/smp_affinity_list")
        self.irq_bound.add(queue)

    def configure_xps(self, queue: int, cpu: int) -> None:
        if queue in self.xps_set:
            return

        # xps_cpus 需要十六进制 CPU mask；配置文件中仍使用普通 CPU 编号。
        mask = cpu_to_mask(cpu)
        print(f"== Setting XPS: TX queue {queue} -> CPU {cpu} mask {mask} ==")
        self.run_shell(f"echo {mask} > /sys/class/net/{self.dev}/queues/tx-{queue}/xps_cpus")
        self.xps_set.add(queue)

    def find_irq_for_queue(self, queue: int) -> str | None:
        if queue in self.irq_maps:
            return self.irq_maps[queue]

        # IRQ 名称由驱动决定。这里覆盖常见 mlx5 和通用 queue 编号形式；
        # 生产环境中推荐用 --irq-map 显式传入。
        #
        # 注意：queue 编号和下面命令取出的 IRQ 列表不是稳定的按序映射：
        #   cat /proc/interrupts | grep "$NIC_PCI" | awk -F ':' '{print $1}'
        # 该命令只表示“这个 PCI function 当前有哪些 IRQ/vector”，其中可能
        # 包含 async/PTP/其他 completion vector。CX5/mlx5e 常见情况下 RX queue
        # 会落到对应 channel/completion vector，但不能假设第 N 个 IRQ 就是
        # queue N；需要结合 IRQ 名称、目标 queue 统计增长，或直接用 --irq-map。
        path = Path("/proc/interrupts")
        if not path.exists():
            return None

        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return find_irq_for_queue_in_lines(lines, queue, self.dev, read_dev_pci_address(self.dev))

    def print_verification_hint(self) -> None:
        print(f"""
Verification hints:
  ethtool -n {self.dev}
  grep -i {self.dev} /proc/interrupts
  cat /sys/class/net/{self.dev}/queues/rx-*/rps_cpus
  cat /sys/class/net/{self.dev}/queues/rx-*/rps_flow_cnt
  sysctl net.core.rps_sock_flow_entries
  tc -s filter show dev {self.dev} egress
  ethtool -S {self.dev} | egrep 'rx|tx|queue|ch'

Use 方法 6 in 观察NAPI差异实战指南.md to confirm dst-ip -> CPU set convergence.""")

    def _check_queue_exists(self, queue: int) -> None:
        if self.do_rx and not Path(f"/sys/class/net/{self.dev}/queues/rx-{queue}").is_dir():
            raise SystemExit(f"error: RX queue does not exist: /sys/class/net/{self.dev}/queues/rx-{queue}")
        if self.do_tx and not Path(f"/sys/class/net/{self.dev}/queues/tx-{queue}").is_dir():
            raise SystemExit(f"error: TX queue does not exist: /sys/class/net/{self.dev}/queues/tx-{queue}")

    def _check_queue_cpu_conflict(self, queue: int, cpu: int) -> None:
        # 单个 queue 只有一个 IRQ affinity 目标和一个 XPS CPU mask；
        # 发现同 queue 多 CPU 时，在修改主机状态前直接失败。
        existing = self.queue_cpu.get(queue)
        if existing is not None and existing != cpu:
            raise SystemExit(
                f"error: queue {queue} is mapped to multiple CPUs ({existing} and {cpu}); "
                "use one queue per CPU-local instance"
            )
        self.queue_cpu[queue] = cpu

    @staticmethod
    def _parse_irq_maps(items: list[str]) -> dict[int, str]:
        maps: dict[int, str] = {}
        for item in items:
            try:
                queue, irq = item.split(":", 1)
                maps[int(queue)] = irq
            except ValueError as exc:
                raise SystemExit(f"error: invalid --irq-map, expected QUEUE:IRQ: {item}") from exc
        return maps


def cpu_to_mask(cpu: int) -> str:
    if cpu < 0:
        raise SystemExit("error: CPU must be non-negative")

    words = [0] * (cpu // 32 + 1)
    words[cpu // 32] = 1 << (cpu % 32)
    parts = [f"{word:08x}" for word in reversed(words)]
    while len(parts) > 1 and parts[0] == "00000000":
        parts.pop(0)
    return (",".join(parts).lstrip("0") or "0")


def read_dev_pci_address(dev: str) -> str | None:
    device = Path(f"/sys/class/net/{dev}/device")
    if not device.exists():
        return None
    return device.resolve().name


def parse_interrupt_irq(line: str) -> str | None:
    match = re.match(r"\s*(\d+)\s*:", line)
    if match is None:
        return None
    return match.group(1)


def find_irq_for_queue_in_lines(lines: list[str], queue: int, dev: str, pci: str | None) -> str | None:
    q = str(queue)

    # CX5/mlx5e 的真实 IRQ 名称常见为 mlx5_compN@pci:<BDF>。
    # 先用 compN + PCI 精确匹配，避免 queue 0 误命中 mlx5_async0。
    if pci:
        mlx5_comp_pci = re.compile(rf"\bmlx5_comp{re.escape(q)}@pci:{re.escape(pci)}\b")
        for line in lines:
            if mlx5_comp_pci.search(line):
                return parse_interrupt_irq(line)

    dev_queue = re.compile(rf"{re.escape(dev)}.*(^|[^0-9]){re.escape(q)}([^0-9]|$)")
    for line in lines:
        if dev in line and dev_queue.search(line):
            return parse_interrupt_irq(line)

    # 没有 PCI 信息时才退化到 mlx5_compN 的精确名称；这仍比旧的
    # mlx5.*N 安全，因为不会把 mlx5_async0 当成 queue 0。
    if not pci:
        mlx5_comp = re.compile(rf"\bmlx5_comp{re.escape(q)}@pci:")
        for line in lines:
            if mlx5_comp.search(line):
                return parse_interrupt_irq(line)

    return None


def parse_ntuple_rule_locations(output: str) -> list[str]:
    locations: list[str] = []
    for line in output.splitlines():
        match = re.search(r"^\s*Filter:\s+(\S+)\s*$", line)
        if match:
            locations.append(match.group(1))
    return locations


def parse_tc_egress_filter_prefs(output: str) -> list[str]:
    prefs: set[str] = set()
    for line in output.splitlines():
        fields = line.split()
        if "pref" in fields:
            index = fields.index("pref")
            if index + 1 < len(fields):
                prefs.add(fields[index + 1])
    return sorted(prefs, key=lambda value: (0, int(value)) if value.isdigit() else (1, value))


def parse_rule(text: str) -> Rule:
    # 命令行规则格式：IP:QUEUE:CPU[:PORT]。
    parts = text.split(":")
    if len(parts) not in (3, 4):
        raise SystemExit(f"error: invalid rule, expected IP:QUEUE:CPU[:PORT]: {text}")

    ip, queue, cpu = parts[:3]
    port = parts[3] if len(parts) == 4 else None

    try:
        ipaddress.IPv4Address(ip)
        queue_i = int(queue)
        cpu_i = int(cpu)
        port_i = int(port) if port not in (None, "") else None
    except ValueError as exc:
        raise SystemExit(f"error: invalid rule: {text}") from exc

    if queue_i < 0 or cpu_i < 0:
        raise SystemExit(f"error: queue and CPU must be non-negative: {text}")
    if port_i is not None and not (1 <= port_i <= 65535):
        raise SystemExit(f"error: port out of range in rule: {text}")

    return Rule(ip=ip, queue=queue_i, cpu=cpu_i, port=port_i)


def load_config(path: str) -> list[Rule]:
    rules: list[Rule] = []
    config = Path(path)
    if not config.is_file():
        raise SystemExit(f"error: config file not found: {path}")

    for raw in config.read_text(encoding="utf-8").splitlines():
        # 配置文件支持空白分隔字段和行尾注释。
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) not in (3, 4):
            raise SystemExit(f"error: invalid config line, expected: IP QUEUE CPU [PORT]; got: {raw}")
        ip, queue, cpu = fields[:3]
        port = fields[3] if len(fields) == 4 else ""
        rules.append(parse_rule(f"{ip}:{queue}:{cpu}:{port}" if port else f"{ip}:{queue}:{cpu}"))
    return rules


def build_parser() -> argparse.ArgumentParser:
    script = Path(sys.argv[0]).name
    parser = argparse.ArgumentParser(
        prog=f"./{script}",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Bind IPv4 TCP traffic for selected IPs to specific RX/TX queues and CPUs "
            "on a multi-queue netdev."
        ),
        epilog="""Dependencies:
  Runtime: python3
  Apply mode: root, ethtool, tc, sysctl(procps)
  Kernel/device: multi-queue netdev, ethtool ntuple support for RX steering,
                 tc flower/skbedit/clsact support for TX queue mapping,
                 writable /sys queue and /proc/irq affinity files
  Dry-run: does not require root, ethtool, tc, or sysctl

Examples:
  ./{script} --dev enp23s0f1np1 --rule 10.0.0.11:5:18:6379 --dry-run
  ./{script} --dev enp23s0f1np1 --config ip-queue-cpu.txt
  ./{script} --dev enp23s0f1np1 --delete-rules --dry-run

Config file format:
  # IP         QUEUE  CPU  PORT
  10.0.0.11   5      18   6379
  10.0.0.12   6      26   6379
""".format(script=script),
    )
    parser.add_argument("--dev", required=True, help="Target netdev, e.g. enp23s0f1np1")
    parser.add_argument("--rule", action="append", default=[], help="IP:QUEUE:CPU[:PORT], can be repeated")
    parser.add_argument("--config", help="Read rules from file: IP QUEUE CPU [PORT]")
    parser.add_argument("--irq-map", action="append", default=[], help="QUEUE:IRQ, can be repeated")
    parser.add_argument("--location-base", type=int, default=500, help="Base location for ethtool ntuple rules")
    parser.add_argument("--pref-base", type=int, default=500, help="Base pref for tc egress filters")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument(
        "--delete-rules",
        action="store_true",
        help="Only delete RX ntuple rules and TX egress filters",
    )
    parser.add_argument("--rx-only", action="store_true", help="Configure RX side only")
    parser.add_argument("--tx-only", action="store_true", help="Configure TX side only")
    parser.add_argument("--keep-rps", dest="disable_rps", action="store_false", help="Do not disable RPS/RFS")
    parser.add_argument("--no-enable-ntuple", dest="enable_ntuple", action="store_false", help="Do not enable ntuple")
    parser.add_argument(
        "--allow-missing-irq",
        dest="strict_irq",
        action="store_false",
        help="Continue if RX queue IRQ cannot be discovered",
    )
    parser.set_defaults(disable_rps=True, enable_ntuple=True, strict_irq=True)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.rx_only and args.tx_only:
        raise SystemExit("error: --rx-only and --tx-only are mutually exclusive")

    rules = [parse_rule(rule) for rule in args.rule]
    if args.config:
        rules.extend(load_config(args.config))

    binder = Binder(args)
    binder.require_interface()
    binder.require_root()
    binder.require_tools()
    if args.delete_rules:
        binder.delete_rules()
        return

    binder.validate_rules(rules)
    binder.apply(rules)


if __name__ == "__main__":
    main()
