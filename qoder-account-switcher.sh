#!/bin/bash
# ============================================================
# Qoder CN / QoderWork CN 账号切换脚本 (v5.0)
#
# v5.0 改进: 跨平台支持 (macOS / Windows)
#   - 新增 platform.sh 平台抽象层
#   - Windows 使用 DPAPI 解密, macOS 使用 Keychain
#   - Windows 使用 %APPDATA%, macOS 使用 ~/Library/Application Support
#   - install.sh 自动检测系统并安装
#
# v4.1 改进: 拆分为主入口 + qodercn.sh + qoderworkcn.sh
# v4.0 改进:
#   1. 目录结构: accounts/qodercn/ 和 accounts/qoderwork/ 分开
#   2. 交互式 UI: 左右键选应用 → 上下键选操作 → 上下键选账号
#   3. 同名账号在不同应用下互不冲突
#
# 用法:
#   ./qoder-account-switcher.sh                  # 交互模式
#   ./qoder-account-switcher.sh save <别名>       # 保存当前登录态
#   ./qoder-account-switcher.sh list              # 列出所有已保存账号
#   ./qoder-account-switcher.sh switch <别名>     # 切换到指定账号
#   ./qoder-account-switcher.sh delete <别名>     # 删除某个账号备份
#   ./qoder-account-switcher.sh status            # 查看两个应用的状态
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === 加载平台抽象层 (必须最先加载) ===
source "${SCRIPT_DIR}/platform.sh"

# === 加载子模块 ===
source "${SCRIPT_DIR}/qodercn.sh"
source "${SCRIPT_DIR}/qoderworkcn.sh"

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
REV='\033[7m'

die() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
hint() { echo -e "${CYAN}[HINT]${NC} $1"; }

BACKUP_ROOT="${HOME}/.qoder-account-switcher/accounts"

# ============================================================
# 终端键盘输入工具函数
# ============================================================

# 检查是否在交互式终端中
is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

# 保存终端设置
save_term() {
    if [ -t 0 ]; then
        stty -g 2>/dev/null
    fi
}

# 恢复终端设置
restore_term() {
    local saved="$1"
    [ -z "$saved" ] && return
    stty "$saved" 2>/dev/null
}

# 读取单键（支持方向键、回车）
read_key() {
    if ! [ -t 0 ]; then
        echo "Q"
        return
    fi

    local saved=$(save_term)
    stty raw -echo 2>/dev/null || { restore_term "$saved"; echo "Q"; return; }

    local key
    key=$(dd bs=1 count=1 2>/dev/null) || key=""
    restore_term "$saved"

    if [ -z "$key" ]; then
        echo "Q"
        return
    fi

    if [ "$key" = $'\x1b' ]; then
        local saved2=$(save_term)
        stty raw -echo 2>/dev/null || { restore_term "$saved2"; echo "ESC"; return; }
        local seq
        seq=$(dd bs=1 count=1 2>/dev/null) || seq=""
        restore_term "$saved2"

        if [ "$seq" = "[" ]; then
            local saved3=$(save_term)
            stty raw -echo 2>/dev/null || { restore_term "$saved3"; echo "ESC"; return; }
            key=$(dd bs=1 count=1 2>/dev/null) || key=""
            restore_term "$saved3"
            case "$key" in
                A) echo "UP" ;;
                B) echo "DOWN" ;;
                C) echo "RIGHT" ;;
                D) echo "LEFT" ;;
                *) echo "ESC" ;;
            esac
        else
            echo "ESC"
        fi
    elif [ "$key" = $'\x0a' ] || [ "$key" = $'\x0d' ]; then
        echo "ENTER"
    elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
        echo "Q"
    else
        echo "$key"
    fi
}

# 清屏并重绘
redraw() {
    if { true >&3; } 2>/dev/null; then
        printf '\033[3J\033[2J\033[H' >&3
    else
        printf '\033[3J\033[2J\033[H' >&2
    fi
}

# 隐藏光标
hide_cursor() { printf '\033[?25l'; }
# 显示光标
show_cursor() { printf '\033[?25h'; }

# 输出到终端（绕过 $() 捕获）
render() {
    if { true >&3; } 2>/dev/null; then
        printf '%b\r\n' "$*" >&3
    else
        printf '%b\r\n' "$*" >&2
    fi
}

