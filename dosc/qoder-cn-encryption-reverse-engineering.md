# Qoder CN 缓存加密逆向工程文档

## 1. 概述

### 1.1 背景

Qoder CN（v1.0.1）使用 Go 语言编写的 sidecar 进程管理登录态，启动时从本地缓存文件恢复会话。本项目需要在不启动 Qoder CN 原进程的情况下，通过 Rust 代码直接生成合法的缓存文件，实现账号切换功能。

### 1.2 问题

初始实现的 Rust 代码生成的 `cache/user` 文件被 Qoder CN 判定为无效，导致：
- 额度（quota）不显示
- 发送消息报错"当前账号异常"
- HTTP 403 错误

根因是 `cache/user` 中的 `key` 和 `encrypt_user_info` 两个加密字段生成不正确。

### 1.3 目标二进制

- **路径**：`/Applications/Qoder CN.app/Contents/Resources/app/resources/bin/aarch64_darwin/QoderCN`
- **类型**：Mach-O 64-bit executable arm64
- **Go 版本**：1.23.0
- **大小**：约 108 MB

---

## 2. 文件结构

### 2.1 缓存文件位置

```
~/Library/Application Support/QoderCN/SharedClientCache/cache/
├── id          # 设备标识（明文，用作外层加密密钥）
├── user        # 用户登录态（AES-128-CBC 加密）
└── quota       # 配额信息（AES-128-CBC 加密）
```

### 2.2 加密层次结构

`cache/user` 是一个双层加密结构：

```
cache/user 文件
│
├── [外层加密] AES-128-CBC，密钥 = IV = cache/id[:16]
│   │
│   └── 明文 JSON（22 字段 CosyUserInfo struct）
│       ├── name, aid, uid, yx_uid, ...
│       ├── key: base64(RSA-1024-PKCS1v15(UUID[:16]))          ← 内层密钥
│       └── encrypt_user_info: base64(AES-128-CBC(JSON))       ← 内层密文
│           │
│           └── [内层加密] AES-128-CBC，密钥 = IV = UUID[:16]
│               │
│               └── 明文 JSON（22 字段，11 有值 + 11 零值）
│                   ├── name, aid, uid: 用户标识
│                   ├── security_oauth_token, refresh_token: Token
│                   ├── account_source: "example_source"
│                   ├── login_method: "example_method"
│                   └── 其余字段为零值
```

### 2.3 cache/quota 结构

`cache/quota` 仅有一层加密：

```
cache/quota 文件
│
└── [单层加密] AES-128-CBC，密钥 = IV = cache/id[:16]
    │
    └── 明文 JSON
        ├── expireTime: 时间戳
        ├── userId, name, avatarUrl
        ├── quota: 0
        ├── status: 2
        ├── whitelist: 3
        └── email: ""
```

---

## 3. 逆向工具链

| 工具 | 用途 | 版本/来源 |
|------|------|-----------|
| `GoReSym` | Go 符号表恢复，提取函数名和类型信息 | github.com/mandiant/GoReSym |
| `otool -tv` | arm64 汇编反汇编 | macOS 系统自带 |
| `nm` | 符号表查看 | macOS 系统自带 |
| Python3 + openssl | AES 加解密验证、数据对比 | 系统自带 |

---

## 4. 逆向过程

### 4.1 第一阶段：外层加密方案确认

#### 步骤 1：定位缓存文件

通过观察 Qoder CN 运行时的文件系统活动，定位到缓存目录：
```
~/Library/Application Support/QoderCN/SharedClientCache/cache/
```

文件加密特征：base64 编码的二进制数据，无法直接读取。

#### 步骤 2：识别加密算法

通过分析 `cache/user` 和 `cache/quota` 文件：
- 文件内容为标准 base64 文本
- base64 解码后长度为 16 的倍数（AES 块大小）
- 文件大小随内容变化而变化（排除了固定长度算法）

初步假设为 AES-CBC + PKCS7 padding + base64。

#### 步骤 3：找到加密密钥

通过 GoReSym 恢复 Go sidecar 二进制符号表：

