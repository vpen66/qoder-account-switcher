#!/bin/bash
# ============================================================
# Qoder Account Switcher 一键安装脚本
# 支持 macOS / Windows (Git Bash)
# ============================================================

set -e

# === 颜色定义 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die() { error "$1"; exit 1; }

# === 配置 GitHub 仓库信息 ===
GITHUB_OWNER="vpen66"
GITHUB_REPO="qoder-account-switcher"

# === 检测操作系统与架构 ===
detect_os() {
    OS_TYPE="$(uname -s)"
    ARCH_TYPE="$(uname -m)"

    case "$OS_TYPE" in
        Darwin*)
            _OS="macos"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            _OS="windows"
            ;;
        Linux*)
            _OS="linux"
            ;;
        *)
            die "不支持的操作系统: $OS_TYPE"
            ;;
    esac
}

detect_os

# === 根据平台匹配下载文件名 ===
get_asset_name() {
    if [ "$_OS" = "macos" ]; then
        if [ "$ARCH_TYPE" = "arm64" ]; then
            echo "qoder-switch-macos-arm64"
        else
            echo "qoder-switch-macos-amd64"
        fi
    elif [ "$_OS" = "windows" ]; then
        echo "qoder-switch-windows-amd64.exe"
    else
        # Linux fallback (尝试 amd64 编译包)
        echo "qoder-switch-macos-amd64"
    fi
}

ASSET_NAME=$(get_asset_name)
DOWNLOAD_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest/download/${ASSET_NAME}"

# === 获取目标安装路径 ===
get_install_dir() {
    if [ "$_OS" = "macos" ] || [ "$_OS" = "linux" ]; then
        if [ -w "/usr/local/bin" ]; then
            echo "/usr/local/bin"
        else
            # 用户级 PATH 路径
            mkdir -p "${HOME}/.local/bin"
            echo "${HOME}/.local/bin"
        fi
    elif [ "$_OS" = "windows" ]; then
        # Git Bash 下的常用 PATH 路径
        mkdir -p "${HOME}/bin"
        echo "${HOME}/bin"
    fi
}

INSTALL_DIR=$(get_install_dir)
TARGET_FILE="${INSTALL_DIR}/qoder-switch"
[ "$_OS" = "windows" ] && TARGET_FILE="${TARGET_FILE}.exe"

# === 下载并安装二进制文件 ===
info "正在从 GitHub 下载最新版本..."
info "链接: ${DOWNLOAD_URL}"

# 创建临时下载文件
TEMP_FILE=$(mktemp)
# mktemp on Windows Git Bash creates under /tmp, curl handles it fine

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DOWNLOAD_URL" -o "$TEMP_FILE" || die "下载失败，请检查网络或 GitHub 仓库地址"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TEMP_FILE" "$DOWNLOAD_URL" || die "下载失败，请检查网络或 GitHub 仓库地址"
else
    die "未检测到 curl 或 wget，请先安装下载工具"
fi

# 移动到目标路径并赋予执行权限
info "正在安装到: ${TARGET_FILE}"
mv "$TEMP_FILE" "$TARGET_FILE"
chmod +x "$TARGET_FILE"

# === 环境配置提示与验证 ===
verify_installation() {
    echo ""
    info "安装成功！"
    echo -e "────────────────────────────────────────────"
    
    # 检测路径是否在 PATH 中
    if [[ ":$PATH:" == *":${INSTALL_DIR}:"* ]]; then
        info "已成功加入系统 PATH 环境变量。"
        info "现在你可以在终端中直接输入以下命令运行切换工具："
        echo -e "  ${BOLD}qoder-switch${NC}"
    else
        warn "安装路径 ${INSTALL_DIR} 尚未包含在你的环境变量 PATH 中！"
        echo -e "请将以下内容添加到你的配置文件（如 ~/.zshrc 或 ~/.bashrc）中："
        echo -e "  ${BOLD}export PATH=\"\$PATH:${INSTALL_DIR}\"${NC}"
        echo -e "修改后，运行 ${BOLD}source ~/.zshrc${NC} (或对应的配置文件) 即可生效。"
    fi
    echo -e "────────────────────────────────────────────"
}

verify_installation
