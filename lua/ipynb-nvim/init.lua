-- Renders a .ipynb (Jupyter notebook, plain JSON on disk) as an editable
-- text buffer: one "# %% 💻" marker per code cell, "# %% 📝" per markdown
-- cell, source code/text in between. Converts back to JSON on save. Cell
-- outputs, execution counts and per-cell metadata are not shown in the
-- buffer, but are preserved on write for any cell whose position and type
-- didn't change since the last read/write.
local M = {}

-- bufnr -> last-known full notebook JSON (Lua table). Needed on write to
-- recover the metadata/outputs we deliberately don't render.
local notebooks = {}

local HEADER_PATTERN = "^# %%"
local CODE_EMOJI = "💻"
local MARKDOWN_EMOJI = "📝"
local BAR_CHAR = "─"

local ns = vim.api.nvim_create_namespace("ipynb_nvim_decorations")

local function is_header(line)
  return line:match(HEADER_PATTERN) ~= nil
end

local function header_is_markdown(line)
  return line:find(MARKDOWN_EMOJI, 1, true) ~= nil
end

local function cell_header_text(cell_type)
  if cell_type == "markdown" then
    return "# %% " .. MARKDOWN_EMOJI
  end
  return "# %% " .. CODE_EMOJI
end

local function set_highlights()
  -- `nocombine = true` stops this highlight from blending with whatever
  -- Tree-sitter drew underneath it (its @comment.python, which is italic,
  -- since "# %% ..." is a valid Python comment) — plain `italic = false`
  -- isn't reliable here, since Neovim can't always distinguish "explicitly
  -- off" from "never set" once two highlights at different priorities
  -- are composited.
  local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
  vim.api.nvim_set_hl(0, "IpynbCellHeader", vim.tbl_extend("force", title, { italic = false, nocombine = true }))

  local nontext = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
  vim.api.nvim_set_hl(0, "IpynbCellBorder", vim.tbl_extend("force", nontext, { italic = false, nocombine = true }))
end

local function bar_virt_lines(width)
  return { { { BAR_CHAR:rep(math.max(width, 1)), "IpynbCellBorder" } } }
end

-- Draws a border bar above and below every cell, and de-italicizes the
-- header line. Purely visual: extmarks, so none of this touches the
-- actual buffer text or what gets written back to the notebook.
local function render_decorations(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then
    return
  end

  local ok, width = pcall(vim.api.nvim_win_get_width, 0)
  if not ok or width <= 0 then
    width = 80
  end

  local header_rows = {} -- 0-indexed
  for i, line in ipairs(lines) do
    if is_header(line) then
      table.insert(header_rows, i - 1)
    end
  end

  for k, row in ipairs(header_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      virt_lines = bar_virt_lines(width),
      virt_lines_above = true,
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_row = row + 1,
      hl_group = "IpynbCellHeader",
      hl_eol = true,
      priority = 200,
    })

    local next_row = header_rows[k + 1]
    local end_row = next_row and (next_row - 1) or (#lines - 1)
    if end_row >= row then
      vim.api.nvim_buf_set_extmark(bufnr, ns, end_row, 0, {
        virt_lines = bar_virt_lines(width),
      })
    end
  end
end

-- nbformat stores `source` as a list of strings, one per source line, each
-- keeping its own trailing "\n" except the cell's last line.
local function source_to_text_lines(source)
  local text = type(source) == "table" and table.concat(source, "") or (source or "")
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true, trimempty = false })
end

