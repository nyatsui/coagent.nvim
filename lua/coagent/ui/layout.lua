--- Window layout for the agent panel + input: right split (default) or float.
local M = {}

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
  local w = cfg.width <= 1 and math.floor(cols * cfg.width) or cfg.width
  w = math.max(cfg.min_width, math.min(cfg.max_width, w))
  -- always leave room for the editor
  return math.min(w, math.max(cfg.min_width, cols - 30))
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
    pw = vim.api.nvim_open_win(panel_buf, false, { split = 'right', win = -1, width = M.panel_width(cfg) })
    local input_h = math.min(cfg.input_height, math.max(1, math.floor(vim.o.lines / 5)))
    iw = vim.api.nvim_open_win(input_buf, false, { split = 'below', win = pw, height = input_h })
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
    pcall(vim.api.nvim_win_set_width, wins.panel, M.panel_width(cfg))
    if vim.api.nvim_win_is_valid(wins.input) then
      pcall(vim.api.nvim_win_set_height, wins.input, math.min(cfg.input_height, math.max(1, math.floor(vim.o.lines / 5))))
    end
  end
end

return M
