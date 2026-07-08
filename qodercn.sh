#!/bin/bash
# ============================================================
# Qoder CN (VS Code fork) 专用函数
# 被 qoder-account-switcher.sh source 引用
# 支持 macOS / Windows
# ============================================================

# Qoder CN 应用路径配置 (跨平台)
if is_macos 2>/dev/null || [ -z "$_OS" ]; then
    QODERCN_APP_DATA="${HOME}/Library/Application Support/QoderCN"
elif is_windows 2>/dev/null; then
    QODERCN_APP_DATA="${APPDATA:-${USERPROFILE:-$HOME}\\AppData\\Roaming}\\QoderCN"
    # 转为 Unix 风格路径 (Git Bash)
    QODERCN_APP_DATA=$(echo "$QODERCN_APP_DATA" | sed 's|\\|/|g' | sed 's|^\([a-zA-Z]\):|/\L\1|I')
else
    QODERCN_APP_DATA="${HOME}/.config/QoderCN"
fi
QODERCN_BUNDLE="Qoder CN"
QODERCN_TYPE="qodercn"
# Windows 可执行文件名 (用于进程检测/启动)
QODERCN_WIN_PROCESS="QoderCN.exe"
QODERCN_WIN_EXE="QoderCN.exe"

# Qoder CN 需要备份的文件列表
QODERCN_FILES=(
    "auth-v2.dat"
    "SharedClientCache/cache/user"
    "SharedClientCache/cache/quota"
    "SharedClientCache/cache/id"
    "SharedClientCache/cache/cache.json"
    "SharedClientCache/cache/app-config.json"
)

# ============================================================
# 检测 Qoder CN 登录态
# ============================================================
qodercn_has_login_state() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    if [ -f "${app_data}/auth-v2.dat" ]; then return 0; fi
    if [ -f "${app_data}/SharedClientCache/cache/user" ]; then return 0; fi
    local gsdb="${app_data}/User/globalStorage/state.vscdb"
    if [ -f "$gsdb" ]; then
        local count=$(sqlite3 "$gsdb" "SELECT COUNT(*) FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" 2>/dev/null || echo "0")
        [ "$count" -gt 0 ] && return 0
    fi
    return 1
}

# ============================================================
# 获取 Qoder CN 当前登录用户名（从 state.vscdb 解密）
# ============================================================
qodercn_get_current_user_info() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    local gsdb="${app_data}/User/globalStorage/state.vscdb"
    if [ ! -f "$gsdb" ]; then
        echo ""
        return
    fi

    local os_marker="$_OS"
    python3 -c "
import json, hashlib, sqlite3, subprocess, sys, os

os_marker = '$os_marker'
gsdb = '$gsdb'
conn = sqlite3.connect(gsdb)
cur = conn.cursor()
cur.execute(\"SELECT value FROM ItemTable WHERE key='secret://aicoding.auth.userInfo'\")
row = cur.fetchone()
conn.close()
if not row:
    exit(0)

buf = json.loads(row[0])
raw = bytes(buf['data'])

def decrypt_macos(raw):
    pw = subprocess.run(['security','find-generic-password','-w','-s','Qoder CN Safe Storage'], capture_output=True, text=True).stdout.strip()
    if not pw:
        return None
    key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
    iv = b' ' * 16
    from Crypto.Cipher import AES
    cipher = AES.new(key, AES.MODE_CBC, iv)
    dec = cipher.decrypt(raw[3:])
    pad = dec[-1]
    if 1 <= pad <= 16:
        dec = dec[:-pad]
    return dec

def decrypt_windows(raw):
    # Electron OSCrypt on Windows: prefix 'v10' or 'DPAPI' + DPAPI-encrypted blob
    import ctypes
    import ctypes.wintypes as w
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

if os_marker == 'windows':
    dec = decrypt_windows(raw)
else:
    dec = decrypt_macos(raw)

if not dec:
    exit(0)

obj = json.loads(dec.decode('utf-8'))
name = obj.get('name', '')
if name:
    print(name)
" 2>/dev/null
}

# ============================================================
# 获取 Qoder CN 当前登录用户 ID
# ============================================================
qodercn_get_current_user_id() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    local gsdb="${app_data}/User/globalStorage/state.vscdb"
    if [ ! -f "$gsdb" ]; then
        echo ""
        return
    fi

    local os_marker="$_OS"
    python3 -c "
