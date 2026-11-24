#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
developer_dir=$(xcode-select -p 2>/dev/null) || {
    printf '%s\n' '未找到 Swift 命令行工具。可在终端运行 xcode-select --install 安装。' >&2
    exit 1
}
cache_dir=$(getconf DARWIN_USER_TEMP_DIR)
if [ -d "$developer_dir/SDKs/MacOSX.sdk" ]; then
    exec xcrun swift -sdk "$developer_dir/SDKs/MacOSX.sdk" -module-cache-path "${cache_dir}bbdc-swift-cache" "$script_dir/collect-today.swift" "$@"
fi
exec xcrun swift -module-cache-path "${cache_dir}bbdc-swift-cache" "$script_dir/collect-today.swift" "$@"
