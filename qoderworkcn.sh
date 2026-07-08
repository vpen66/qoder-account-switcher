#!/bin/bash
# ============================================================
# QoderWork CN (独立 Electron 应用) 专用函数
# 被 qoder-account-switcher.sh source 引用
# 支持 macOS / Windows
# ============================================================

# QoderWork CN 应用路径配置 (跨平台)
if is_macos 2>/dev/null || [ -z "$_OS" ]; then
    QODERWORK_APP_DATA="${HOME}/Library/Application Support/QoderWork CN"
elif is_windows 2>/dev/null; then
    QODERWORK_APP_DATA="${APPDATA:-${USERPROFILE:-$HOME}\\AppData\\Roaming}\\QoderWork CN"
    # 转为 Unix 风格路径 (Git Bash)
    QODERWORK_APP_DATA=$(echo "$QODERWORK_APP_DATA" | sed 's|\\|/|g' | sed 's|^\([a-zA-Z]\):|/\L\1|I')
else
    QODERWORK_APP_DATA="${HOME}/.config/QoderWork CN"
fi
QODERWORK_BUNDLE="QoderWork CN"
QODERWORK_TYPE="qoderwork"
# Windows 可执行文件名 (用于进程检测/启动)
QODERWORK_WIN_PROCESS="QoderWork CN.exe"
QODERWORK_WIN_EXE="QoderWork CN.exe"

# QoderWork CN 需要备份的文件列表
QODERWORK_FILES=("auth-v2.dat" "auth.dat")

# ============================================================
# 检测 QoderWork CN 登录态
# ============================================================
qoderwork_has_login_state() {
    local app_data="${1:-$QODERWORK_APP_DATA}"

    [ -f "${app_data}/auth-v2.dat" ] || [ -f "${app_data}/auth.dat" ]
}

# ============================================================
# 获取 QoderWork CN 当前登录用户名（从 auth-v2.dat 解密）
# ============================================================
qoderwork_get_current_user_info() {
    local app_data="${1:-$QODERWORK_APP_DATA}"

    if [ -f "${app_data}/auth-v2.dat" ]; then
        local os_marker="$_OS"
        local name=$(python3 -c "
import json, hashlib, subprocess, ctypes
import ctypes.wintypes as w

os_marker = '$os_marker'

def decrypt_macos():
    pw = subprocess.run(['security','find-generic-password','-w','-s','QoderWork CN Safe Storage'], capture_output=True, text=True).stdout.strip()
    if not pw:
        return None
    key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
    iv = b' ' * 16
    from Crypto.Cipher import AES
    with open('${app_data}/auth-v2.dat', 'rb') as f:
        raw = f.read()
    if raw[:3] != b'v10':
        return None
    cipher = AES.new(key, AES.MODE_CBC, iv)
    dec = cipher.decrypt(raw[3:])
    pad_len = dec[-1]
    if 1 <= pad_len <= 16:
        dec = dec[:-pad_len]
    return dec

def decrypt_windows():
    with open('${app_data}/auth-v2.dat', 'rb') as f:
        raw = f.read()
    if raw[:3] == b'v10':
        encrypted = raw[3:]
    elif raw[:5] == b'DPAPI':
        encrypted = raw[5:]
    else:
        encrypted = raw
    class DATA_BLOB(ctypes.Structure):
        _fields_ = [('cbData', w.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]
    in_blob = DATA_BLOB(len(encrypted), ctypes.cast(ctypes.c_char_p(encrypted), ctypes.POINTER(ctypes.c_char)))
    out_blob = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob)):
        return None
    plaintext = ctypes.string_at(out_blob.pbData, out_blob.cbData)
    ctypes.windll.kernel32.LocalFree(out_blob.pbData)
    return plaintext

try:
    if os_marker == 'windows':
        dec = decrypt_windows()
    else:
        dec = decrypt_macos()
    if not dec:
        exit(0)
    obj = json.loads(dec.decode('utf-8'))
    name = obj.get('user', {}).get('name', '')
    if name:
        print(name)
except:
    pass
" 2>/dev/null)
        if [ -n "$name" ]; then
            echo "$name"
        else
            echo "(已登录)"
        fi
    fi
}