local function text_lines_to_source(lines)
  -- Trailing blank lines are just spacing before the next cell's header
  -- in the buffer, not meaningful content, so they're dropped here.
  local trimmed = vim.deepcopy(lines)
  while #trimmed > 0 and trimmed[#trimmed] == "" do
    table.remove(trimmed)
  end
  local source = {}
  for i, line in ipairs(trimmed) do
    source[i] = (i < #trimmed) and (line .. "\n") or line
  end
  return source
end

local function read_notebook(bufnr, path)
  local ok, raw_lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("ipynb-nvim: could not read " .. path .. ": " .. tostring(raw_lines), vim.log.levels.ERROR)
    return
  end

  local ok2, notebook = pcall(vim.json.decode, table.concat(raw_lines, "\n"))
  if not ok2 or type(notebook) ~= "table" then
    vim.notify("ipynb-nvim: " .. path .. " is not valid notebook JSON", vim.log.levels.ERROR)
    return
  end

  local display_lines = {}
  for _, cell in ipairs(notebook.cells or {}) do
    table.insert(display_lines, cell_header_text(cell.cell_type))
    for _, l in ipairs(source_to_text_lines(cell.source)) do
      table.insert(display_lines, l)
    end
    table.insert(display_lines, "")
  end
  if display_lines[#display_lines] == "" then
    table.remove(display_lines)
  end
  if #display_lines == 0 then
    display_lines = { cell_header_text("code"), "" }
  end

  notebooks[bufnr] = notebook

  vim.bo[bufnr].buftype = ""
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
  vim.bo[bufnr].filetype = "ipynb"
  vim.bo[bufnr].modified = false
  render_decorations(bufnr)
end

local function parse_buffer_cells(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local current = nil
  for _, line in ipairs(lines) do
    if is_header(line) then
      if current then
        table.insert(blocks, current)
      end
      current = { cell_type = header_is_markdown(line) and "markdown" or "code", lines = {} }
    elseif current then
      table.insert(current.lines, line)
    end
  end
  if current then
    table.insert(blocks, current)
  end
  return blocks
end

local function write_notebook(bufnr, path)
  local notebook = notebooks[bufnr]
  if not notebook then
    vim.notify("ipynb-nvim: no notebook state for this buffer, refusing to write", vim.log.levels.ERROR)
    return
  end

  local blocks = parse_buffer_cells(bufnr)
  local old_cells = notebook.cells or {}
  local new_cells = {}

  for i, block in ipairs(blocks) do
    local old = old_cells[i]
    local cell
    -- Reuse the old cell's metadata/outputs/execution_count only if a cell
    -- of the same type still occupies the same position. Anything else
    -- (a newly added cell, or one whose type changed) starts fresh.
    if old and old.cell_type == block.cell_type then
      cell = vim.deepcopy(old)
    elseif block.cell_type == "markdown" then
      cell = { cell_type = "markdown", metadata = vim.empty_dict(), source = {} }
    else
      cell = { cell_type = "code", metadata = vim.empty_dict(), execution_count = vim.NIL, outputs = {}, source = {} }
    end
    cell.source = text_lines_to_source(block.lines)
    table.insert(new_cells, cell)
  end

  notebook.cells = new_cells
  notebooks[bufnr] = notebook

  local ok, encoded = pcall(vim.json.encode, notebook)
  if not ok then
    vim.notify("ipynb-nvim: failed to encode notebook: " .. tostring(encoded), vim.log.levels.ERROR)
    return
  end

  local ok2, err = pcall(vim.fn.writefile, { encoded }, path)
  if not ok2 then
    vim.notify("ipynb-nvim: failed to write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.bo[bufnr].modified = false
end

-- Returns the 1-indexed line of the current cell's header, and the line
-- of the next cell's header (or line-count + 1 if this is the last cell).
local function current_cell_bounds(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local header_idx = nil
  for i = cursor_line, 1, -1 do
    if is_header(lines[i]) then
      header_idx = i
      break
    end
  end
  if not header_idx then
    return nil
  end

  local next_header_idx = #lines + 1
  for i = header_idx + 1, #lines do
    if is_header(lines[i]) then
      next_header_idx = i
      break
    end
  end
  return header_idx, next_header_idx
end

function M.new_cell(cell_type)
  local bufnr = vim.api.nvim_get_current_buf()
  local _, insert_before = current_cell_bounds(bufnr)
  insert_before = insert_before or (vim.api.nvim_buf_line_count(bufnr) + 1)

  local new_lines = { cell_header_text(cell_type or "code"), "", "" }
  vim.api.nvim_buf_set_lines(bufnr, insert_before - 1, insert_before - 1, false, new_lines)
  vim.api.nvim_win_set_cursor(0, { insert_before, 0 })
  render_decorations(bufnr)
end

function M.delete_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local header_idx, next_header_idx = current_cell_bounds(bufnr)
  if not header_idx then
    vim.notify("ipynb-nvim: cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, header_idx - 1, next_header_idx - 1, false, {})
  render_decorations(bufnr)
end

function M.toggle_cell_type()
  local bufnr = vim.api.nvim_get_current_buf()
  local header_idx = current_cell_bounds(bufnr)
  if not header_idx then
    vim.notify("ipynb-nvim: cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  local header_line = vim.api.nvim_buf_get_lines(bufnr, header_idx - 1, header_idx, false)[1]
  local new_type = header_is_markdown(header_line) and "code" or "markdown"
  vim.api.nvim_buf_set_lines(bufnr, header_idx - 1, header_idx, false, { cell_header_text(new_type) })
  render_decorations(bufnr)
end

-- Exposed so ftplugin/ipynb.lua can re-run decorations on manual edits
-- (typing, dd-ing a header line, etc.) that don't go through the commands above.
M.render_decorations = render_decorations

-- Exposed so sibling plugins (e.g. ipynb-run-nvim) can find cell boundaries
-- without duplicating this parsing logic.
M.is_header = is_header
M.current_cell_bounds = current_cell_bounds

function M.setup()
  set_highlights()
  local group = vim.api.nvim_create_augroup("ipynb_nvim", { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.ipynb",
    callback = function(args)
      read_notebook(args.buf, args.file)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "*.ipynb",
    callback = function(args)
      write_notebook(args.buf, args.file)
    end,
  })

  -- Colorscheme changes wipe highlight definitions, so re-link ours.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = set_highlights,
  })

  vim.api.nvim_create_user_command("IpynbNewCodeCell", function()
    M.new_cell("code")
  end, {})
  vim.api.nvim_create_user_command("IpynbNewMarkdownCell", function()
    M.new_cell("markdown")
  end, {})
  vim.api.nvim_create_user_command("IpynbDeleteCell", M.delete_cell, {})
  vim.api.nvim_create_user_command("IpynbToggleCellType", M.toggle_cell_type, {})
end

return M