# 逐字符读取一行输入，支持回退键删除，左键取消，回车确认
read_line_with_cancel() {
    _INPUT_RESULT=""
    local buffer=""
    local saved_term
    local key

    while true; do
        saved_term=$(save_term)
        stty raw -echo 2>/dev/null || { restore_term "$saved_term"; break; }
        key=$(dd bs=1 count=1 2>/dev/null) || key=""
        restore_term "$saved_term"

        if [ -z "$key" ]; then
            break
        fi

        if [ "$key" = $'\x1b' ]; then
            local saved2=$(save_term)
            stty raw -echo 2>/dev/null || { restore_term "$saved2"; break; }
            local seq
            seq=$(dd bs=1 count=1 2>/dev/null) || seq=""
            restore_term "$saved2"

            if [ "$seq" = "[" ]; then
                local saved3=$(save_term)
                stty raw -echo 2>/dev/null || { restore_term "$saved3"; break; }
                key=$(dd bs=1 count=1 2>/dev/null) || key=""
                restore_term "$saved3"
                case "$key" in
                    D) # LEFT - 取消输入
                        _INPUT_RESULT=""
                        return 1
                        ;;
                    3) # DEL (可能是 \x1b[3~)
                        local saved4=$(save_term)
                        stty raw -echo 2>/dev/null || { restore_term "$saved4"; break; }
                        local tilde
                        tilde=$(dd bs=1 count=1 2>/dev/null) || tilde=""
                        restore_term "$saved4"
                        if [ "$tilde" = "~" ] && [ -n "$buffer" ]; then
                            buffer="${buffer%?}"
                            printf '\b \b' >&2
                        fi
                        ;;
                esac
            fi
        elif [ "$key" = $'\x7f' ]; then
            if [ -n "$buffer" ]; then
                buffer="${buffer%?}"
                printf '\b \b' >&2
            fi
        elif [ "$key" = $'\x0a' ] || [ "$key" = $'\x0d' ]; then
            printf '\n' >&2
            _INPUT_RESULT="$buffer"
            return 0
        elif [ "$key" = $'\x09' ]; then
            :
        elif [ "$key" = $'\x03' ]; then
            printf '\n' >&2
            _INPUT_RESULT=""
            return 1
        elif [ "$(printf '%d' "'$key")" -ge 32 ] 2>/dev/null; then
            buffer="${buffer}${key}"
            printf '%s' "$key" >&2
        fi
    done
    return 1
}

# ============================================================
# 通用：检测应用是否安装/运行 (委托给平台抽象层)
# ============================================================
app_is_running() {
    local bundle="$1"
    local win_process="$2"
    # 平台抽象层函数 (同名, 来自 platform.sh)
    _platform_app_is_running "$bundle" "$win_process"
}

app_is_installed() {
    local bundle="$1"
    local win_exe="$2"
    _platform_app_is_installed "$bundle" "$win_exe"
}

# ============================================================
# 根据应用类型获取配置（统一接口）
# ============================================================
get_app_config() {
    local app_type="$1"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        APP_DATA="$QODERWORK_APP_DATA"
        APP_BUNDLE="$QODERWORK_BUNDLE"
        APP_TYPE="$QODERWORK_TYPE"
        APP_LABEL="QoderWork CN"
        APP_FILES=("${QODERWORK_FILES[@]}")
        APP_WIN_PROCESS="$QODERWORK_WIN_PROCESS"
        APP_WIN_EXE="$QODERWORK_WIN_EXE"
    else
        APP_DATA="$QODERCN_APP_DATA"
        APP_BUNDLE="$QODERCN_BUNDLE"
        APP_TYPE="$QODERCN_TYPE"
        APP_LABEL="Qoder CN"
        APP_FILES=("${QODERCN_FILES[@]}")
        APP_WIN_PROCESS="$QODERCN_WIN_PROCESS"
        APP_WIN_EXE="$QODERCN_WIN_EXE"
    fi

    ACCOUNT_BACKUP_DIR="${BACKUP_ROOT}/${APP_TYPE}"
}

# ============================================================
# 通用：检测登录态（根据应用类型分发）
# ============================================================
has_login_state() {
    local app_type="$1"
    local app_data="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_has_login_state "$app_data"
    else
        qodercn_has_login_state "$app_data"
    fi
}

# ============================================================
# 通用：获取当前登录用户名（根据应用类型分发）
# ============================================================
get_current_user_info() {
    local app_type="$1"
    local app_data="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_get_current_user_info "$app_data"
    else
        qodercn_get_current_user_info "$app_data"
    fi
}

# ============================================================
# 通用：获取用户元信息 JSON（根据应用类型分发）
# ============================================================
get_user_meta_json() {
    local app_type="$1"
    local app_data="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_get_user_meta_json "$app_data"
    else
        qodercn_get_user_meta_json "$app_data"
    fi
}

# ============================================================
# 通用：判断备份账号是否为当前使用的账号（根据应用类型分发）
# ============================================================
is_current_account() {
    local app_type="$1"
    local account_dir="$2"
    local app_data="$3"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_is_current_account "$account_dir" "$app_data"
    else
        qodercn_is_current_account "$account_dir" "$app_data"
    fi
}

# ============================================================
# 通用：保存账号特有的文件操作（根据应用类型分发）
# ============================================================
save_account_extra_files() {
    local app_type="$1"
    local account_dir="$2"
    local app_data="$3"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_save_account_files "$account_dir" "$app_data"
    else
        qodercn_save_account_files "$account_dir" "$app_data"
    fi
}

# ============================================================
# 通用：清除登录态（根据应用类型分发）
# ============================================================
clear_login_state() {
    local app_type="$1"
    local app_data="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_clear_login_state "$app_data"
    else
        qodercn_clear_login_state "$app_data"
    fi
}

# ============================================================
# 通用：恢复 secret 和 token（根据应用类型分发）
# ============================================================
restore_secrets_and_token() {
    local app_type="$1"
    local account_dir="$2"
    local app_data="$3"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_restore_secrets_and_token "$account_dir" "$app_data"
    else
        qodercn_restore_secrets_and_token "$account_dir" "$app_data"
    fi
}

# ============================================================
# 通用：构建 .meta.json 中的用户信息（根据应用类型分发）
# ============================================================
build_meta_json() {
    local app_type="$1"
    local user_meta="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_build_meta_json "$user_meta"
    else
        qodercn_build_meta_json "$user_meta"
    fi
}

