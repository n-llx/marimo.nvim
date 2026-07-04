-- Auto-sourced by Neovim whenever a buffer's filetype is set to "ipynb"
-- (see :h ftplugin). "# %%" markers are plain Python comments, so pointing
-- the Python parser at this filetype gives code cells real syntax
-- highlighting for free, while markdown cell prose (not valid Python)
-- stays plain, unstyled text.
vim.treesitter.start(0, "python")
vim.bo.commentstring = "# %s"

local ipynb = require("ipynb-nvim")
local run = require("ipynb-run-nvim")
local bufnr = vim.api.nvim_get_current_buf()
local opts = { buffer = true }

-- Cell editing (ipynb-nvim)
vim.keymap.set("n", "<leader>na", function() ipynb.new_cell("code") end, opts)
vim.keymap.set("n", "<leader>nA", function() ipynb.new_cell("markdown") end, opts)
vim.keymap.set("n", "<leader>nd", function() ipynb.delete_cell() end, opts)
vim.keymap.set("n", "<leader>nm", function() ipynb.toggle_cell_type() end, opts)

-- Cell execution (ipynb-run-nvim)
vim.keymap.set("n", "<leader>nr", run.run_cell, { buffer = true, desc = "Run current cell (browser output)" })
vim.keymap.set("n", "<leader>nR", run.run_all_cells, { buffer = true, desc = "Run all cells (browser output)" })

-- Keep border bars/header styling and cell-number labels in sync with manual
-- edits (typing, dd-ing a header line, etc.) that don't go through the
-- commands above.
run.render_cell_numbers(bufnr)
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
  buffer = bufnr,
  callback = function()
    ipynb.render_decorations(bufnr)
    run.render_cell_numbers(bufnr)
  end,
})
