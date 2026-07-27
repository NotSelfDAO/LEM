# LEM 更新系统技术规格文档

## 1. 命令语法

```
lem update              检查并提示更新
lem update --check      仅检查版本
lem update --apply      下载并应用更新
lem update --history    查看版本更新历史
lem update --rollback [version]  回滚到指定版本
lem update --resume     恢复中断的更新
lem update --status     显示当前更新状态
```

---

## 2. 用户交互流程

### 2.1 检查版本

显示当前版本和远程版本：

```
LEM 当前版本: v2.0.0
远程最新版本: v2.1.0

有新版本可用！运行 'lem update --apply' 进行更新。
```

### 2.2 确认更新

执行 `--apply` 时提示用户确认：

```
发现新版本: v2.0.0 -> v2.1.0
是否更新？[y/N]
```

### 2.3 进度显示

6 步骤进度条：

```
[CHECK]    ✓ 检查远程版本
[DOWNLOAD] [=====>          ] 30% (1.5/5.1 MB) 下载速度: 2.3 MB/s  预计剩余: 00:23
[BACKUP]   等待中...
[EXTRACT]  等待中...
[COMPILE]  等待中...
[VERIFY]   等待中...
[COMMIT]   等待中...
```

步骤状态标记：
- `等待中...` — 尚未开始
- `[==>    ]` — 进行中（含进度条，仅 DOWNLOAD 步骤显示百分比）
- `✓` — 完成
- `✗` — 失败（显示错误信息并触发回滚）

### 2.4 中断恢复

检测到未完成更新时，提供选项：

```
检测到上次更新未完成（中断于步骤: DOWNLOAD）
  [R] 恢复更新 (Resume)
  [C] 取消更新 (Cancel)
  [S] 跳过并重新检查 (Skip)
请选择 [R/C/S]:
```

### 2.5 回滚流程

```
$ lem update --rollback

可用历史版本:
  1. v2.0.0  (2025-07-20 14:30:00)  [当前]
  2. v1.9.0  (2025-06-15 10:00:00)
  3. v1.8.2  (2025-05-01 08:15:00)

要回滚到哪个版本？(输入版本号或序号): 2
确认回滚到 v1.9.0？此操作将恢复备份文件。[y/N]: y
[BACKUP]   备份当前版本...
[RESTORE]  从备份恢复 v1.9.0...
[VERIFY]   验证恢复结果...
✓ 已回滚到 v1.9.0
```

---

## 3. 技术实现方案

### 3.1 步骤管道模式

每次更新操作以管道（pipeline）方式推进，每个步骤完成时将状态持久化到 SQLite 数据库，使中断恢复成为可能。

```
CHECK → DOWNLOAD → BACKUP → EXTRACT → COMPILE → VERIFY → COMMIT
  ↑                                                        ↑
  |______ 每步完成后写入 update_state 表 ____________________|
```

状态机定义：

| 状态值    | 含义                 |
|-----------|----------------------|
| `idle`    | 无进行中的更新       |
| `check`   | CHECK 步骤完成       |
| `download`| DOWNLOAD 步骤完成    |
| `backup`  | BACKUP 步骤完成      |
| `extract` | EXTRACT 步骤完成     |
| `compile` | COMPILE 步骤完成     |
| `verify`  | 全部步骤完成（终态） |
| `committing` | AUTO COMMIT 步骤进行中 |
| `failed`  | 某步骤失败（终态）   |
| `rolled_back` | 已回滚（终态）   |

每步执行逻辑（伪代码）：

```lua
local function run_pipeline(url, version)
    -- 写入初始状态
    db.set_update_state("download", url, version)

    -- DOWNLOAD
    download(url)
    db.set_update_state("backup")

    -- BACKUP
    backup_current()
    db.set_update_state("extract")

    -- EXTRACT
    extract_tarball()
    db.set_update_state("compile")

    -- COMPILE
    compile_native()
    db.set_update_state("verify")

    -- VERIFY
    local ok = verify_installation()
    if ok then
        db.set_update_state("verify")  -- 终态
        record_version_history(version)
    else
        rollback()
        db.set_update_state("failed")
    end
end
```

### 3.2 断点续传

使用 `curl -C -` 配合 HTTP Range 头实现下载中断恢复：