```bash
GoReSym -t -d -p "QoderCN" > symbols.json
```

分析 `cosy/encrypt` 包中的函数调用链，发现 `cache/id` 文件被用作密钥来源。

验证方式：用 `cache/id` 的前 16 字节作为 AES-128-CBC 密钥（IV=key）解密 `cache/user` 和 `cache/quota`，成功获得合法 JSON。

```python
# 解密验证
openssl enc -d -aes-128-cbc -K $(head -c 16 cache/id | xxd -p) -iv $(head -c 16 cache/id | xxd -p) -in <(base64 -d cache/user) -nopad
```

#### 结论

外层加密方案：
- **算法**：AES-128-CBC
- **密钥**：`cache/id` 前 16 字节（UTF-8）
- **IV**：与密钥相同
- **Padding**：PKCS7
- **编码**：标准 base64

### 4.2 第二阶段：内层 encrypt_user_info 加密方案逆向

#### 步骤 4：识别 encrypt_user_info 的作用

通过对比 Qoder CN 原生生成的 `cache/user` 和本项目生成的 `cache/user`：
- 外层 JSON 结构一致
- `key` 和 `encrypt_user_info` 字段值不同
- 使用 Qoder CN 原生的 `key` + `encrypt_user_info` 替换 → 正常工作
- 使用本项目生成的 `key` + `encrypt_user_info` → 失败

→ 问题锁定在 `key` / `encrypt_user_info` 的生成算法。

#### 步骤 5：定位 SaveUserInfo 函数

通过 GoReSym 查找关键函数：

```bash
GoReSym -t -d -p "QoderCN" | grep -i "SaveUserInfo"
```

找到 `cosy/auth/user.SaveUserInfo`，地址 `0x1AABBCCDD`。

#### 步骤 6：反汇编 SaveUserInfo

```bash
otool -tv "QoderCN" | sed -n '/^00000001AABBCCDD/,/^00000001AABBCCEE/p'
```

#### 步骤 7：追踪 AES 密钥来源

从反汇编代码中提取关键调用链：

```
0x1AABBCC94:  str x1, [sp, #0xd0]      ; 保存 json.Marshal 结果
0x1AABBCC98:  str x0, [sp, #0x130]
0x1AABBCC9c:  orr x0, xzr, #0x1
0x1AABBCCa0:  bl  0x1AABBCC88          ; GetMachineId()
0x1AABBCCb0:  bl  0x1AABBCC77          ; uuid.NewString()
0x1AABBCCcc:  bl  0x1AABBCC99          ; strings.ReplaceAll(uuid, "-", "")
0x1AABBCCd0:  cmp x1, #0x10            ; 检查长度 >= 16
0x1AABBCCd8:  str x0, [sp, #0x118]     ; 保存 UUID 指针
0x1AABBCC0c:  orr x1, xzr, #0x10       ; x1 = 16（数据长度）
0x1AABBCC18:  mov x0, x3               ; x0 = UUID 指针
0x1AABBCC20:  bl  0x1AABBCCFF          ; RsaEncrypt(UUID[:16], publicKey)
0x1AABBCCd8:  ldr x2, [sp, #0x118]     ; x2 = UUID 指针（密钥）
0x1AABBCCdc:  orr x3, xzr, #0x10       ; x3 = 16（密钥长度）
0x1AABBCCe0:  bl  0x1AABBCCEE          ; AesEncryptWithBase64(json, UUID[:16])
```

**关键发现**：AES 密钥是 UUID 去掉横线后的前 16 个 ASCII 十六进制字符！

例如：
```
uuid.NewString()          → "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
strings.ReplaceAll(x,"-","") → "a1b2c3d4e5f67890abcdef1234567890"
[:16]                        → "a1b2c3d4e5f67890"  ← AES 密钥
```

#### 步骤 8：确认 AES IV 和填充模式

反汇编 `AesEncryptWithBase64`（0x1AABBCCEE）：

