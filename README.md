# marimo.nvim

A thin Neovim plugin for working with [marimo](https://marimo.io) notebooks — real,
plain `.py` files where cells are `@app.cell`-decorated functions, not JSON, not
comment markers.

This plugin used to be a much larger, fully custom notebook system: a hand-built
`.ipynb` JSON↔text transform, a custom aiohttp+Jupyter kernel execution server with
its own browser page, and a shadow-buffer LSP proxy to get pyright working around a
custom filetype. All of that is gone. Because marimo notebooks are genuinely valid
Python, pyright attaches to them **natively**, through whatever LSP config you
already have — zero plugin code involved. And because `marimo edit --watch` already
provides a mature kernel, reactive execution, and a polished browser UI, there's
nothing left to build there either. What remains is small on purpose.

## What it does

- **`<leader>nr`** — launches `marimo edit --watch` for the current file and opens
  the browser (or, over SSH, prints the URL to open on your laptop).
- **`<leader>na`** — inserts a new `@app.cell`. If the buffer isn't a marimo
  notebook yet (no `app = marimo.App()`), bootstraps the full file structure first —
  this is exactly how you'd start a brand-new notebook from an empty `.py` file.
- **Nothing else.** No custom filetype, no buffer transform, no shadow buffer, no
  execution server. Both keymaps are bound in `ftplugin/python.lua`, active on any
  `.py` file — there's no "is this actually a marimo notebook" detection, since
  pressing `<leader>nr` on a plain/empty `.py` file is exactly how you'd start one.

## Real LSP, for free

pyright already attaches to marimo `.py` files through your existing global LSP
config (`filetype = "python"`, same as any other Python file) — full diagnostics,
hover, go-to-definition, rename, references, autotrigger completion, all of it,
with nothing this plugin does or needs to do. Import resolution for whatever your
notebook imports (marimo itself, pandas, plotly, ...) is standard pyright/Python
project configuration — e.g. a `.venv` in the notebook's own directory, which
pyright auto-detects — not something this plugin manages.

## Prerequisites (one-time)

**If you already use your own project venv** (`uv`, `poetry`, plain `venv` — doesn't
matter which): just `pip install marimo` (or `uv add marimo`) into it. As long as
that venv is activated in the shell Neovim was started from, `require("marimo-nvim")`
finds `marimo` on `$PATH` automatically — no config needed. (Verified: it resolves
whatever `marimo` is first on `$PATH` before falling back to the dedicated venv
below, so an already-active project environment always wins.)

**Otherwise**, set up a dedicated venv just for this plugin:
```bash
sudo apt install python3-pip python3-venv
python3 -m venv ~/.local/share/nvim/marimo-nvim/venv
~/.local/share/nvim/marimo-nvim/venv/bin/pip install marimo
```
Add any library your notebooks actually `import` (pandas, plotly, matplotlib, ...)
to whichever of these two venvs is actually in use, or to a separate project-local
one if you want pyright to resolve those imports too (see above). You can also force
a specific interpreter regardless of `$PATH`: `require("marimo-nvim").setup({
marimo_bin = "/path/to/venv/bin/marimo" })`.

**For saving to actually re-run affected cells** (rather than just marking them
stale until you click "run" in marimo's own UI), add to the notebook project's
`pyproject.toml`:
```toml
[tool.marimo.runtime]
watcher_on_save = "autorun"
```

## Using this over SSH / a remote instance

Off by default — the port marimo picks (it self-selects starting at `2718`,
auto-incrementing if that's taken) changes based on what else is running, which is
awkward to tunnel reliably. If you code on a remote box over `ssh` and want the
browser on your laptop, pin a fixed port:

```lua
require("marimo-nvim").setup({ port = 8765 })
```

marimo still only ever binds `127.0.0.1` — fixed port or not, it's never reachable
except through an SSH tunnel. Add a persistent forward to `~/.ssh/config`:
```
Host your-remote
  HostName <ip-or-dns>
  User <user>
  LocalForward 8765 127.0.0.1:8765
```
Neovim detects the SSH session (`$SSH_CONNECTION`/`$SSH_TTY`) and prints the URL to
open locally instead of trying to launch a browser on the headless remote box.

## Migrating existing `.ipynb` notebooks

```bash
marimo convert notebook.ipynb -o notebook.py
```
Note the execution model is genuinely different, not just the file format: marimo
builds a dependency graph from which cells define/read which variables and executes
in that order, not top-to-bottom by position. The same variable can't be defined in
two cells, and mutations must happen in the cell that defines the variable. Code
written for Jupyter's manual/out-of-order execution may need real refactoring, not
just a format conversion, to work correctly under marimo. Converting back the other
way: `marimo export ipynb notebook.py -o notebook.ipynb --include-outputs`.

## Known limitations

- No cell-boundary decorations/visuals in Neovim (no border bars, no cell numbers)
  — marimo's own browser UI already provides polished cell visuals; duplicating
  that in the terminal wasn't judged worth it for what's left to build here.
- `--port 0` doesn't give a true OS-assigned ephemeral port (verified: marimo just
  starts from its own default `2718` and increments on conflict) — in practice this
  behaves fine for "don't worry about collisions," just with predictable rather than
  random ports.
- A hard `kill -9` of Neovim can orphan the marimo process (normal `:qa`/closing the
  buffer cleans up correctly, verified across multiple cycles). Recovery:
  `pkill -f "marimo edit"`.

## File layout

```
lua/marimo-nvim/init.lua   -- launch/cleanup lifecycle, new-cell helper
ftplugin/python.lua        -- keymaps, active on any .py file
```