# ============================================================
# 通用：打印应用状态（根据应用类型分发）
# ============================================================
print_app_status() {
    local app_type="$1"
    local app_data="$2"

    if [ "$app_type" = "$QODERWORK_TYPE" ]; then
        qoderwork_print_app_status "$app_data"
    else
        qodercn_print_app_status "$app_data"
    fi
}

# ============================================================
# 获取某应用下已备份的账号列表
# ============================================================
get_saved_accounts() {
    local app_type="$1"
    local dir="${BACKUP_ROOT}/${app_type}"
    if [ ! -d "$dir" ]; then
        echo ""
        return
    fi

    for d in "${dir}"/*/; do
        [ -d "$d" ] || continue
        local alias=$(basename "$d")
        local meta="${d}.meta.json"
        local display="?"
        local date="?"
        if [ -f "$meta" ]; then
            display=$(python3 -c "
import json
try:
    d = json.load(open('$meta'))
    name = d.get('name','') or d.get('username','') or d.get('display_name','?')
    print(name)
except:
    print('?')
" 2>/dev/null || echo "?")
            date=$(python3 -c "import json; d=json.load(open('$meta')); print(d.get('saved_at','?'))" 2>/dev/null || echo "?")
        fi
        echo "${alias}|${display}|${date}"
    done | sort
}

# ============================================================
# 交互式菜单绘制
# ============================================================

draw_header() {
    local title="$1"
    render ""
    render "${BOLD}============================================${NC}"
    render "${BOLD}  ${title}${NC}"
    render "${BOLD}============================================${NC}"
    render ""
}

draw_footer() {
    render ""
    render "${CYAN}────────────────────────────────────────────${NC}"
    case "$1" in
        app_select)
            render "  ${BOLD}↑ ↓${NC} 选择应用    ${BOLD}Enter${NC} 进入下级    ${BOLD}←${NC} 返回"
            ;;
        op_select)
            render "  ${BOLD}↑ ↓${NC} 选择操作    ${BOLD}Enter${NC} 进入下级    ${BOLD}←${NC} 返回"
            ;;
        account_select)
            render "  ${BOLD}↑ ↓${NC} 选择账号    ${BOLD}Enter${NC} 确认    ${BOLD}←${NC} 返回"
            ;;
    esac
}

# 应用选择菜单 (上下键)
select_app_interactive() {
    _SELECT_RESULT=""
    local apps=("$QODERCN_TYPE" "$QODERWORK_TYPE")
    local labels=("Qoder CN" "QoderWork CN")
    local installed=()
    local display_labels=()

    for i in "${!apps[@]}"; do
        local bundle win_exe win_proc
        if [ "${apps[$i]}" = "$QODERCN_TYPE" ]; then
            bundle="$QODERCN_BUNDLE"; win_exe="$QODERCN_WIN_EXE"; win_proc="$QODERCN_WIN_PROCESS"
        else
            bundle="$QODERWORK_BUNDLE"; win_exe="$QODERWORK_WIN_EXE"; win_proc="$QODERWORK_WIN_PROCESS"
        fi
        if app_is_installed "$bundle" "$win_exe"; then
            installed+=("${apps[$i]}")
            local running=""
            app_is_running "$bundle" "$win_proc" && running=" ${GREEN}●运行中${NC}" || running=" ${RED}○未运行${NC}"
            display_labels+=("${labels[$i]}${running}")
        fi
    done

    if [ ${#installed[@]} -eq 0 ]; then
        render ""
        render "${RED}未检测到 Qoder CN 或 QoderWork CN，请确认已安装${NC}"
        render ""
        return 1
    fi

    if [ ${#installed[@]} -eq 1 ]; then
        _SELECT_RESULT="${installed[0]}"
        return 0
    fi

    local idx=0
    while true; do
        redraw
        draw_header "选择应用"
        render ""
        for i in "${!display_labels[@]}"; do
            if [ $i -eq $idx ]; then
                render "  ${REV} ▶ ${display_labels[$i]} ${NC}"
            else
                render "    ${display_labels[$i]}"
            fi
        done
        draw_footer "app_select"

        local key=$(read_key)
        case "$key" in
            UP)    idx=$(( (idx - 1 + ${#display_labels[@]}) % ${#display_labels[@]} )) ;;
            DOWN)  idx=$(( (idx + 1) % ${#display_labels[@]} )) ;;
            RIGHT|ENTER) break ;;
            LEFT)  return 1 ;;
            Q)     return 1 ;;
        esac
    done

    _SELECT_RESULT="${installed[$idx]}"
    return 0
}

# 操作选择菜单 (上下键)
select_operation() {
    _SELECT_RESULT=""
    local ops=("switch" "save" "list" "delete" "status")
    local op_labels=(
        "切换账号   (切换到已保存的账号)"
        "保存账号   (保存当前登录态)"
        "列出账号   (查看该应用下的所有备份)"
        "删除账号   (删除某个账号备份)"
        "查看状态   (查看该应用当前的登录状态)"
    )

    local idx=0
    while true; do
        redraw
        local app_label
        [ "$app_type" = "$QODERCN_TYPE" ] && app_label="Qoder CN" || app_label="QoderWork CN"
        draw_header "应用: ${app_label}"
        render ""
        for i in "${!op_labels[@]}"; do
            if [ $i -eq $idx ]; then
                render "  ${REV} ▶ ${op_labels[$i]} ${NC}"
            else
                render "    ${op_labels[$i]}"
            fi
        done
        draw_footer "op_select"

        local key=$(read_key)
        case "$key" in
            UP)    idx=$(( (idx - 1 + ${#op_labels[@]}) % ${#op_labels[@]} )) ;;
            DOWN)  idx=$(( (idx + 1) % ${#op_labels[@]} )) ;;
            RIGHT|ENTER) break ;;
            LEFT)  return 2 ;;
            Q)     return 1 ;;
        esac
    done

    _SELECT_RESULT="${ops[$idx]}"
    return 0
}

# 账号选择菜单 (上下键)
select_account() {
    _SELECT_RESULT=""
    local app_type="$1"
    local accounts_str
    accounts_str=$(get_saved_accounts "$app_type")

    if [ -z "$accounts_str" ]; then
        render ""
        render "${CYAN}[HINT]${NC} 该应用下还没有保存任何账号"
        render ""
        printf '  \033[1m← \033[0m返回\n' >&2
        local _dummy=$(read_key)
        return 1
    fi

    local aliases=()
    local displays=()
    local dates=()
    while IFS='|' read -r alias display date; do
        [ -z "$alias" ] && continue
        aliases+=("$alias")
        displays+=("$display")
        dates+=("$date")
    done <<< "$accounts_str"

    # 预计算当前使用的账号索引
    get_app_config "$app_type"
    local current_idx=-1
    for i in "${!aliases[@]}"; do
        local account_dir="${BACKUP_ROOT}/${app_type}/${aliases[$i]}"
        if is_current_account "$app_type" "$account_dir" "$APP_DATA"; then
            current_idx=$i
            break
        fi
    done

    local idx=0
    while true; do
        redraw
        local app_label
        [ "$app_type" = "$QODERCN_TYPE" ] && app_label="Qoder CN" || app_label="QoderWork CN"
        draw_header "选择账号 — ${app_label}"
        render ""
        if [ ${#aliases[@]} -eq 0 ]; then
            render "  ${YELLOW}没有可用的账号备份${NC}"
        fi
        for i in "${!aliases[@]}"; do
            local marker=""
            if [ $i -eq $current_idx ]; then
                marker=" ${GREEN}★ 当前使用${NC}"
            fi
            if [ $i -eq $idx ]; then
                render "  ${REV} ▶ ${aliases[$i]}  →  ${displays[$i]}  (${dates[$i]})${marker} ${NC}"
            else
                render "    ${aliases[$i]}  →  ${displays[$i]}  (${dates[$i]})${marker}"
            fi
        done
        draw_footer "account_select"

        local key=$(read_key)
        case "$key" in
            UP)    idx=$(( (idx - 1 + ${#aliases[@]}) % ${#aliases[@]} )) ;;
            DOWN)  idx=$(( (idx + 1) % ${#aliases[@]} )) ;;
            RIGHT|ENTER) break ;;
            LEFT)  return 2 ;;
            Q)     return 1 ;;
        esac
    done

    _SELECT_RESULT="${aliases[$idx]}"
    return 0
}

# ============================================================
# SAVE - 保存当前账号登录态
# ============================================================
cmd_save() {
    local alias="$1"
    local app_type="$2"

    if [ -z "$app_type" ]; then
        select_app_interactive
        [ $? -ne 0 ] && { info "已取消"; return; }
        app_type="$_SELECT_RESULT"
        [ -z "$app_type" ] && return
    fi

    get_app_config "$app_type"

    if [ -z "$alias" ]; then
        local default_alias=""
        default_alias=$(get_current_user_info "$APP_TYPE" "$APP_DATA")
        if [ "$default_alias" = "(已登录)" ]; then
            default_alias=""
        fi
        if [ -n "$default_alias" ]; then
            printf '%s' "请输入账号别名（默认: ${default_alias}）: " >&2
            read -r alias
            [ -z "$alias" ] && alias="$default_alias"
        else
            printf '%s' "请输入账号别名: " >&2
            read -r alias
            [ -z "$alias" ] && { die "别名不能为空"; }
        fi
    fi

    if ! has_login_state "$APP_TYPE" "$APP_DATA"; then
        warn "============================================"
        warn "未检测到有效的登录态！"
        warn "当前 ${APP_LABEL} 似乎没有登录任何账号。"
        warn "请先在 ${APP_LABEL} 中登录目标账号，再执行 save。"
        warn "============================================"
        printf '%b\n' "按 ${BOLD}Enter${NC} 取消，按 ${BOLD}y${NC} 强制保存: " >&2
        local force_key
        while true; do
            force_key=$(read_key)
            case "$force_key" in
                ENTER|LEFT|n|N|Q|ESC) force="n"; break ;;
                y|Y) force="y"; break ;;
            esac
        done
        if [ "$force" != "y" ]; then
            echo ""
            info "已取消"
            return
        fi
    fi

    local current_user=$(get_current_user_info "$APP_TYPE" "$APP_DATA")
    if [ -z "$current_user" ]; then
        warn "无法获取当前登录用户名（登录态数据是加密的）"
        printf '%s' "请输入此账号的显示名称（用于列表识别）: " >&2
        read -r current_user
        if [ -z "$current_user" ]; then
            current_user="(未命名)"
        fi
    fi

    local account_dir="${ACCOUNT_BACKUP_DIR}/${alias}"

    if [ -d "$account_dir" ]; then
        warn "账号 '${alias}' 在 ${APP_LABEL} 下已存在，将覆盖"
        rm -rf "$account_dir"
    fi

    mkdir -p "$account_dir"

    # 1. 复制应用相关的文件
    info "正在保存账号 '${alias}' 的登录态文件..."
    info "  应用: ${APP_LABEL}"
    local file_count=0
    for rel_path in "${APP_FILES[@]}"; do
        local src="${APP_DATA}/${rel_path}"
        if [ -f "$src" ]; then
            local dst_dir="${account_dir}/$(dirname "$rel_path")"
            mkdir -p "$dst_dir"
            cp -p "$src" "${account_dir}/${rel_path}"
            info "  ✓ ${rel_path}"
            ((file_count++))
        else
            warn "  ✗ ${rel_path} (不存在，跳过)"
        fi
    done

    # 2. 应用特有的额外文件操作
    save_account_extra_files "$APP_TYPE" "$account_dir" "$APP_DATA"

    # 3. 从 state.vscdb 或 auth-v2.dat 解析用户详细信息
    local user_meta="{}"
    info "正在解析用户信息..."
    user_meta=$(get_user_meta_json "$APP_TYPE" "$APP_DATA")
    if [ "$user_meta" != "{}" ] && [ -n "$user_meta" ]; then
        info "  ✓ 已解析用户元信息"
    else
        warn "  ✗ 未能解析用户元信息"
    fi

    # 4. 写入元信息
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    local now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local extra_meta="{}"
    extra_meta=$(build_meta_json "$APP_TYPE" "$user_meta")

    python3 -c "
import json

extra_meta = json.loads('''${extra_meta}''')

meta = {
    'alias': '${alias}',
    'display_name': '${current_user}',
    'app': '${APP_LABEL}',
    'app_type': '${APP_TYPE}',
    'saved_at': '${now}',
    'saved_at_iso': '${now_iso}',
    'version': '4.1',
    'file_count': ${file_count},
}

# 合并应用特有的元信息
meta.update(extra_meta)

with open('${account_dir}/.meta.json', 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
        cat > "${account_dir}/.meta.json" << EOFF
{
    "alias": "${alias}",
    "display_name": "${current_user}",
    "app": "${APP_LABEL}",
    "app_type": "${APP_TYPE}",
    "saved_at": "${now}",
    "version": "4.0",
    "file_count": ${file_count}
}
EOFF
    }

    echo ""
    info "============================================"
    info "账号 '${alias}' 保存成功！"
    info "  应用:   ${APP_LABEL}"
    info "  用户:   ${current_user}"
    info "  文件数: ${file_count}"
    info "  位置:   ${account_dir}"
    info "============================================"
}

# ============================================================
# LIST - 列出所有已保存账号
# ============================================================
cmd_list() {
    local app_type="$1"

    local has_any=false
    local app_types=()
    if [ -n "$app_type" ]; then
        app_types=("$app_type")
    else
        app_types=("$QODERCN_TYPE" "$QODERWORK_TYPE")
    fi

    for at in "${app_types[@]}"; do
        local dir="${BACKUP_ROOT}/${at}"
        [ -d "$dir" ] || continue

        local app_label
        [ "$at" = "$QODERCN_TYPE" ] && app_label="Qoder CN" || app_label="QoderWork CN"

        local first=true
        for d in "${dir}"/*/; do
            [ -d "$d" ] || continue
            if $first; then
                echo ""
                echo "============================================"
                echo -e "  ${GREEN}${app_label}${NC}"
                echo "============================================"
                first=false
                has_any=true
            fi
            local alias=$(basename "$d")
            local meta="${d}.meta.json"
            local marker=""

            # 获取该应用的数据目录来判断当前账号
            local app_data
            [ "$at" = "$QODERCN_TYPE" ] && app_data="$QODERCN_APP_DATA" || app_data="$QODERWORK_APP_DATA"
            if is_current_account "$at" "$d" "$app_data"; then
                marker=" ${GREEN}★ 当前使用${NC}"
            fi
            if [ -f "$meta" ]; then
                local name=$(python3 -c "
import json
try:
    d = json.load(open('$meta'))
    name = d.get('name','') or d.get('username','') or d.get('display_name','?')
    print(name)
except:
    print('?')
" 2>/dev/null || echo "?")
                local date=$(python3 -c "import json; d=json.load(open('$meta')); print(d.get('saved_at','?'))" 2>/dev/null || echo "?")
                echo -e "  ${GREEN}${alias}${NC}  →  ${name}  (${date})${marker}"
            else
                echo -e "  ${YELLOW}${alias}${NC}  →  (无元信息)${marker}"
            fi
        done
    done

    if ! $has_any; then
        hint "还没有保存任何账号备份"
        echo ""
        hint "使用方法: $0 save <账号别名>"
    fi
    echo ""
}

# ============================================================
# SWITCH - 切换到指定账号
# ============================================================
cmd_switch() {
    local alias="$1"
    local app_type="$2"

    if [ -z "$app_type" ]; then
        select_app_interactive
        [ $? -ne 0 ] && { info "已取消"; return; }
        app_type="$_SELECT_RESULT"
        [ -z "$app_type" ] && return
    fi

    get_app_config "$app_type"

    if [ -z "$alias" ]; then
        select_account "$app_type"
        local ret=$?
        alias="$_SELECT_RESULT"
        if [ $ret -eq 1 ]; then info "已取消"; return; fi
        if [ $ret -eq 2 ]; then return; fi
        [ -z "$alias" ] && { hint "没有可用的账号"; return; }
    fi

    local account_dir="${ACCOUNT_BACKUP_DIR}/${alias}"
    if [ ! -d "$account_dir" ]; then
        die "账号 '${alias}' 在 ${APP_LABEL} 下不存在，请先 save"
    fi

    local target_name=""
    if [ -f "${account_dir}/.meta.json" ]; then
        target_name=$(python3 -c "
import json
try:
    d = json.load(open('${account_dir}/.meta.json'))
    name = d.get('name','') or d.get('username','') or d.get('display_name','')
    print(name)
except:
    print('')
" 2>/dev/null)
    fi

    if ! app_is_installed "$APP_BUNDLE" "$APP_WIN_EXE"; then
        die "${APP_LABEL} 未安装"
    fi

    # 一次确认：按 Enter 重启应用（退出 → 切换 → 启动），按 ← 返回
    echo ""
    printf '%b\n' "按 ${BOLD}Enter${NC} 重启 ${APP_LABEL} 并切换到 ${alias}，按 ${BOLD}←${NC} 返回: " >&2
    local confirm_key
    while true; do
        confirm_key=$(read_key)
        case "$confirm_key" in
            ENTER|RIGHT) confirm="y"; break ;;
            LEFT|ESC|Q)  confirm="n"; break ;;
            y|Y) confirm="y"; break ;;
            n|N) confirm="n"; break ;;
        esac
    done
    if [ "$confirm" != "y" ]; then
        echo ""
        info "已取消"
        return
    fi

    # 强制退出应用（如果在运行）
    if app_is_running "$APP_BUNDLE" "$APP_WIN_PROCESS"; then
        info "正在强制退出 ${APP_LABEL}..."
        # 直接强制终止进程，避免 QoderWork 弹出退出确认对话框
        local attempts=0
        while app_is_running "$APP_BUNDLE" "$APP_WIN_PROCESS" && [ $attempts -lt 6 ]; do
            kill_app "$APP_BUNDLE" "$APP_WIN_PROCESS"
            sleep 0.5
            attempts=$((attempts + 1))
        done

        if app_is_running "$APP_BUNDLE" "$APP_WIN_PROCESS"; then
            die "${APP_LABEL} 未能完全退出，请手动退出后重试"
        fi
        info "${APP_LABEL} 已完全退出"
    fi

    echo ""
    info "============================================"
    info "正在切换到账号: ${alias} (${target_name})"
    info "目标应用: ${APP_LABEL}"
    info "============================================"

    # 1. 清除当前登录态
    clear_login_state "$APP_TYPE" "$APP_DATA"

    # 2. 注入目标账号的文件
    info "正在注入账号 '${alias}' 的登录态..."
    local restored=0
    for rel_path in "${APP_FILES[@]}"; do
        local src="${account_dir}/${rel_path}"
        local dst="${APP_DATA}/${rel_path}"
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -p "$src" "$dst"
            info "  ✓ ${rel_path}"
            ((restored++))
        fi
    done

    # 3. 应用特有的恢复操作
    restore_secrets_and_token "$APP_TYPE" "$account_dir" "$APP_DATA"

    echo ""
    info "============================================"
    info "账号切换完成！"
    info "  账号: ${alias} (${target_name})"
    info "  应用: ${APP_LABEL}"
    info "  已恢复 ${restored} 个文件"
    info "============================================"

    info "正在启动 ${APP_LABEL}..."
    launch_app "$APP_BUNDLE" ""
    info "${APP_LABEL} 已启动"
}