import json, hashlib, sqlite3, subprocess, ctypes
import ctypes.wintypes as w

os_marker = '$os_marker'
gsdb = '$gsdb'
conn = sqlite3.connect(gsdb)
cur = conn.cursor()
cur.execute(\"SELECT value FROM ItemTable WHERE key='secret://aicoding.auth.userInfo'\")
row = cur.fetchone()
conn.close()
if not row:
    exit(0)

buf = json.loads(row[0])
raw = bytes(buf['data'])

def decrypt_macos(raw):
    pw = subprocess.run(['security','find-generic-password','-w','-s','Qoder CN Safe Storage'], capture_output=True, text=True).stdout.strip()
    if not pw:
        return None
    key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
    iv = b' ' * 16
    from Crypto.Cipher import AES
    cipher = AES.new(key, AES.MODE_CBC, iv)
    dec = cipher.decrypt(raw[3:])
    pad = dec[-1]
    if 1 <= pad <= 16:
        dec = dec[:-pad]
    return dec

def decrypt_windows(raw):
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

if os_marker == 'windows':
    dec = decrypt_windows(raw)
else:
    dec = decrypt_macos(raw)

if not dec:
    exit(0)

obj = json.loads(dec.decode('utf-8'))
uid = obj.get('id', '')
if uid:
    print(uid)
" 2>/dev/null
}

# ============================================================
# 解密 Qoder CN 的 state.vscdb 中 secret://aicoding.auth.* 的数据
# ============================================================
qodercn_decrypt_state_vscdb_auth() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    local os_marker="$_OS"
    python3 -c "
import json, os, hashlib, sqlite3, subprocess, ctypes
import ctypes.wintypes as w

os_marker = '$os_marker'
app_data = '$app_data'
result = {}

# === 解密函数 (跨平台) ===
def get_decryptor():
    if os_marker == 'windows':
        def decrypt_windows(raw):
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
        return decrypt_windows
    else:
        # macOS: Keychain + PBKDF2 + AES
        try:
            pw = subprocess.run(
                ['security', 'find-generic-password', '-w', '-s', 'Qoder CN Safe Storage'],
                capture_output=True, text=True
            ).stdout.strip()
            if not pw:
                return None
            key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
            iv = b' ' * 16
        except Exception as e:
            return None
        def decrypt_v10(buf):
            from Crypto.Cipher import AES
            cipher = AES.new(key, AES.MODE_CBC, iv)
            dec = cipher.decrypt(buf[3:])  # skip 'v10' prefix
            pad_len = dec[-1]
            if 1 <= pad_len <= 16:
                dec = dec[:-pad_len]
            return dec
        return decrypt_v10

decrypt_fn = get_decryptor()
if decrypt_fn is None:
    print(json.dumps({'error': 'Failed to get decryptor (Keychain/DPAPI)'}))
    exit(0)

# 1. 从 SharedClientCache/cache/id 获取 UUID
cache_id_path = os.path.join(app_data, 'SharedClientCache/cache/id')
if os.path.isfile(cache_id_path):
    with open(cache_id_path) as f:
        uuid_val = f.read().strip()
    if uuid_val:
        result['uuid'] = uuid_val
        result['uuid_short'] = uuid_val[:8]

# 2. 从 state.vscdb 解密用户信息
gsdb = os.path.join(app_data, 'User', 'globalStorage', 'state.vscdb')
if os.path.isfile(gsdb):
    try:
        conn = sqlite3.connect(gsdb)
        cur = conn.cursor()
        cur.execute(\"SELECT key, value FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%'\")
        rows = cur.fetchall()
        conn.close()

        for k, v in rows:
            buf = json.loads(v)
            raw = bytes(buf['data'])
            short_key = k.replace('secret://aicoding.auth.', '')
            try:
                dec = decrypt_fn(raw)
                if dec:
                    obj = json.loads(dec.decode('utf-8'))
                    result[short_key] = obj
                else:
                    result[short_key + '_error'] = 'decryption returned None'
            except Exception as e:
                result[short_key + '_error'] = str(e)
                result[short_key + '_size'] = len(raw)
    except Exception as e:
        result['state_vscdb_error'] = str(e)

# 3. 从 SharedClientCache/cache/db/local.db 获取 supabase_token
scc_db = os.path.join(app_data, 'SharedClientCache', 'cache', 'db', 'local.db')
if os.path.isfile(scc_db):
    try:
        conn = sqlite3.connect(scc_db)
        cur = conn.cursor()
        cur.execute('SELECT user_id, org_id, expires_at FROM supabase_token LIMIT 1')
        row = cur.fetchone()
        if row:
            result['supabase_token'] = {
                'user_id': row[0],
                'org_id': row[1],
                'expires_at': row[2]
            }
        conn.close()
    except Exception as e:
        result['supabase_token_error'] = str(e)

print(json.dumps(result, ensure_ascii=False))
" 2>/dev/null
}

