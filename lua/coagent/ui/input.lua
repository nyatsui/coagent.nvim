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
    local hint = string.format('Ask the agent%s (%s send %s #buffer #selection #file:path)', ic.ellipsis, type(k) == 'table' and (k.n or k.i) or k, ic.dot)
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
  if self.on_submit(text) == false then
    return
  end
  table.insert(self.history, text)
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
