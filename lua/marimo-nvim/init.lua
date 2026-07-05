-- Launches marimo (https://marimo.io) for the current .py file. marimo owns
-- the kernel, reactive execution, and browser UI entirely — this plugin's
-- only job is: spawn/track the process, extract its URL, open it (or print
-- it over SSH), clean up on exit, and offer a snippet for a new @app.cell.
--
-- marimo notebooks are plain, real Python files (cells are @app.cell-
-- decorated functions), so pyright already attaches via the existing global
-- LSP config (lua/config/lsp.lua) with zero extra code — nothing here is
-- LSP-related at all.
local M = {}

-- bufnr -> { handle, url }
M.servers = {}

local opened_buffers = {}

local config = {
  -- 0 (default): marimo self-selects, starting at its own default (2718)
  -- and auto-incrementing if that's taken — verified empirically, this
  -- already behaves like "don't worry about collisions" without needing a
  -- true OS-assigned ephemeral port. Set a fixed port for SSH tunneling to
  -- a remote instance (see README).
  port = 0,
  -- nil (default): resolved automatically, see marimo_bin() below. Set this
  -- explicitly only if you want to override both the $PATH lookup and the
  -- dedicated-venv fallback.
  marimo_bin = nil,
}

local function is_ssh_session()
  return vim.env.SSH_CONNECTION ~= nil or vim.env.SSH_TTY ~= nil
end

local function is_wsl()
  local ok, f = pcall(io.open, "/proc/version", "r")
  if not ok or not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  return content:lower():find("microsoft") ~= nil
end

local function dedicated_venv_bin(name)
  return vim.fn.stdpath("data") .. "/marimo-nvim/venv/bin/" .. name
end

-- Resolution order: (1) an explicit require("marimo-nvim").setup({ marimo_bin
-- = "..." }) override, (2) whatever "marimo" is already first on $PATH —
-- this is what makes an already-activated project venv (uv, poetry, plain
-- venv, doesn't matter) just work with zero config, since Neovim inherits
-- the PATH of the shell it was started from, (3) the dedicated venv this
-- plugin creates for people without their own project environment.
local function marimo_bin()
  if config.marimo_bin then
    return config.marimo_bin
  end
  local on_path = vim.fn.exepath("marimo")
  if on_path ~= "" then
    return on_path
  end
  return dedicated_venv_bin("marimo")
end

local function notify_missing_marimo()
  vim.notify(
    "marimo-nvim: marimo not found on $PATH or in the dedicated venv.\n"
      .. "If you have your own project venv (uv/poetry/plain venv), activate it\n"
      .. "before starting Neovim and `pip install marimo` (or `uv add marimo`) into it —\n"
      .. "no config needed, it'll be found on $PATH automatically.\n"
      .. "Otherwise, set up a dedicated one:\n"
      .. "  sudo apt install python3-pip python3-venv\n"
      .. "  python3 -m venv " .. vim.fn.stdpath("data") .. "/marimo-nvim/venv\n"
      .. "  " .. dedicated_venv_bin("pip") .. " install marimo",
    vim.log.levels.ERROR
  )
end

local function open_browser(bufnr, url)
  if opened_buffers[bufnr] then
    return
  end
  opened_buffers[bufnr] = true

  -- Over SSH there's no local GUI browser to launch on this machine.
  if is_ssh_session() then
    local lines = { "marimo-nvim: notebook server running (on this machine)." }
    if config.port == 0 then
      table.insert(
        lines,
        "Port may change next session — set a fixed one via require('marimo-nvim').setup({ port = <N> })."
      )
    end
    table.insert(lines, "From your laptop, forward the port over SSH, then open: " .. url)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end

  if is_wsl() then
    vim.system({ "/mnt/c/Windows/System32/cmd.exe", "/c", "start", url }, { detach = true })
  elseif vim.fn.executable("xdg-open") == 1 then
    vim.system({ "xdg-open", url }, { detach = true })
  else
    vim.notify("marimo-nvim: open " .. url .. " in your browser", vim.log.levels.INFO)
  end
end

function M.launch()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.servers[bufnr] then
    vim.notify("marimo-nvim: already running for this buffer", vim.log.levels.INFO)
    return
  end

  local marimo = marimo_bin()
  if vim.fn.filereadable(marimo) == 0 then
    notify_missing_marimo()
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    vim.notify("marimo-nvim: save this buffer to a .py file first", vim.log.levels.WARN)
    return
  end

  local entry = {}
  M.servers[bufnr] = entry

  local buf = ""
  entry.handle = vim.system({
    marimo,
    "edit",
    "--watch",
    "--headless",
    "--host",
    "127.0.0.1",
    "--port",
    tostring(config.port),
    "--no-token", -- matches this project's stance: 127.0.0.1-only binding is
    -- the security boundary, not a per-session auth token
    path,
  }, {
    detach = true,
    stdout = function(_, data)
      if not data or entry.url then
        return
      end
      buf = buf .. data
      local url = buf:match("URL:%s*(http://[%w%.%-]+:%d+)")
      if url then
        entry.url = url
        vim.schedule(function()
          open_browser(bufnr, url)
        end)
      end
    end,
  }, function()
    M.servers[bufnr] = nil
  end)
end

-- Inserts a new @app.cell. If the buffer isn't already a marimo notebook
-- (no `app = marimo.App()` yet — e.g. a brand-new empty .py file), bootstraps
-- the full file structure first: this is exactly how you'd start a fresh
-- marimo notebook from nothing, matching the plugin's approach of not trying
-- to detect "is this file a marimo notebook" ahead of time.
function M.new_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")

  if not text:find("app%s*=%s*marimo%.App%(%)") then
    local skeleton = {
      "import marimo",
      "",
      "app = marimo.App()",
      "",
      "",
      "@app.cell",
      "def _():",
      "    return",
      "",
      "",
      'if __name__ == "__main__":',
      "    app.run()",
    }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, skeleton)
    vim.api.nvim_win_set_cursor(0, { 8, 4 })
    return
  end

  -- Insert a new cell right before the `if __name__ == "__main__":` footer,
  -- which is always the last thing in a marimo file.
  local footer_line = nil
  for i, line in ipairs(lines) do
    if line:match('^if __name__ == ["\']__main__["\']:') then
      footer_line = i
      break
    end
  end
  local insert_at = footer_line and (footer_line - 1) or #lines
  local new_cell = { "@app.cell", "def _():", "    return", "" }
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, new_cell)
  vim.api.nvim_win_set_cursor(0, { insert_at + 3, 4 })
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})

  local group = vim.api.nvim_create_augroup("marimo_nvim", { clear = true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.py",
    callback = function(args)
      local entry = M.servers[args.buf]
      if entry and entry.handle then
        pcall(function()
          entry.handle:kill(15)
        end)
      end
      M.servers[args.buf] = nil
      opened_buffers[args.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, entry in pairs(M.servers) do
        if entry.handle then
          pcall(function()
            entry.handle:kill(15)
          end)
        end
      end
    end,
  })
end

return M