# ============================================================
# DELETE - 删除某个账号备份
# ============================================================
cmd_delete() {
    local alias="$1"
    local app_type="$2"

    if [ -z "$app_type" ]; then
        select_app_interactive
        [ $? -ne 0 ] && { info "已取消"; return; }
        app_type="$_SELECT_RESULT"
        [ -z "$app_type" ] && return
    fi

    get_app_config "$app_type"

    if [ -z "$alias" ]; then
        select_account "$app_type"
        local ret=$?
        alias="$_SELECT_RESULT"
        if [ $ret -eq 1 ]; then info "已取消"; return; fi
        if [ $ret -eq 2 ]; then return; fi
        [ -z "$alias" ] && { hint "没有可用的账号"; return; }
    fi

    local account_dir="${ACCOUNT_BACKUP_DIR}/${alias}"
    if [ ! -d "$account_dir" ]; then
        die "账号 '${alias}' 在 ${APP_LABEL} 下不存在"
    fi

    printf '%b' "确认删除 ${APP_LABEL} 下的账号 '${alias}'？" >&2
    printf '\n' >&2
    printf '%b' "${CYAN}────────────────────────────────────────────${NC}" >&2
    printf '\n' >&2
    printf '%b' "  ${BOLD}Enter${NC} 确认    ${BOLD}←${NC} 取消" >&2
    printf '\033[2A' >&2
    printf '\r' >&2
    printf '%b' "确认删除 ${APP_LABEL} 下的账号 '${alias}'？" >&2
    local del_key
    while true; do
        del_key=$(read_key)
        case "$del_key" in
            ENTER|y|Y) confirm="y"; break ;;
            LEFT|n|N|Q|ESC) confirm="n"; break ;;
        esac
    done
    if [ "$confirm" != "y" ]; then
        echo ""
        return 2
    fi

    rm -rf "$account_dir"
    info "账号 '${alias}' 已从 ${APP_LABEL} 删除"
}