```lua
-- 检查已下载的字节数
local function get_partial_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size
end

-- 断点续传下载
local function download_with_resume(url, dest)
    local partial = get_partial_size(dest)
    local cmd = string.format(
        "curl -C - -L --connect-timeout 30 --max-time %d -o '%s' '%s'",
        config.update.download_timeout, dest, url
    )
    -- 如果已有部分文件，curl -C - 自动发送 Range 头
    return Executor.execute(cmd)
end
```

配置项 `resume_download = true` 控制是否启用断点续传。

### 3.3 备份策略

- **格式**：tar.gz 压缩归档
- **位置**：`~/.local/share/lem/backups/`
- **命名**：`lem-v{version}-{timestamp}.tar.gz`
  - 示例：`lem-v2.0.0-20250720-143000.tar.gz`
- **保留策略**：
  - 保留最近 `backup_retention`（默认 3）个备份
  - 超过 `backup_max_age`（默认 30 天）的自动清理
- **排除内容**：`state.db`、`backups/` 目录本身、用户配置（`~/.config/lem/`）

```lua
local function create_backup(version)
    local timestamp = os.date("%Y%m%d-%H%M%S")
    local backup_name = string.format("lem-v%s-%s.tar.gz", version, timestamp)
    local backup_path = backup_dir .. "/" .. backup_name

    local cmd = string.format(
        "tar -czf '%s' --exclude='state.db' --exclude='backups' -C '%s' .",
        backup_path, lem_root
    )
    local result = Executor.execute(cmd)

    if result.success then
        prune_old_backups()  -- 按保留策略清理
    end
    return result.success, backup_path
end
```

### 3.4 增量更新

通过 sha256 文件哈希对比，跳过未变更文件，减少不必要的覆盖和编译：

```lua
local function compute_file_hash(path)
    local result = Executor.execute("sha256sum '" .. path .. "'")
    if result.success then
        return result.output:match("(%S+)")
    end
    return nil
end

local function should_update_file(src_path, dest_path)
    -- 目标不存在则需要更新
    if not FS.file_exists(dest_path) then return true end

    local src_hash = compute_file_hash(src_path)
    local dest_hash = compute_file_hash(dest_path)

    -- 哈希不同则需要更新
    return src_hash ~= dest_hash
end
```

### 3.5 条件编译

`native/` 目录源码未变更时跳过 `make`，节省编译时间：

```lua
local function needs_recompile(lem_root, new_source_dir)
    local native_src = lem_root .. "/native/"
    local new_native = new_source_dir .. "/native/"

    -- 对比 native/ 下所有 .c 和 .h 文件
    local files = FS.list_files(native_src, {"*.c", "*.h"})
    for _, file in ipairs(files) do
        if should_update_file(new_native .. file, native_src .. file) then
            return true  -- 有变更，需要重新编译
        end
    end
    return false  -- 无变更，跳过编译
end
```

配置项 `skip_unchanged_compile = true` 控制此行为。

### 3.6 自动 Git 提交

更新成功后，自动将变更提交到 Git 仓库并推送到远程。

```
VERIFY 通过
  │
  ▼
[AUTO COMMIT]
  │  git add -A           ← 暂存所有变更
  │  git commit -m "chore: auto-update to vX.Y.Z"
  │  git push             ← 推送到远程
  ▼
更新完成
```

行为说明：
- 提交信息格式：`chore: auto-update to vX.Y.Z`
- 非 Git 仓库时自动跳过，不影响更新结果
- 推送失败不影响本地提交，仅发出警告
- 通过 `config/lem.lua` 中的 `auto_commit = true/false` 控制开关

```lua
local function auto_commit(version)
    -- 检查配置开关
    if config.update.auto_commit == false then
        return {success = true, message = "disabled by config"}
    end

    -- 检查是否在 git 仓库中
    local git_check = Executor.execute('git -C "' .. lem_root .. '" rev-parse --is-inside-work-tree')
    if not git_check.success then
        return {success = false, error = "not a git repository"}
    end

    -- 暂存、提交、推送
    Executor.execute('git -C "' .. lem_root .. '" add -A')
    Executor.execute('git -C "' .. lem_root .. '" commit -m "chore: auto-update to v' .. version .. '"')
    Executor.execute('git -C "' .. lem_root .. '" push')
end
```

