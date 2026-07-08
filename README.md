# Qoder Account Switcher (Go 零依赖版)

qoder-switch 是一个专门为 Qoder CN 和 QoderWork CN 开发的多账号切换工具。

本工具使用 Go 语言（Golang）编写，完全移除了对 Python、sqlite3、pip 加密库等外部环境的依赖。它是一个单文件绿色版二进制可执行文件，解压即用，拥有极佳的交互体验与极高的稳定性。

---

## 核心特性

- **零依赖，开箱即用**：下载即可直接运行，无需安装 Python 或任何依赖包，不再担心 PyCryptodome 安装报错。
- **完美跨平台**：
  - **macOS**：原生支持 Apple Silicon (arm64) 与 Intel (amd64)，通过系统 Keychain 安全读取加密密钥。
  - **Windows**：原生 .exe 支持，可在普通的 CMD、PowerShell 中运行，无需 Git Bash/MSYS 环境，原生调用 Windows DPAPI 接口解密。
- **完美向下兼容**：完美读取和还原之前版本 Bash 脚本备份的账号数据与 .meta.json 元信息。
- **极简键盘交互**：
  - 使用 **↑ / ↓** 键选择应用、操作与账号。
  - 按 **Enter** 键执行或进入。
  - 按 **← (左方向键)** 随时返回上一步或在输入别名时**中途取消**。
  - 支持 **Q** 键一键退出。
- **动态 SQLite 表结构兼容**：智能适配不同版本客户端的 supabase_token 表结构，自动跳过不存在的列，绝不发生数据库逻辑错误崩溃。

---

## 安装与下载

### 1. 一键命令行安装 (推荐)
在 macOS Terminal 或 Windows Git Bash 中，直接运行以下命令即可自动检测系统环境、下载最新版二进制并完成安装：
```bash
curl -fsSL https://raw.githubusercontent.com/vpen66/qoder-account-switcher/main/install.sh | bash
```

### 2. 手动下载
你可以直接在 GitHub 的 Releases 页面下载对应你操作系统的最新二进制文件，并重命名为 qoder-switch：

- **Windows**: qoder-switch-windows-amd64.exe
- **macOS (M1/M2/M3)**: qoder-switch-macos-arm64
- **macOS (Intel)**: qoder-switch-macos-amd64

### macOS 安装说明

将下载的二进制文件移动到系统的 PATH 路径（如 /usr/local/bin）并赋予执行权限：
```bash
# 复制到系统路径并重命名
sudo cp qoder-switch-macos-arm64 /usr/local/bin/qoder-switch

# 赋予执行权限
sudo chmod +x /usr/local/bin/qoder-switch
```

---

## 快速使用

### 1. 交互式菜单模式 (推荐)
直接运行 qoder-switch，系统会根据终端宽度展示自适应的 UI 导航选单：
```bash
qoder-switch
```

### 2. 命令行快捷操作
除交互菜单外，本工具支持在终端中直接带参数快速执行：

```bash
# 1. 保存当前登录态为别名 "work_main"
qoder-switch save work_main

# 2. 切换到账号 "work_main"（会自动关闭并重启应用）
qoder-switch switch work_main

# 3. 查看两个应用的安装状态及当前登录状态
qoder-switch status

# 4. 列出所有已备份的账号
qoder-switch list

# 5. 删除账号备份
qoder-switch delete work_main

# 6. 查看帮助
qoder-switch help
```

---

## 本地编译

如果你本地安装了 Go 环境（Go 1.21+），可以通过根目录下的 build.sh 脚本一键编译所有平台的包：

```bash
# 给予脚本执行权限
chmod +x build.sh

# 运行跨平台构建
./build.sh
```
编译生成的二进制文件将输出在 dist/ 目录中。

---

## GitHub Actions 自动发布

项目集成了 GitHub Actions 持续集成。每次在仓库中推送带有版本号的 git tag 时，云端会自动编译并创建一个 Release 供用户下载：

```bash
# 创建版本标签并推送，云端将自动构建发布
git tag v1.0.0
git push origin v1.0.0
```