```
0x1AABBCCc4:  bl  0x1AABBCCBB          ; runtime.stringtoslicebyte(data)
0x1AABBCCe0:  bl  0x1AABBCCBB          ; runtime.stringtoslicebyte(key)
0x1AABBCCf0:  bl  0x1AABBCC22          ; crypto/aes.NewCipher(key)
0x1AABBCC30:  bl  0x1AABBCC00          ; cosy/encrypt.pkcs5Padding
0x1AABBCC48:  ldr x2, [sp, #0x78]      ; IV = keyBytes ← 关键！
0x1AABBCC4c:  ldr x3, [sp, #0x50]      ; IV len = key len
0x1AABBCC54:  bl  0x1AABBCC33          ; crypto/cipher.NewCBCEncrypter(block, keyBytes)
```

**关键发现**：`NewCBCEncrypter(block, keyBytes)` → IV = key！

#### 步骤 9：确认 RSA 填充模式

反汇编 `RsaEncrypt`（0x1AABBCCFF）：

通过 GoReSym 查找调用的函数：
- `crypto/rsa.EncryptPKCS1v15` → PKCS#1 v1.5 填充

#### 步骤 10：提取 RSA 公钥

从 Go 二进制中读取 RSA 公钥字符串：

```
__DATA 段地址 0x1DDEEFF00  →  Go 字符串指针
     → __TEXT.__rodata  →  PEM 格式公钥
```

```pem
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCxXxXxXxXxXxXxXxXxXxXxXxXx
XxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXx
XxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXx
XxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXxXx
-----END PUBLIC KEY-----
```

### 4.3 第三阶段：CosyUserInfo 结构体逆向

#### 步骤 11：确定 encrypt_user_info 明文结构

最初假设只有 5 个字段（144 字节明文），但实际密文为 608 字节，不匹配。

通过 Go 类型描述符解析，发现完整结构体包含 22 个字段：

```go
type CosyUserInfo struct {
    // --- 有值字段（11 个）---
    Name                 string    // offset 0x00  - 用户显示名
    Aid                  string    // offset 0x10  - 账号 ID
    Uid                  string    // offset 0x20  - 用户 ID
    YxUid                string    // offset 0x30  - 邮箱用户 ID
    OrganizationId       string    // offset 0x40  - 组织 ID
    OrganizationName     string    // offset 0x50  - 组织名称
    SecurityOauthToken   string    // offset 0x80  - OAuth Token
    RefreshToken         string    // offset 0x90  - 刷新 Token
    AccountSource        string    // offset 0xd8  - 账号来源
    LoginMethod          string    // offset 0xe8  - 登录方式
    UserType             string    // offset 0xf8  - 用户类型

    // --- 零值字段（11 个）---
    StaffId              string    // offset 0x60
    AvatarUrl            string    // offset 0x70
    ExpireTime           int64     // offset 0xa0
    Key                  string    // offset 0xa8
    EncryptUserInfo      string    // offset 0xb8
    UserSourceChannel    string    // offset 0xc8
    DataPolicyAgreed     bool      // offset 0x108
    Email                string    // offset 0x110
    IsDataPolicyModifiable bool    // offset 0x120
    IsQuotaExceeded      bool      // offset 0x121
    OrganizationTags     []string  // offset 0x128
}
```

#### 步骤 12：确认字段复制逻辑

通过反汇编 `SaveUserInfo` 的栈复制逻辑，确认内层明文只有 11 个字段有值：

```
; 从输入 CosyUserInfo 复制 11 个字段到临时结构体
ldp x2, x3, [x1, #0x00]  → temp2[0x00]  ; name, aid
ldp x2, x3, [x1, #0x10]  → temp2[0x10]  ; uid, yx_uid
ldp x2, x3, [x1, #0x20]  → temp2[0x20]  ; org_id, org_name
ldp x2, x3, [x1, #0x30]  → temp2[0x30]  ; staffId, avatar_url（会清零）
ldp x2, x3, [x1, #0x40]  → temp2[0x40]  ; (已清零)
...
ldp x2, x3, [x1, #0x80]  → temp2[0x80]  ; security_oauth_token
ldp x2, x3, [x1, #0x90]  → temp2[0x90]  ; refresh_token
...
; 偏移 0x60-0x7f 和 0xa0-0xff 保留为零值
```

