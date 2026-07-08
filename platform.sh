#!/bin/bash
# ============================================================
# 平台抽象层 (v1.0)
# 自动检测操作系统 (macOS / Windows / Linux)
# 提供统一的路径、进程、密钥、stat 等接口
# 被 qodercn.sh / qoderworkcn.sh / qoder-account-switcher.sh 引用
# ============================================================

# === 操作系统检测 ===
detect_os() {
    case "$(uname -s)" in
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
            _OS="unknown"
            ;;
    esac
}

detect_os

# === 用户主目录 (跨平台) ===
if [ "$_OS" = "windows" ]; then
    # Git Bash 下 $HOME 通常已经是 Windows 用户目录
    # 但 APPDATA 可能更准确
    _USER_HOME="${USERPROFILE:-$HOME}"
    # 转换 Windows 路径为 Unix 风格 (Git Bash 已自动处理)
    _APPDATA="${APPDATA:-${_USER_HOME}/AppData/Roaming}"
else
    _USER_HOME="$HOME"
    _APPDATA="${_USER_HOME}/Library/Application Support"
fi

# ============================================================
# 应用数据目录根 (跨平台)
# macOS:   ~/Library/Application Support
# Windows: %APPDATA% (C:\Users\<user>\AppData\Roaming)
# ============================================================
get_app_support_dir() {
    echo "$_APPDATA"
}

