---
name: qoder-cn-generate-key-encrypt-userinfo
overview: 用逆向出的 JS encryptUserInfo 算法（RSA-1024 PKCS1v15 加密随机AES密钥 + AES-128-CBC 加密5字段明文，IV=key）自己生成 cache/user 的 key/encrypt_user_info 字段，替代当前空值；同时修正 email 字段为空字符串匹配 Qoder CN schema。生成后实测切换账号验证 Qoder CN 额度显示与消息发送。
todos:
  - id: add-generate-func
    content: 新增 QODER_CN_RSA_PUBLIC_KEY_PEM 常量 + generate_key_and_encrypt_user_info 函数（RSA-1024 PKCS1v15 + 复用 aes128_cbc_encrypt_base64）
    status: completed
  - id: wire-and-fix-email
    content: 修改 write_shared_client_cache_files：用 generate_key_and_encrypt_user_info 替换空值 key/encrypt_user_info，修正 user/quota email=""
    status: completed
    dependencies:
      - add-generate-func
  - id: compile-verify
    content: cargo check 编译通过，解密生成的 cache/user 确认 key/encrypt_user_info 非空且 uid 匹配
    status: completed
    dependencies:
      - wire-and-fix-email
---

## 产品概述

切换 Qoder CN 账号时，自己生成 `cache/user` 中的 `key`（128B RSA blob）和 `encrypt_user_info`（AES 加密 blob），替代当前写空值导致 Qoder CN 鉴权失败的方案。

## 核心功能

- 用 RSA-1024 PKCS1v15 + AES-128-CBC 算法（逆向自 Qoder CN JS `encryptUserInfo` 函数）生成 `key`/`encrypt_user_info`
- 修正 `cache/user` 和 `cache/quota` 的 `email` 字段为空字符串，匹配 Qoder CN 原生 schema
- 切换账号后 Qoder CN 能正确恢复登录态（额度显示、消息发送正常）

## Tech Stack

- 语言：Rust（Tauri 后端），文件 `src-tauri/src/modules/qoder_cn_account.rs`
- 加密依赖（Cargo.toml 已具备）：`rsa=0.9`（Pkcs1v15Encrypt）、`aes=0.8`+`cbc=0.1`、`base64=0.22`、`rand=0.8`
- 参考用法：`src-tauri/src/modules/zed_oauth.rs:3-5`（rsa crate + OsRng 导入模式）

## Implementation Approach

### 生成算法（100% 逆向自 Qoder CN JS sharedProcessMain.js:133 encryptUserInfo）

```
1. 随机生成 16 字节 AES 密钥（OsRng）
2. 明文 JSON = {uid, security_oauth_token, name, aid:"", email:""}（5字段）
3. encrypt_user_info = base64( AES-128-CBC(明文, key=AES密钥, IV=AES密钥) )
   → 复用现有 aes128_cbc_encrypt_base64(&aes_key, &pt_bytes)
4. key = base64( RSA-1024-PKCS1v15(AES密钥16字节) )
   → RsaPublicKey::from_public_key_pem + .encrypt(&mut rng, Pkcs1v15Encrypt, &aes_key)
5. 返回 (key, encrypt_user_info)
```

### RSA-1024 公钥（内嵌 PEM，已 openssl 验证 1024 bit，加密16字节→128B ✓）

```
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDA8iMH5c02LilrsERw9t6Pv5Nc
4k6Pz1EaDicBMpdpssss5OANqUssssss95omAGIOPOh+Nx0spthYA2BqGz+l
6HRkPJ7S236FZz73In/KVuLnwI8JJ2CbuJap8kvheCCZpmAWpb/cPx/3Vr/J6I17
XcW+ML9FoCI6AOvOzwIDAQAB
-----END PUBLIC KEY-----
```

### 关键技术决策

