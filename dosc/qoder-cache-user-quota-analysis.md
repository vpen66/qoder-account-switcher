# QoderCN `cache/user` 与 `cache/quota` 加密方案与自生成分析（最终版）

> 分析对象：`~/Library/Application Support/QoderCN/SharedClientCache/cache/{user,quota,id}`
> 结论：**完全可以自己生成**，无需服务端、无需 Go sidecar。

---

## 一、加密方案（已逆向 + 往返字节级验证）

| 项 | 值 |
|----|----|
| 算法 | **AES-128-CBC** + PKCS7 padding |
| 密钥 | `cache/id` 文件内容的**前 16 字节**（UTF-8） |
| IV | **= 密钥**（同一个值） |
| 外层编码 | 标准 base64 |
| 明文 | UTF-8 JSON |

验证：解密 `user`/`quota` → 用相同算法重新加密 → 与原文件**字节级完全一致**（quota 344B、user 2240B 都完全一致）。

> 例：`cache/id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"`，则 AES-128 key = IV = `b'a1b2c3d4-e5f6-78'`（16 字节）。

**之前关于 RSA 非对称加密的结论是错的**。RSA 公钥/私钥（二进制内嵌的 RSA-1024 公钥、RSA-2048 私钥）用于 `user` 明文里的 `key`/`encrypt_user_info` 内层字段（给服务端解密），**不是**用于整个 cache 文件的加密。

---

## 二、明文 JSON Schema（实测解密结果）

### `quota` 文件明文
```json
{
  "expireTime": 1700000000000,
  "userId": "00000000-aaaa-bbbb-cccc-ddddeeee0001",
  "name": "user_example_12345",
  "avatarUrl": "https://example.com/users/<userId>/default/avatars",
  "quota": 0,
  "status": 2,
  "whitelist": 3,
  "email": ""
}
```

### `user` 文件明文
```json
{
  "name": "user_example_12345",
  "aid": "00000000-aaaa-bbbb-cccc-ddddeeee0001",
  "uid": "00000000-aaaa-bbbb-cccc-ddddeeee0001",
  "yx_uid": "",
  "organization_id": "",
  "organization_name": "",
  "staffId": "",
  "avatar_url": "https://example.com/users/<userId>/default/avatars",
  "security_oauth_token": "dt-XxxYyyZzzAaaBbb123CccDdd456",   // ← access token (登录态核心)
  "refresh_token": "drt-XxxYyyZzzAaaBbb123CccDdd456",          // ← refresh token (登录态核心)
  "expire_time": 1750000000000,                              // ← token 过期时间(ms)
  "key": "<base64, 128B RSA-1024 加密 blob>",               // 给服务端, 本地不解析
  "encrypt_user_info": "<base64, 608B 加密 blob>",          // 给服务端, 本地不解析
  "user_source_channel": "",
  "account_source": "example_source",
  "login_method": "device_token",
  "user_type": "personal_trial",
  "data_policy_agreed": true,
  "email": "",
  "is_data_policy_modifiable": false,
  "is_quota_exceeded": false,
  "organization_tags": null
}
```

**登录态关键字段**：`security_oauth_token`（dt-...）、`refresh_token`（drt-...）、`expire_time`、`uid`/`aid`。Qoder CN 启动时从 `user` 文件解密读取这些来恢复登录。

---

## 三、谁生成、能否自己生成

### 生成者
`SharedClientCache/cache/{user,quota,id}` 由 Qoder CN 内置的 **Go sidecar**（`/Applications/Qoder CN.app/.../bin/aarch64_darwin/QoderCN`，113MB）在登录/刷新后写入。cockpit-tools **不写**这两个文件（只读 `cache/id`、`cache/machine_token.json`）。

### 能否自己生成？**能。**
- 密钥来源（`cache/id`）是本地明文 UUID，完全可读。
- 算法是标准 AES-128-CBC，openssl/任意语言都能实现。
- 明文 schema 已知。
- 往返验证证明：自己加密的文件与 Go sidecar 生成的**字节级一致**。

**不需要服务端生成**——服务端 OpenAPI 只返回明文 JSON（`/api/v3/user/status`、`/api/v2/quota/usage` 等），加密落盘纯客户端行为，而加密密钥就在本地 `cache/id`。

---

