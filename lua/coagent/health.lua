local M = {}

function M.check()
  local h = vim.health
  h.start('coagent.nvim')

  if vim.fn.has('nvim-0.11') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.11+ is required')
  end

  if pcall(require, 'plenary.async') then
    h.ok('plenary.nvim found')
  else
    h.error('plenary.nvim not found (CopilotChat.nvim dependency)')
  end

  local Backend = require('coagent.backend.copilotchat')
  local ok, err = Backend.available()
  if ok then
    local v = '?'
    local path = vim.api.nvim_get_runtime_file('version.txt', true)
    for _, p in ipairs(path) do
      if p:find('CopilotChat', 1, true) then
        local f = io.open(p)
        if f then
          v = vim.trim(f:read('*a'))
          f:close()
        end
      end
    end
    h.ok('CopilotChat.nvim found (version ' .. v .. '); authentication and API access are delegated to it')
  else
    h.error(err)
  end

  for _, exe in ipairs({ 'git', 'rg' }) do
    if vim.fn.executable(exe) == 1 then
      h.ok(exe .. ' found')
    elseif exe == 'rg' then
      h.warn('ripgrep (rg) not found: search falls back to grep, glob to a slower directory scan')
    else
      h.warn(exe .. ' not found')
    end
  end

  local sb_mod = require('coagent.tools.sandbox')
  local sb = sb_mod.backend()
  if sb then
    h.ok('command sandbox available: ' .. sb)
  else
    h.warn('no command sandbox: ' .. sb_mod.unavailable_reason() .. '. Auto mode then runs allowlisted commands unconfined (supervised mode is unaffected).')
  end

  if pcall(vim.treesitter.language.add, 'markdown') then
    h.ok('treesitter markdown parser available')
  else
    h.info('treesitter markdown parser missing; using legacy markdown syntax')
  end
  if pcall(require, 'render-markdown') then
    h.info("render-markdown.nvim found: add 'coagent' to its file_types to render the panel")
  end

  local cfg = require('coagent.config').options
  h.info('mode: ' .. cfg.mode .. '; sessions: ' .. (cfg.session.persist and (cfg.session.dir or (vim.fn.stdpath('state') .. '/coagent/sessions')) or 'not persisted'))
end

return M
