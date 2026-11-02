# critic.nvim

I love the concept of using LLMs to teach myself, but they often end up
fixing most errors on their own. Therefore taking inspiration from Zed's
Ask mode alongside 99 by Primeage I have created this. (Still very much in infancy)

It works as an LLM that can only interact via diagnostics, this allows direct
instructions for the user while also restriciting the LLM. I want it to be such that
it can provide the user learning input while also not just going about making changes itself.

If required the user can just run their own harness for deeper or faster work. This is more slow.

## Roadmap

Currently Features:

- [x] Criticise Selection
- [x] Criticise Git Diff
- [x] Criticise Diagnostics
- [x] Guiding Question to Criticism

Planned Features:

- [ ] Implement better context control
- [ ] Keystrokes
- [ ] Maybe direct access with no harness (pi in my case), it's too much of a hassle for a plugin this small tho.
- [ ] Criticise Whole File
- [ ] Criticise Project ? (Seems large tho)
- [ ] Create a larger dialog system, so that it can create prompts which can be used as a doctor type referral to a more dedicated LLM/Harness


## Requirements

- Neovim 0.10+
- A backend CLI that reads a prompt on stdin and prints a JSON array of
  comments on stdout. [pi](https://github.com/badlogic/pi-mono) works great:

  ```sh
  pi --print --no-tools --no-session --model <provider/model>
  ```

## Install

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/Sammybro11/critic.nvim" })
require("critic").setup({
  backends = {
    glm  = { cmd = { "pi", "--print", "--no-tools", "--no-session", "--model", "hyper/glm-5.3-flash" } },
  },
})
```

The first backend is the default. The `cmd` contract: prompt in on stdin,
JSON out on stdout. Any CLI that does this works (claude, ollama, ...).

## Commands

| Command | Reviews |
|---|---|
| `:Critic [question]` | Visual selection, or the function under the cursor |
| `:CriticGit [question]` | Uncommitted changes (`git diff -U3`) |
| `:CriticDiag [question]` | Every LSP diagnostic, with surrounding context |
| `:CriticClear` | Remove all critic comments from the buffer |
| `:CriticToggle` | Disable/enable critic for this buffer |
| `:CriticBackend` | Switch backend (uses `vim.ui.select`) |

Examples:

```vim
:'<,'>Critic is this idiomatic?
:CriticGit focus on error handling
:CriticDiag how do I fix these?
```

A selection is expanded with treesitter, so the model also sees the
enclosing function and class — not just the lines you marked.

## Options

```lua
require("critic").setup({
  backend = nil,        -- defaults to the first key of `backends`
  backends = {},        -- name -> { cmd = { ... } }
  timeout_ms = 60000,   -- kill reviews taking longer than this
  max_lines = 2000,     -- skip huge buffers
  diagnostics = {       -- passed to vim.diagnostic.config() for the critic
    virtual_text = { prefix = "◆" },  -- namespace; set virtual_text = false
    underline = false,                -- if you use global virtual_lines
    severity_sort = true,
  },
})
```

## Contributing

I would appreciate help from people interested in helping this become a
human centric knowledge enchancer while programming. Thank you :)