## 四、自己生成的完整流程（cockpit-tools 集成思路）

```
1. OAuth 登录 → 拿到明文数据 (cockpit-tools qoder_oauth.rs 已具备):
   - access_token (dt-...)      ← 来自 deviceToken/poll
   - refresh_token (drt-...)    ← 来自 deviceToken/poll
   - userId / name / email / avatarUrl
   - quota / status / whitelist / userType ...
   - expire_time / refreshTokenExpireTime

2. 确保 cache/id 存在 (32 字节以上的 UUID 字符串)
   key = IV = cache/id[:16]

3. 构造 quota JSON (见 schema) → AES-128-CBC 加密 → base64 → 写 cache/quota
4. 构造 user  JSON (见 schema) → AES-128-CBC 加密 → base64 → 写 cache/user
```

### 字段映射（cockpit-tools OAuth 数据 → cache 明文）
| cache 字段 | 来源 |
|-----------|------|
| `security_oauth_token` | `token_data.token`（deviceToken/poll 响应，dt- 前缀） |
| `refresh_token` | `token_data.refresh_token`（drt- 前缀） |
| `expire_time` | `token_data.expires_at` → 毫秒 |
| `uid`/`aid`/`userId` | `user_status.id` |
| `name` | `user_status.name` / `user_info.name` |
| `avatarUrl`/`avatar_url` | `https://example.com/users/{uid}/default/avatars` |
| `quota` | `user_status.quota` |
| `status`/`whitelist` | `calculate_auth_status(user_status)` 算出的 (status, whitelist) |
| `user_type` | `user_status.userType` |
| `expireTime`(quota) | 当前刷新时间戳(ms) |
| `account_source` | 固定 `"example_source"` |
| `login_method` | 固定 `"device_token"` |
| `data_policy_agreed` | `data_policy` 响应推断 |

### `key` / `encrypt_user_info` 两个字段的处理
这两个是 RSA 加密的内层 blob（给服务端解密，客户端不解析）：
- `key`：128B = 1 个 RSA-1024 块（用内嵌 RSA-1024 公钥加密）
- `encrypt_user_info`：608B 加密 blob

**实践建议**：
- 若 Qoder CN 启动时只读 `security_oauth_token`/`refresh_token` 恢复登录、不强校验这两个字段 → 可**照搬一次真实登录产生的旧值**，或置空测试。
- 若需精确生成 → 需进一步逆向 `CustomEncryptV1` 中 RSA 部分（用内嵌 RSA-1024 公钥加密什么明文）。可后续单独逆向。

---

## 五、工具脚本

已生成 `scripts/qoder_cn_cache_crypto.py`，支持解密/加密/编辑：

```bash
# 解密查看明文
python3 scripts/qoder_cn_cache_crypto.py decrypt user
python3 scripts/qoder_cn_cache_crypto.py decrypt quota

# 从 JSON 重新加密生成文件
python3 scripts/qoder_cn_cache_crypto.py encrypt user --json user.json --out cache/user
python3 scripts/qoder_cn_cache_crypto.py encrypt quota --json quota.json --out cache/quota

# 解密 → 编辑器修改 → 重新加密写回
python3 scripts/qoder_cn_cache_crypto.py edit user
```

依赖：系统 `openssl` + `python3`（无第三方库）。

### Rust 集成要点（cockpit-tools）
用 `aes` + `cbc` + `base64` crate：
```rust
// key = iv = cache_id.as_bytes()[..16]
// AES-128-CBC 加密 + PKCS7, 再 base64
// 解密: base64 → AES-128-CBC 解密(iv=key) → 去 PKCS7 → UTF-8 JSON
```
cockpit-tools 已有 `qoder_oauth.rs` 拿明文数据、`qoder_cn_account.rs` 管理账号，加一个 `qoder_cn_cache.rs` 模块实现加密落盘即可。

---

## 六、一句话总结

`cache/user`、`cache/quota` 是 **AES-128-CBC**（key=IV=`cache/id` 前16字节）加密的 JSON，密钥就在本地明文 `cache/id` 里。**完全能自己解密和生成**，不需要服务端、不需要 Go sidecar——登录后从 OpenAPI 拿明文，按 schema 构造 JSON，AES 加密+base64 落盘即可让 Qoder CN 保持登录态。
