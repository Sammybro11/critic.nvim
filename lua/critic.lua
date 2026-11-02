local M = {}

local ns = vim.api.nvim_create_namespace("critic")
local jobs = {}
local last_hash = {}
local spinners = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Animated spinner via mini.notify's update API; falls back to plain
--- start/finish toasts. ponytail: only mini.notify gets animation; other
--- notifiers need their own update APIs (nvim-notify: opts.replace).
local function spinner_start(buf, text)
  local ok, mini = pcall(require, "mini.notify")
  if not ok then
    vim.notify(text, vim.log.levels.INFO)
    return
  end
  local id = mini.add(spinner_frames[1] .. " " .. text, "INFO", "Comment")
  local timer = vim.uv.new_timer()
  local i = 1
  timer:start(80, 80, vim.schedule_wrap(function()
    if not jobs[buf] then
        timer:close()
        --- Clear spinner buffer also ?
      return
    end
    i = i % #spinner_frames + 1
    pcall(mini.update, id, { msg = spinner_frames[i] .. " " .. text })
  end))
  spinners[buf] = { id = id, timer = timer, mini = mini }
end

local function spinner_stop(buf, final)
  local s = spinners[buf]
  if not s then
    if final then
      vim.notify(final, vim.log.levels.INFO)
    end
    return
  end
  spinners[buf] = nil
  s.timer:stop()
  s.timer:close()
  if final then
    pcall(s.mini.update, s.id, { msg = final, hl_group = "Normal" })
    vim.defer_fn(function()
      pcall(s.mini.remove, s.id)
    end, 3000)
  else
    pcall(s.mini.remove, s.id)
  end
end

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

local function numbered(buf, s, e)
  local lines = vim.api.nvim_buf_get_lines(buf, s, e + 1, false)
  for i, line in ipairs(lines) do
    lines[i] = string.format("%d: %s", s + i, line)
  end
  return table.concat(lines, "\n")
end

local function is_construct(node_type)
  for _, kw in ipairs({ "function", "method", "class", "struct", "impl", "module" }) do
    if node_type:find(kw, 1, true) then
      return true
    end
  end
  return false
end

