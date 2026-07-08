# QoderCN 登录态处理机制分析（修订版）

## 核心结论

QoderCN 登录态存在 **两套独立的存储系统**，之前只清除了其中一套（编辑器层），遗漏了**后台守护进程层**——这才是删除后仍显示登录的根因。

## 两套存储系统

### 系统一：编辑器层（Electron/VSCode）

| 文件 | 说明 |
|---|---|
| `auth-v2.dat` | v10 加密的主 token（419B） |
| `User/globalStorage/state.vscdb` → `secret://aicoding.auth.userInfo` | 加密的用户信息（~2383B） |
| `User/globalStorage/state.vscdb` → `secret://aicoding.auth.userPlan` | 加密的套餐信息（1193B） |
| `User/globalStorage/state.vscdb.backup` | 上述库的备份（也会被恢复） |

### 系统二：后台守护进程层（SharedClientCache）⭐ 之前遗漏

后台有一个独立的 `QoderCN` 守护进程（PID 2276），通过 Unix socket `qodercn.sock` 与编辑器通信，维护着自己的一套登录态：

| 文件 | 说明 |
|---|---|
| **`SharedClientCache/cache/user`** | **Base64 加密的完整用户凭据**（2240B），ASCII 文本 |
| **`SharedClientCache/cache/quota`** | **Base64 加密的配额信息**（344B） |
| `SharedClientCache/cache/id` | 客户端 ID（明文 UUID） |
| `SharedClientCache/cache/cache.json` | 区域配置、网关端点（`gateway.qoder.com.cn`） |
| `SharedClientCache/cache/db/local.db` → `supabase_token` 表 | 存储 `access_token`（明文，含 `user_id`/`org_id`/`expires_at`） |
| `SharedClientCache/.info.json` | 守护进程元信息（pid、websocketPort、ipcServerPath） |

## 为什么删除后仍显示登录

```
编辑器启动
  └─ 通过 qodercn.sock 连接后台守护进程（PID 2276）
  └─ 守护进程从 SharedClientCache/cache/user 读取凭据  ← 你没删这个
  └─ 守护进程将登录态推送给编辑器
  └─ 编辑器重新写入 state.vscdb[secret://aicoding.auth.*]  ← 被恢复的原因
  └─ 重新生成 auth-v2.dat
```

**证据**：
- 删除 `state.vscdb` 中的 secret 键后，值从 2383B 变为 2377B（重新写入，内容略有变化）
- `SharedClientCache/cache/user` 修改时间为 13:38（与重新写入时间一致）
- 后台进程 `QoderCN start --workDir .../SharedClientCache` 正在运行（PID 2276）
- `local.db` 的 `supabase_token` 表中有 2 条 access_token 记录

## 正确的清除方案

### 方案 A：先杀进程再清文件（推荐）

```bash
# 1. 先退出 Qoder CN 应用（Cmd+Q），确保所有进程退出
osascript -e 'quit app "Qoder CN"'
sleep 2
# 确认进程已退出
pgrep -fl "QoderCN\|Qoder CN" || echo "进程已退出"

# 2. 清除编辑器层登录态
rm -f "/Users/vpen/Library/Application Support/QoderCN/auth-v2.dat"
sqlite3 "/Users/vpen/Library/Application Support/QoderCN/User/globalStorage/state.vscdb" \
  "DELETE FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';"
sqlite3 "/Users/vpen/Library/Application Support/QoderCN/User/globalStorage/state.vscdb.backup" \
  "DELETE FROM ItemTable WHERE key LIKE 'secret://aicoding.auth%';"

# 3. 清除后台守护进程层登录态（关键！）
rm -f "/Users/vpen/Library/Application Support/QoderCN/SharedClientCache/cache/user"
rm -f "/Users/vpen/Library/Application Support/QoderCN/SharedClientCache/cache/quota"
sqlite3 "/Users/vpen/Library/Application Support/QoderCN/SharedClientCache/cache/db/local.db" \
  "DELETE FROM supabase_token;"

# 4. 可选：清除 Cookie
rm -f "/Users/vpen/Library/Application Support/QoderCN/Cookies"*

# 5. 重新启动应用，应提示重新登录
```

### 方案 B：应用内退出登录（最安全）

在 Qoder CN 的设置/账户页面点击「退出登录」，这会同时清理两层存储并通过服务端注销 token。

## 加密方式对比

| 存储层 | 加密方式 | 特征 |
|---|---|---|
| 编辑器层（auth-v2.dat, secret://） | Chromium OSCrypt `v10` | Keychain 密钥 + AES，文件头 `v10` |
| 守护进程层（cache/user, cache/quota） | 自定义 Base64 加密 | 纯 ASCII Base64 文本，无 `v10` 前缀 |
| local.db.supabase_token | 明文存储 | access_token 直接以明文写入 SQLite |

## 完整文件清单

```
/Users/vpen/Library/Application Support/QoderCN/
├── auth-v2.dat                              ← 编辑器层 token（v10加密）
├── machineid                                ← 设备指纹（明文）
├── User/globalStorage/
│   ├── state.vscdb                          ← secret://aicoding.auth.*
│   └── state.vscdb.backup                   ← 备份（也会恢复）
└── SharedClientCache/                       ← 后台守护进程层
    ├── .info.json                           ← 守护进程 PID/port
    ├── qodercn.sock                         ← IPC Unix socket
    └── cache/
        ├── user                             ← ⭐ 用户凭据（Base64加密）
        ├── quota                            ← ⭐ 配额信息（Base64加密）
        ├── id                               ← 客户端 ID
        ├── cache.json                       ← 网关配置
        └── db/local.db
            └── supabase_token 表            ← ⭐ access_token（明文）
```

## 修订说明

上一版分析遗漏了 `SharedClientCache` 这套独立存储。该目录由独立的 `QoderCN` 守护进程管理（非 Electron 主进程），是登录态的**权威数据源**——编辑器层的 `auth-v2.dat` 和 `state.vscdb` 实际上是从这里同步派生而来的。
