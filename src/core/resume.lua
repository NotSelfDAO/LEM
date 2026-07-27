-- LEM Download Acceleration Module
-- Supports resume downloads and speed tracking

local Executor = require("core.executor")
local FS = require("core.fs")
local Logger = require("core.logger")

local M = {}

-- Get remote file size via HEAD request
function M.get_remote_size(url)
    local cmd = string.format('curl -sIL "%s"', url)
    local ok, result = pcall(Executor.execute, cmd)
    if not ok or not result.success then
        return nil
    end
    local size = result.stdout:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
    if size then
        return tonumber(size)
    end
    return nil
end

-- Get local file size
function M.get_local_size(path)
    if not FS.file_exists(path) then
        return 0
    end
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

-- Download with resume support
function M.download(url, dest, progress_callback)
    local start_time = os.time()
    
    -- Get remote total size
    local total_bytes = M.get_remote_size(url)
    
    -- Check local partial file
    local local_size = M.get_local_size(dest)
    local resumed = false
    
    if local_size > 0 and total_bytes and local_size < total_bytes then
        resumed = true
        Logger.info(string.format("Resuming download from byte %d", local_size))
    end
    
    -- Build curl command
    local cmd
    if resumed then
        cmd = string.format('curl -C - -L --connect-timeout 30 -o "%s" "%s"', dest, url)
    else
        if local_size > 0 then
            os.remove(dest)
        end
        cmd = string.format('curl -L --connect-timeout 30 -o "%s" "%s"', dest, url)
    end
    
    -- Execute download
    local ok, result = pcall(Executor.execute, cmd)
    local end_time = os.time()
    local duration = math.max(end_time - start_time, 1)
    
    if not ok or not result.success then
        Logger.error("Download failed: " .. (result and result.stderr or "unknown"))
        return {
            success = false,
            bytes_downloaded = 0,
            total_bytes = total_bytes or 0,
            duration = duration,
            error = result and result.stderr or "download failed"
        }
    end
    
    -- Verify result
    local final_size = M.get_local_size(dest)
    if total_bytes and final_size ~= total_bytes then
        Logger.warn(string.format("Size mismatch: expected %d, got %d", total_bytes, final_size))
    end
    
    local speed = final_size / duration
    
    if progress_callback then
        progress_callback(final_size, total_bytes or final_size, speed)
    end
    
    Logger.info(string.format("Downloaded %s in %ds (%s/s)",
        M.format_bytes(final_size), duration, M.format_bytes(speed)))
    
    return {
        success = true,
        bytes_downloaded = final_size,
        total_bytes = total_bytes or final_size,
        duration = duration,
        resumed = resumed,
        speed = speed
    }
end

-- Format bytes to human readable
function M.format_bytes(bytes)
    if not bytes then return "unknown" end
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

-- Format time to human readable
function M.format_time(seconds)
    if not seconds or seconds < 0 then
        return "--:--"
    end
    seconds = math.floor(seconds)
    if seconds < 3600 then
        return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
    else
        return string.format("%02d:%02d:%02d",
            math.floor(seconds / 3600),
            math.floor((seconds % 3600) / 60),
            seconds % 60)
    end
end

return M
