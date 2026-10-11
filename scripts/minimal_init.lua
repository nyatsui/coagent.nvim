-- Init file used for every spec process spawned by plenary's test harness.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. '/.dependencies/plenary.nvim')
vim.opt.runtimepath:append(root .. '/.dependencies/CopilotChat.nvim')
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.o.columns = 160
vim.o.lines = 48

local state = vim.fn.tempname()
vim.fn.mkdir(state, 'p')
vim.env.XDG_STATE_HOME = state
vim.env.XDG_DATA_HOME = state

vim.cmd('runtime plugin/plenary.vim')
vim.cmd('runtime plugin/coagent.lua')
