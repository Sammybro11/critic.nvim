local M = {}

local context = require("critic.context")
local spinner = require("critic.spinner")

local ns = vim.api.nvim_create_namespace("critic")
local jobs = {}
local last_hash = {}

M.defaults = {
  backend = nil,
  backends = {},
  timeout_ms = 60000,
  max_lines = 2000,
  -- passed to vim.diagnostic.config() for the critic namespace; set
  -- virtual_text = false here if you use global virtual_lines
  diagnostics = {
    virtual_text = { prefix = "◆" },
    underline = false,
    severity_sort = true,
  },
}

M.config = nil

local function get_config()
  if not M.config then
    M.config = vim.tbl_deep_extend("force", {}, M.defaults)
  end
  return M.config
end

local function eligible(buf)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if vim.api.nvim_buf_line_count(buf) > get_config().max_lines then
    return false
  end
  if vim.b[buf].critic_enabled == false then
    return false
  end
  return true
end

local function parse(out)
  out = out:gsub("^%s*```%w*\n?", ""):gsub("\n?```%s*$", "")
  local ok, items = pcall(vim.json.decode, out)
  if not ok or type(items) ~= "table" then
    return nil
  end
  local diags = {}
  for _, it in ipairs(items) do
    if type(it) == "table" and type(it.line) == "number" and type(it.comment) == "string" then
      diags[#diags + 1] = {
        lnum = math.max(it.line - 1, 0),
        col = 0,
        severity = it.severity == "warn" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.HINT,
        message = it.comment,
        source = "critic",
      }
    end
  end
  return diags
end

--- @param buf number|nil
--- @param opts table|nil { range = {s, e} (0-based, inclusive), mode = "diag", question = string }
function M.run(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  if not eligible(buf) then
    return
  end
  local cfg = get_config()
  local backend = cfg.backends[cfg.backend]
  if not backend then
    vim.notify("critic: no backend configured", vim.log.levels.WARN)
    return
  end
  local prompt, err = context.collect(buf, opts, ns)
  if not prompt then
    vim.notify("critic: " .. err, vim.log.levels.INFO)
    return
  end
  local hash = vim.fn.sha256(prompt)
  if hash == last_hash[buf] then
    return
  end
  if jobs[buf] then
    jobs[buf].job:kill(9)
    spinner.stop(jobs[buf].spinner)
  end
  local handle = spinner.start("critic: reviewing (" .. cfg.backend .. ")…")
  local job
  job = vim.system(backend.cmd, { stdin = prompt, text = true, timeout = cfg.timeout_ms }, function(obj)
    if jobs[buf] and jobs[buf].job == job then
      jobs[buf] = nil
    end
    vim.schedule(function()
      if obj.code ~= 0 then
        spinner.stop(handle)
        if obj.signal == 0 then
          vim.notify("critic: " .. (obj.stderr or "failed"):sub(1, 200), vim.log.levels.WARN)
        end
        return
      end
      local diags = parse(obj.stdout or "")
      if not diags then
        spinner.stop(handle)
        return
      end
      last_hash[buf] = hash
      if vim.api.nvim_buf_is_valid(buf) then
        vim.diagnostic.set(ns, buf, diags)
        spinner.stop(handle, string.format("critic: %d comment%s", #diags, #diags == 1 and "" or "s"))
      else
        spinner.stop(handle)
      end
    end)
  end)
  jobs[buf] = { job = job, spinner = handle }
end

function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].critic_enabled = vim.b[buf].critic_enabled == false
  vim.notify("critic: " .. (vim.b[buf].critic_enabled and "enabled" or "disabled"))
end

function M.clear()
  vim.diagnostic.reset(ns, vim.api.nvim_get_current_buf())
end

function M.pick_backend()
  local names = vim.tbl_keys(get_config().backends)
  table.sort(names)
  vim.ui.select(names, { prompt = "critic backend" }, function(choice)
    if choice then
      M.config.backend = choice
    end
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  if not M.config.backend then
    M.config.backend = vim.tbl_keys(M.config.backends)[1]
  end

  vim.diagnostic.config(M.config.diagnostics, ns)
end

return M