# ============================================================
# STATUS - 显示两个应用的状态
# ============================================================
cmd_status() {
    echo ""
    echo "============================================"
    echo "  Qoder 应用登录状态"
    echo "============================================"

    print_app_status "$QODERCN_TYPE" "$QODERCN_APP_DATA"
    print_app_status "$QODERWORK_TYPE" "$QODERWORK_APP_DATA"

    echo ""
    echo "============================================"
    echo ""

    cmd_list
}

# ============================================================
# 交互式主菜单
# ============================================================
interactive_main() {
    if ! is_interactive; then
        echo ""
        warn "当前环境不支持交互式模式（非 TTY 终端）"
        echo ""
        hint "请使用命令行模式:"
        hint "  $0 save <别名>       保存账号"
        hint "  $0 list              列出账号"
        hint "  $0 switch <别名>     切换账号"
        hint "  $0 status            查看状态"
        echo ""
        return
    fi

    exec 3>&1
    hide_cursor
    trap 'stty sane 2>/dev/null; show_cursor; exec 3>&-' EXIT

    local app_type
    while true; do
        select_app_interactive
        ret=$?
        app_type="$_SELECT_RESULT"
        if [ $ret -ne 0 ] || [ -z "$app_type" ]; then
            stty sane 2>/dev/null; show_cursor
            printf '\n' >&3 2>/dev/null
            info "再见！"
            exit 0
        fi

        get_app_config "$app_type"

        local op
        while true; do
            select_operation "$app_type"
            ret=$?
            op="$_SELECT_RESULT"
            if [ $ret -eq 2 ]; then
                break
            fi
            if [ $ret -ne 0 ] || [ -z "$op" ]; then
                stty sane 2>/dev/null; show_cursor
                echo ""
                info "再见！"
                exit 0
            fi

            local tmp_out="${TMPDIR:-/tmp}/qoder-out-$$"
            case "$op" in
                switch)
                    select_account "$app_type"
                    ret=$?
                    local alias="$_SELECT_RESULT"
                    if [ $ret -eq 2 ]; then continue; fi
                    if [ $ret -eq 1 ] || [ -z "$alias" ]; then continue; fi
                    redraw
                    stty sane 2>/dev/null; show_cursor
                    cmd_switch "$alias" "$app_type" > "$tmp_out"
                    stty raw -echo 2>/dev/null; hide_cursor
                    redraw
                    if [ -f "$tmp_out" ]; then
                        while IFS= read -r line || [ -n "$line" ]; do
                            render "$line"
                        done < "$tmp_out"
                        rm -f "$tmp_out"
                    fi
                    render ""
                    render "  ${BOLD}←${NC} 返回操作菜单    ${BOLD}Q${NC} 退出"
                    local _dummy=$(read_key)
                    ;;
                save)
                    redraw
                    stty sane 2>/dev/null; show_cursor
                    local alias
                    local default_alias=""
                    default_alias=$(get_current_user_info "$app_type" "$APP_DATA")
                    if [ "$default_alias" = "(已登录)" ]; then
                        default_alias=""
                    fi
                    if [ -n "$default_alias" ]; then
                        printf '%s' "请输入账号别名（默认: ${default_alias}）: " >&2
                    else
                        printf '%s' "请输入账号别名: " >&2
                    fi
                    printf '\n' >&2
                    printf '%b' "${CYAN}────────────────────────────────────────────${NC}" >&2
                    printf '\n' >&2
                    printf '%b' "  ${BOLD}Enter 确认    ← 返回${NC}" >&2
                    printf '\033[2A' >&2
                    printf '\r' >&2
                    if [ -n "$default_alias" ]; then
                        printf '%s' "请输入账号别名（默认: ${default_alias}）: " >&2
                    else
                        printf '%s' "请输入账号别名: " >&2
                    fi
                    read_line_with_cancel
                    local read_ret=$?
                    alias="$_INPUT_RESULT"
                    if [ $read_ret -ne 0 ]; then
                        stty raw -echo 2>/dev/null; hide_cursor
                        continue
                    fi
                    [ -z "$alias" ] && alias="$default_alias"
                    if [ -z "$alias" ]; then
                        stty raw -echo 2>/dev/null; hide_cursor
                        continue
                    fi
                    cmd_save "$alias" "$app_type" > "$tmp_out"
                    stty raw -echo 2>/dev/null; hide_cursor
                    redraw
                    if [ -f "$tmp_out" ]; then
                        while IFS= read -r line || [ -n "$line" ]; do
                            render "$line"
                        done < "$tmp_out"
                        rm -f "$tmp_out"
                    fi
                    render ""
                    render "  ${BOLD}←${NC} 返回操作菜单    ${BOLD}Q${NC} 退出"
                    local _dummy=$(read_key)
                    ;;
                list)
                    redraw
                    render ""
                    local app_label
                    [ "$app_type" = "$QODERCN_TYPE" ] && app_label="Qoder CN" || app_label="QoderWork CN"
                    draw_header "${app_label} — 已保存的账号"
                    local accounts_str
                    accounts_str=$(get_saved_accounts "$app_type")
                    if [ -z "$accounts_str" ]; then
                        render "  ${YELLOW}还没有保存任何账号备份${NC}"
                    else
                        get_app_config "$app_type"
                        while IFS='|' read -r alias display date; do
                            [ -z "$alias" ] && continue
                            local marker=""
                            local account_dir="${BACKUP_ROOT}/${app_type}/${alias}"
                            if is_current_account "$app_type" "$account_dir" "$APP_DATA"; then
                                marker=" ${GREEN}★ 当前使用${NC}"
                            fi
                            render "  ${GREEN}${alias}${NC}  →  ${display}  (${date})${marker}"
                        done <<< "$accounts_str"
                    fi
                    render ""
                    render "  ${BOLD}←${NC} 返回操作菜单    ${BOLD}Q${NC} 退出"
                    local _dummy=$(read_key)
                    ;;
                delete)
                    select_account "$app_type"
                    ret=$?
                    local alias="$_SELECT_RESULT"
                    if [ $ret -eq 2 ]; then continue; fi
                    if [ $ret -eq 1 ] || [ -z "$alias" ]; then continue; fi
                    redraw
                    stty sane 2>/dev/null; show_cursor
                    cmd_delete "$alias" "$app_type" > "$tmp_out"
                    local del_ret=$?
                    stty raw -echo 2>/dev/null; hide_cursor
                    redraw
                    if [ $del_ret -eq 2 ]; then
                        rm -f "$tmp_out"
                        continue
                    fi
                    if [ -f "$tmp_out" ]; then
                        while IFS= read -r line || [ -n "$line" ]; do
                            render "$line"
                        done < "$tmp_out"
                        rm -f "$tmp_out"
                    fi
                    render ""
                    render "  ${BOLD}←${NC} 返回操作菜单    ${BOLD}Q${NC} 退出"
                    local _dummy=$(read_key)
                    ;;
                status)
                    redraw
                    render ""
                    local app_label
                    [ "$app_type" = "$QODERCN_TYPE" ] && app_label="Qoder CN" || app_label="QoderWork CN"
                    draw_header "${app_label} — 登录状态"
                    get_app_config "$app_type"
                    render ""
                    if app_is_installed "$APP_BUNDLE" "$APP_WIN_EXE"; then
                        render "  安装:           ${GREEN}是${NC}"
                    else
                        render "  安装:           ${RED}否${NC}"
                    fi
                    if app_is_running "$APP_BUNDLE" "$APP_WIN_PROCESS"; then
                        render "  运行状态:       ${GREEN}运行中${NC}"
                    else
                        render "  运行状态:       ${RED}未运行${NC}"
                    fi
                    if has_login_state "$APP_TYPE" "$APP_DATA"; then
                        local user=$(get_current_user_info "$APP_TYPE" "$APP_DATA")
                        if [ -n "$user" ]; then
                            render "  登录用户:       ${GREEN}${user}${NC}"
                        else
                            render "  登录状态:       ${GREEN}已登录${NC}"
                        fi
                    else
                        render "  登录状态:       ${RED}未登录${NC}"
                    fi
                    render ""
                    render "  ${BOLD}已备份的账号:${NC}"
                    local accounts_str
                    accounts_str=$(get_saved_accounts "$app_type")
                    if [ -z "$accounts_str" ]; then
                        render "    ${YELLOW}(无)${NC}"
                    else
                        while IFS='|' read -r alias display date; do
                            [ -z "$alias" ] && continue
                            render "    ${GREEN}${alias}${NC}  →  ${display}  (${date})"
                        done <<< "$accounts_str"
                    fi
                    render ""
                    render "  ${BOLD}←${NC} 返回操作菜单    ${BOLD}Q${NC} 退出"
                    local _dummy=$(read_key)
                    ;;
                *)
                    continue
                    ;;
            esac
        done
    done
}

