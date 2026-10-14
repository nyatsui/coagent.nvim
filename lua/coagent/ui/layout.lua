--- Window layout for the agent panel + input: right split (default) or float.
---
--- The split width follows what you set by hand: resizing the panel (mouse,
--- <C-w><, <C-w>>, :vertical resize, :CoagentWidth, `<` / `>` in the panel)
--- is remembered as a fraction of the terminal width, kept when the panel is
--- reopened or the terminal is resized, and saved across restarts
--- (`ui.remember_size`). The input height is remembered the same way.
local M = {}

---@class Coagent.LayoutSize
---@field width_ratio number? panel width / columns, set by the user
---@field input_height integer? input window height, set by the user
M.size = nil

local function size_file()
  return vim.fn.stdpath('state') .. '/coagent/ui_size.json'
end

---@param cfg table ui config
---@return Coagent.LayoutSize
function M.load_size(cfg)
  if M.size then
    return M.size
  end
  M.size = {}
  if cfg.remember_size ~= false then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(size_file()), '\n'))
    end)
    if ok and type(data) == 'table' then
      M.size.width_ratio = tonumber(data.width_ratio)
      M.size.input_height = tonumber(data.input_height)
    end
  end
  return M.size
end

local function save_size(cfg)
  if cfg.remember_size == false or not M.size then
    return
  end
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(size_file(), ':h'), 'p', tonumber('700', 8))
    vim.fn.writefile({ vim.json.encode({ width_ratio = M.size.width_ratio, input_height = M.size.input_height }) }, size_file())
  end)
end

--- Columns left for the editor next to the panel.
local function min_editor(cfg)
  return cfg.min_editor_width or 30
end

local function clamp_width(cfg, w)
  local cols = vim.o.columns
  w = math.max(cfg.min_width, w)
  if cfg.max_width then
    w = math.min(cfg.max_width <= 1 and math.floor(cols * cfg.max_width) or cfg.max_width, w)
  end
  return math.min(w, math.max(cfg.min_width, cols - min_editor(cfg)))
end

local function set_opts(win, extra)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.spell = false
  wo.list = false
  wo.cursorline = false
  wo.wrap = true
  wo.linebreak = true
  wo.breakindent = true
  wo.statuscolumn = ''
  wo.fillchars = 'eob: '
  wo.foldenable = false
  for k, v in pairs(extra or {}) do
    wo[k] = v
  end
end

---@param cfg table ui config
---@return integer
function M.panel_width(cfg)
  local cols = vim.o.columns
  local size = M.load_size(cfg)
  local w
  if size.width_ratio then
    w = math.floor(cols * size.width_ratio + 0.5)
  else
    w = cfg.width <= 1 and math.floor(cols * cfg.width) or cfg.width
  end
  return clamp_width(cfg, w)
end

---@param cfg table ui config
---@return integer
function M.input_height(cfg)
  local size = M.load_size(cfg)
  local h = size.input_height or math.min(cfg.input_height, math.max(1, math.floor(vim.o.lines / 5)))
  return math.max(1, math.min(h, math.max(1, vim.o.lines - 8)))
end

--- Remember a size the user set by hand (WinResized). Ignores changes that
--- only reflect coagent's own resizing.
---@param cfg table ui config
---@param wins {panel:integer, input:integer, layout:string}?
---@param changed integer[] windows reported by WinResized
function M.record(cfg, wins, changed)
  if not (wins and wins.layout ~= 'float' and vim.api.nvim_win_is_valid(wins.panel)) or M.applying then
    return
  end
  local size = M.load_size(cfg)
  local dirty = false
  for _, w in ipairs(changed or {}) do
    if w == wins.panel then
      local width = vim.api.nvim_win_get_width(wins.panel)
      if width ~= M.panel_width(cfg) then
        size.width_ratio = width / vim.o.columns
        dirty = true
      end
    elseif w == wins.input and vim.api.nvim_win_is_valid(wins.input) then
      local h = vim.api.nvim_win_get_height(wins.input)
      if h ~= M.input_height(cfg) then
        size.input_height = h
        dirty = true
      end
    end
  end
  if dirty then
    save_size(cfg)
  end
end

