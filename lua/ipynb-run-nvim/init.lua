-- Talks to a per-buffer local server (server/app.py: aiohttp + a real ipykernel)
-- over plain HTTP. Neovim never renders output itself — it just tells the server
-- "run cell N with this code", and a browser tab connected to that same server
-- appends a new, permanent log entry (code + output) for that run. The browser
-- is a queue/history of what's actually been run, not a live mirror of the
-- buffer — re-running a cell adds a new entry, it doesn't replace the old one.
local M = {}

-- bufnr -> { port, handle, pending = {callbacks} | nil }
M.servers = {}

local opened_buffers = {}

local CELL_NUMBER_NS = vim.api.nvim_create_namespace("ipynb_run_nvim_cell_numbers")

-- port = 0 (default): OS-assigned ephemeral port, a fresh one every time —
-- structurally can't collide with anything, but inconvenient to tunnel over
-- SSH since it changes every session. Set a fixed port via
-- require("ipynb-run-nvim").setup({ port = N }) to make SSH port-forwarding
-- to a remote instance practical (see README's remote-usage section).
local config = {
  port = 0,
}

local function is_ssh_session()
  return vim.env.SSH_CONNECTION ~= nil or vim.env.SSH_TTY ~= nil
end

-- Derived from this very file's own path (not hardcoded), so this plugin
-- works no matter where it's actually installed — a local `dir` checkout,
-- lazy.nvim's own clone under stdpath("data")/lazy, anywhere.
local function plugin_root()
  local this_file = debug.getinfo(1, "S").source:sub(2) -- strip leading "@"
  return vim.fn.fnamemodify(this_file, ":h:h:h")
end

local function venv_python()
  return vim.fn.stdpath("data") .. "/ipynb-run-nvim/venv/bin/python"
end

local function server_script()
  return plugin_root() .. "/server/app.py"
end

local function notify_missing_venv()
  vim.notify(
    "ipynb-run-nvim: Python venv not found. Run this once in a terminal:\n"
      .. "  sudo apt install python3-pip python3-venv\n"
      .. "  python3 -m venv " .. vim.fn.stdpath("data") .. "/ipynb-run-nvim/venv\n"
      .. "  " .. venv_python() .. " -m pip install -r " .. plugin_root() .. "/server/requirements.txt",
    vim.log.levels.ERROR
  )
end

-- Returns (cellId, code) for the cell under the cursor, or nil if the cursor
-- isn't inside a cell. cellId is the 1-based position of this cell's header
-- among all headers in the buffer (recomputed every call, not stored).
local function cell_info(bufnr)
  local ipynb = require("ipynb-nvim")
  local header_idx, next_header_idx = ipynb.current_cell_bounds(bufnr)
  if not header_idx then
    return nil
  end

  local preceding = vim.api.nvim_buf_get_lines(bufnr, 0, header_idx - 1, false)
  local id = 1
  for _, line in ipairs(preceding) do
    if ipynb.is_header(line) then
      id = id + 1
    end
  end

  local body = vim.api.nvim_buf_get_lines(bufnr, header_idx, next_header_idx - 1, false)
  while #body > 0 and body[#body] == "" do
    table.remove(body)
  end

  return id, table.concat(body, "\n")
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

local function maybe_open_browser(bufnr, port)
  if opened_buffers[bufnr] then
    return
  end
  opened_buffers[bufnr] = true
  local url = "http://127.0.0.1:" .. port .. "/"

  -- Over SSH there's no local GUI browser to launch on this machine — trying
  -- xdg-open here would just fail silently. Tell the user what to do instead.
  if is_ssh_session() then
    local lines = {
      "ipynb-run-nvim: notebook server running on port " .. port .. " (on this machine).",
    }
    if config.port == 0 then
      table.insert(
        lines,
        "This is a random port that changes every session. For a persistent SSH tunnel,"
      )
      table.insert(lines, "set a fixed one: require('ipynb-run-nvim').setup({ port = <N> }).")
    end
    table.insert(lines, "From your laptop, forward this port over SSH, then open " .. url)
    table.insert(lines, "(see README.md: 'Using this over SSH / a remote instance').")
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end

  if is_wsl() then
    vim.system({ "/mnt/c/Windows/System32/cmd.exe", "/c", "start", url }, { detach = true })
  elseif vim.fn.executable("xdg-open") == 1 then
    vim.system({ "xdg-open", url }, { detach = true })
  else
    vim.notify("ipynb-run-nvim: open " .. url .. " in your browser", vim.log.levels.INFO)
  end
end

local function post_json(port, path, tbl, cb)
  local body = vim.json.encode(tbl)
  vim.system({
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "--data-binary",
    body,
    "http://127.0.0.1:" .. port .. path,
  }, { text = true }, function(res)
    if cb then
      vim.schedule(function()
        cb(res)
      end)
    end
  end)
end

-- Ensures a server is running for this buffer, then calls on_ready(port).
-- Multiple concurrent calls before the server is up all get queued and
-- fired once, rather than spawning duplicate servers.
local function spawn_server(bufnr, on_ready)
  local existing = M.servers[bufnr]
  if existing and existing.port then
    on_ready(existing.port)
    return
  end
  if existing and existing.pending then
    table.insert(existing.pending, on_ready)
    return
  end

  local python = venv_python()
  if vim.fn.filereadable(python) == 0 then
    notify_missing_venv()
    return
  end

  local notebook_path = vim.api.nvim_buf_get_name(bufnr)
  local entry = { pending = { on_ready } }
  M.servers[bufnr] = entry

  local buf = ""
  entry.handle = vim.system({
    python,
    server_script(),
    "--notebook-path",
    notebook_path,
    "--port",
    tostring(config.port),
  }, {
    detach = true,
    stdout = function(_, data)
      if not data or entry.port then
        return
      end
      buf = buf .. data
      local nl = buf:find("\n")
      if not nl then
        return
      end
      local line = buf:sub(1, nl - 1)
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and decoded.port then
        entry.port = decoded.port
        local pending = entry.pending
        entry.pending = nil
        vim.schedule(function()
          for _, cb in ipairs(pending) do
            cb(entry.port)
          end
        end)
      end
    end,
  }, function()
    M.servers[bufnr] = nil
  end)
end

-- Shows "[Cell N]" as virtual text at the end of every "# %% ..." header
-- line, purely visual (an extmark, doesn't touch buffer text). Recomputed
-- from scratch each call, since ids are just header position, not stored.
function M.render_cell_numbers(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, CELL_NUMBER_NS, 0, -1)
  local ipynb = require("ipynb-nvim")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local id = 0
  for i, line in ipairs(lines) do
    if ipynb.is_header(line) then
      id = id + 1
      vim.api.nvim_buf_set_extmark(bufnr, CELL_NUMBER_NS, i - 1, 0, {
        virt_text = { { " [Cell " .. id .. "]", "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end

function M.run_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local id, code = cell_info(bufnr)
  if not id then
    vim.notify("ipynb-run-nvim: cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  spawn_server(bufnr, function(port)
    post_json(port, "/run", { cellId = id, code = code })
    maybe_open_browser(bufnr, port)
  end)
end

function M.run_all_cells()
  local bufnr = vim.api.nvim_get_current_buf()
  local ipynb = require("ipynb-nvim")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local headers = {}
  for i, line in ipairs(lines) do
    if ipynb.is_header(line) then
      table.insert(headers, i)
    end
  end
  if #headers == 0 then
    vim.notify("ipynb-run-nvim: no cells found", vim.log.levels.WARN)
    return
  end

  spawn_server(bufnr, function(port)
    for idx, header_line in ipairs(headers) do
      local next_header_line = headers[idx + 1] or (#lines + 1)
      local body = vim.api.nvim_buf_get_lines(bufnr, header_line, next_header_line - 1, false)
      while #body > 0 and body[#body] == "" do
        table.remove(body)
      end
      post_json(port, "/run", { cellId = idx, code = table.concat(body, "\n") })
    end
    maybe_open_browser(bufnr, port)
  end)
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})

  local group = vim.api.nvim_create_augroup("ipynb_run_nvim", { clear = true })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.ipynb",
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
