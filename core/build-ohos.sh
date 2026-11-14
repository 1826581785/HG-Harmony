#!/usr/bin/env bash
# 构建 core/ → entry/libs/arm64-v8a/libhg.so
# 用法: 在 HG/core 目录下执行 bash build-ohos.sh [debug|release]
# 依赖: RUSTUP_HOME/CARGO_HOME 指向 D:/opt/rust（本机 Rust 工具链位置）
set -euo pipefail

MODE="${1:-release}"
NDK="D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony"

export RUSTUP_HOME="D:/opt/rust/rustup"
export CARGO_HOME="D:/opt/rust/cargo"
export PATH="D:/opt/rust/cargo/bin:$PATH"
export OHOS_NDK_HOME="$NDK"

cargo build --"$MODE" --target aarch64-unknown-linux-ohos

SO="target/aarch64-unknown-linux-ohos/$MODE/libhg.so"
DEST="../entry/libs/arm64-v8a/libhg.so"
mkdir -p ../entry/libs/arm64-v8a
cp "$SO" "$DEST"
echo "OK: $DEST ($(wc -c < "$DEST") bytes)"
