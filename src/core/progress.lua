-- src/core/progress.lua
-- Multi-step progress controller with terminal bar rendering and ETA estimation

local M = {}

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Detect whether stdout is an interactive TTY.
-- @return boolean
local function _is_tty()
    local ok, term = pcall(os.getenv, "TERM")
    if not ok or not term or term == "" then
        return false
    end
    local out_type = io.type(io.output())
    -- "file" means redirected; nil / "closed" also not a tty
    if out_type == "file" then
        return false
    end
    return true
end

--- Query terminal width via tput; falls back to 80.
-- @return number
local function _term_width()
    local ok, handle = pcall(io.popen, "tput cols 2>/dev/null")
    if not ok or not handle then
        return 80
    end
    local raw = handle:read("*l")
    pcall(handle.close, handle)
    local w = tonumber(raw)
    return (w and w > 20) and w or 80
end

--- Format byte count into human-readable string.
-- @param bytes number
-- @return string  e.g. "1.5 MB"
local function _format_bytes(bytes)
    if type(bytes) ~= "number" or bytes < 0 then
        return "??"
    end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local idx = 1
    local val = bytes
    while val >= 1024 and idx < #units do
        val = val / 1024
        idx = idx + 1
    end
    if idx == 1 then
        return string.format("%d %s", math.floor(val), units[idx])
    end
    return string.format("%.1f %s", val, units[idx])
end

--- Format seconds into MM:SS.
-- @param seconds number
-- @return string
local function _format_time(seconds)
    if type(seconds) ~= "number" or seconds < 0 or seconds ~= seconds then
        return "--:--"
    end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d", m, s)
end

------------------------------------------------------------------------
-- Progress object
------------------------------------------------------------------------

local Progress = {}
Progress.__index = Progress

--- Create a new multi-step progress controller.
-- @param steps table  ordered list of step names, e.g. {"CHECK","DOWNLOAD",...}
-- @return Progress object
function M.new(steps)
    local self = setmetatable({}, Progress)
    self.steps       = steps or {}
    self.step_index  = {}          -- step_name -> 1-based index
    self.step_done   = {}          -- step_name -> boolean
    self.current_step = nil        -- current step name
    self.current_idx  = 0          -- 1-based position in steps list
    self.is_tty       = _is_tty()
    self.term_width   = _term_width()

    -- per-step tracking
    self._step_start  = nil        -- os.time() when current step started
    self._last_current = nil
    self._last_time    = nil
    self._step_current = 0
    self._step_total   = 0

    -- build index
    for i, name in ipairs(self.steps) do
        self.step_index[name] = i
        self.step_done[name]  = false
    end

    return self
end

--- Enter the next step by name, recording its start time.
-- @param step_name string
function Progress:start_step(step_name)
    local ok, err = pcall(function()
        -- mark previous step done if it wasn't explicitly completed
        if self.current_step and not self.step_done[self.current_step] then
            self.step_done[self.current_step] = true
        end

        self.current_step  = step_name
        self.current_idx   = self.step_index[step_name] or self.current_idx + 1
        self._step_start   = os.time()
        self._last_current = nil
        self._last_time    = nil
        self._step_current = 0
        self._step_total   = 0

        if not self.is_tty then
            io.write(string.format("[%s] 开始...\n", step_name))
            io.flush()
        end
    end)
    if not ok then
        pcall(io.write, "[PROGRESS] start_step error: " .. tostring(err) .. "\n")
    end
end

--- Update the current step's progress.
-- @param current number  current amount (e.g. bytes downloaded)
-- @param total   number  total amount (0 if unknown)
function Progress:update(current, total)
    local ok, err = pcall(function()
        if not self.current_step then return end

        local now = os.time()
        self._step_current = current or 0
        self._step_total   = total   or 0

        -- calculate speed
        local speed = 0
        if self._last_time and self._last_current and (now - self._last_time) > 0 then
            local dt = now - self._last_time
            local dc = self._step_current - self._last_current
            if dc >= 0 then
                speed = dc / dt
            end
        end
        self._last_current = self._step_current
        self._last_time    = now

        -- percentage
        local pct = 0
        if self._step_total > 0 then
            pct = math.min(100, math.floor(self._step_current / self._step_total * 100))
        end

        -- ETA
        local eta = self:_estimate_eta()

        if self.is_tty then
            self:_render_bar(pct, self._step_current, self._step_total, speed, eta)
        else
            -- non-TTY: periodic log line every ~20% or on completion
            local prev_pct = self._last_logged_pct or -1
            if pct - prev_pct >= 20 or pct >= 100 then
                self._last_logged_pct = pct
                if self._step_total > 0 then
                    io.write(string.format("[%s] %d%% (%s/%s)\n",
                        self.current_step, pct,
                        _format_bytes(self._step_current),
                        _format_bytes(self._step_total)))
                else
                    io.write(string.format("[%s] %d%%\n", self.current_step, pct))
                end
                io.flush()
            end
        end
    end)
    if not ok then
        pcall(io.write, "[PROGRESS] update error: " .. tostring(err) .. "\n")
    end
