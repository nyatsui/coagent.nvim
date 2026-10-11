-- Offline demo: try the UI without GitHub Copilot.
--   nvim --clean -u scripts/demo.lua
-- A scripted mock model fixes a bug in a throwaway workspace (search -> read ->
-- edit -> test fails -> fix -> test passes). Every edit/command asks for approval
-- (supervised mode) so you can try a / A / d / D / r / gd / <Tab> / gc.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. '/.dependencies/plenary.nvim')
vim.opt.runtimepath:append(root .. '/.dependencies/CopilotChat.nvim')
vim.opt.swapfile = false
vim.opt.termguicolors = vim.env.COLORTERM == 'truecolor' or vim.env.COLORTERM == '24bit'
vim.cmd('runtime plugin/plenary.vim')
vim.cmd('runtime plugin/coagent.lua')

local ws = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(ws .. '/tests', 'p')
local function write(p, s)
  local f = assert(io.open(ws .. '/' .. p, 'w'))
  f:write(s)
  f:close()
end
write('calc.py', 'def add(a, b):\n    """Return the sum of a and b."""\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n')
write('tests/test_calc.sh', [[
if grep -q 'return a + b' calc.py; then
  echo 'tests/test_calc.py::test_add PASSED'
  echo 'tests/test_calc.py::test_mul PASSED'
  echo '==== 7 passed in 0.03s ===='
else
  echo 'tests/test_calc.py::test_add FAILED'
  echo 'E   assert add(2, 3) == 5'
  echo 'E    +  where -1 = add(2, 3)'
  echo '==== 2 failed, 5 passed in 0.04s ===='
  exit 1
fi
]])
write('README.md', '# calc\n\nRun `sh tests/test_calc.sh`.\n')
vim.fn.system({ 'git', '-C', ws, 'init', '-q' })
vim.fn.system({ 'git', '-C', ws, '-c', 'user.email=demo@example.com', '-c', 'user.name=demo', 'add', '-A' })
vim.fn.system({ 'git', '-C', ws, '-c', 'user.email=demo@example.com', '-c', 'user.name=demo', 'commit', '-qm', 'init' })
vim.fn.chdir(ws)

local Mock = require('coagent.backend.mock')
local script = {
  { content = "I'll find the `add` implementation and its tests.", delay_ms = 25, chunks = 8, tool_calls = { { name = 'search', arguments = { pattern = 'def add' } }, { name = 'glob', arguments = { pattern = 'tests/**' } } } },
  { tool_calls = { { name = 'read_file', arguments = { path = 'calc.py' } } } },
  { content = '`add()` subtracts instead of adding. Let me run the tests first.', delay_ms = 25, tool_calls = { { name = 'run_command', arguments = { command = 'sh tests/test_calc.sh', purpose = 'reproduce' } } } },
  { content = 'The test confirms `add(2, 3)` returns `-1`. Fixing it.', delay_ms = 25, tool_calls = { { name = 'edit_file', arguments = { path = 'calc.py', old_string = '    return a - b', new_string = '    return a + b' } } } },
  { tool_calls = { { name = 'run_command', arguments = { command = 'sh tests/test_calc.sh' } } } },
  {
    content = table.concat({
      '## Summary',
      '',
      '- **Bug**: `add()` in `calc.py:3` returned `a - b`.',
      '- **Fix**: return `a + b`.',
      '',
      '| check | result |',
      '|---|---|',
      '| `sh tests/test_calc.sh` | 7 passed |',
      '',
      '```python',
      'def add(a, b):',
      '    return a + b',
      '```',
    }, '\n'),
    delay_ms = 20,
    chunks = 12,
  },
}
local backend = Mock.new(function(_, n)
  return script[n] or { content = 'Demo script finished. Start a new session with :CoagentNew.' }
end)

require('coagent').setup({
  backend = backend,
  session = { persist = false },
  ui = { icons = vim.env.DEMO_ICONS or 'unicode' },
  keymaps = { global = { toggle = '<leader>aa' } },
})
vim.cmd('edit calc.py')
require('coagent').open()

-- Hooks used by scripts/screenshot.lua
_G.Demo = {
  submit = function(text)
    require('coagent').view().input:set_text(text)
    require('coagent').view().input:submit()
  end,
  state = function()
    return require('coagent').controller():state()
  end,
  approve = function()
    require('coagent').approve()
  end,
}
