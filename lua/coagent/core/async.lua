--- Thin helpers over plenary.async (already a dependency of CopilotChat.nvim,
--- whose client must be called from inside a plenary coroutine).
local async = require('plenary.async')

local M = {}

M.run = async.run
M.wrap = async.wrap

--- Make sure we are on the main loop (not in a fast libuv callback) before
--- touching Neovim APIs.
M.main = async.wrap(function(cb)
  if vim.in_fast_event() then
    vim.schedule(cb)
  else
    cb()
  end
end, 1)

--- Yield to the event loop for `ms` milliseconds.
M.sleep = async.wrap(function(ms, cb)
  vim.defer_fn(cb, ms)
end, 2)

--- A one-shot "future": `wait()` suspends the current coroutine until
--- `resolve(value)` is called from anywhere (UI keymap, timer, ...).
---@return {wait: fun():any, resolve: fun(value:any), resolved: fun():boolean}
function M.future()
  local done, value, waiter = false, nil, nil
  local f = {}
  f.resolve = function(v)
    if done then
      return
    end
    done, value = true, v
    if waiter then
      local w = waiter
      waiter = nil
      w(v)
    end
  end
  f.resolved = function()
    return done
  end
  f.wait = async.wrap(function(cb)
    if done then
      cb(value)
    else
      waiter = cb
    end
  end, 1)
  return f
end

return M