# ============================================================
# 应用安装检测 (跨平台)
# macOS:   /Applications/<Bundle>.app
# Windows: 注册表 或 Program Files
# ============================================================
_platform_app_is_installed() {
    local bundle="$1"
    local win_exe="$2"   # Windows 可执行文件名 (可选)

    if [ "$_OS" = "macos" ]; then
        [ -d "/Applications/${bundle}.app" ]
    elif [ "$_OS" = "windows" ]; then
        # 1. 检查注册表
        if [ -n "$win_exe" ]; then
            # 尝试从注册表读取卸载信息
            local reg_key
            reg_key=$(reg query "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall" //s //f "$bundle" 2>/dev/null | head -1)
            [ -n "$reg_key" ] && return 0
            reg_key=$(reg query "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall" //s //f "$bundle" 2>/dev/null | head -1)
            [ -n "$reg_key" ] && return 0
        fi
        # 2. 检查常见安装路径
        local pf_unix="/c/Program Files"
        local pf86_unix="/c/Program Files (x86)"
        local lad_unix
        lad_unix=$(echo "${LOCALAPPDATA:-${_USER_HOME}\\AppData\\Local}" | sed 's|\\|/|g' | sed 's|^\([a-zA-Z]\):|/\L\1|I')

        [ -d "${pf_unix}/${bundle}" ] && return 0
        [ -d "${pf86_unix}/${bundle}" ] && return 0
        [ -d "${lad_unix}/${bundle}" ] && return 0
        # 也检查 Programs
        [ -d "${lad_unix}/Programs/${bundle}" ] && return 0
        return 1
    else
        return 1
    fi
}

# ============================================================
# 应用运行检测 (跨平台)
# macOS:   pgrep -f "/<bundle>.app/Contents/MacOS/"
# Windows: tasklist + 进程名
# ============================================================
_platform_app_is_running() {
    local bundle="$1"
    local win_process="$2"   # Windows 进程名 (如 QoderCN.exe)

    if [ "$_OS" = "macos" ]; then
        pgrep -f "/${bundle}.app/Contents/MacOS/" > /dev/null 2>&1
    elif [ "$_OS" = "windows" ]; then
        if [ -n "$win_process" ]; then
            tasklist //FI "IMAGENAME eq ${win_process}" 2>/dev/null | grep -qi "$win_process"
        else
            return 1
        fi
    else
        return 1
    fi
}

# ============================================================
# 强制退出应用 (跨平台)
# macOS:   pkill -9 -f "/<bundle>.app/Contents/MacOS/"
# Windows: taskkill //F //IM <process>
# ============================================================
kill_app() {
    local bundle="$1"
    local win_process="$2"

    if [ "$_OS" = "macos" ]; then
        pkill -9 -f "/${bundle}.app/Contents/MacOS/" 2>/dev/null || true
    elif [ "$_OS" = "windows" ]; then
        if [ -n "$win_process" ]; then
            taskkill //F //IM "$win_process" 2>/dev/null || true
        fi
    fi
}

# ============================================================
# 启动应用 (跨平台)
# macOS:   open -a "<bundle>"
# Windows: start "" "<path>"
# ============================================================
launch_app() {
    local bundle="$1"
    local win_exe_path="$2"   # Windows 完整 exe 路径 (可选，自动探测)

    if [ "$_OS" = "macos" ]; then
        open -a "${bundle}"
    elif [ "$_OS" = "windows" ]; then
        if [ -n "$win_exe_path" ] && [ -f "$win_exe_path" ]; then
            cmd //c start "" "$win_exe_path" 2>/dev/null || true
        else
            # 自动探测
            local pf_unix="/c/Program Files"
            local pf86_unix="/c/Program Files (x86)"
            local lad_unix
            lad_unix=$(echo "${LOCALAPPDATA:-${_USER_HOME}\\AppData\\Local}" | sed 's|\\|/|g' | sed 's|^C:|/c|I')

            local found=""
            for base in "$pf_unix" "$pf86_unix" "$lad_unix" "${lad_unix}/Programs"; do
                if [ -d "${base}/${bundle}" ]; then
                    # 查找 .exe
                    found=$(find "${base}/${bundle}" -maxdepth 1 -name "*.exe" 2>/dev/null | head -1)
                    [ -n "$found" ] && break
                fi
            done

            if [ -n "$found" ]; then
                cmd //c start "" "$found" 2>/dev/null || true
            else
                # fallback: 尝试用 bundle 名直接 start
                cmd //c start "" "$bundle" 2>/dev/null || true
            fi
        fi
    fi
}

# ============================================================
# 获取文件大小 (跨平台)
# macOS:   stat -f%z
# Windows: stat -c%s (Git Bash) 或 wc -c
# ============================================================
file_size() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "0"
        return
    fi
    if [ "$_OS" = "macos" ]; then
        stat -f%z "$file" 2>/dev/null || echo "0"
    else
        # Git Bash / Linux
        stat -c%s "$file" 2>/dev/null || wc -c < "$file" | tr -d ' '
    fi
}

# ============================================================
# OSCrypt 密钥获取 (跨平台)
# macOS:   security find-generic-password -w -s "<service> Safe Storage"
# Windows: DPAPI (通过 powershell 或 python win32crypt)
#
# 返回: base64 编码的密钥 (供 python 解密使用)
#       Windows DPAPI 不需要预派生密钥，直接对密文解密
# ============================================================
get_oscrypt_key_base64() {
    local service="$1"   # 如 "Qoder CN" / "QoderWork CN"

    if [ "$_OS" = "macos" ]; then
        # macOS: 从 Keychain 获取密码，返回原始密码的 base64
        local pw
        pw=$(security find-generic-password -w -s "${service} Safe Storage" 2>/dev/null)
        if [ -n "$pw" ]; then
            printf '%s' "$pw" | base64
        else
            echo ""
        fi
    elif [ "$_OS" = "windows" ]; then
        # Windows: Electron OSCrypt 使用 DPAPI 加密
        # 密文前缀是 "v10" 或 "DPAPI"
        # 返回标记 "DPAPI" 表示需要用 DPAPI 解密
        echo "DPAPI"
    else
        echo ""
    fi
}

# ============================================================
# 获取 OSCrypt 密钥的原始值 (macOS only, 用于兼容旧 python 内联代码)
# Windows 下返回空，python 代码会走 DPAPI 分支
# ============================================================
get_oscrypt_key_raw() {
    local service="$1"

    if [ "$_OS" = "macos" ]; then
        security find-generic-password -w -s "${service} Safe Storage" 2>/dev/null
    else
        echo ""
    fi
}

# ============================================================
# 判断是否为 macOS
# ============================================================
is_macos() {
    [ "$_OS" = "macos" ]
}

# ============================================================
# 判断是否为 Windows
# ============================================================
is_windows() {
    [ "$_OS" = "windows" ]
}

# ============================================================
# 获取操作系统显示名
# ============================================================
os_display_name() {
    case "$_OS" in
        macos)   echo "macOS" ;;
        windows) echo "Windows" ;;
        linux)   echo "Linux" ;;
        *)       echo "Unknown" ;;
    esac
}
