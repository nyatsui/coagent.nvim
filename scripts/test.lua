-- Headless test bootstrap.
-- Usage: nvim --headless --clean -u scripts/test.lua [-- <test dir or file>]
-- Dependencies are cloned into .dependencies/ on first run. Tests never talk to
-- GitHub Copilot: the LLM is replaced by a scripted mock backend.
local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'

local deps = {
  ['plenary.nvim'] = 'https://github.com/nvim-lua/plenary.nvim',
  ['CopilotChat.nvim'] = 'https://github.com/CopilotC-Nvim/CopilotChat.nvim',
}

for name, url in pairs(deps) do
  local path = root .. '/.dependencies/' .. name
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.system({ 'git', 'clone', '--depth=1', url, path })
  end
  vim.opt.runtimepath:append(path)
end

-- Keep all state written by tests inside a throwaway directory.
local state = vim.fn.tempname()
vim.fn.mkdir(state, 'p')
vim.env.XDG_STATE_HOME = state
vim.env.XDG_DATA_HOME = state

vim.cmd('runtime plugin/plenary.vim')

local target = vim.env.TEST_PATH or 'tests'
require('plenary.test_harness').test_directory(target, {
  minimal_init = root .. '/scripts/minimal_init.lua',
  sequential = true,
  timeout = 120000,
})