--- Build treesitter context for a selection: the smallest node covering it,
--- plus every enclosing function/method/class construct, outermost first.
--- ponytail: enclosing constructs only, not callees; true call-graph context
--- needs per-language locals queries. Fallback: numbered selection lines.
local function ts_context(buf, s, e, label)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  parser:parse(true)
  local indent = #(vim.api.nvim_buf_get_lines(buf, s, s + 1, false)[1] or ""):match("^%s*")
  local node = vim.treesitter.get_node({ bufnr = buf, pos = { s, indent } })
  if not node then
    return nil
  end
  while node:parent() do
    local sr, _, er = node:range()
    if sr <= s and er >= e then
      break
    end
    node = node:parent()
  end
  local chunks = {}
  local total = 0
  local n = node
  while n do
    if is_construct(n:type()) then
      local sr, _, er = n:range()
      local chunk = string.format("Enclosing %s (lines %d-%d):\n%s", n:type(), sr + 1, er + 1, numbered(buf, sr, er))
      total = total + #chunk
      table.insert(chunks, 1, chunk)
    end
    n = n:parent()
  end
  chunks[#chunks + 1] = string.format("%s (%d-%d):\n%s", label or "Selected lines", s + 1, e + 1, numbered(buf, s, e))
  if total > 30000 then
    return nil
  end
  return table.concat(chunks, "\n\n")
end

local function git_diff(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    return nil
  end
  local obj = vim.system({ "git", "diff", "-U3", "--", file }, { text = true }):wait(3000)
  if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
    return nil
  end
  -- ponytail: hard cap instead of smart hunk selection; upgrade path is
  -- keeping only hunks that intersect changed lines.
  -- Suggestion: Maybe separate at hunk boundary or use smart hunk
  return obj.stdout:sub(1, 30000)
end

local function other_diagnostics(buf)
  local diags = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.namespace ~= ns then
      diags[#diags + 1] = string.format(
        "line %d [%s] %s: %s",
        d.lnum + 1,
        vim.diagnostic.severity[d.severity],
        d.source or "?",
        d.message:gsub("\n", " ")
      )
    end
  end
  return diags
end

--- Treesitter context around every non-critic diagnostic line, deduplicated.
local function diag_context(buf)
  local chunks, seen = {}, {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.namespace ~= ns then
      local ctx = ts_context(buf, d.lnum, d.lnum, string.format("Diagnostic at line %d", d.lnum + 1))
        or string.format("Diagnostic at line %d:\n%s", d.lnum + 1, numbered(buf, d.lnum, d.lnum))
      if not seen[ctx] then
        seen[ctx] = true
        chunks[#chunks + 1] = ctx
      end
    end
  end
  if #chunks == 0 then
    return nil
  end
  return table.concat(chunks, "\n\n")
end

local function collect(buf, opts)
  opts = opts or {}
  local subject, text
  if opts.mode == "diag" then
    subject = "the existing diagnostics and their surrounding code"
    text = diag_context(buf)
    if not text then
      return nil, "no diagnostics in buffer"
    end
  elseif opts.range then
    local s, e = opts.range[1], opts.range[2]
    subject = string.format("the selected lines %d-%d", s + 1, e + 1)
    text = ts_context(buf, s, e) or string.format("Selected lines (%d-%d):\n%s", s + 1, e + 1, numbered(buf, s, e))
  else
    subject = "the changes below"
    text = git_diff(buf)
    if not text then
      local last = math.min(vim.api.nvim_buf_line_count(buf), 400) - 1
      text = "(no git diff; first buffer lines follow)\n" .. numbered(buf, 0, last)
    end
  end
  local diags = other_diagnostics(buf)
  local question = ""
  if opts.question and opts.question ~= "" then
    question = string.format('\n\nThe user asks: "%s". Address this in your comments.', opts.question)
  end
  return string.format(
    "You are a read-only code reviewer. Review %s of this %s file.\n"
      .. 'Return ONLY a JSON array: [{"line": <1-based buffer line>, "severity": "hint"|"warn", "comment": "<short actionable note>"}].\n'
      .. "Line numbers refer to the numbered lines in the input. Return [] if nothing is worth noting. No prose, no markdown fences.\n\n"
      .. "File: %s\n\nExisting diagnostics:\n%s\n\n%s%s",
    subject,
    vim.bo[buf].filetype,
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."),
    #diags > 0 and table.concat(diags, "\n") or "(none)",
    text,
    question
  )
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
  local prompt, err = collect(buf, opts)
  if not prompt then
    vim.notify("critic: " .. err, vim.log.levels.INFO)
    return
  end
  local hash = vim.fn.sha256(prompt)
  if hash == last_hash[buf] then
    return
  end
  if jobs[buf] then
    jobs[buf]:kill(9)
    spinner_stop(buf)
  end
  spinner_start(buf, "critic: reviewing (" .. cfg.backend .. ")…")
  jobs[buf] = vim.system(backend.cmd, { stdin = prompt, text = true, timeout = cfg.timeout_ms }, function(obj)
    jobs[buf] = nil
    if obj.code ~= 0 then
      vim.schedule(function()
        spinner_stop(buf)
        if obj.signal == 0 then
          vim.notify("critic: " .. (obj.stderr or "failed"):sub(1, 200), vim.log.levels.WARN)
        end
      end)
      return
    end
    local diags = parse(obj.stdout or "")
    if not diags then
      vim.schedule(function()
        spinner_stop(buf)
      end)
      return
    end
    last_hash[buf] = hash
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        vim.diagnostic.set(ns, buf, diags)
        spinner_stop(buf, string.format("critic: %d comment%s", #diags, #diags == 1 and "" or "s"))
      end
    end)
  end)
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