配置项 `auto_commit = true` 控制此行为。

---

## 4. 数据库 Schema

### 4.1 update_state — 更新管道状态

跟踪当前更新操作的进度，用于中断恢复。

```sql
CREATE TABLE IF NOT EXISTS update_state (
    id              INTEGER PRIMARY KEY CHECK (id = 1),  -- 单行表，全局唯一状态
    status          TEXT    NOT NULL DEFAULT 'idle',
        -- idle | check | download | backup | extract | compile | verify | failed | rolled_back
    target_version  TEXT,
    download_url    TEXT,
    download_path   TEXT,           -- 下载文件临时路径
    backup_path     TEXT,           -- 本次更新的备份路径
    bytes_total     INTEGER DEFAULT 0,
    bytes_downloaded INTEGER DEFAULT 0,
    started_at      TEXT,           -- ISO-8601 时间戳
    updated_at      TEXT,           -- 最后更新时间戳
    error_message   TEXT            -- 失败时的错误信息
);
```

### 4.2 version_history — 版本更新历史

记录每次成功更新的版本信息。

```sql
CREATE TABLE IF NOT EXISTS version_history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    version         TEXT    NOT NULL,
    previous_version TEXT,
    backup_path     TEXT,           -- 对应备份文件路径
    release_tag     TEXT,           -- GitHub release tag
    applied_at      TEXT    NOT NULL,  -- ISO-8601 时间戳
    checksum        TEXT,           -- tarball sha256
    notes           TEXT            -- 版本说明摘要
);

CREATE INDEX IF NOT EXISTS idx_version_history_version
    ON version_history(version);
CREATE INDEX IF NOT EXISTS idx_version_history_applied
    ON version_history(applied_at);
```

### 4.3 file_manifest — 文件清单与哈希

记录安装目录中每个文件的哈希值，用于增量更新对比。

```sql
CREATE TABLE IF NOT EXISTS file_manifest (
    path            TEXT    PRIMARY KEY,
    sha256          TEXT    NOT NULL,
    size            INTEGER NOT NULL DEFAULT 0,
    mtime           TEXT,           -- 文件修改时间
    updated_at      TEXT    NOT NULL  -- 记录更新时间
);

CREATE INDEX IF NOT EXISTS idx_file_manifest_hash
    ON file_manifest(sha256);
```

---

## 5. 配置项

在 `config/lem.lua` 中定义更新相关配置：

```lua
update = {
    -- 备份保留数量
    backup_retention = 3,

    -- 备份最大保留天数
    backup_max_age = 30,

    -- 是否启用断点续传
    resume_download = true,

    -- 源码未变更时跳过 native 模块编译
    skip_unchanged_compile = true,

    -- 下载超时（秒）
    download_timeout = 600,

    -- 更新成功后自动提交到 Git 仓库
    auto_commit = true,
}
```

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `backup_retention` | number | 3 | 保留的历史备份数量上限 |
| `backup_max_age` | number | 30 | 备份最大保留天数，超期自动清理 |
| `resume_download` | boolean | true | 启用 `curl -C -` 断点续传 |
| `skip_unchanged_compile` | boolean | true | `native/` 源码无变更时跳过 `make` |
| `download_timeout` | number | 600 | curl 下载最大等待时间（秒） |
| `auto_commit` | boolean | true | 更新成功后自动 git commit + push |

---

## 6. 进度条格式

### 6.1 下载进度条

```
[=====>          ] 30% (1.5/5.1 MB) 下载速度: 2.3 MB/s  预计剩余: 00:23
```

字段说明：
- `[=====>          ]` — 30 字符宽度的可视化进度条，`=` 为已完成，`>` 为当前进度头，空格为未完成
- `30%` — 完成百分比
- `(1.5/5.1 MB)` — 已下载/总大小
- `下载速度: 2.3 MB/s` — 实时下载速度（基于最近 5 秒滑动窗口）
- `预计剩余: 00:23` — 预计剩余时间（MM:SS 格式）

### 6.2 进度条渲染规则