- **复用 `aes128_cbc_encrypt_base64`**：该函数接收 `&[u8;16]` key + `&[u8]` plaintext，返回 base64 bytes，正好适用于 encrypt_user_info 生成（key=IV=随机16字节）。
- **RSA 用 `Pkcs1v15Encrypt`**（非 OAEP）：JS 源码明确 `RSA_PKCS1_PADDING`，且验证 128B 输出匹配。
- **明文5字段**：所有 JS `encryptUserInfo` 调用点统一用 `{uid, security_oauth_token, name, aid:"", email:""}`。虽 cache 实际 encrypt_user_info 为 608B（Go 生成，明文更大），但服务端解密后解析 JSON 字段，5字段含鉴权关键字段 uid/security_oauth_token，大概率被接受。需实测确认。
- **email="" 修正**：Qoder CN 自己写的 cache/user 和 cache/quota 中 email 均为空字符串，当前代码写 `account.email`（UUID）是错误的。

### Performance & Reliability

- RSA-1024 加密 + AES-128-CBC 加密：微秒级，无性能瓶颈
- 生成失败返回 Err，调用方 `?` 传播，记 warn 不阻断切换（与现有逻辑一致）
- 随机密钥每次切换重新生成，不缓存

## Implementation Notes

- **use 导入模式**：函数内 local `use`（与现有 `aes128_cbc_encrypt_base64` 一致），避免文件级导入冲突
- **rand 0.8 API**：`let aes_key: [u8; 16] = rand::rngs::OsRng.gen();`（OsRng 实现 Rng trait）
- **rsa 0.9 API**：`RsaPublicKey::from_public_key_pem(PEM)` 来自 `rsa::pkcs1::DecodePublicKey`；`.encrypt(&mut rng, Pkcs1v15Encrypt, &aes_key)` 返回 `Vec<u8>`
- **JSON 字段顺序**：serde_json 默认 BTreeMap（字母序），与 JS JSON.stringify（插入序）不同，但服务端解析 JSON 不关心字段顺序，不影响
- **blast radius**：仅修改 `write_shared_client_cache_files` 内 key/encrypt_user_info 来源 + email 字段，不涉及 switch_account 流程其他步骤

## Directory Structure

```
src-tauri/src/modules/
└── qoder_cn_account.rs  # [MODIFY] 三处改动
```

**改动 1 — 新增 RSA 公钥常量 + generate_key_and_encrypt_user_info 函数（:1895 后，aes128_cbc_encrypt_base64 之后）**

- 内嵌 `QODER_CN_RSA_PUBLIC_KEY_PEM` 常量
- `generate_key_and_encrypt_user_info(uid, security_oauth_token, name) -> Result<(String, String), String>`
- 生成随机16字节AES密钥 → AES-128-CBC加密明文JSON（复用 aes128_cbc_encrypt_base64）→ RSA-1024 PKCS1v15加密AES密钥 → 返回 (key_b64, encrypt_user_info_b64)

**改动 2 — write_shared_client_cache_files 替换 key/encrypt_user_info 来源（:1794-1811）**

- 删除从 auth_user_info_raw 取空值的 match 块
- 改为调用 `generate_key_and_encrypt_user_info(&uid, &account.access_token, &account.display_name)`

**改动 3 — 修正 email 字段（:1833, :1849）**

- `user_json.email`：`account.email` → `""`
- `quota_json.email`：`account.email` → `""`

## Key Code Structures

```rust
const QODER_CN_RSA_PUBLIC_KEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\n\
MIGfMA0GCSqGSIb3ssDQEBAQUAA4GNADCBsssiQKBgQDA8iMH5c02LilrsERw9t6Pv5Nc\n\
4k6Pz1EaDicBMpdpxKduSZu5OANqUq8esssr4GM95omAGIOPOh+Nx0spthYA2BqGz+l\n\
6HRkPJ7S236FZz73In/KVuLnwI8JJ2CbsssuJap8kvheCCZpmAWpb/cPx/3Vr/J6I17\n\
XcW+ML9FoCI6AOvOzwIDAQAB\n\
-----END PUBLIC KEY-----";

/// 生成 cache/user 的 key/encrypt_user_info 字段（逆向自 Qoder CN JS encryptUserInfo）。
/// key = base64(RSA-1024-PKCS1v15(随机AES密钥)), encrypt_user_info = base64(AES-128-CBC(明文JSON))
fn generate_key_and_encrypt_user_info(
    uid: &str,
    security_oauth_token: &str,
    name: &str,
) -> Result<(String, String), String>
```