初始只复制了 5 个字符串（80 字节），然后跳过间隙直接复制 security_oauth_token 和 refresh_token。

### 4.4 第四阶段：JSON 序列化顺序问题

Go 的 `json.Marshal` 按 struct 字段声明顺序输出 JSON 键。Rust 的 `serde_json` 使用 `BTreeMap` 按字母顺序排序，导致生成的 JSON 键顺序不同。

**修复**：在 `Cargo.toml` 中启用 `preserve_order` feature：

```toml
serde_json = { version = "1", features = ["preserve_order"] }
```

### 4.5 第五阶段：AES 密钥格式问题（核心 bug）

#### 初始实现（错误）

```rust
// 随机 16 字节二进制作为 AES 密钥
let mut aes_key = [0u8; 16];
rand::rngs::OsRng.fill_bytes(&mut aes_key);
// → [0x3f, 0xa2, 0x8b, 0x01, ...]
```

#### Go 原始实现（正确）

```go
uuidStr := uuid.NewString()              // "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
uuidHex := strings.ReplaceAll(uuidStr, "-", "") // "a1b2c3d4e5f67890abcdef1234567890"
aesKey := uuidHex[:16]                   // "a1b2c3d4e5f67890"（ASCII hex）
```

#### 修复

```rust
let uuid_hex = uuid::Uuid::new_v4().simple().to_string();
let mut aes_key = [0u8; 16];
aes_key.copy_from_slice(uuid_hex.as_bytes()[..16].as_ref());
```

---

## 5. 完整加密算法

### 5.1 外层加密（cache/user 和 cache/quota）

```
输入: 明文 JSON 字节流
输出: base64 编码的密文文件

算法:
  1. key = cache/id 文件内容的前 16 字节（UTF-8）
  2. plaintext = JSON 序列化后的字节流（UTF-8）
  3. ciphertext = AES-128-CBC-Encrypt(plaintext, key=IV=key, padding=PKCS7)
  4. output = base64(ciphertext)
```

### 5.2 内层加密（encrypt_user_info 字段）

```
输入: 用户账号对象
输出: (key 字段, encrypt_user_info 字段)

算法:
  1. uuid = UUID v4 生成 ("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
  2. aes_key = uuid 去横线后前 16 个 ASCII 字符 ("a1b2c3d4e5f67890")

  3. 构造内层明文 JSON（22 字段，11 有值 + 11 零值）
  4. encrypt_info = AES-128-CBC-Encrypt(内层JSON, key=IV=aes_key)
  5. encrypt_user_info = base64(encrypt_info)

  6. rsa_ct = RSA-1024-PKCS1v15-Encrypt(aes_key, publicKey)
  7. key = base64(rsa_ct)
```

### 5.3 完整数据流

```
┌─────────────────────────────────────────────────────────┐
│               SaveUserInfo(account)                      │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  1. 生成 UUID v4                                        │
│     ↓                                                    │
│  2. UUID 去横线，取 [:16]  →  aes_key                   │
│     ↓                                                    │
│  3. 构造内层 JSON（22字段，11有值）                      │
│     ↓                                                    │
│  4. AES-128-CBC(内层JSON, key=IV=aes_key)               │
│     ↓ base64                                             │
│  5. encrypt_user_info                                    │
│                                                          │
│  6. RSA-1024-PKCS1v15(aes_key, publicKey)               │
│     ↓ base64                                             │
│  7. key                                                  │
│                                                          │
│  8. 构造外层 JSON（22字段，key和encrypt_user_info替换）   │
│     ↓                                                    │
│  9. AES-128-CBC(外层JSON, key=IV=cache/id[:16])         │
│     ↓ base64                                             │
│  10. 写入 cache/user                                     │
│                                                          │
│  11. 构造 quota JSON                                     │
│      ↓                                                   │
│  12. AES-128-CBC(quotaJSON, key=IV=cache/id[:16])       │
│      ↓ base64                                            │
│  13. 写入 cache/quota                                    │
└─────────────────────────────────────────────────────────┘
```