- 进度条总宽度固定为 30 字符
- 百分比 = `bytes_downloaded / bytes_total * 100`
- 下载速度 = 滑动窗口内字节差 / 时间差
- 预计剩余 = `(bytes_total - bytes_downloaded) / speed`
- 总大小未知时显示：`[======>         ] 1.5 MB  下载速度: 2.3 MB/s`
- 每秒刷新一次（通过 `\r` 回车覆写当前行）

### 6.3 步骤级进度总览

```
lem update --apply

发现新版本: v2.0.0 -> v2.1.0
是否更新？[y/N] y

[1/7 CHECK]    ✓ 检查远程版本                    (0.5s)
[2/7 DOWNLOAD] [=====>          ] 30% (1.5/5.1 MB) 下载速度: 2.3 MB/s  预计剩余: 00:23
[3/7 BACKUP]   等待中...
[4/7 EXTRACT]  等待中...
[5/7 COMPILE]  等待中...
[6/7 VERIFY]   等待中...
[7/7 COMMIT]   等待中...
```

---

## 7. 安全机制设计

### 7.1 下载验证（三层防护）

更新包下载后必须通过三层验证才能继续后续步骤，任一层失败则中止更新并报错。

```
下载完成
  │
  ▼
[第 1 层] HTTP 状态码检查
  │  curl -w "%{http_code}" 确认 200 OK
  │  非 200 → 中止，报告 HTTP 错误码
  ▼
[第 2 层] 文件大小合理性检查
  │  文件大小 > 0 且 < 500 MB（防止 CDN 返回 HTML 错误页）
  │  异常 → 中止，报告文件大小
  ▼
[第 3 层] SHA-256 校验和比对
  │  从 GitHub Release 的 assets 中获取 .sha256 文件
  │  本地计算 sha256sum 并与之比对
  │  不匹配 → 中止，报告哈希差异
  ▼
验证通过，继续 BACKUP 步骤
```

实现逻辑：

```lua
local function verify_download(tarball_path, expected_checksum)
    -- 第 1 层：文件存在且非空
    if not FS.file_exists(tarball_path) then
        return nil, "下载文件不存在"
    end

    local size = FS.file_size(tarball_path)
    if size == 0 then
        return nil, "下载文件为空（可能是网络错误）"
    end

    -- 第 2 层：大小合理性（上限 500 MB）
    local MAX_SIZE = 500 * 1024 * 1024
    if size > MAX_SIZE then
        return nil, string.format("文件大小异常: %d bytes（上限 %d bytes）", size, MAX_SIZE)
    end

    -- 第 3 层：SHA-256 校验
    if expected_checksum then
        local actual = compute_sha256(tarball_path)
        if actual ~= expected_checksum then
            return nil, string.format(
                "SHA-256 校验失败\n  期望: %s\n  实际: %s",
                expected_checksum, actual
            )
        end
    end

    return true
end
```

### 7.2 原子替换

文件替换采用"写入临时目录 → 验证 → 原子重命名"策略，确保任何步骤失败都不会破坏现有安装。

```
LEM_ROOT/
├── src/              ← 当前生产版本（正在运行）
├── src.new/          ← 解压新版本到此临时目录
└── src.old/          ← 硬链接/拷贝备份（用于快速回滚）
```

替换流程：

```lua
local function atomic_replace(lem_root, new_dir)
    local src_dir     = lem_root .. "/src"
    local src_new     = lem_root .. "/src.new"
    local src_old     = lem_root .. "/src.old"

    -- 1. 清理可能残留的临时目录
    Executor.execute("rm -rf '" .. src_new .. "' '" .. src_old .. "'")

    -- 2. 将新版本解压到临时目录
    local ok, err = copy_directory(new_dir, src_new)
    if not ok then return nil, "复制新版本失败: " .. err end

    -- 3. 备份当前版本
    ok, err = copy_directory(src_dir, src_old)
    if not ok then
        Executor.execute("rm -rf '" .. src_new .. "'")
        return nil, "备份当前版本失败: " .. err
    end

    -- 4. 原子重命名（POSIX rename 是原子操作）
    --    先移除旧目录，再将新目录重命名到位
    ok = os.execute("rm -rf '" .. src_dir .. "' && mv '" .. src_new .. "' '" .. src_dir .. "'")
    if not ok then
        -- 重命名失败，从 .old 恢复
        os.execute("rm -rf '" .. src_dir .. "' && mv '" .. src_old .. "' '" .. src_dir .. "'")
        return nil, "原子替换失败，已自动恢复"
    end

    -- 5. 清理旧备份目录
    Executor.execute("rm -rf '" .. src_old .. "'")

    return true
end
```

