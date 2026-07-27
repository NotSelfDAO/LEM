# LEM v1.0 — Linux Environment Manager

**LEM** (Lua Environment Manager) 是一个基于 Lua 5.4 + C 的轻量级 Linux 环境管理工具。它通过统一的 CLI 界面，整合软件安装、软件源管理、环境变量配置、服务部署和环境配方等功能，让你快速搭建和管理 Linux 开发/服务器环境。

---

## 目录

- [功能特性](#功能特性)
- [系统要求](#系统要求)
- [快速安装](#快速安装)
- [安装部署](#安装部署)
- [快速开始](#快速开始)
- [命令详解](#命令详解)
- [Recipe 配方系统](#recipe-配方系统)
- [配置说明](#配置说明)
- [C 原生模块编译](#c-原生模块编译)
- [项目结构](#项目结构)
- [GitHub Release 发布](#github-release-发布)
- [常见问题](#常见问题)

---

## 功能特性

- **包管理（APT + Docker 双后端）** — 统一命令管理软件包，自动切换 APT 和 Docker 后端
- **软件源管理（GPG 密钥 + 仓库管理）** — 内置 Docker、VS Code、Node.js 等常用源，自动处理 GPG 密钥
- **声明式 Recipe 系统** — 通过 Lua 脚本定义环境配方，一键部署完整开发环境
- **环境变量管理** — 集中管理环境变量，支持生成和加载
- **服务管理（Systemd + Docker）** — 支持 Systemd 系统服务和 Docker 容器服务
- **配置备份/恢复** — 快速备份和恢复系统配置文件
- **环境自动初始化（lem init）** — 首次运行自动检测并初始化环境，零配置启动
- **依赖自管理（lem deps）** — 自动检测、报告和安装 LEM 运行所需的系统依赖
- **系统扫描与环境接管（lem scan）** — 扫描系统已安装软件包，一键导入 LEM 管理
- **一键安装脚本** — `install.sh` 自动完成依赖安装、C 模块编译、环境配置
- **SQLite 状态追踪** — 记录所有已安装软件的状态信息
- **安全机制** — 命令白名单 + 参数消毒，防止危险操作
- **C 原生加速** — 可选的 C 原生模块，自动 fallback 到纯 Lua 实现

---

## 系统要求

| 依赖 | 说明 |
|------|------|
| Linux | 基于 Debian/Ubuntu 的发行版（使用 APT） |
| Lua 5.4 | 运行环境 |
| SQLite3 | 状态数据库（C 模块需要 `libsqlite3-dev`） |
| GCC | 编译 C 原生模块（可选） |
| Docker | 使用 Docker 相关功能时需要 |

---

## 快速安装

### 一键安装（推荐）

```bash
# 下载项目
git clone https://github.com/your-repo/LEM.git
cd LEM

# 运行安装脚本（自动安装依赖、编译模块、配置环境）
bash install.sh
```

### 自定义安装

```bash
# 指定安装路径
bash install.sh --prefix=/opt/lem

# 跳过依赖安装（已有环境时）
bash install.sh --skip-deps

# 跳过 C 模块编译（无 GCC 时）
bash install.sh --no-compile

# 强制重新安装
bash install.sh --force
```

### 卸载

```bash
bash install.sh uninstall
```

### 手动安装

```bash
# 1. 安装系统依赖
sudo apt install lua5.4 liblua5.4-dev libsqlite3-dev gcc make

# 2. 编译 C 原生模块（可选）
cd native && make && cd ..

# 3. 运行初始化
./lem init
```

---

## 安装部署

### 远程安装（推荐）

```bash
# 一键远程安装
curl -sL https://github.com/AAA-Software-Wholesaler/LEM/releases/latest/download/install.sh | bash
```

### 1. 安装依赖

```bash
sudo apt update
sudo apt install lua5.4 libsqlite3-dev gcc pkg-config
```

### 2. 获取 LEM

```bash
git clone <repository-url> lem
cd lem
```

### 3. 编译 C 原生模块（可选）

```bash
cd native
make
cd ..
```

> 如果不编译 C 模块，LEM 会自动使用纯 Lua 实现，功能完全一致，仅性能略有差异。

### 4. 设置执行权限

```bash
chmod +x lem
```

### 5. 添加到 PATH（可选）

```bash
# 将 lem 目录加入 PATH
export PATH="/path/to/lem:$PATH"

# 或创建软链接
sudo ln -s /path/to/lem/lem /usr/local/bin/lem
```

---

## 快速开始

```bash
# 查看帮助
lem help

# 查看版本
lem version

# 安装软件包
lem install git vim curl

# 查看已安装的软件
lem status

# 添加 Docker 软件源
lem source add docker

# 部署 C++ 开发环境
lem apply cpp

# 查看环境变量
lem env

# 检查依赖状态
lem deps status

# 检查初始化状态
lem check
```

---

## 命令详解

LEM v1.0 共提供 **16 个命令**：

### `lem install` — 安装软件包

安装一个或多个软件包，默认使用 APT 后端。

```bash
# 安装单个包
lem install git

# 安装多个包
lem install git curl wget vim

# 指定使用 Docker 后端
lem install nginx --manager=docker
```

### `lem remove` — 卸载软件包

卸载一个或多个已安装的软件包。LEM 会自动从数据库查找对应的管理后端。

```bash
# 卸载单个包
lem remove git

# 卸载多个包
lem remove vim curl
```

### `lem status` — 查看软件状态

查看 LEM 管理的软件包状态。

```bash
# 查看所有已管理的软件包
lem status

# 查看指定软件的状态
lem status git
```

输出示例：

```
NAME                 MANAGER    VERSION         STATUS
------------------------------------------------------------
git                  apt        2.43.0          installed
docker.io            apt        24.0.7          installed
```

### `lem source` — 软件源管理

管理 APT 软件源，支持添加、列出、移除和更新操作。

```bash
# 添加内置软件源（支持 docker / vscode / nodejs）
lem source add docker
lem source add vscode
lem source add nodejs

# 列出所有已管理的软件源
lem source list

# 移除软件源
lem source remove docker

# 更新包列表（相当于 apt update）
lem source update
```

**内置软件源：**

| 名称 | 地址 | 说明 |
|------|------|------|
| `docker` | download.docker.com | Docker CE 官方源 |
| `vscode` | packages.microsoft.com | VS Code 编辑器源 |
| `nodejs` | deb.nodesource.com | Node.js 20.x 源 |

> 也支持自定义源：将配置文件放入 `$LEM_CONFIG/sources/<name>.lua` 即可通过 `lem source add <name>` 添加。

### `lem apply` — 部署环境配方

使用声明式 Recipe 一键部署完整环境。

```bash
# 部署 C++ 开发环境
lem apply cpp

# 部署通用开发工具集
lem apply dev

# 部署 Docker 环境
lem apply docker

# 部署服务器环境（含 MySQL + Redis 容器）
lem apply server

# 查看所有可用配方
lem apply
```

### `lem env` — 查看环境变量

显示 LEM 管理的环境变量配置。

```bash
# 查看当前环境变量
lem env

# 等同于
lem env show
```

> 环境变量存储在 `~/.config/lem/env.sh`，可通过 `source ~/.config/lem/env.sh` 加载到当前 Shell。

### `lem backup` — 备份配置

备份系统配置文件到 LEM 备份目录。

```bash
# 备份指定配置文件
lem backup /etc/nginx/nginx.conf /etc/redis/redis.conf

# 不指定则备份默认配置集
lem backup
```

### `lem restore` — 恢复配置

从备份中恢复配置文件。

```bash
# 恢复指定配置
lem restore /etc/nginx/nginx.conf

# 不指定则恢复所有备份
lem restore
```

### `lem deps` — 依赖管理

检查和管理 LEM 运行所需系统依赖。

```bash
# 查看依赖状态报告
lem deps status
lem deps check

# 安装缺失的依赖
lem deps install

# 列出所有依赖
lem deps list
```

### `lem update` — 更新系统

更新软件包列表并升级已安装的软件。

```bash
# 更新包列表 + 升级所有包（默认）
lem update
lem update all

# 仅更新包列表，不升级
lem update system

# 检查 LEM 自身更新
lem update lem
```

### 检查与更新

```bash
# 检查是否有新版本
lem update

# 仅检查版本
lem update --check

# 下载并应用更新
lem update --apply
```

### 版本历史与回滚

```bash
# 查看版本更新历史
lem update --history

# 回滚到上一版本
lem update --rollback

# 回滚到指定版本
lem update --rollback 1.0.0

# 恢复中断的更新
lem update --resume

# 查看当前更新状态
lem update --status
```

### 更新进度显示

更新过程中会显示 7 步进度条：
1. **CHECK** — 检查远端版本
2. **DOWNLOAD** — 下载发布包（支持断点续传）
3. **BACKUP** — 备份当前版本
4. **EXTRACT** — 解压并安装
5. **COMPILE** — 重编译 C 模块（源码未变更时自动跳过）
6. **VERIFY** — 验证更新结果
7. **COMMIT** — 自动提交变更到 Git 仓库

### 中断恢复

如果更新过程中被中断（Ctrl+C、网络断开等），下次运行 `lem update` 时会自动检测并提供恢复选项：
- **[R] 恢复** — 从备份还原到更新前版本
- **[C] 继续** — 从中断步骤继续更新
- **[S] 跳过** — 清除中断状态

### 更新配置

在 `config/lem.lua` 中可配置更新行为：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `backup_retention` | 3 | 保留最近 N 个备份 |
| `backup_max_age` | 30 | 超过 N 天的备份自动清理 |
| `resume_download` | true | 启用断点续传 |
| `skip_unchanged_compile` | true | 源码未变更时跳过编译 |
| `download_timeout` | 600 | 下载超时（秒） |
| `auto_commit` | true | 更新成功后自动 git commit + push |

### `lem init` — 初始化环境

初始化 LEM 运行环境，包括数据库、Shell 集成和 C 模块编译。

```bash
# 标准初始化
lem init

# 强制重新初始化
lem init --force

# 跳过特定步骤
lem init --skip-shell
lem init --skip-db
lem init --skip-compile

# 预览模式（不实际操作）
lem init --dry-run
```

### `lem check` — 检查初始化状态

检查 LEM 环境是否已正确初始化。退出码：0=完成，1=部分，2=未初始化。

```bash
lem check
```

### `lem report` — 环境报告

显示 LEM 环境详细报告。

```bash
# 标准报告
lem report

# 详细报告
lem report --verbose
```

### `lem scan` — 系统扫描与环境接管

扫描系统中已安装的软件包，并可选择导入到 LEM 进行管理。需要在配置中启用 `system_takeover = true`。

```bash
# 扫描系统环境（仅显示，不导入）
lem scan

# 扫描并导入到 LEM
lem scan --import

# 预览模式（不实际操作）
lem scan --dry-run

# 使用 reinstall 模式导入
lem scan --import --mode=reinstall

# 使用 symlink 模式导入（默认）
lem scan --import --mode=symlink
```

**接管模式说明：**

| 模式 | 说明 |
|------|------|
| `symlink` | 在 LEM bin 目录创建软链接，指向系统已安装的二进制文件 |
| `reinstall` | 通过 LEM 包管理后端重新安装，完全接管 |

### `lem help` — 帮助信息

显示 LEM 的完整命令列表。

```bash
lem help
```

### `lem version` — 版本号

显示当前 LEM 版本。

```bash
lem version
```

### 全局选项

以下选项可与任何命令搭配使用：

| 选项 | 缩写 | 说明 |
|------|------|------|
| `--help` | `-h` | 显示帮助信息 |
| `--version` | `-v` | 显示版本号 |
| `--verbose` | — | 启用详细/调试输出 |
| `--manager=<name>` | — | 指定包管理器（默认 `apt`） |

```bash
# 以调试模式运行
lem --verbose install git

# 指定包管理器
lem --manager=docker install nginx
```

---

## Recipe 配方系统

Recipe 是 LEM 的核心功能之一，通过 Lua 脚本声明式定义环境配置，包含软件包列表、Docker 服务和环境变量。

### 内置 Recipe

#### `cpp` — C++ 开发环境

```
build-essential, clang, cmake, ninja-build, gdb, git
环境变量: CC=clang, CXX=clang++
```

#### `dev` — 通用开发工具

```
git, curl, wget, vim, htop, tmux, jq, unzip, net-tools
```

#### `docker` — Docker 环境

```
docker.io, docker-compose
```

#### `server` — 服务器环境

```
docker.io + MySQL 8 容器 (3306) + Redis 7 容器 (6379)
```

### 自定义 Recipe

在 `recipes/` 目录下创建 `.lua` 文件即可定义自己的 Recipe。格式示例：

```lua
-- recipes/myenv.lua
return {
    name = "myenv",
    description = "我的自定义开发环境",

    packages = {
        { name = "git" },
        { name = "vim" },
        { name = "nginx" },
        { name = "redis-server" },
    },

    services = {
        {
            name = "my-redis",
            image = "redis:7",
            port = "6379:6379",
        },
    },

    env = {
        MY_APP_HOME = "/opt/myapp",
        MY_APP_PORT = "8080",
    },
}
```

然后执行：

```bash
lem apply myenv
```

---

## 配置说明

### 全局配置文件

路径：`config/lem.lua`

```lua
return {
    -- 默认包管理器
    default_manager = "apt",

    -- 日志级别: "DEBUG", "INFO", "WARN", "ERROR"
    log_level = "INFO",

    -- 自动确认安装（跳过 y/n 提示）
    auto_confirm = false,

    -- 命令超时时间（秒）
    timeout = 300,

    -- 系统接管（扫描并导入系统已安装软件包）
    system_takeover = false,
}
```

### 路径约定

| 路径 | 说明 |
|------|------|
| `~/.local/share/lem/state.db` | SQLite 状态数据库 |
| `~/.local/share/lem/lem.log` | 日志文件 |
| `~/.config/lem/env.sh` | 环境变量脚本 |
| `~/.local/share/lem/backups/` | 配置备份目录 |

### 环境变量覆盖

可通过环境变量覆盖默认路径：

```bash
export LEM_CONFIG="/custom/config/path"
export LEM_DATA="/custom/data/path"
export LEM_CACHE="/custom/cache/path"
```

---

## C 原生模块编译

LEM 包含三个可选的 C 原生模块，编译后可获得更好的性能。

### 模块列表

| 模块 | 功能 |
|------|------|
| `lem_executor.so` | 进程执行（白名单 + 参数消毒） |
| `lem_db.so` | SQLite3 数据库绑定 |
| `lem_fs.so` | 文件系统底层操作 |

### 编译步骤

```bash
cd native
make          # 编译所有模块
make clean    # 清理编译产物
```

### 编译依赖

- GCC
- Lua 5.4 开发头文件（`lua5.4` 或 `liblua5.4-dev`）
- SQLite3 开发库（`libsqlite3-dev`，仅 `lem_db.so` 需要）

> 编译完成后，`.so` 文件须放在 `native/` 目录下。LEM 启动时会自动检测并加载，未找到的模块会自动 fallback 到纯 Lua 实现。

---

## 项目结构

```
LEM/
├── .github/
│   └── workflows/
│       └── release.yml            # GitHub Actions 发布工作流
├── CHANGELOG.md                   # 变更日志
├── lem                          # 入口脚本（Bash）
├── install.sh                   # 一键安装脚本
├── config/
│   └── lem.lua                  # 全局配置
├── src/
│   ├── main.lua                 # 主入口，路径初始化
│   ├── cli.lua                  # CLI 命令路由（16 个命令）
│   ├── core/
│   │   ├── init.lua             # 环境初始化与自动检测
│   │   ├── executor.lua         # 命令执行引擎
│   │   ├── logger.lua           # 日志系统
│   │   ├── fs.lua               # 文件系统操作
│   │   ├── db.lua               # SQLite 状态数据库
│   │   ├── deps.lua             # 依赖自管理
│   │   ├── scanner.lua          # 系统扫描模块
│   │   ├── takeover.lua         # 环境接管模块
│   │   ├── updater.lua          # 自动更新模块
│   │   ├── progress.lua         # 进度条与 ETA
│   │   ├── resume.lua           # 断点续传与下载加速
│   │   └── snapshot.lua         # 备份快照与中断恢复
│   ├── package/
│   │   ├── init.lua             # 包模块入口
│   │   ├── manager.lua          # 包管理抽象层
│   │   ├── apt.lua              # APT 后端
│   │   └── docker.lua           # Docker 后端
│   ├── source/
│   │   ├── repository.lua       # 软件源管理
│   │   └── keyring.lua          # GPG 密钥管理
│   ├── environment/
│   │   ├── variable.lua         # 环境变量管理
│   │   └── manager.lua          # 配置备份/恢复
│   ├── service/
│   │   └── systemd.lua          # Systemd 服务管理
│   └── recipe/
│       └── loader.lua           # Recipe 加载器
├── docs/
│   └── update-spec.md           # 更新机制技术规格
├── native/                      # C 原生模块
│   ├── lem_common.h             # 公共头文件
│   ├── lem_executor.c           # 执行器 C 实现
│   ├── lem_db.c                 # 数据库 C 实现
│   ├── lem_fs.c                 # 文件系统 C 实现
│   └── Makefile                 # 编译脚本
├── recipes/                     # 内置环境配方
│   ├── cpp.lua                  # C++ 开发环境
│   ├── dev.lua                  # 通用开发工具
│   ├── docker.lua               # Docker 环境
│   └── server.lua               # 服务器环境
└── tests/
    └── test_runner.lua          # 测试框架
```

---

## GitHub Release 发布

### 自动发布

推送 `v*` 标签时，GitHub Actions 自动触发构建和发布：

```bash
git tag v1.2.0
git push origin v1.2.0
```

工作流将自动：
- 打包项目文件为 `lem-vX.Y.Z.tar.gz`
- 从 CHANGELOG.md 生成 Release Notes
- 创建 GitHub Release 并上传发布包

### 版本更新

LEM 支持自动检查和更新：

```bash
# 检查最新版本
lem update

# 自动更新（备份当前版本 → 下载 → 覆盖 → 重新编译）
lem update --apply
```

更新过程中用户配置（`~/.config/lem/`）和状态数据库（`~/.local/share/lem/state.db`）不会被覆盖。

### 自动提交

更新成功后，LEM 会自动将变更提交到 Git 仓库并推送到远程（如果项目是 Git 仓库）。
提交信息格式：`chore: auto-update to vX.Y.Z`

如果不在 Git 仓库中或推送失败，更新仍然成功完成。可通过配置 `auto_commit = false` 禁用此功能。

---

## 常见问题

### Q: 不编译 C 模块能正常使用吗？

可以。LEM 的所有功能都有纯 Lua 实现作为 fallback，C 模块仅用于性能优化。

### Q: 支持哪些 Linux 发行版？

LEM 当前主要支持基于 Debian/Ubuntu 的发行版（使用 APT 包管理器）。Docker 相关功能在任何安装了 Docker 的 Linux 上均可使用。

### Q: 如何添加自定义软件源？

在 `~/.config/lem/sources/` 目录下创建一个 Lua 配置文件，格式如下：

```lua
-- ~/.config/lem/sources/myrepo.lua
return {
    name = "myrepo",
    url = "https://example.com/repo/ubuntu",
    distribution = "jammy",
    component = "main",
    key_url = "https://example.com/repo/gpg.key",
}
```

然后通过 `lem source add myrepo` 添加。

### Q: Recipe 执行失败怎么办？

1. 使用 `--verbose` 选项查看详细日志：`lem --verbose apply cpp`
2. 检查日志文件：`cat ~/.local/share/lem/lem.log`
3. 确认系统已安装必要的依赖（如 `apt`、`docker`）

### Q: 如何查看 LEM 管理了哪些软件？

```bash
lem status
```

所有安装/卸载记录都存储在 SQLite 数据库 `~/.local/share/lem/state.db` 中。

### Q: 备份存放在哪里？

配置备份存放在 `~/.local/share/lem/backups/` 目录下。

### Q: `lem init` 做了什么？

`lem init` 会执行以下操作：
1. 创建必要的目录结构（数据目录、配置目录、缓存目录）
2. 初始化 SQLite 状态数据库
3. 检测并编译 C 原生模块
4. 配置 Shell 集成（将 LEM 路径加入 `.bashrc`/`.zshrc`）
5. 生成默认环境变量文件

首次运行任何 LEM 命令时会自动触发初始化。

---

## 许可证

本项目仅供学习和内部使用。
