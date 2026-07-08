#!/bin/bash
# ============================================================
# Qoder Account Switcher 跨平台编译脚本
# ============================================================

set -e

# 创建构建输出目录
DIST_DIR="dist"
mkdir -p "$DIST_DIR"

echo "正在整理 Go 依赖..."
go mod tidy

echo "=============================================="
echo " 开始编译 Qoder Account Switcher..."
echo "=============================================="

# 1. 编译 macOS (Intel)
echo "正在编译 macOS (Intel - amd64)..."
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o "${DIST_DIR}/qoder-switch-macos-amd64" main.go

# 2. 编译 macOS (Apple Silicon)
echo "正在编译 macOS (Apple Silicon - arm64)..."
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o "${DIST_DIR}/qoder-switch-macos-arm64" main.go

# 3. 编译 Windows (64位)
echo "正在编译 Windows (amd64)..."
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o "${DIST_DIR}/qoder-switch-windows-amd64.exe" main.go

echo "=============================================="
echo " 编译完成！文件已输出到 dist/ 目录:"
ls -l "$DIST_DIR"
echo "=============================================="