end

--- Mark the current step as complete.
function Progress:complete_step()
    local ok, err = pcall(function()
        if not self.current_step then return end
        self.step_done[self.current_step] = true

        if self.is_tty then
            -- overwrite the line with a clean "done" message
            local label = string.format("[%s]", self.current_step)
            local pad   = string.rep(" ", math.max(0, 12 - #label))
            io.write("\r" .. label .. pad .. " 完成" .. string.rep(" ", self.term_width) .. "\n")
            io.flush()
        else
            io.write(string.format("[%s] 完成\n", self.current_step))
            io.flush()
        end

        self._last_logged_pct = nil
    end)
    if not ok then
        pcall(io.write, "[PROGRESS] complete_step error: " .. tostring(err) .. "\n")
    end
end

--- Finish all progress output (newline + cleanup).
function Progress:finish()
    local ok, err = pcall(function()
        if self.is_tty then
            pcall(io.write, "\n")
            pcall(io.flush)
        end
        self.current_step = nil
    end)
    if not ok then
        pcall(io.write, "[PROGRESS] finish error: " .. tostring(err) .. "\n")
    end
end

------------------------------------------------------------------------
-- Internal rendering / estimation
------------------------------------------------------------------------

--- Render the progress bar on the current terminal line.
-- @param pct     number  0-100
-- @param current number
-- @param total   number
-- @param speed   number  bytes per second
-- @param eta     number  seconds remaining (or nil)
function Progress:_render_bar(pct, current, total, speed, eta)
    local label = string.format("[%s]", self.current_step or "?")
    local pad   = string.rep(" ", math.max(0, 12 - #label))

    -- bar geometry: reserve space for label + pct + metadata
    -- [STEP]       [====>      ] 30% (1.5/5.1 MB) 速度: 2.3 MB/s  剩余: 00:23
    local prefix  = label .. pad
    local pct_str = string.format("%3d%%", pct)

    -- metadata parts
    local meta_parts = {}
    if total > 0 then
        table.insert(meta_parts, string.format("(%s/%s)", _format_bytes(current), _format_bytes(total)))
    end
    if speed and speed > 0 then
        table.insert(meta_parts, "速度: " .. _format_bytes(speed) .. "/s")
    end
    if eta and eta >= 0 then
        table.insert(meta_parts, "剩余: " .. _format_time(eta))
    end
    local meta_str = table.concat(meta_parts, " ")

    -- available width for the bar itself
    -- prefix(12) + space(1) + '[' + bar + ']' + space(1) + pct(4) + space(1) + meta
    local overhead = #prefix + 1 + 1 + 1 + 1 + 4 + 1 + #meta_str + 2 -- brackets + spaces
    local bar_width = math.max(10, self.term_width - overhead)

    local filled = math.floor(bar_width * pct / 100)
    local empty  = bar_width - filled

    local bar
    if filled > 0 and empty > 0 then
        bar = string.rep("=", filled - 1) .. ">" .. string.rep(" ", empty)
    elseif filled > 0 then
        bar = string.rep("=", filled)
    else
        bar = string.rep(" ", bar_width)
    end

    local line = string.format("\r%s [%s] %s %s", prefix, bar, pct_str, meta_str)
    -- pad to term width to clear leftover chars
    if #line - 1 < self.term_width then  -- -1 for leading \r
        line = line .. string.rep(" ", self.term_width - (#line - 1))
    end

    io.write(line)
    io.flush()
end

--- Estimate remaining seconds based on elapsed time and overall progress ratio.
-- Uses cross-step ratio: completed_steps + current_step_partial / total_steps.
-- @return number|nil  seconds, or nil if cannot estimate
function Progress:_estimate_eta()
    local total_steps = #self.steps
    if total_steps == 0 or not self._step_start then
        return nil
    end

    -- count fully completed steps
    local done_count = 0
    for _, name in ipairs(self.steps) do
        if self.step_done[name] then
            done_count = done_count + 1
        end
    end

    -- add partial progress of current step
    local partial = 0
    if self._step_total > 0 then
        partial = self._step_current / self._step_total
    end

    local progress_ratio = (done_count + partial) / total_steps
    if progress_ratio <= 0 or progress_ratio >= 1 then
        return nil
    end

    local elapsed = os.time() - self._step_start
    -- add time already spent on completed steps (approximate: elapsed so far covers current ratio)
    -- Simple model: total_estimated = elapsed / progress_ratio
    local total_estimated = elapsed / progress_ratio
    local eta = total_estimated * (1 - progress_ratio)

    return math.max(0, math.floor(eta))
end

------------------------------------------------------------------------
-- Expose internal helpers on the module for testing / external use
------------------------------------------------------------------------
M._format_bytes = _format_bytes
M._format_time  = _format_time
M._is_tty       = _is_tty

return M
