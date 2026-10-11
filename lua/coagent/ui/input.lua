--- Prompt input buffer (separate from the timeline).
local ns = vim.api.nvim_create_namespace('coagent_input')

---@class Coagent.Input
local Input = {}
Input.__index = Input

---@param config table
---@param on_submit fun(text:string)
function Input.new(config, on_submit)
  local self = setmetatable({ config = config, on_submit = on_submit, history = {}, hist_pos = nil }, Input)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.buf, 'coagent://input/' .. self.buf)
  local bo = vim.bo[self.buf]
  bo.buftype = 'nofile'
  bo.bufhidden = 'hide'
  bo.swapfile = false
  bo.filetype = 'coagent-input'
  pcall(vim.treesitter.language.register, 'markdown', 'coagent-input')
  pcall(vim.treesitter.start, self.buf, 'markdown')
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufEnter' }, {
    buffer = self.buf,
    callback = function()
      self:placeholder()
    end,
  })
  local slash = require('coagent.ui.slash')
  bo.omnifunc = "v:lua.require'coagent.ui.slash'.omnifunc"
  if config.ui.slash_complete ~= false or config.ui.mention_complete ~= false then
    -- show the menu without inserting the first candidate while typing; fuzzy
    -- keeps @path matches fuzzy while the menu narrows (Neovim 0.11+)
    if not pcall(function()
      bo.completeopt = 'menuone,noinsert,fuzzy'
    end) then
      pcall(function()
        bo.completeopt = 'menuone,noinsert'
      end)
    end
    vim.api.nvim_create_autocmd('TextChangedI', {
      buffer = self.buf,
      callback = function()
        -- complete() cannot run inside the autocommand itself
        vim.schedule(slash.autocomplete)
      end,
    })
  end
  self:placeholder()
  return self
end

function Input:valid()
  return self.buf and vim.api.nvim_buf_is_valid(self.buf)
end

function Input:text()
  if not self:valid() then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), '\n')
end

function Input:set_text(text)
  if not self:valid() then
    return
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, vim.split(text or '', '\n', { plain = true }))
  self:placeholder()
end

function Input:append(text)
  local cur = vim.trim(self:text())
  self:set_text(cur == '' and text or (cur .. ' ' .. text))
end

function Input:placeholder()
  if not self:valid() then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  if self:text() == '' then
    local k = self.config.keymaps.input.submit
    local ic = require('coagent.ui.icons').get(self.config.ui.icons)
    local hint = string.format('Ask the agent%s (%s send %s @file #buffer #selection %s /help)', ic.ellipsis, type(k) == 'table' and (k.n or k.i) or k, ic.dot, ic.dot)
    if self.busy_hint then
      hint = self.busy_hint
    end
    vim.api.nvim_buf_set_extmark(self.buf, ns, 0, 0, { virt_text = { { hint, 'CoagentPlaceholder' } }, virt_text_pos = 'overlay' })
  end
end

function Input:set_busy_hint(text)
  self.busy_hint = text
  self:placeholder()
end

function Input:submit()
  local text = vim.trim(self:text())
  if text == '' then
    return
  end
  -- Keep the text when the agent refuses it (e.g. busy) so nothing is lost.
  local ok, opts = self.on_submit(text)
  if ok == false then
    return
  end
  if not (opts and opts.history == false) then
    table.insert(self.history, text)
  end
  self.hist_pos = nil
  self:set_text('')
end

function Input:history_move(delta)
  if #self.history == 0 then
    return
  end
  local pos = self.hist_pos or (#self.history + 1)
  pos = math.max(1, math.min(#self.history + 1, pos + delta))
  self.hist_pos = pos
  self:set_text(self.history[pos] or '')
end

function Input:destroy()
  if self:valid() then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.buf = nil
end

return Input
