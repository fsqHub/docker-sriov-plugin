#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$SCRIPT_DIR"

TARGET_OS=linux
TARGET_ARCH=arm64
TARGET_PLATFORM="${TARGET_OS}/${TARGET_ARCH}"

IMAGE_TAG="${IMAGE_TAG:-sriov-plugin:test-arm64}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-debian:stretch-slim-arm64local}"
RUNTIME_ARCHIVE="${RUNTIME_ARCHIVE:-$REPO_ROOT/debian_stretch-slim_aarch64.tar}"
BUILDX_CONFIG_DIR="${BUILDX_CONFIG:-/tmp/docker-sriov-plugin-buildx}"

DRY_RUN=0
KEEP_WORKDIR=0
WORKDIR=""

GOPATH_ROOT=""
GOCACHE_DIR=""
BINARY_PATH=""
IMAGE_CONTEXT_DIR=""

DEPENDENCIES=(
	"github.com/codegangsta/cli|https://github.com/codegangsta/cli.git|8e01ec4cd3e2d84ab2fe90d8210528ffbb06d8ff"
	"github.com/docker/go-plugins-helpers|https://github.com/docker/go-plugins-helpers.git|bd8c600f0cdd76c7a57ff6aa86bd2b423868c688"
	"github.com/docker/libnetwork|https://github.com/docker/libnetwork.git|40bae11aa7cdbe99dabbedba672f80fc0dfb6643"
	"github.com/Mellanox/rdmamap|https://github.com/Mellanox/rdmamap.git|a5b6a9343308252b018b5cef44bfe30f6d36e64f"
	"github.com/Mellanox/sriovnet|https://github.com/Mellanox/sriovnet.git|9fed9e830316a115b30622b82575cbe8632a41e9"
	"github.com/vishvananda/netlink|https://github.com/vishvananda/netlink.git|985ab95d37f9c4632a65b2e456d89d76a07ffb40"
	"github.com/vishvananda/netns|https://github.com/vishvananda/netns.git|8ba1072b58e0c2a240eb5f6120165c7776c3e7b8"
	"github.com/coreos/go-systemd|https://github.com/coreos/go-systemd.git|d2196463941895ee908e13531a23a39feb9e1243"
	"github.com/docker/go-connections|https://github.com/docker/go-connections.git|3ede32e2033de7505e6500d6c868c2b9ed9f169d"
	"github.com/satori/go.uuid|https://github.com/satori/go.uuid.git|36e9d2ebbde5e3f13ab2e25625fd453271d6522e"
	"golang.org/x/net|https://github.com/golang/net.git|5f9ae10d9af5b1c89ae6904293b14b064d4ada23"
	"golang.org/x/sys|https://github.com/golang/sys.git|3b87a42e500a6dc65dae1a55d0b641295971163e"
	"golang.org/x/text|https://github.com/golang/text.git|f21a4dfb5e38f5895301dc265a8def02365cc3d0"
	# docker/docker is not pinned in Gopkg.lock, but the current client imports
	# require this repository to exist in GOPATH mode during compilation.
	"github.com/docker/docker|https://github.com/docker/docker.git|5d6db842238e3c4f5f9fb9ad70ea46b35227d084"
)

usage() {
	cat <<'EOF'
Usage: ./build-arm64-host.sh [OPTIONS]

Build an ARM64 docker-sriov-plugin image on either x86_64 or aarch64 hosts.
The helper cross-compiles on non-ARM hosts, and performs an equivalent native
ARM64 build on aarch64 hosts, then packages the result into an ARM64 runtime
image by using the local Debian ARM64 archive when needed.

Options:
  --dry-run                Print the commands without executing them
  --keep-workdir           Keep the temporary work directory after completion
  --workdir PATH           Reuse a specific temporary work directory
  --image-tag TAG          Override the output image tag
  --runtime-image IMAGE    Override the runtime image tag
  -h, --help               Show this help message

Environment overrides:
  IMAGE_TAG                Output image tag (default: sriov-plugin:test-arm64)
  RUNTIME_IMAGE            Runtime image tag (default: debian:stretch-slim-arm64local)
  RUNTIME_ARCHIVE          Path to the ARM64 Debian OCI archive
  BUILDX_CONFIG            Writable buildx config directory
EOF
}

print_cmd() {
	printf '+'
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

cleanup() {
	if [ -n "$WORKDIR" ] && [ "$KEEP_WORKDIR" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
		rm -rf "$WORKDIR"
	fi
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--dry-run)
				DRY_RUN=1
				;;
			--keep-workdir)
				KEEP_WORKDIR=1
				;;
			--workdir)
				shift
				WORKDIR=${1:-}
				;;
			--image-tag)
				shift
				IMAGE_TAG=${1:-}
				;;
			--runtime-image)
				shift
				RUNTIME_IMAGE=${1:-}
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				echo "unknown option: $1" >&2
				usage >&2
				exit 1
				;;
		esac
		shift
	done
}

require_tools() {
	local tool
	for tool in git go docker; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "missing required tool: $tool" >&2
			exit 1
		fi
	done
}

