-- Render the real Neovim screen of the demo as text (for docs and visual checks).
--   nvim -l scripts/screenshot.lua [cols] [rows] [icons]
-- Spawns `nvim --embed` with scripts/demo.lua, attaches as a UI over msgpack-rpc
-- (vim.mpack), rebuilds the grid from redraw events and prints snapshots.
local cols = tonumber(arg[1]) or 120
local rows = tonumber(arg[2]) or 36
local icons = arg[3] or 'unicode'

local stdin, stdout = vim.uv.new_pipe(), vim.uv.new_pipe()
local child = vim.uv.spawn('nvim', {
  args = { '--embed', '--clean', '-n', '-u', 'scripts/demo.lua' },
  stdio = { stdin, stdout, nil },
  env = { 'DEMO_ICONS=' .. icons, 'HOME=' .. vim.env.HOME, 'PATH=' .. vim.env.PATH, 'TMPDIR=' .. (vim.env.TMPDIR or '/tmp') },
}, function() end)
assert(child, 'failed to spawn nvim')

local grid = {}
local responses = {}
local msgid = 0
local unpacker = vim.mpack.Unpacker()

local function reset_grid(w, h)
  grid = {}
  for r = 0, h - 1 do
    grid[r] = {}
    for c = 0, w - 1 do
      grid[r][c] = ' '
    end
  end
end
reset_grid(cols, rows)

local handlers = {
  grid_resize = function(_, w, h)
    reset_grid(w, h)
  end,
  grid_clear = function()
    reset_grid(cols, rows)
  end,
  grid_line = function(_, row, col, cells)
    local last
    for _, cell in ipairs(cells) do
      local text = cell[1]
      local rep = cell[3] or 1
      for _ = 1, rep do
        if grid[row] then
          grid[row][col] = text
        end
        col = col + 1
      end
      last = text
    end
    return last
  end,
  grid_scroll = function(_, top, bot, left, right, nrows)
    if nrows > 0 then
      for r = top, bot - nrows - 1 do
        for c = left, right - 1 do
          grid[r][c] = grid[r + nrows][c]
        end
      end
    else
      for r = bot - 1, top - nrows, -1 do
        for c = left, right - 1 do
          grid[r][c] = grid[r + nrows][c]
        end
      end
    end
  end,
}

stdout:read_start(function(_, data)
  if not data then
    return
  end
  local pos = 1
  while pos <= #data do
    local msg
    msg, pos = unpacker(data, pos)
    if msg == nil then
      break
    end
    if msg[1] == 1 then
      responses[msg[2]] = { err = msg[3], result = msg[4] }
    elseif msg[1] == 2 and msg[2] == 'redraw' then
      for _, batch in ipairs(msg[3]) do
        local h = handlers[batch[1]]
        if h then
          for i = 2, #batch do
            h(unpack(batch[i]))
          end
        end
      end
    end
  end
end)

local function request(method, ...)
  msgid = msgid + 1
  local id = msgid
  stdin:write(vim.mpack.encode({ 0, id, method, { ... } }))
  vim.wait(10000, function()
    return responses[id] ~= nil
  end, 5)
  local r = responses[id]
  if r and r.err ~= vim.NIL and r.err ~= nil then
    error(vim.inspect(r.err))
  end
  return r and r.result
end

local function lua(code)
  return request('nvim_exec_lua', code, {})
end

local function snapshot(title)
  vim.wait(150)
  local out = { string.format('── %s (%dx%d) %s', title, cols, rows, string.rep('─', math.max(0, cols - #title - 16))) }
  for r = 0, rows - 1 do
    local line = {}
    for c = 0, cols - 1 do
      table.insert(line, grid[r][c] or ' ')
    end
    table.insert(out, (table.concat(line):gsub('%s+$', '')))
  end
  io.write(table.concat(out, '\n') .. '\n\n')
end

local function wait_state(states, timeout)
  local ok = vim.wait(timeout or 8000, function()
    local s = lua('return Demo.state()')
    return vim.tbl_contains(states, s)
  end, 50)
  return ok
end

request('nvim_ui_attach', cols, rows, { ext_linegrid = true, rgb = true })
vim.wait(600)
snapshot('startup')
lua("Demo.submit('Fix the failing add() test')")
for i = 1, 6 do
  if not wait_state({ 'WAITING_APPROVAL', 'COMPLETED', 'FAILED', 'CANCELLED' }) then
    break
  end
  local s = lua('return Demo.state()')
  if s ~= 'WAITING_APPROVAL' then
    break
  end
  snapshot('approval ' .. i)
  lua('Demo.approve()')
  vim.wait(300)
end
wait_state({ 'COMPLETED', 'FAILED', 'CANCELLED' })
snapshot('completed')
pcall(request, 'nvim_command', 'qa!')
child:kill('sigterm')