--- Set the panel width: "60" (columns), "50%" (of the terminal), "+10" /
--- "-10" (relative), or "reset" (back to `ui.width`).
---@param cfg table ui config
---@param wins {panel:integer, input:integer, layout:string}?
---@param spec string
---@return boolean ok, string? err
function M.set_width(cfg, wins, spec)
  spec = vim.trim(tostring(spec or ''))
  local size = M.load_size(cfg)
  local cols = vim.o.columns
  local current = (wins and wins.layout ~= 'float' and vim.api.nvim_win_is_valid(wins.panel)) and vim.api.nvim_win_get_width(wins.panel) or M.panel_width(cfg)
  local target
  if spec == 'reset' then
    size.width_ratio = nil
    size.input_height = nil
    save_size(cfg)
    M.resize(cfg, wins)
    return true
  elseif spec:match('^%d+%%$') then
    target = math.floor(cols * tonumber(spec:sub(1, -2)) / 100 + 0.5)
  elseif spec:match('^[%+%-]%d+$') then
    target = current + tonumber(spec)
  elseif spec:match('^%d+$') then
    target = tonumber(spec)
  else
    return false, 'expected N (columns), N%, +N, -N or reset'
  end
  target = clamp_width(cfg, target)
  size.width_ratio = target / cols
  save_size(cfg)
  M.resize(cfg, wins)
  return true
end


--- Effective layout: tiny terminals fall back to a float.
---@param cfg table
---@param requested string
function M.effective(cfg, requested)
  if requested == 'vertical' and vim.o.columns < cfg.min_width + 30 then
    return 'float'
  end
  return requested
end

local function float_geometry(cfg)
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local fw, fh = cfg.float.width, cfg.float.height
  local W = math.max(30, math.min(cols - 2, fw <= 1 and math.floor(cols * fw) or fw))
  local H = math.max(10, math.min(lines - 2, fh <= 1 and math.floor(lines * fh) or fh))
  local input_h = math.min(cfg.input_height, math.max(1, math.floor(H / 4)))
  local row = math.max(0, math.floor((lines - H) / 2))
  local col = math.max(0, math.floor((cols - W) / 2))
  local border = cfg.float.border
  local bh = border == 'none' and 0 or 2
  local panel_h = math.max(3, H - input_h - 2 * bh)
  return {
    panel = { relative = 'editor', row = row, col = col, width = W - bh, height = panel_h, border = border, style = 'minimal', zindex = 45, title = ' Coagent ', title_pos = 'center' },
    input = { relative = 'editor', row = row + panel_h + bh, col = col, width = W - bh, height = input_h, border = border, style = 'minimal', zindex = 46 },
  }
end

---@param cfg table ui config
---@param layout string
---@param panel_buf integer
---@param input_buf integer
---@return {panel:integer, input:integer, layout:string}
function M.open(cfg, layout, panel_buf, input_buf)
  layout = M.effective(cfg, layout)
  local pw, iw
  if layout == 'float' then
    local g = float_geometry(cfg)
    pw = vim.api.nvim_open_win(panel_buf, false, g.panel)
    iw = vim.api.nvim_open_win(input_buf, false, g.input)
  else
    M.applying = true
    pw = vim.api.nvim_open_win(panel_buf, false, { split = 'right', win = -1, width = M.panel_width(cfg) })
    iw = vim.api.nvim_open_win(input_buf, false, { split = 'below', win = pw, height = M.input_height(cfg) })
    vim.schedule(function()
      M.applying = false
    end)
    vim.wo[pw].winfixwidth = true
    vim.wo[iw].winfixheight = true
    vim.wo[iw].winfixwidth = true
  end
  set_opts(pw)
  set_opts(iw)
  return { panel = pw, input = iw, layout = layout }
end

--- Re-fit windows after a terminal resize.
---@param cfg table
---@param wins {panel:integer, input:integer, layout:string}
function M.resize(cfg, wins)
  if not (wins and vim.api.nvim_win_is_valid(wins.panel)) then
    return
  end
  if wins.layout == 'float' then
    local g = float_geometry(cfg)
    pcall(vim.api.nvim_win_set_config, wins.panel, g.panel)
    if vim.api.nvim_win_is_valid(wins.input) then
      pcall(vim.api.nvim_win_set_config, wins.input, g.input)
    end
  else
    M.applying = true
    pcall(vim.api.nvim_win_set_width, wins.panel, M.panel_width(cfg))
    if vim.api.nvim_win_is_valid(wins.input) then
      pcall(vim.api.nvim_win_set_height, wins.input, M.input_height(cfg))
    end
    vim.schedule(function()
      M.applying = false
    end)
  end
end

return M