setup_workdir() {
	if [ -z "$WORKDIR" ]; then
		WORKDIR=$(mktemp -d /tmp/docker-sriov-plugin-arm64.XXXXXX)
	else
		run_cmd mkdir -p "$WORKDIR"
	fi

	GOPATH_ROOT="$WORKDIR/gopath"
	GOCACHE_DIR="$WORKDIR/go-cache"
	BINARY_PATH="$WORKDIR/docker-sriov-plugin-arm64"
	IMAGE_CONTEXT_DIR="$WORKDIR/image-context"

	if [ "$DRY_RUN" -eq 0 ]; then
		mkdir -p "$GOPATH_ROOT/src" "$GOCACHE_DIR" "$IMAGE_CONTEXT_DIR"
	fi
}

find_runtime_source_tag() {
	local candidate
	for candidate in docker.io/debian:stretch-slim debian:stretch-slim; do
		if docker image inspect "$candidate" >/dev/null 2>&1; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

ensure_runtime_image() {
	if docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1; then
		return 0
	fi

	if [ ! -f "$RUNTIME_ARCHIVE" ]; then
		echo "runtime image $RUNTIME_IMAGE is missing and archive was not found: $RUNTIME_ARCHIVE" >&2
		exit 1
	fi

	run_cmd docker load -i "$RUNTIME_ARCHIVE"

	local source_tag
	source_tag=$(find_runtime_source_tag) || {
		echo "failed to locate the loaded Debian runtime image after docker load" >&2
		exit 1
	}

	run_cmd docker tag "$source_tag" "$RUNTIME_IMAGE"
}

fetch_repo() {
	local repo_path="$1"
	local repo_url="$2"
	local repo_rev="$3"
	local repo_dir="$GOPATH_ROOT/src/$repo_path"
	local attempt

	if [ "$DRY_RUN" -eq 0 ]; then
		mkdir -p "$(dirname "$repo_dir")"
		rm -rf "$repo_dir"
		mkdir -p "$repo_dir"
	(
		cd "$repo_dir"
		git init -q
		git remote add origin "$repo_url"
		for attempt in 1 2 3; do
			if git -c http.version=HTTP/1.1 fetch --depth 1 origin "$repo_rev" >/dev/null 2>&1; then
				git checkout -q FETCH_HEAD
				return 0
			fi
			sleep 1
		done
		echo "failed to fetch $repo_path at $repo_rev" >&2
		exit 1
	)
	else
		print_cmd git -c http.version=HTTP/1.1 fetch --depth 1 "$repo_url" "$repo_rev"
	fi
}

prepare_gopath_layout() {
	run_cmd mkdir -p "$GOPATH_ROOT/src"
	if [ "$DRY_RUN" -eq 0 ]; then
		ln -sfn "$REPO_ROOT" "$GOPATH_ROOT/src/docker-sriov-plugin"
	else
		print_cmd ln -sfn "$REPO_ROOT" "$GOPATH_ROOT/src/docker-sriov-plugin"
	fi
}

fetch_dependencies() {
	local dep_entry
	local repo_path
	local repo_url
	local repo_rev

	for dep_entry in "${DEPENDENCIES[@]}"; do
		IFS='|' read -r repo_path repo_url repo_rev <<<"$dep_entry"
		fetch_repo "$repo_path" "$repo_url" "$repo_rev"
	done
}

build_binary() {
	# Keep GOARCH pinned to arm64 so the same script works on both native ARM64
	# hosts and non-ARM hosts that need a cross-compile.
	run_cmd env \
		GOPATH="$GOPATH_ROOT" \
		GOCACHE="$GOCACHE_DIR" \
		GO111MODULE=off \
		GOOS="$TARGET_OS" \
		GOARCH="$TARGET_ARCH" \
		CGO_ENABLED=0 \
		go build -ldflags="-s -w" -o "$BINARY_PATH" "$GOPATH_ROOT/src/docker-sriov-plugin"
}

write_runtime_dockerfile() {
	if [ "$DRY_RUN" -eq 0 ]; then
		cat >"$IMAGE_CONTEXT_DIR/Dockerfile" <<EOF
ARG RUNTIME_IMAGE=$RUNTIME_IMAGE
FROM \${RUNTIME_IMAGE}

COPY docker-sriov-plugin /bin/docker-sriov-plugin
COPY ibdev2netdev /tmp/tools/

CMD ["/bin/docker-sriov-plugin"]
EOF
	else
		print_cmd cat '>' "$IMAGE_CONTEXT_DIR/Dockerfile"
	fi
}

prepare_image_context() {
	run_cmd mkdir -p "$IMAGE_CONTEXT_DIR"
	write_runtime_dockerfile
	run_cmd cp "$BINARY_PATH" "$IMAGE_CONTEXT_DIR/docker-sriov-plugin"
	run_cmd cp "$REPO_ROOT/ibdev2netdev" "$IMAGE_CONTEXT_DIR/ibdev2netdev"
}

package_image() {
	run_cmd mkdir -p "$BUILDX_CONFIG_DIR"
	run_cmd env \
		BUILDX_CONFIG="$BUILDX_CONFIG_DIR" \
		docker buildx build --pull=false \
		--platform "$TARGET_PLATFORM" \
		--build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
		-t "$IMAGE_TAG" \
		--load \
		"$IMAGE_CONTEXT_DIR"
}

main() {
	parse_args "$@"
	trap cleanup EXIT
	require_tools
	setup_workdir
	ensure_runtime_image
	prepare_gopath_layout
	fetch_dependencies
	build_binary
	prepare_image_context
	package_image
}

main "$@"