# ============================================================
# 解密 QoderWork CN 的 auth-v2.dat 获取用户信息
# ============================================================
qoderwork_decrypt_auth() {
    local app_data="${1:-$QODERWORK_APP_DATA}"

    local os_marker="$_OS"
    python3 -c "
import json, os, hashlib, subprocess, ctypes
import ctypes.wintypes as w

os_marker = '$os_marker'
app_data = '$app_data'
result = {}

# === 解密函数 (跨平台) ===
def decrypt_auth():
    auth_path = os.path.join(app_data, 'auth-v2.dat')
    if not os.path.isfile(auth_path):
        return None
    with open(auth_path, 'rb') as f:
        raw = f.read()

    if os_marker == 'windows':
        # Windows: DPAPI
        if raw[:3] == b'v10':
            encrypted = raw[3:]
        elif raw[:5] == b'DPAPI':
            encrypted = raw[5:]
        else:
            encrypted = raw
        class DATA_BLOB(ctypes.Structure):
            _fields_ = [('cbData', w.DWORD), ('pbData', ctypes.POINTER(ctypes.c_char))]
        in_blob = DATA_BLOB(len(encrypted), ctypes.cast(ctypes.c_char_p(encrypted), ctypes.POINTER(ctypes.c_char)))
        out_blob = DATA_BLOB()
        if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob)):
            return None
        plaintext = ctypes.string_at(out_blob.pbData, out_blob.cbData)
        ctypes.windll.kernel32.LocalFree(out_blob.pbData)
        return plaintext
    else:
        # macOS: Keychain + PBKDF2 + AES
        pw = subprocess.run(
            ['security', 'find-generic-password', '-w', '-s', 'QoderWork CN Safe Storage'],
            capture_output=True, text=True
        ).stdout.strip()
        if not pw:
            return None
        key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
        iv = b' ' * 16
        if raw[:3] != b'v10':
            return None
        from Crypto.Cipher import AES
        cipher = AES.new(key, AES.MODE_CBC, iv)
        dec = cipher.decrypt(raw[3:])
        pad_len = dec[-1]
        if 1 <= pad_len <= 16:
            dec = dec[:-pad_len]
        return dec

try:
    dec = decrypt_auth()
    if dec:
        obj = json.loads(dec.decode('utf-8'))
        result['auth_v2'] = obj
    else:
        result['error'] = 'Decryption failed or auth-v2.dat not found'
except Exception as e:
    result['auth_v2_error'] = str(e)

print(json.dumps(result, ensure_ascii=False))
" 2>/dev/null
}

# ============================================================
# QoderWork CN: 判断某个备份账号是否为当前使用的账号
# ============================================================
qoderwork_is_current_account() {
    local account_dir="$1"
    local app_data="${2:-$QODERWORK_APP_DATA}"

    local AUTH_V2="${app_data}/auth-v2.dat"
    local AUTH_DAT="${app_data}/auth.dat"

    # 比较 auth-v2.dat
    if [ -f "${account_dir}/auth-v2.dat" ] && [ -f "$AUTH_V2" ]; then
        if cmp -s "${account_dir}/auth-v2.dat" "$AUTH_V2"; then
            return 0
        fi
    fi

    # 比较 auth.dat
    if [ -f "${account_dir}/auth.dat" ] && [ -f "$AUTH_DAT" ]; then
        if cmp -s "${account_dir}/auth.dat" "$AUTH_DAT"; then
            return 0
        fi
    fi

    return 1
}

# ============================================================
# QoderWork CN: 获取用户元信息 JSON（用于写入 .meta.json）
# ============================================================
qoderwork_get_user_meta_json() {
    local app_data="${1:-$QODERWORK_APP_DATA}"
    qoderwork_decrypt_auth "$app_data"
}

# ============================================================
# QoderWork CN: 保存账号特有的文件操作（目前无需额外操作）
# ============================================================
qoderwork_save_account_files() {
    local account_dir="$1"
    local app_data="${2:-$QODERWORK_APP_DATA}"
    # QoderWork CN 无需额外导出操作，仅复制文件
    :
}

