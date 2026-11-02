if vim.g.loaded_critic then
  return
end
vim.g.loaded_critic = true

vim.api.nvim_create_user_command("Critic", function(cmd)
  -- no range given: review the enclosing construct at the cursor line
  require("critic").run(0, { range = { cmd.line1 - 1, cmd.line2 - 1 }, question = cmd.args })
end, { range = true, nargs = "*" })

vim.api.nvim_create_user_command("CriticGit", function(cmd)
  require("critic").run(0, { question = cmd.args })
end, { nargs = "*" })

vim.api.nvim_create_user_command("CriticDiag", function(cmd)
  require("critic").run(0, { mode = "diag", question = cmd.args })
end, { nargs = "*" })

vim.api.nvim_create_user_command("CriticToggle", function()
  require("critic").toggle()
end, {})

vim.api.nvim_create_user_command("CriticClear", function()
  require("critic").clear()
end, {})

vim.api.nvim_create_user_command("CriticBackend", function()
  require("critic").pick_backend()
end, {})
