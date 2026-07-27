# Changelog

All notable changes to LEM (Linux Environment Manager) are documented in this file.

## [v1.1.0] - 2026-07-27

### Added
- **系统扫描与环境接管** (`lem scan`)
  - 自动扫描 dpkg 已安装软件包
  - 自动扫描 Docker 已运行容器
  - 扫描系统常用二进制工具和开发环境
  - 扫描关键环境变量配置
- **环境接管双模式**
  - `symlink` 模式：软连接管理，节省空间
  - `reinstall` 模式：通过 LEM 后端重新安装，完全控制
- `lem scan --import` 导入扫描结果到状态数据库
- `lem scan --dry-run` 预览扫描结果
- `lem scan --mode=symlink|reinstall` 选择接管模式
- `config/lem.lua` 新增 `system_takeover` 开关（默认关闭）
- `src/core/scanner.lua` 系统扫描模块
- `src/core/takeover.lua` 环境接管模块
- `src/core/db.lua` 新增 `import_package` 批量导入接口

### Changed
- `reinstall_takeover` 通过 PackageManager 统一接口调用，解耦具体后端

## [v1.0.0] - 2026-07-25

### Added
- **包管理** — APT + Docker 双后端统一接口
  - `lem install` / `lem remove` / `lem status`
- **软件源管理** — GPG 密钥 + 仓库管理
  - `lem source add/remove/list`
  - 内置 Docker、VSCode、Node.js 等常用源
- **声明式 Recipe 系统** — Lua 脚本定义环境配方
  - `lem apply <recipe>` 一键部署环境
  - 内置 dev、cpp、docker、server 配方
- **环境变量管理**
  - `lem env` 查看环境变量
  - `lem backup` / `lem restore` 配置备份恢复
- **服务管理** — Systemd + Docker 服务编排
- **环境自动初始化**
  - `lem init` 一键初始化环境
  - 首次运行自动检测并初始化
- **依赖自管理**
  - `lem deps status/install/list`
  - 安装后自动记录依赖到状态数据库
- **一键安装脚本** `install.sh`
  - 自动检测 OS 和包管理器
  - 支持 Ubuntu/Debian/Fedora/Arch
  - 自动安装依赖、编译 C 模块、配置 PATH
- **C 原生模块**（可选性能增强）
  - `lem_executor` — 进程执行（fork/execvp）
  - `lem_db` — SQLite3 绑定
  - `lem_fs` — 文件系统底层操作
- **SQLite 状态数据库** — WAL 模式，事务支持
- **命令安全机制** — 白名单验证 + 参数消毒
- **日志系统** — DEBUG/INFO/WARN/ERROR 四级日志
- **测试框架** — 覆盖核心模块的单元测试
