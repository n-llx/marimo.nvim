# ipynb.nvim

A from-scratch Neovim plugin for editing and running Jupyter (`.ipynb`) notebooks,
built to be fully understood rather than assembled from existing tools like
`jupytext`. Two parts, one repo:

- **`ipynb-nvim`** — renders `.ipynb` files as editable plain text, with real syntax
  highlighting and a beautiful cell layout.
- **`ipynb-run-nvim`** — runs cells against a real Python kernel and shows the results
  (text, errors, images, interactive Plotly charts, anything) in a browser tab.

`ipynb-run-nvim` depends on `ipynb-nvim`'s cell-parsing functions, which is why they
live in one repo rather than two.

## ipynb-nvim: editing

`.ipynb` files are JSON. This plugin intercepts opening/saving them (`BufReadCmd`/
`BufWriteCmd`) and transforms them into a plain-text view: one `# %% 💻` marker per
code cell, `# %% 📝` per markdown cell, with the cell's raw source underneath. Saving
reverses the transform back to notebook JSON.

- **Real syntax highlighting**: the buffer's filetype is a custom `ipynb` (not
  `python`), so no LSP ever attaches and complains about markdown prose — but since
  `# %%` markers are valid Python comments, Tree-sitter is pointed at the Python
  parser for this filetype, giving code cells real highlighting for free. Markdown
  cell prose stays plain, unstyled text — no rendering, just editable text.
- **A cell actually looks like a cell**: a border bar above and below each one (drawn
  as extmarks, doesn't touch buffer text), and non-italic, bold headers (`❗`-style
  Tree-sitter comment styling is deliberately overridden with `nocombine`).
- **Fidelity on save**: cell `outputs`/`execution_count`/`metadata` you don't see in
  the buffer are preserved on write, for any cell whose position and type haven't
  changed since the last read/write — editing a cell's code leaves its last output in
  place, exactly like real Jupyter does until you re-run it.
- **Commands/keymaps**: `<leader>na` new code cell, `<leader>nA` new markdown cell,
  `<leader>nd` delete current cell, `<leader>nm` toggle code ↔ markdown.

**Known limitation**: cell identity is tracked by position, not a stable id —
inserting/deleting a cell shifts everything after it, so cells after that point lose
their preserved outputs on that save.

## ipynb-run-nvim: execution

- **`<leader>nr`** runs the cell under the cursor; **`<leader>nR`** runs every cell,
  top to bottom.
- **A real kernel**: each open notebook gets one persistent `ipykernel` process (the
  same kernel implementation Jupyter itself uses, launched via `jupyter_client`), so
  variables set in one cell are usable in a later one — genuine process state, not
  simulated.
- **The browser is an execution log, not a live mirror**: every run appends a new,
  permanent entry ("Cell N — run #M", its code, its output) to the top of the page —
  running the same cell again adds another entry, it never replaces the last one.
  Nothing is pushed to the browser as you type, only actual runs.
- **Renders "every" output type** via the real mimetype IPython's formatter registry
  produces (`text/html`, `image/png`, `image/svg+xml`, `text/plain`) — not a hardcoded
  list of special cases. `matplotlib` works out of the box (`%matplotlib inline` runs
  silently on kernel startup). Plotly figures (`fig.show()` or a bare trailing `fig`)
  render as real interactive charts — the server reconstructs a `Figure` from
  Plotly's own renderer-negotiation output and converts it to HTML itself, so ordinary
  Plotly code works unmodified.
- **Visible cell numbers in Neovim**: `[Cell N]` virtual text on every header line, so
  you know what number a cell will be tagged with in the browser.
- **Auto-opens the browser** once per buffer per Neovim session (WSL2 via
  `cmd.exe /c start`, `xdg-open` elsewhere) — or, over SSH, prints connection
  instructions instead (see below).
- **Cleans up after itself**: closing the notebook buffer or quitting Neovim kills
  that notebook's server and kernel — no orphaned processes.

### How it works

```
Neovim (ipynb-run-nvim)  --curl POST-->  Python server (aiohttp + jupyter_client/ipykernel)
                                                  |
                                                  +--WebSocket-->  Browser tab
```

Neovim computes which cell you're on (its 1-based position among all `# %%` headers)
and its text, then fires a non-blocking `curl POST /run`. The server submits that code
to the kernel, tracks which execution log entry it belongs to via the kernel's
`msg_id`, and as real Jupyter protocol messages arrive on the kernel's iopub channel,
forwards them to every connected browser tab over WebSocket. The browser page is a
small, dependency-free HTML/JS file — HTML output (including Plotly's embedded
`<script>` tags) renders inside a sandboxed `<iframe sandbox="allow-scripts"
srcdoc="...">`, since a plain `innerHTML` assignment wouldn't execute injected scripts.