# ============================================================
# MAIN
# ============================================================
case "${1:-}" in
    save)
        cmd_save "$2"
        ;;
    list|ls)
        cmd_list
        ;;
    switch|use)
        cmd_switch "$2"
        ;;
    delete|rm)
        cmd_delete "$2"
        ;;
    status|stat)
        cmd_status
        ;;
    help|--help|-h)
        echo "Qoder CN / QoderWork CN 账号切换工具 v5.0"
        echo "当前系统: $(os_display_name)"
        echo ""
        echo "用法:"
        echo "  $0                      交互模式（推荐）"
        echo "  $0 save <别名>          保存当前登录态"
        echo "  $0 list                 列出所有已保存账号"
        echo "  $0 switch <别名>        切换到指定账号"
        echo "  $0 delete <别名>        删除某个账号备份"
        echo "  $0 status               显示两个应用的登录状态"
        echo ""
        echo "v5.0 改进:"
        echo "  - 跨平台支持: macOS / Windows"
        echo "  - Windows 使用 DPAPI 解密, macOS 使用 Keychain"
        echo "  - 新增 platform.sh 平台抽象层"
        echo "  - 新增 install.sh 跨平台安装脚本"
        echo ""
        echo "v4.1 改进:"
        echo "  - 拆分为主入口 + qodercn.sh + qoderworkcn.sh 模块化"
        echo "  - 按应用分目录存储，同名账号不冲突"
        echo "  - 交互模式：上下键选应用 → 上下键选操作 → 上下键选账号"
        ;;
    "")
        interactive_main
        ;;
    *)
        echo "Qoder CN / QoderWork CN 账号切换工具 v5.0"
        echo "当前系统: $(os_display_name)"
        echo ""
        echo "用法:"
        echo "  $0                      交互模式（推荐）"
        echo "  $0 save <别名>          保存当前登录态"
        echo "  $0 list                 列出已保存账号"
        echo "  $0 switch <别名>        切换到指定账号"
        echo "  $0 delete <别名>        删除账号备份"
        echo "  $0 status               查看状态"
        ;;
esac