# ============================================================
# QoderWork CN: 清除当前登录态
# ============================================================
qoderwork_clear_login_state() {
    local app_data="${1:-$QODERWORK_APP_DATA}"

    rm -f "${app_data}/auth-v2.dat" "${app_data}/auth.dat"
    info "  ✓ 已清除 QoderWork CN 当前登录态"
}

# ============================================================
# QoderWork CN: 恢复 secret 和 token（无需额外操作）
# ============================================================
qoderwork_restore_secrets_and_token() {
    local account_dir="$1"
    local app_data="${2:-$QODERWORK_APP_DATA}"
    # QoderWork CN 无需额外恢复操作
    :
}

# ============================================================
# QoderWork CN: 构建 .meta.json 中的用户信息
# ============================================================
qoderwork_build_meta_json() {
    local user_meta="$1"

    python3 -c "
import json

user_meta = json.loads('''${user_meta}''')

meta_updates = {}

# 从解密的 auth-v2.dat 提取用户信息
auth_v2 = user_meta.get('auth_v2', {})
if auth_v2:
    meta_updates['name'] = auth_v2.get('name', '') or auth_v2.get('user', {}).get('name', '')
    meta_updates['email'] = auth_v2.get('email', '') or auth_v2.get('user', {}).get('email', '')
    meta_updates['avatar_url'] = auth_v2.get('imageUrl', '') or auth_v2.get('user', {}).get('imageUrl', '')
    meta_updates['tier'] = auth_v2.get('tier', '') or auth_v2.get('user', {}).get('tier', '')
    meta_updates['schema_version'] = auth_v2.get('schemaVersion', '')
    meta_updates['login_method'] = auth_v2.get('loginMethod', '')
    meta_updates['login_timestamp'] = auth_v2.get('loginTimestamp', '')
    meta_updates['expires_at'] = auth_v2.get('expiresAt', '')
    meta_updates['login_device_id'] = auth_v2.get('loginDeviceId', '')

    # user 子对象中的信息
    user_obj = auth_v2.get('user', {})
    if user_obj:
        meta_updates['user_id'] = user_obj.get('id', '')
        meta_updates['username'] = user_obj.get('username', '')
        meta_updates['org_id'] = user_obj.get('orgId', '')
        meta_updates['org_tags'] = user_obj.get('orgTags')

        # 第三方身份
        third_party = user_obj.get('thirdPartyIdentities', [])
        if third_party:
            meta_updates['third_party_provider'] = third_party[0].get('provider', '')
            meta_updates['third_party_open_id'] = third_party[0].get('openId', '')

print(json.dumps(meta_updates, ensure_ascii=False))
" 2>/dev/null
}

# ============================================================
# QoderWork CN: 打印状态信息
# ============================================================
qoderwork_print_app_status() {
    local app_data="${1:-$QODERWORK_APP_DATA}"

    echo ""
    echo "--------------------------------------------"
    echo -e "  ${GREEN}QoderWork CN${NC}"
    echo "--------------------------------------------"

    if app_is_installed "$QODERWORK_BUNDLE" "$QODERWORK_WIN_EXE"; then
        echo -e "  安装:           ${GREEN}是${NC}"
    else
        echo -e "  安装:           ${RED}否${NC}"
    fi

    if app_is_running "$QODERWORK_BUNDLE" "$QODERWORK_WIN_PROCESS"; then
        echo -e "  运行状态:       ${GREEN}运行中${NC}"
    else
        echo -e "  运行状态:       ${RED}未运行${NC}"
    fi

    local has_login=false
    if [ -f "${app_data}/auth-v2.dat" ]; then
        local size=$(file_size "${app_data}/auth-v2.dat")
        echo -e "  auth-v2.dat:    ${GREEN}存在${NC} (${size} B)"
        has_login=true
    else
        echo -e "  auth-v2.dat:    ${RED}不存在${NC}"
    fi
    if [ -f "${app_data}/auth.dat" ]; then
        local size=$(file_size "${app_data}/auth.dat")
        echo -e "  auth.dat:       ${GREEN}存在${NC} (${size} B)"
        has_login=true
    else
        echo -e "  auth.dat:       ${RED}不存在${NC}"
    fi

    if $has_login; then
        echo -e "  ${GREEN}✓ 检测到登录态${NC}"
    else
        echo -e "  ${RED}✗ 未检测到登录态${NC}"
    fi
}
