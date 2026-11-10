#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/../.." && pwd)"
NDK="${OHOS_NDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"
GO="${OHOS_GO:-go}"
export GOTOOLCHAIN=local
export GOWORK=off
if ! "$GO" tool dist list | grep -x 'openharmony/arm64' > /dev/null; then
  printf '%s\n' 'Set OHOS_GO to an OpenHarmony-enabled Go executable.' >&2
  exit 1
fi

cd "$ROOT"
export CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64
export CC="$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
export AR="$NDK/llvm/bin/llvm-ar"
export CGO_CFLAGS="--sysroot=$NDK/sysroot -D__MUSL__ -fPIC"
export CGO_LDFLAGS="--sysroot=$NDK/sysroot -fPIC"
mkdir -p "$PROJECT_ROOT/entry/libs/arm64-v8a"
"$GO" build -mod=readonly -buildmode=c-shared \
  -ldflags '-s -w -extldflags "-Wl,-soname,libtungo.so -Wl,-z,max-page-size=16384"' \
  -o "$PROJECT_ROOT/entry/libs/arm64-v8a/libtungo.so" .
"$NDK/llvm/bin/llvm-nm" -D "$PROJECT_ROOT/entry/libs/arm64-v8a/libtungo.so" | grep -E 'TunStart|TunStop'