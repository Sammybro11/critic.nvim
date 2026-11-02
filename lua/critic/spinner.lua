local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Animated spinner via mini.notify's update API; falls back to plain
--- start/finish toasts. ponytail: only mini.notify gets animation; other
--- notifiers need their own update APIs (nvim-notify: opts.replace).
local M = {}

--- @return table|nil handle for M.stop, nil on the toast fallback
function M.start(text)
  local ok, mini = pcall(require, "mini.notify")
  if not ok then
    vim.notify(text, vim.log.levels.INFO)
    return nil
  end
  local id = mini.add(frames[1] .. " " .. text, "INFO", "Comment")
  local timer = vim.uv.new_timer()
  local i = 1
  timer:start(80, 80, vim.schedule_wrap(function()
    i = i % #frames + 1
    pcall(mini.update, id, { msg = frames[i] .. " " .. text })
  end))
  return { id = id, timer = timer, mini = mini }
end

--- @param handle table|nil from M.start
--- @param final string|nil replacement message, auto-dismissed after 3s
function M.stop(handle, final)
  if not handle then
    if final then
      vim.notify(final, vim.log.levels.INFO)
    end
    return
  end
  handle.timer:stop()
  handle.timer:close()
  if final then
    pcall(handle.mini.update, handle.id, { msg = final, hl_group = "Normal" })
    vim.defer_fn(function()
      pcall(handle.mini.remove, handle.id)
    end, 3000)
  else
    pcall(handle.mini.remove, handle.id)
  end
end

return M