# ============================================================
# Qoder CN: 判断某个备份账号是否为当前使用的账号
# ============================================================
qodercn_is_current_account() {
    local account_dir="$1"
    local app_data="${2:-$QODERCN_APP_DATA}"

    local AUTH_V2="${app_data}/auth-v2.dat"
    local AUTH_DAT="${app_data}/auth.dat"

    # 比较 user_id
    local current_uid=$(qodercn_get_current_user_id "$app_data")
    local meta="${account_dir}/.meta.json"
    if [ -n "$current_uid" ] && [ -f "$meta" ]; then
        local saved_uid=$(python3 -c "import json; d=json.load(open('$meta')); print(d.get('user_id',''))" 2>/dev/null)
        if [ -n "$saved_uid" ] && [ "$saved_uid" = "$current_uid" ]; then
            return 0
        fi
    fi

    # 备选: 比较 auth-v2.dat
    if [ -f "${account_dir}/auth-v2.dat" ] && [ -f "$AUTH_V2" ]; then
        if cmp -s "${account_dir}/auth-v2.dat" "$AUTH_V2"; then
            return 0
        fi
    fi

    return 1
}

# ============================================================
# Qoder CN: 获取用户元信息 JSON（用于写入 .meta.json）
# ============================================================
qodercn_get_user_meta_json() {
    local app_data="${1:-$QODERCN_APP_DATA}"
    qodercn_decrypt_state_vscdb_auth "$app_data"
}

# ============================================================
# Qoder CN: 保存账号 - 复制文件 + 导出 secret + supabase_token
# ============================================================
qodercn_save_account_files() {
    local account_dir="$1"
    local app_data="${2:-$QODERCN_APP_DATA}"

    local GSDB="${app_data}/User/globalStorage/state.vscdb"
    local GSDB_BACKUP="${app_data}/User/globalStorage/state.vscdb.backup"
    local SCC_DB="${app_data}/SharedClientCache/cache/db/local.db"

    # 导出 state.vscdb secret 键
    if [ -f "$GSDB" ]; then
        sqlite3 "$GSDB" "SELECT key, value FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" \
            > "${account_dir}/state.vscdb_secrets.txt" 2>/dev/null || true
        if [ -s "${account_dir}/state.vscdb_secrets.txt" ]; then
            local count=$(wc -l < "${account_dir}/state.vscdb_secrets.txt" | tr -d ' ')
            info "  ✓ 导出了 ${count} 行 secret 数据"
        else
            warn "  ✗ state.vscdb 中无 secret 键"
        fi
    fi

    if [ -f "$GSDB_BACKUP" ]; then
        sqlite3 "$GSDB_BACKUP" "SELECT key, value FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" \
            > "${account_dir}/state.vscdb.backup_secrets.txt" 2>/dev/null || true
    fi

    # 导出 supabase_token
    if [ -f "$SCC_DB" ]; then
        sqlite3 "$SCC_DB" "SELECT user_id, org_id, access_token, refresh_token, expires_at, gmt_create, gmt_modified FROM supabase_token;" \
            > "${account_dir}/supabase_token.txt" 2>/dev/null || true
        if [ -s "${account_dir}/supabase_token.txt" ]; then
            info "  ✓ 已导出 supabase_token"
        else
            warn "  ✗ supabase_token 表为空"
        fi
    fi
}

