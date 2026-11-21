--- Images attached to a user message (#image:path, #image = the clipboard,
--- @file.png, the input's paste_image key).
---
--- An attached image is copied into a store
---   <stdpath('state')>/coagent/images/<id>.<ext>   (images.dir)
--- and the message keeps only a small record {id, path, mime, label, bytes,
--- width, height, tokens}. The backend reads the file and sends it as a data
--- URL when the request is built (backend/copilotchat.lua), so sessions stay
--- small and the picture sent is the one the user attached, even if the
--- workspace file changes later.
local util = require('coagent.core.util')

local M = {}

M.EXT = { ['image/png'] = 'png', ['image/jpeg'] = 'jpg', ['image/gif'] = 'gif', ['image/webp'] = 'webp' }
local EXT_MIME = { png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg', gif = 'image/gif', webp = 'image/webp' }

--- Rough tokens for an image whose size is not known.
M.UNKNOWN_TOKENS = 1000

---@class Coagent.Image
---@field id string
---@field path string file in the store
---@field mime string
---@field label string where it came from (file name or "clipboard")
---@field bytes integer
---@field width integer?
---@field height integer?
---@field tokens integer rough input tokens

local function options()
  local ok, cfg = pcall(require, 'coagent.config')
  local o = ok and cfg.options and cfg.options.images or nil
  if not o and ok and cfg.defaults then
    o = cfg.defaults().images
  end
  return o or {}
end
M.options = options

--- Image type from the first bytes (not the file name).
---@param data string
---@return string? mime
function M.sniff(data)
  if type(data) ~= 'string' or #data < 12 then
    return nil
  end
  if data:sub(1, 8) == '\137PNG\r\n\26\n' then
    return 'image/png'
  elseif data:sub(1, 3) == '\255\216\255' then
    return 'image/jpeg'
  elseif data:sub(1, 6) == 'GIF87a' or data:sub(1, 6) == 'GIF89a' then
    return 'image/gif'
  elseif data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WEBP' then
    return 'image/webp'
  end
end

--- Does the file name look like an image coagent can send?
---@param path string
---@return boolean
function M.is_image_name(path)
  local ext = tostring(path or ''):match('%.(%w+)$')
  return ext ~= nil and EXT_MIME[ext:lower()] ~= nil
end

local function be16(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le16(s, i)
  local a, b = s:byte(i, i + 1)
  return a + b * 256
end

local function le24(s, i)
  local a, b, c = s:byte(i, i + 2)
  return a + b * 256 + c * 65536
end

--- Width and height from the image header (nil when not found).
---@param data string
---@param mime string
---@return integer? width, integer? height
function M.dims(data, mime)
  local ok, w, h = pcall(function()
    if mime == 'image/png' and data:sub(13, 16) == 'IHDR' then
      return be32(data, 17), be32(data, 21)
    elseif mime == 'image/gif' then
      return le16(data, 7), le16(data, 9)
    elseif mime == 'image/jpeg' then
      local i = 3
      while i + 8 <= #data do
        if data:byte(i) ~= 0xFF then
          return nil
        end
        local marker = data:byte(i + 1)
        if marker == 0xFF then
          i = i + 1
        elseif marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
          i = i + 2
        else
          local len = be16(data, i + 2)
          -- SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC)
          if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
            return be16(data, i + 7), be16(data, i + 5)
          end
          i = i + 2 + len
        end
      end
    elseif mime == 'image/webp' then
      local chunk = data:sub(13, 16)
      if chunk == 'VP8X' then
        return le24(data, 25) + 1, le24(data, 28) + 1
      elseif chunk == 'VP8 ' then
        return le16(data, 27) % 16384, le16(data, 29) % 16384
      elseif chunk == 'VP8L' then
        local b1, b2, b3, b4 = data:byte(22, 25)
        local bits = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
      end
    end
  end)
  if ok and w and h and w > 0 and h > 0 then
    return w, h
  end
end

--- Rough input tokens of an image, the OpenAI way: fit in 2048x2048, scale
--- the short side down to 768, 170 per 512px tile plus 85. Other providers
--- count differently; this is an estimate for the context budget only.
---@param w integer?
---@param h integer?
---@return integer
function M.tokens(w, h)
  if not (w and h) then
    return M.UNKNOWN_TOKENS
  end
  local s = math.min(1, 2048 / math.max(w, h))
  w, h = w * s, h * s
  s = math.min(1, 768 / math.min(w, h))
  w, h = w * s, h * s
  return 85 + 170 * math.ceil(w / 512) * math.ceil(h / 512)
end

---@param n integer
---@return string
function M.human(n)
  if n < 1024 then
    return n .. ' B'
  elseif n < 1024 * 1024 then
    return string.format('%.0f KB', n / 1024)
  end
  return string.format('%.1f MB', n / 1024 / 1024)
end

--- "shot.png, 1280x720, 120 KB, ~1105 tokens"
---@param img Coagent.Image
---@return string
function M.describe(img)
  local parts = { img.label }
  if img.width and img.height then
    table.insert(parts, img.width .. 'x' .. img.height)
  end
  table.insert(parts, M.human(img.bytes or 0))
  table.insert(parts, '~' .. tostring(img.tokens or M.UNKNOWN_TOKENS) .. ' tokens')
  return table.concat(parts, ', ')
end

---@return string
function M.dir()
  local d = options().dir
  return d and vim.fs.normalize(d) or (vim.fn.stdpath('state') .. '/coagent/images')
end

--- Check and copy image data into the store.
---@param data string
---@param label string
---@return Coagent.Image?, string? err
function M.store(data, label)
  local mime = M.sniff(data)
  if not mime then
    return nil, label .. ' is not a PNG, JPEG, GIF or WebP image'
  end
  local max = options().max_bytes or 5 * 1024 * 1024
  if #data > max then
    return nil, string.format('%s is %s; images larger than %s are not attached (images.max_bytes): make it smaller or crop it', label, M.human(#data), M.human(max))
  end
  local id = vim.fn.sha256(vim.base64.encode(data)):sub(1, 16)
  local path = M.dir() .. '/' .. id .. '.' .. M.EXT[mime]
  if not vim.uv.fs_stat(path) then
    local ok, err = pcall(util.write_file, path, data)
    if not ok then
      return nil, 'could not save ' .. label .. ': ' .. tostring(err)
    end
  else
    -- touched again: pruning keeps it
    pcall(vim.uv.fs_utime, path, os.time(), os.time())
  end
  local w, h = M.dims(data, mime)
  return { id = id, path = path, mime = mime, label = label, bytes = #data, width = w, height = h, tokens = M.tokens(w, h) }
end

--- An image already in the store (`#image:clip:<id>`, inserted by the paste key).
---@param id string
---@return Coagent.Image?, string? err
function M.find(id)
  if not tostring(id):match('^%x+$') then
    return nil, 'not an image id: ' .. tostring(id)
  end
  for _, ext in pairs(M.EXT) do
    local path = M.dir() .. '/' .. id .. '.' .. ext
    if vim.uv.fs_stat(path) then
      local data = util.read_file(path)
      if not data then
        return nil, 'could not read ' .. path
      end
      return M.store(data, 'clipboard')
    end
  end
  return nil, 'the pasted image ' .. id .. ' is no longer stored (images.keep_days)'
end

------------------------------------------------------------------------------
-- Clipboard
------------------------------------------------------------------------------

local function run(cmd, timeout)
  local ok, obj = pcall(function()
    return vim.system(cmd, { text = false }):wait(timeout or 5000)
  end)
  if not ok then
    return nil, tostring(obj)
  end
  if obj.code ~= 0 then
    return nil, vim.trim(obj.stderr or '') ~= '' and vim.trim(obj.stderr) or ('exit code ' .. tostring(obj.code))
  end
  return obj.stdout or ''
end

local PS_SCRIPT = table.concat({
  'Add-Type -AssemblyName System.Windows.Forms,System.Drawing;',
  '$i=[System.Windows.Forms.Clipboard]::GetImage();',
  'if ($i -eq $null) { exit 3 };',
  '$m=New-Object System.IO.MemoryStream;',
  '$i.Save($m,[System.Drawing.Imaging.ImageFormat]::Png);',
  '[Console]::Out.Write([Convert]::ToBase64String($m.ToArray()))',
}, ' ')

--- The command that prints the clipboard image (nil when there is none for
--- this system) and how to read its output.
---@return string[]? cmd, string? how 'hex' | 'base64' | 'raw', string? missing
function M.clipboard_command()
  if vim.fn.has('mac') == 1 then
    -- prints «data PNGf89504E47...»
    return { 'osascript', '-e', 'the clipboard as «class PNGf»' }, 'hex'
  end
  if vim.fn.has('win32') == 1 or vim.fn.has('wsl') == 1 then
    local ps = vim.fn.executable('powershell.exe') == 1 and 'powershell.exe' or 'powershell'
    return { ps, '-NoProfile', '-NonInteractive', '-STA', '-Command', PS_SCRIPT }, 'base64'
  end
  if vim.env.WAYLAND_DISPLAY and vim.fn.executable('wl-paste') == 1 then
    return { 'wl-paste', '--no-newline', '--type', 'image/png' }, 'raw'
  end
  if vim.fn.executable('xclip') == 1 then
    return { 'xclip', '-selection', 'clipboard', '-t', 'image/png', '-o' }, 'raw'
  end
  return nil, nil, 'reading an image from the clipboard needs wl-paste (Wayland) or xclip (X11)'
end

local function from_hex(hex)
  return (hex:gsub('%x%x', function(c)
    return string.char(tonumber(c, 16))
  end))
end

--- The image in the clipboard, stored. Runs a local command (osascript,
--- PowerShell, wl-paste or xclip); nothing is sent anywhere.
---@return Coagent.Image?, string? err
function M.from_clipboard()
  local cmd, how, missing = M.clipboard_command()
  if not cmd then
    return nil, missing
  end
  local out, err = run(cmd, 10000)
  if not out or out == '' then
    return nil, 'no image in the clipboard' .. (err and err ~= 'exit code 3' and (' (' .. util.clip(err, 160) .. ')') or '')
  end
  local data = out
  if how == 'hex' then
    local hex = out:match('PNGf(%x+)')
    if not hex then
      return nil, 'no image in the clipboard'
    end
    data = from_hex(hex)
  elseif how == 'base64' then
    local ok, dec = pcall(vim.base64.decode, vim.trim(out))
    if not ok or not dec or dec == '' then
      return nil, 'no image in the clipboard'
    end
    data = dec
  end
  return M.store(data, 'clipboard')
end

--- A file (already checked by the caller), stored.
---@param real string
---@param label string
---@return Coagent.Image?, string? err
function M.from_file(real, label)
  local st = vim.uv.fs_stat(real)
  local max = options().max_bytes or 5 * 1024 * 1024
  if st and st.size > max then
    return nil, string.format('%s is %s; images larger than %s are not attached (images.max_bytes): make it smaller or crop it', label, M.human(st.size), M.human(max))
  end
  local data = util.read_file(real)
  if not data then
    return nil, label .. ' not found'
  end
  return M.store(data, label)
end

------------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------------

-- path -> data URL of the last few images (each request re-sends the images
-- of the conversation; reading and encoding them every step is wasted work)
local cache, order = {}, {}
local CACHE_MAX = 8

--- `data:<mime>;base64,...` for an attached image, nil when its file is gone.
---@param img Coagent.Image
---@return string?
function M.data_url(img)
  if type(img) ~= 'table' or type(img.path) ~= 'string' then
    return nil
  end
  if cache[img.path] then
    return cache[img.path]
  end
  local data = util.read_file(img.path)
  local mime = data and M.sniff(data)
  if not mime then
    return nil
  end
  local url = 'data:' .. mime .. ';base64,' .. vim.base64.encode(data)
  -- still in use: pruning (images.keep_days) keeps it
  pcall(vim.uv.fs_utime, img.path, os.time(), os.time())
  cache[img.path] = url
  table.insert(order, img.path)
  if #order > CACHE_MAX then
    cache[table.remove(order, 1)] = nil
  end
  return url
end

--- The messages with their images left out: each user message with images
--- (a copy; the originals are not changed) names them and says `note`.
---@param messages table[]
---@param note string
---@return table[]
function M.as_names(messages, note)
  local out = {}
  for _, m in ipairs(messages) do
    if type(m) == 'table' and m.role == 'user' and type(m.images) == 'table' and #m.images > 0 then
      local copy = vim.tbl_extend('force', {}, m)
      copy.images = nil
      local names = table.concat(vim.tbl_map(function(i)
        return string.format('[image %s: %s]', tostring(i.n or '?'), tostring(i.label or 'image'))
      end, m.images), ', ')
      copy.content = tostring(m.content or '') .. '\n\n(' .. names .. ' ' .. note .. ')'
      table.insert(out, copy)
    else
      table.insert(out, m)
    end
  end
  return out
end

function M._reset_cache()
  cache, order = {}, {}
end

--- Total rough tokens of the images of `messages`.
---@param messages table[]
---@return integer tokens, integer count
function M.count(messages)
  local tokens, n = 0, 0
  for _, m in ipairs(messages or {}) do
    for _, img in ipairs(type(m.images) == 'table' and m.images or {}) do
      tokens = tokens + (tonumber(img.tokens) or M.UNKNOWN_TOKENS)
      n = n + 1
    end
  end
  return tokens, n
end

--- Delete stored images not used for `days`.
---@param days integer
function M.prune(days)
  local dir = M.dir()
  if vim.fn.isdirectory(dir) == 0 then
    return
  end
  local limit = os.time() - days * 86400
  for name, t in vim.fs.dir(dir) do
    local path = dir .. '/' .. name
    local st = t == 'file' and vim.uv.fs_stat(path)
    if st and st.mtime.sec < limit then
      os.remove(path)
    end
  end
end

return M