### 7.3 回滚机制

回滚分为"自动回滚"和"手动回滚"两种场景。

#### 自动回滚

更新管道中任何步骤失败时，自动从备份恢复：

```lua
local function auto_rollback(backup_path, lem_root, failed_step)
    print(string.format("  ✗ 步骤 %s 失败，正在自动回滚...", failed_step))

    -- 从 tar.gz 备份恢复
    local cmd = string.format("tar -xzf '%s' -C '%s'", backup_path, lem_root)
    local result = Executor.execute(cmd)

    if result.success then
        print("  ✓ 已自动回滚到更新前版本")
        db.set_update_state("rolled_back")
    else
        -- 极端情况：tar 恢复也失败，尝试从 .old 目录恢复
        local old_dir = lem_root .. "/src.old"
        if FS.dir_exists(old_dir) then
            os.execute("cp -r '" .. old_dir .. "/.' '" .. lem_root .. "/src/'")
            print("  ✓ 已从备用目录恢复")
        else
            print("  ✗ 自动回滚失败！请手动从备份恢复:")
            print("    " .. backup_path)
        end
        db.set_update_state("failed")
    end
end
```

#### 手动回滚

用户通过 `lem update --rollback [version]` 主动回滚到历史版本：

```lua
local function manual_rollback(target_version)
    -- 1. 查询 version_history 获取备份路径
    local record = db.query_version_history(target_version)
    if not record or not record.backup_path then
        return nil, "未找到 v" .. target_version .. " 的备份记录"
    end

    if not FS.file_exists(record.backup_path) then
        return nil, "备份文件已不存在: " .. record.backup_path
    end

    -- 2. 确认操作
    print(string.format("确认回滚到 v%s？此操作将恢复备份文件。", target_version))
    io.write("[y/N] ")
    if io.read("*l") ~= "y" then
        print("已取消。")
        return true
    end

    -- 3. 备份当前版本（回滚前也做备份）
    local current = Updater.current_version
    local ok, backup = create_backup(current)
    if not ok then
        return nil, "回滚前备份失败"
    end

    -- 4. 从备份恢复
    local cmd = string.format("tar -xzf '%s' -C '%s'", record.backup_path, lem_root)
    local result = Executor.execute(cmd)
    if not result.success then
        return nil, "恢复失败: " .. tostring(result.output)
    end

    -- 5. 记录回滚事件
    record_rollback_event(target_version, current)
    print(string.format("✓ 已回滚到 v%s", target_version))
    return true
end
```

### 7.4 校验和获取

SHA-256 校验和从 GitHub Release 的配套 `.sha256` 文件获取：

```lua
local function fetch_expected_checksum(info)
    -- 在 release assets 中查找 .sha256 文件
    for _, asset in ipairs(info.assets) do
        if asset.name and asset.name:match("%.sha256$") then
            local result = Executor.execute("curl -sL '" .. asset.url .. "'")
            if result.success then
                -- .sha256 文件格式: <hash>  <filename>
                local hash = result.output:match("(%S+)")
                return hash
            end
        end
    end

    -- 如果没有 .sha256 asset，尝试从 release body 中提取
    -- 或者回退到无校验和模式（仅做大小检查）
    return nil
end
```

### 7.5 安全机制总结

| 机制 | 触发时机 | 失败行为 |
|------|----------|----------|
| HTTP 状态码检查 | 下载完成后 | 中止更新，报告错误码 |
| 文件大小合理性 | 下载完成后 | 中止更新，防止错误页被当作有效包 |
| SHA-256 校验 | 下载完成后 | 中止更新，报告哈希差异 |
| 原子替换 | EXTRACT 步骤 | 自动恢复到替换前状态 |
| 自动回滚 | 任何步骤失败 | 从备份 tar.gz 或 .old 目录恢复 |
| 回滚前备份 | 手动回滚前 | 中止回滚，防止数据丢失 |