---

## 6. Go 函数对照表

| Go 函数 | 地址 | 用途 |
|---------|------|------|
| `cosy/auth/user.SaveUserInfo` | `0x1AABBCCDD` | 生成并写入 cache/user |
| `cosy/encrypt.AesEncryptWithBase64` | `0x1AABBCCEE` | AES-128-CBC 加密 + base64 编码 |
| `cosy/encrypt.RsaEncrypt` | `0x1AABBCCFF` | RSA 公钥加密 |
| `cosy/encrypt.pkcs5Padding` | `0x1AABBCC00` | PKCS7 填充（实际为 PKCS7） |
| `cosy/util.ToJsonStr` | `0x1AABBCC11` | JSON 序列化 |
| `crypto/aes.NewCipher` | `0x1AABBCC22` | 创建 AES 加密器 |
| `crypto/cipher.NewCBCEncrypter` | `0x1AABBCC33` | 创建 CBC 加密器（IV=key） |
| `crypto/rsa.EncryptPKCS1v15` | `0x1AABBCC44` | RSA PKCS1v15 加密 |
| `encoding/json.Marshal` | `0x1AABBCC55` | JSON 序列化 |
| `encoding/base64.(*Encoding).EncodeToString` | `0x1AABBCC66` | Base64 编码 |
| `uuid.NewString` | `0x1AABBCC77` | 生成 UUID v4 |
| `GetMachineId` | `0x1AABBCC88` | 获取设备标识 |
| `strings.ReplaceAll` | `0x1AABBCC99` | 字符串替换 |
| `runtime.convT` | `0x1AABBCCAA` | 类型转换 |
| `runtime.stringtoslicebyte` | `0x1AABBCCBB` | string → []byte |
| `runtime.slicebytetostring` | `0x1AABBCCCC` | []byte → string |
| `runtime.makeslice` | `0x1AABBCCDD` | 分配 slice 内存 |

---

## 7. 文件格式规范

### 7.1 cache/user（外层）

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | string | 用户显示名 |
| `aid` | string | 账号 ID |
| `uid` | string | 用户 ID |
| `yx_uid` | string | 邮箱用户 ID |
| `organization_id` | string | 组织 ID |
| `organization_name` | string | 组织名称 |
| `staffId` | string | 员工 ID |
| `avatar_url` | string | 头像 URL |
| `security_oauth_token` | string | OAuth 访问令牌 |
| `refresh_token` | string | 刷新令牌 |
| `expire_time` | int64 | Token 过期时间戳 |
| `key` | string | RSA 加密后的 AES 密钥（base64） |
| `encrypt_user_info` | string | AES 加密后的用户信息（base64） |
| `user_source_channel` | string | 用户来源渠道 |
| `account_source` | string | 账号来源（`example_source`） |
| `login_method` | string | 登录方式（`example_method`） |
| `user_type` | string | 用户类型 |
| `data_policy_agreed` | bool | 数据政策同意 |
| `email` | string | 邮箱 |
| `is_data_policy_modifiable` | bool | 数据政策是否可修改 |
| `is_quota_exceeded` | bool | 是否超出配额 |
| `organization_tags` | []string/null | 组织标签 |

### 7.2 encrypt_user_info（内层明文）

| 字段 | 值来源 | 说明 |
|------|--------|------|
| `name` | 有值 | 用户显示名 |
| `aid` | 有值 | 账号 ID |
| `uid` | 有值 | 用户 ID |
| `yx_uid` | 有值 | 邮箱用户 ID |
| `organization_id` | 有值 | 组织 ID |
| `organization_name` | 有值 | 组织名称 |
| `staffId` | **零值** `""` | |
| `avatar_url` | **零值** `""` | |
| `security_oauth_token` | 有值 | OAuth Token |
| `refresh_token` | 有值 | 刷新 Token |
| `expire_time` | **零值** `0` | |
| `key` | **零值** `""` | |
| `encrypt_user_info` | **零值** `""` | |
| `user_source_channel` | **零值** `""` | |
| `account_source` | 有值 | `"example_source"` |
| `login_method` | 有值 | `"example_method"` |
| `user_type` | 有值 | 用户类型 |
| `data_policy_agreed` | **零值** `false` | |
| `email` | **零值** `""` | |
| `is_data_policy_modifiable` | **零值** `false` | |
| `is_quota_exceeded` | **零值** `false` | |
| `organization_tags` | **零值** `null` | |