### Prerequisites (one-time)

```bash
sudo apt install python3-pip python3-venv
python3 -m venv ~/.local/share/nvim/ipynb-run-nvim/venv
~/.local/share/nvim/ipynb-run-nvim/venv/bin/pip install -r server/requirements.txt
```

If installing `ipykernel` tries to compile `pyzmq` from source (can happen on very new
Python versions without prebuilt wheels yet), use an older interpreter for this venv
instead of fighting the compiler toolchain:

```bash
sudo apt install python3.12 python3.12-venv
python3.12 -m venv ~/.local/share/nvim/ipynb-run-nvim/venv
# then re-run the pip install line above
```

Any library your notebook cells `import` (pandas, plotly, matplotlib, ...) needs to be
installed into this same venv. If the venv is missing, Neovim will `vim.notify` you
with these exact commands rather than silently failing.

### Using this over SSH / a remote instance

Off by default. The server binds a random port every time by default, which is fine
locally but awkward to tunnel. If you code on a remote box over `ssh` and want the
browser on your local laptop:

1. On the remote machine, pass a fixed port in your lazy.nvim config:
   ```lua
   require("ipynb-run-nvim").setup({ port = 8765 })
   ```
   The server still only ever binds `127.0.0.1` — fixed port or not, it's never
   reachable except through an SSH tunnel.
2. On your laptop, add a persistent forward to `~/.ssh/config`:
   ```
   Host your-remote
     HostName <ip-or-dns>
     User <user>
     LocalForward 8765 127.0.0.1:8765
   ```
3. Connect and run a cell. Neovim detects the SSH session (`$SSH_CONNECTION`/
   `$SSH_TTY`) and, instead of trying to launch a browser on the remote box, notifies
   you the URL to open locally: `http://127.0.0.1:8765/`.

## Installation

Both plugins are wired into Neovim via a single `dir`-based lazy.nvim spec:

```lua
return {
  dir = "/path/to/ipynb.nvim", -- or use lazy.nvim's normal `"n-llx/ipynb.nvim"` form
  name = "ipynb.nvim",
  lazy = false, -- must load before any .ipynb file is opened
  config = function()
    require("ipynb-nvim").setup()
    require("ipynb-run-nvim").setup({ port = 0 }) -- 0 = random port (default)
  end,
}
```

## Message protocol (ipynb-run-nvim)

**Neovim → server (HTTP POST):**
```json
POST /run  { "cellId": 3, "code": "..." }
GET  /health -> 200 "ok"
```

**Server → browser (WebSocket), tagged by `runId` (per-execution, not per-cell):**
```json
{ "type": "full_state", "runs": [ { "runId": 1, "cellId": 3, "code": "...", "outputs": [...] }, ... ] }
{ "type": "run_started", "runId": 4, "cellId": 3, "code": "..." }
{ "type": "output", "runId": 4, "kind": "stream", "stream": "stdout", "text": "..." }
{ "type": "output", "runId": 4, "kind": "result", "mimetype": "text/html", "data": "..." }
{ "type": "output", "runId": 4, "kind": "error", "ename": "...", "evalue": "...", "traceback": "..." }
{ "type": "run_finished", "runId": 4 }
```

## Known limitations

- Cell numbers/identity are positional, recomputed from header order — inserting or
  deleting a cell shifts everything after it.
- One kernel per notebook, no interrupt/restart keymap yet — a hung cell currently
  means closing and reopening the buffer.
- A hard `kill -9` of Neovim can orphan the kernel process (normal `:qa`/closing the
  buffer cleans up correctly). Recovery: `pkill -f ipykernel_launcher`.
- No LSP support inside `.ipynb` buffers, deliberately — markdown cells being raw,
  unprefixed text would make a real Python LSP see the whole buffer as full of syntax
  errors, and IPython magics (`%matplotlib inline`, `!pip install x`) aren't valid
  Python syntax either.

## File layout

```
lua/ipynb-nvim/init.lua          -- BufReadCmd/BufWriteCmd, cell editing commands, decorations
lua/ipynb-run-nvim/init.lua      -- server lifecycle, cell-id computation, run commands
ftplugin/ipynb.lua               -- keymaps + live decoration/cell-number updates, per-buffer
server/
├── app.py                       -- aiohttp server: kernel manager, HTTP+WS, output routing
├── requirements.txt             -- jupyter_client, ipykernel, aiohttp, plotly, nbformat
└── static/index.html            -- the browser page
```
