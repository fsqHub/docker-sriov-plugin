#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_SCRIPT="$SCRIPT_DIR/build-arm64-host.sh"

if [ ! -x "$BUILD_SCRIPT" ]; then
	echo "missing executable build script: $BUILD_SCRIPT" >&2
	exit 1
fi

OUTPUT=$("$BUILD_SCRIPT" --dry-run)

case "$OUTPUT" in
	*"GOOS=linux GOARCH=arm64"* ) ;;
	* )
		echo "dry-run output does not contain cross-compile command" >&2
		exit 1
	;;
esac

case "$OUTPUT" in
	*"docker buildx build --pull=false --platform linux/arm64"* ) ;;
	* )
		echo "dry-run output does not contain runtime image packaging command" >&2
		exit 1
	;;
esac

case "$OUTPUT" in
	*"debian:stretch-slim-arm64local"* ) ;;
	* )
		echo "dry-run output does not contain the default arm64 runtime image" >&2
		exit 1
	;;
esac

echo "build-arm64-host dry-run smoke test passed"
