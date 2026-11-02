local M = {}

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
  -- keeping only hunks that intersect changed lines / splitting at hunk
  -- boundaries.
  return obj.stdout:sub(1, 30000)
end

local function other_diagnostics(buf, ns)
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
local function diag_context(buf, ns)
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

--- Build the review prompt. @param ns number critic namespace, excluded from diagnostics
--- @return string|nil prompt, string|nil err
function M.collect(buf, opts, ns)
  opts = opts or {}
  local subject, text
  if opts.mode == "diag" then
    subject = "the existing diagnostics and their surrounding code"
    text = diag_context(buf, ns)
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
  local diags = other_diagnostics(buf, ns)
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

return M