# ============================================================
# Qoder CN: 清除当前登录态
# ============================================================
qodercn_clear_login_state() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    local SCC="${app_data}/SharedClientCache/cache"
    local GSDB="${app_data}/User/globalStorage/state.vscdb"
    local GSDB_BACKUP="${app_data}/User/globalStorage/state.vscdb.backup"
    local SCC_DB="${SCC}/db/local.db"

    rm -f "${app_data}/auth-v2.dat" "${app_data}/auth.dat"
    rm -f "${SCC}/user" "${SCC}/quota" "${SCC}/id" "${SCC}/cache.json" "${SCC}/app-config.json"

    if [ -f "$GSDB" ]; then
        sqlite3 "$GSDB" "DELETE FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" 2>/dev/null || true
    fi
    if [ -f "$GSDB_BACKUP" ]; then
        sqlite3 "$GSDB_BACKUP" "DELETE FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" 2>/dev/null || true
    fi
    if [ -f "$SCC_DB" ]; then
        sqlite3 "$SCC_DB" "DELETE FROM supabase_token;" 2>/dev/null || true
    fi

    info "  ✓ 已清除 Qoder CN 当前登录态"
}

# ============================================================
# Qoder CN: 恢复 state.vscdb secret 键 + supabase_token
# ============================================================
qodercn_restore_secrets_and_token() {
    local account_dir="$1"
    local app_data="${2:-$QODERCN_APP_DATA}"

    local GSDB="${app_data}/User/globalStorage/state.vscdb"
    local GSDB_BACKUP="${app_data}/User/globalStorage/state.vscdb.backup"
    local SCC_DB="${app_data}/SharedClientCache/cache/db/local.db"

    # 恢复 state.vscdb secret 键
    local secrets_file="${account_dir}/state.vscdb_secrets.txt"
    if [ -f "$secrets_file" ] && [ -s "$secrets_file" ] && [ -f "$GSDB" ]; then
        while IFS='|' read -r key value; do
            if [ -n "$key" ] && [ -n "$value" ]; then
                local safe_value="${value//\'/\'\'}"
                sqlite3 "$GSDB" "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('${key}', '${safe_value}');" 2>/dev/null || true
            fi
        done < "$secrets_file"
        info "  ✓ state.vscdb secret 键已恢复"
    fi

    local secrets_backup="${account_dir}/state.vscdb.backup_secrets.txt"
    if [ -f "$secrets_backup" ] && [ -s "$secrets_backup" ] && [ -f "$GSDB_BACKUP" ]; then
        while IFS='|' read -r key value; do
            if [ -n "$key" ] && [ -n "$value" ]; then
                local safe_value="${value//\'/\'\'}"
                sqlite3 "$GSDB_BACKUP" "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('${key}', '${safe_value}');" 2>/dev/null || true
            fi
        done < "$secrets_backup"
        info "  ✓ state.vscdb.backup secret 键已恢复"
    fi

    # 恢复 supabase_token
    local token_file="${account_dir}/supabase_token.txt"
    if [ -f "$token_file" ] && [ -s "$token_file" ] && [ -f "$SCC_DB" ]; then
        while IFS='|' read -r user_id org_id access_token refresh_token expires_at gmt_create gmt_modified; do
            if [ -n "$user_id" ] && [ -n "$access_token" ]; then
                local safe_at="${access_token//\'/\'\'}"
                local safe_rt="${refresh_token//\'/\'\'}"
                sqlite3 "$SCC_DB" "
                    INSERT OR REPLACE INTO supabase_token (user_id, org_id, access_token, refresh_token, expires_at, gmt_create, gmt_modified)
                    VALUES ('${user_id}', '${org_id}', '${safe_at}', '${safe_rt}', ${expires_at:-0}, ${gmt_create:-0}, ${gmt_modified:-0});
                " 2>/dev/null || true
            fi
        done < "$token_file"
        info "  ✓ supabase_token 已恢复"
    fi
}