### 7.3 cache/quota

| 字段 | 类型 | 说明 |
|------|------|------|
| `expireTime` | int64 | 过期时间戳 |
| `userId` | string | 用户 ID |
| `name` | string | 用户显示名 |
| `avatarUrl` | string | 头像 URL |
| `quota` | int | 配额（通常为 0） |
| `status` | int | 状态（通常为 2） |
| `whitelist` | int | 白名单状态（通常为 3） |
| `email` | string | 邮箱 |

---

## 8. Rust 实现要点

### 8.1 依赖

```toml
[dependencies]
serde_json = { version = "1", features = ["preserve_order"] }  # JSON 字段顺序
uuid = { version = "1.10", features = ["v4", "serde"] }        # UUID v4 生成
aes = "0.8"                                                     # AES 加密
cbc = "0.1"                                                     # CBC 模式
rsa = "0.9"                                                     # RSA 加密
base64 = "0.22"                                                 # Base64 编码
rand = "0.8"                                                    # 随机数
```

### 8.2 关键函数

```rust
/// AES-128-CBC 加密 + base64
fn aes128_cbc_encrypt_base64(key: &[u8; 16], plaintext: &[u8]) -> Result<Vec<u8>, String>

/// 生成 key 和 encrypt_user_info 字段
fn generate_key_and_encrypt_user_info(account: &QoderCnAccount) -> Result<(String, String), String>

/// 写入 SharedClientCache/cache/{user,quota}
fn write_shared_client_cache_files(account: &QoderCnAccount) -> Result<(), String>
```

### 8.3 加密参数

| 参数 | 外层加密 | 内层加密 |
|------|----------|----------|
| 算法 | AES-128-CBC | AES-128-CBC |
| 密钥 | `cache/id[:16]` | `UUID[:16]`（ASCII hex） |
| IV | 与密钥相同 | 与密钥相同 |
| Padding | PKCS7 | PKCS7 |
| 编码 | 标准 base64 | 标准 base64 |
| RSA | — | 1024-bit, PKCS1v15 |

---

## 9. 常见问题排查

### 问题 1：额度不显示 / 消息发送异常

**症状**：切换账号后 Qoder CN 启动，额度为 0，发送消息报错"当前账号异常"。

**可能原因**：
1. `encrypt_user_info` 的 AES 密钥不是 UUID 派生的 ASCII hex
2. 内层 JSON 字段顺序与 Go struct 不一致（需要 `preserve_order`）
3. `cache/id` 读取不正确（需要 trim 处理换行符）
4. Token 已过期

**排查方法**：
```bash
# 解密 cache/user 检查结构
python3 scripts/qoder_cn_cache_crypto.py decrypt user

# 检查内层 encrypt_user_info 是否可解密
# （需要 RSA 私钥，不可行）
```

### 问题 2：生成的文件大小不对

- `encrypt_user_info` 明文约 489-592 字节，加密 + base64 后约 664 字节
- `cache/user` 完整密文约 1200-1300 字节
- 如果大小明显偏小，可能是 JSON 结构不完整

---

## 10. 参考资料

- [Go 1.17+ Register ABI 调用约定](https://go.dev/doc/asm)
- [AES-CBC 模式 RFC 3602](https://datatracker.ietf.org/doc/html/rfc3602)
- [PKCS#1 v1.5 RSA 加密 RFC 2313](https://datatracker.ietf.org/doc/html/rfc2313)
- [PKCS#7 填充 RFC 2315](https://datatracker.ietf.org/doc/html/rfc2315)
- [GoReSym](https://github.com/mandiant/GoReSym) - Go 二进制逆向工具
