# LEM — Linux Environment Manager

**LEM** (Lua Environment Manager) 是一个基于 Lua 5.4 + C 的轻量级 Linux 环境管理工具。它通过统一的 CLI 界面，整合软件安装、软件源管理、环境变量配置、服务部署和环境配方等功能，让你快速搭建和管理 Linux 开发/服务器环境。

---

## 目录

- [功能特性](#功能特性)
- [系统要求](#系统要求)
- [安装部署](#安装部署)
- [快速开始](#快速开始)
- [命令详解](#命令详解)
- [Recipe 配方系统](#recipe-配方系统)
- [配置说明](#配置说明)
- [C 原生模块编译](#c-原生模块编译)
- [常见问题](#常见问题)

---

## 功能特性

- **统一包管理** — 同时支持 APT 和 Docker 后端，一条命令管理软件包
- **软件源管理** — 内置 Docker、VS Code、Node.js 等常用源，一键添加
- **声明式 Recipe** — 通过 Lua 脚本定义环境配方，一键部署完整开发环境
- **环境变量管理** — 集中管理环境变量，支持生成和加载
- **配置备份/恢复** — 快速备份和恢复系统配置文件
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

## 安装部署

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
```

---

## 命令详解

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
docker.io + MySQL 8 容器 + Redis 7 容器
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

> 编译完成后，`.so` 文件会放在 `native/` 目录下。LEM 启动时会自动检测并加载，未找到的模块会自动 fallback 到纯 Lua 实现。

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

---

## 项目结构

```
lem/
├── lem                          # 入口脚本（Bash）
├── src/
│   ├── main.lua                 # 主入口，路径初始化
│   ├── cli.lua                  # CLI 命令路由（14 个命令）
│   ├── core/
│   │   ├── executor.lua         # 命令执行引擎
│   │   ├── logger.lua           # 日志系统
│   │   ├── fs.lua               # 文件系统操作
│   │   └── db.lua               # SQLite 状态数据库
│   ├── package/
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
├── native/                      # C 原生模块
│   ├── lem_executor.c
│   ├── lem_db.c
│   ├── lem_fs.c
│   ├── lem_common.h
│   └── Makefile
├── recipes/                     # 内置环境配方
├── config/
│   └── lem.lua                  # 全局配置
└── tests/
    └── test_runner.lua          # 测试框架
```

---

## 许可证

本项目仅供学习和内部使用。