# ============================================================
# Qoder CN: 构建 .meta.json 中的用户信息
# ============================================================
qodercn_build_meta_json() {
    local user_meta="$1"
    local meta_json=""

    meta_json=$(python3 -c "
import json

user_meta = json.loads('''${user_meta}''')

meta_updates = {}

# UUID
if user_meta.get('uuid'):
    meta_updates['uuid'] = user_meta['uuid']
    meta_updates['uuid_short'] = user_meta['uuid_short']

# 从解密的 userInfo 提取用户信息
user_info = user_meta.get('userInfo', {})
if user_info:
    meta_updates['name'] = user_info.get('name', '')
    meta_updates['username'] = user_info.get('name', '')
    meta_updates['user_id'] = user_info.get('id', '')
    meta_updates['account_id'] = user_info.get('accountId', '')
    meta_updates['email'] = user_info.get('email', '')
    meta_updates['avatar_url'] = user_info.get('avatarUrl', '')
    meta_updates['org_id'] = user_info.get('orgId', '')
    meta_updates['org_name'] = user_info.get('orgName', '')
    meta_updates['user_type'] = user_info.get('userType', '')
    meta_updates['quota'] = user_info.get('quota', '')
    meta_updates['expire_time'] = user_info.get('expireTime', '')
    meta_updates['is_sub_account'] = user_info.get('isSubAccount', False)

# 从解密的 userPlan 提取套餐信息
user_plan = user_meta.get('userPlan', {})
if user_plan:
    meta_updates['plan_tier'] = user_plan.get('plan_tier_name', '')
    meta_updates['user_plan_type'] = user_plan.get('user_type', '')
    meta_updates['plan_start_date'] = user_plan.get('start_date', '')
    meta_updates['plan_end_date'] = user_plan.get('end_date', '')
    meta_updates['plan_features'] = user_plan.get('feature_allowed', {})

# supabase_token
if user_meta.get('supabase_token'):
    meta_updates['supabase_user_id'] = user_meta['supabase_token'].get('user_id')
    meta_updates['supabase_org_id'] = user_meta['supabase_token'].get('org_id')
    meta_updates['supabase_expires_at'] = user_meta['supabase_token'].get('expires_at')

print(json.dumps(meta_updates, ensure_ascii=False))
" 2>/dev/null)

    echo "$meta_json"
}

# ============================================================
# Qoder CN: 打印状态信息
# ============================================================
qodercn_print_app_status() {
    local app_data="${1:-$QODERCN_APP_DATA}"

    echo ""
    echo "--------------------------------------------"
    echo -e "  ${GREEN}Qoder CN${NC}"
    echo "--------------------------------------------"

    if app_is_installed "$QODERCN_BUNDLE" "$QODERCN_WIN_EXE"; then
        echo -e "  安装:           ${GREEN}是${NC}"
    else
        echo -e "  安装:           ${RED}否${NC}"
    fi

    if app_is_running "$QODERCN_BUNDLE" "$QODERCN_WIN_PROCESS"; then
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

    local scc="${app_data}/SharedClientCache/cache"
    for f in user quota id; do
        if [ -f "${scc}/${f}" ]; then
            local size=$(file_size "${scc}/${f}")
            echo -e "  cache/${f}:      ${GREEN}存在${NC} (${size} B)"
            has_login=true
        else
            echo -e "  cache/${f}:      ${RED}不存在${NC}"
        fi
    done

    local gsdb="${app_data}/User/globalStorage/state.vscdb"
    if [ -f "$gsdb" ]; then
        local count=$(sqlite3 "$gsdb" "SELECT COUNT(*) FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo -e "  state.vscdb:    ${GREEN}${count} 个 secret 键${NC}"
            has_login=true
        else
            echo -e "  state.vscdb:    ${YELLOW}无 secret 键${NC}"
        fi
    fi

    local scc_db="${scc}/db/local.db"
    if [ -f "$scc_db" ]; then
        local token_count=$(sqlite3 "$scc_db" "SELECT COUNT(*) FROM supabase_token;" 2>/dev/null || echo "0")
        if [ "$token_count" -gt 0 ]; then
            echo -e "  supabase_token: ${GREEN}${token_count} 条${NC}"
            has_login=true
        fi
    fi

    if $has_login; then
        local user=$(qodercn_get_current_user_info "$app_data")
        if [ -n "$user" ]; then
            echo -e "  ${GREEN}✓ 检测到登录态: ${user}${NC}"
        else
            echo -e "  ${YELLOW}⚠ 检测到登录态文件，但无法确定用户${NC}"
        fi
    else
        echo -e "  ${RED}✗ 未检测到登录态${NC}"
    fi
}
