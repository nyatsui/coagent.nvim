-- Images sent with a message: #image:path, #image (clipboard), @shot.png, the
-- store, and how the backend puts them into the body CopilotChat builds
-- (Chat Completions and Responses API) with the Copilot-Vision-Request header.
local h = require('tests.helpers')
local async = require('plenary.async')
local Mock = require('coagent.backend.mock')
local context = require('coagent.agent.context')
local Images = require('coagent.agent.images')
local Backend = require('coagent.backend.copilotchat')
local Workspace = require('coagent.tools.workspace')

local PROTECTED = require('coagent.config').defaults().auto.protected_globs

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- a PNG header (enough for sniffing and the size)
local function png(w, h_, extra)
  return '\137PNG\r\n\26\n' .. '\0\0\0\13IHDR' .. be32(w) .. be32(h_) .. '\8\2\0\0\0' .. 'crc!' .. (extra or string.rep('\0', 16))
end

local function resolve(ws, text)
  local res = h.run_async(function()
    return { context.resolve_references(text, { ws = ws, source = {} }) }
  end)
  return res[1], res[2], res[3], res[4], res[5]
end

describe('image helpers', function()
  it('recognizes images by their bytes and reads their size', function()
    assert.are.equal('image/png', Images.sniff(png(1280, 720)))
    assert.are.same({ 1280, 720 }, { Images.dims(png(1280, 720), 'image/png') })
    local gif = 'GIF89a' .. string.char(0x40, 0x01, 0xF0, 0x00) .. string.rep('\0', 8)
    assert.are.equal('image/gif', Images.sniff(gif))
    assert.are.same({ 320, 240 }, { Images.dims(gif, 'image/gif') })
    -- JPEG: SOI, an APP0 segment, then SOF0 with height 600 / width 800
    local jpeg = '\255\216' .. '\255\224\0\16' .. string.rep('\0', 14) .. '\255\192\0\17\8' .. '\2\88' .. '\3\32' .. string.rep('\0', 12)
    assert.are.equal('image/jpeg', Images.sniff(jpeg))
    assert.are.same({ 800, 600 }, { Images.dims(jpeg, 'image/jpeg') })
    assert.is_nil(Images.sniff('just some text, not an image'))
    assert.is_true(Images.is_image_name('a/B.PNG'))
    assert.is_false(Images.is_image_name('a.svg'))
  end)

  it('estimates tokens the OpenAI way and stores a copy once', function()
    assert.are.equal(85 + 170 * 4, Images.tokens(1024, 1024)) -- 768x768: 2x2 tiles
    assert.are.equal(Images.UNKNOWN_TOKENS, Images.tokens(nil, nil))
    local a = assert(Images.store(png(10, 10), 'a.png'))
    local b = assert(Images.store(png(10, 10), 'b.png'))
    assert.are.equal(a.id, b.id)
    assert.are.equal(a.path, b.path)
    assert.is_truthy(Images.data_url(a):find('^data:image/png;base64,'))
    local found = assert(Images.find(a.id))
    assert.are.equal(a.path, found.path)
    local none, err = Images.store('not an image at all', 'x.txt')
    assert.is_nil(none)
    assert.is_truthy(err:find('not a PNG', 1, true))
  end)

  it('reads the clipboard image through the system command', function()
    local orig = Images.clipboard_command
    local root = h.workspace({ ['c.png'] = png(64, 32) })
    local ok, err = pcall(function()
      Images.clipboard_command = function()
        return { 'cat', root .. '/c.png' }, 'raw'
      end
      local img = assert(Images.from_clipboard())
      assert.are.same({ 'clipboard', 64, 32 }, { img.label, img.width, img.height })
      -- macOS prints the data as «data PNGf<hex>»
      local hex = png(8, 8):gsub('.', function(c)
        return string.format('%02X', c:byte())
      end)
      Images.clipboard_command = function()
        return { 'printf', '%s', '«data PNGf' .. hex .. '»' }, 'hex'
      end
      img = assert(Images.from_clipboard())
      assert.are.equal(8, img.width)
      Images.clipboard_command = function()
        return { 'sh', '-c', 'exit 1' }, 'raw'
      end
      local none, e = Images.from_clipboard()
      assert.is_nil(none)
      assert.is_truthy(e:find('no image in the clipboard', 1, true))
    end)
    Images.clipboard_command = orig
    assert(ok, err)
  end)
end)

describe('#image references', function()
  local ws, root
  before_each(function()
    root = h.workspace({ ['shot.png'] = png(1280, 720), ['ui/b.png'] = png(100, 50), ['notes.txt'] = 'text\n', ['fake.png'] = 'not really a png' })
    ws = Workspace.new(root, { protected_globs = PROTECTED })
  end)

  it('attaches #image:path and @shot.png as images, with a marker in the text', function()
    local text, atts, errors, _, images = resolve(ws, 'Why is #image:shot.png wrong? compare @ui/b.png')
    assert.are.same({}, errors)
    assert.are.same({}, atts) -- not as text attachments
    assert.are.equal(2, #images)
    assert.are.equal('shot.png', images[1].label)
    assert.are.equal('ui/b.png', images[2].label)
    assert.are.equal('Why is [image 1: shot.png] wrong? compare ui/b.png', text)
    -- the same image twice is sent once
    local _, _, _, _, again = resolve(ws, '#image:shot.png and @shot.png')
    assert.are.equal(1, #again)
  end)

  it('refuses what is not an image, outside the workspace, or over the limits', function()
    local _, _, errors, _, images = resolve(ws, '#image:notes.txt #image:fake.png #image:missing.png #image:/etc/hosts')
    assert.are.equal(0, #images)
    local all = table.concat(errors, '\n')
    assert.is_truthy(all:find('notes.txt is not a PNG', 1, true))
    assert.is_truthy(all:find('fake.png is not a PNG', 1, true))
    assert.is_truthy(all:find('missing.png not found', 1, true))
    assert.is_truthy(all:find('outside the workspace', 1, true))

    local cfg = require('coagent.config')
    local saved = cfg.options.images
    cfg.options.images = vim.tbl_extend('force', saved, { max_bytes = 40 })
    _, _, errors, _, images = resolve(ws, '#image:shot.png')
    cfg.options.images = vim.tbl_extend('force', saved, { max_per_message = 1 })
    local _, _, errors2, _, images2 = resolve(ws, '#image:shot.png #image:ui/b.png')
    cfg.options.images = saved
    assert.are.equal(0, #images)
    assert.is_truthy(errors[1]:find('images.max_bytes', 1, true))
    assert.are.equal(1, #images2)
    assert.is_truthy(errors2[1]:find('images.max_per_message', 1, true))
  end)

  it('#image alone and #clipboard without text take the clipboard image; clip:<id> a pasted one', function()
    local orig_cmd, orig_read = Images.clipboard_command, context.read_clipboard
    local ok, err = pcall(function()
      Images.clipboard_command = function()
        return { 'cat', root .. '/ui/b.png' }, 'raw'
      end
      context.read_clipboard = function()
        return nil
      end
      local text, _, errors, _, images = resolve(ws, 'look at #image please')
      assert.are.same({}, errors)
      assert.are.equal('clipboard', images[1].label)
      assert.are.equal('look at [image 1: clipboard] please', text)
      local _, _, _, _, from_cb = resolve(ws, '#clipboard')
      assert.are.equal(1, #from_cb)
      local pasted = assert(Images.from_clipboard())
      local _, _, e3, _, by_id = resolve(ws, '#image:clip:' .. pasted.id)
      assert.are.same({}, e3)
      assert.are.equal(pasted.path, by_id[1].path)
    end)
    Images.clipboard_command, context.read_clipboard = orig_cmd, orig_read
    assert(ok, err)
  end)

  it('a task carries its images to the backend and lists them on the panel', function()
    local backend = Mock.new(function()
      return { content = 'It is a screenshot.' }
    end)
    local c = require('coagent.agent').build({ config = h.config(root), backend = backend })
    c:submit('what is in #image:shot.png ?')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local sent = backend.requests[1].messages[1]
    assert.are.equal(1, #sent.images)
    assert.are.equal('shot.png', sent.images[1].label)
    assert.is_truthy(sent.content:find('[image 1: shot.png]', 1, true))
    local user
    for _, it in ipairs(c.session.items) do
      if it.type == 'user' then
        user = it
      end
    end
    assert.is_truthy(user.images[1]:find('shot.png, 1280x720', 1, true))
    -- counted in the context estimate
    assert.is_true(context.estimate({ sent }) > Images.tokens(1280, 720))
    -- a summary transcript names it
    assert.is_truthy(context.transcript(c.session.messages, 0, 1):find('images attached (not shown here): shot.png', 1, true))
  end)
end)

describe('images in the request body', function()
  local img
  before_each(function()
    img = assert(Images.store(png(20, 20), 'shot.png'))
  end)

  it('turns the message into text + image parts (Chat Completions and Responses API)', function()
    local inputs = { { role = 'system', content = 'S' }, { role = 'user', content = 'look', coagent_images = { img } }, { role = 'assistant', content = 'look' } }
    local chat = { messages = { { role = 'system', content = 'S' }, { role = 'user', content = 'look' }, { role = 'assistant', content = 'look' } } }
    assert.are.equal(1, Backend.add_images(chat, inputs, false))
    local parts = chat.messages[2].content
    assert.are.same({ type = 'text', text = 'look' }, parts[1])
    assert.are.same({ type = 'text', text = '[image 1: shot.png]' }, parts[2])
    assert.are.equal('image_url', parts[3].type)
    assert.is_truthy(parts[3].image_url.url:find('^data:image/png;base64,'))
    assert.are.equal('look', chat.messages[3].content) -- the assistant's text is left alone

    local resp = { input = { { role = 'user', content = 'look' } } }
    assert.are.equal(1, Backend.add_images(resp, inputs, true))
    assert.are.equal('input_text', resp.input[1].content[1].type)
    assert.are.equal('input_image', resp.input[1].content[3].type)
    assert.is_truthy(resp.input[1].content[3].image_url:find('^data:image/png;base64,'))

    -- CopilotChat already sent it as parts (its own image support): untouched
    local own = { messages = { { role = 'user', content = { { type = 'text', text = 'look' } } } } }
    assert.are.equal(0, Backend.add_images(own, inputs, false))
    assert.are.equal(1, #own.messages[1].content)

    -- the stored copy is gone: a note instead of the image
    local gone = vim.tbl_extend('force', img, { path = img.path .. '.missing' })
    local body = { messages = { { role = 'user', content = 'x' } } }
    assert.are.equal(0, Backend.add_images(body, { { role = 'user', content = 'x', coagent_images = { gone } } }, false))
    assert.are.equal('string', type(body.messages[1].content))
    assert.is_truthy(body.messages[1].content:find('no longer available', 1, true))
  end)

  it('sends nothing a model is known not to take, and keeps the newest within its per-request limit', function()
    local a = vim.tbl_extend('force', img, { n = 1, label = 'a.png' })
    local b = vim.tbl_extend('force', img, { n = 2, label = 'b.png' })
    local inputs = { { role = 'user', content = 'first', coagent_images = { a } }, { role = 'assistant', content = 'ok' }, { role = 'user', content = 'second', coagent_images = { b } } }
    local function body()
      return { messages = { { role = 'user', content = 'first' }, { role = 'assistant', content = 'ok' }, { role = 'user', content = 'second' } } }
    end
    -- no vision: plain text that names the images
    local req = body()
    local n, skipped = Backend.add_images(req, inputs, false, { id = 'text-only', vision = false })
    assert.are.equal(0, n)
    assert.are.same({ vision = 2 }, skipped)
    assert.are.equal('string', type(req.messages[1].content))
    assert.is_truthy(req.messages[1].content:find('[image 1: a.png not sent: model text-only does not accept images]', 1, true))
    -- learned this session (refused images earlier): the same
    req = body()
    assert.are.equal(0, (Backend.add_images(req, inputs, false, { id = 'x' }, true)))
    -- the model list's per-request limit is not applied (models took more)
    req = body()
    assert.are.equal(2, (Backend.add_images(req, inputs, false, { id = 'listed', vision = true, vision_limits = { max_prompt_images = 1 } })))
    -- a limit learned from a refusal: the newest goes, the older one is named
    req = body()
    n, skipped = Backend.add_images(req, inputs, false, { id = 'one', vision = true }, false, 1)
    assert.are.equal(1, n)
    assert.are.same({ count = 1 }, skipped)
    assert.is_truthy(req.messages[1].content:find('not sent again: model one refused more than 1', 1, true))
    assert.are.equal('image_url', req.messages[3].content[3].type)
    assert.are.equal('[image 2: b.png]', req.messages[3].content[2].text)
    -- a type or size the model does not take
    req = body()
    n, skipped = Backend.add_images(req, inputs, false, { id = 'small', vision = true, vision_limits = { max_prompt_image_size = 10, supported_media_types = { 'image/png' } } })
    assert.are.equal(0, n)
    assert.are.same({ size = 2 }, skipped)
    req = body()
    n, skipped = Backend.add_images(req, inputs, false, { id = 'jpg', vision = true, vision_limits = { supported_media_types = { 'image/jpeg' } } })
    assert.are.same({ type = 2 }, skipped)
    -- nothing known about the model: sent
    req = body()
    assert.are.equal(2, (Backend.add_images(req, inputs, false, { id = 'unknown' })))
  end)

  it('keeps what the models API says about images on CopilotChat\'s model list', function()
    local curl = require('CopilotChat.utils.curl')
    local orig_get = curl.get
    curl.get = function()
      return {
        body = {
          data = {
            { id = 'seeing', capabilities = { supports = { vision = true }, limits = { vision = { max_prompt_images = 1, max_prompt_image_size = 3145728 } } } },
            { id = 'blind', capabilities = { supports = { streaming = true } } },
          },
        },
      }
    end
    local get_models = Backend.wrap_get_models(function()
      local r = curl.get('https://api.example.invalid/models')
      return vim.tbl_map(function(m)
        return { id = m.id }
      end, r.body.data)
    end)
    local ok, models = pcall(get_models, {})
    local restored = curl.get
    curl.get = orig_get
    assert(ok, models)
    assert.are.equal(orig_get ~= nil and restored ~= nil, true)
    assert.is_true(models[1].vision)
    assert.are.equal(1, models[1].vision_limits.max_prompt_images)
    assert.is_false(models[2].vision)
    assert.is_nil(models[2].vision_limits)
    -- the wrapper is idempotent
    assert.are.equal(get_models, Backend.wrap_get_models(get_models))
  end)

  describe('through the real CopilotChat client', function()
    local curl = require('CopilotChat.utils.curl')
    local orig_post = curl.post
    local captured, fail

    before_each(function()
      captured, fail = {}, nil
      local providers = require('CopilotChat.config.providers')
      require('CopilotChat').setup({
        model = 'fake-model',
        providers = {
          copilot = { disabled = true },
          github_models = { disabled = true },
          fake = {
            get_headers = function()
              return { Authorization = 'Bearer test-token' }
            end,
            get_models = function()
              return { { id = 'fake-model', name = 'Fake', tools = true, streaming = true, max_input_tokens = 100000 } }
            end,
            prepare_input = providers.copilot.prepare_input,
            prepare_output = providers.copilot.prepare_output,
            get_url = function()
              return 'https://fake.invalid/chat/completions'
            end,
          },
        },
      })
      curl.post = async.wrap(function(_, args, cb)
        table.insert(captured, { body = vim.deepcopy(args.body), headers = args.headers })
        if fail then
          cb({ status = 400, body = fail }, fail)
          return
        end
        local job = { shutdown = function() end }
        vim.schedule(function()
          args.stream(nil, 'data: ' .. vim.json.encode({ choices = { { delta = { content = 'a cat' } } } }), job)
          args.stream(nil, 'data: ' .. vim.json.encode({ choices = { { finish_reason = 'stop', delta = {} } } }), job)
          cb({ status = 200, body = '' })
        end)
      end, 3)
    end)

    after_each(function()
      curl.post = orig_post
    end)

    local function ask(messages)
      local backend = Backend.new()
      return h.run_async(function()
        local r, e = backend:ask({ model = 'fake-model', system_prompt = 'SYS', tools = {}, messages = messages, no_network_wait = true })
        return { r = r, e = e }
      end)
    end

    it('sends the image parts and the Copilot-Vision-Request header only with images', function()
      local out = ask({ { role = 'user', content = 'what is it?', images = { img } } })
      assert.are.equal('a cat', out.r.content)
      local req = captured[1]
      assert.are.equal('true', req.headers['Copilot-Vision-Request'])
      local parts = req.body.messages[2].content
      assert.are.equal('what is it?', parts[1].text)
      assert.are.equal('image_url', parts[3].type)
      -- the body on the wire is valid JSON
      assert.is_truthy(vim.json.encode(req.body):find('data:image/png;base64,', 1, true))

      ask({ { role = 'user', content = 'no image' } })
      assert.is_nil(captured[2].headers['Copilot-Vision-Request'])
      assert.are.equal('no image', captured[2].body.messages[2].content)

      local cfg = require('coagent.config')
      local saved = cfg.options.images
      cfg.options.images = vim.tbl_extend('force', saved, { vision_header = false })
      ask({ { role = 'user', content = 'again', images = { img } } })
      cfg.options.images = saved
      assert.is_nil(captured[3].headers['Copilot-Vision-Request'])
      assert.are.equal('table', type(captured[3].body.messages[2].content))
    end)

    it('a model that refuses the images gets the request again without them, and no images after that', function()
      local backend = Backend.new()
      local calls = 0
      local post = curl.post
      curl.post = function(url, args)
        calls = calls + 1
        if calls == 1 then
          table.insert(captured, { body = vim.deepcopy(args.body), headers = args.headers })
          error('400: image input is not supported for this model', 0)
        end
        return post(url, args)
      end
      local function go(content)
        return h.run_async(function()
          local r, e = backend:ask({ model = 'fake-model', system_prompt = 'S', tools = {}, messages = { { role = 'user', content = content, images = { img } } }, no_network_wait = true })
          return { r = r, e = e }
        end)
      end
      local out = go('what is it?')
      assert.are.equal('a cat', out.r.content)
      assert.are.equal('table', type(captured[1].body.messages[2].content))
      assert.are.equal('string', type(captured[2].body.messages[2].content))
      assert.is_truthy(captured[2].body.messages[2].content:find('does not accept images', 1, true))
      assert.is_nil(captured[2].headers['Copilot-Vision-Request'])
      assert.is_truthy(table.concat(out.r.notices or {}, '\n'):find('refused the images', 1, true))
      go('and now?')
      assert.are.equal('string', type(captured[3].body.messages[2].content))
    end)

    it('a model that refuses several images gets the newest again, and keeps to that number', function()
      local backend = Backend.new()
      local img2 = vim.deepcopy(img)
      img2.n, img2.label = 2, 'second.png'
      local calls = 0
      local post = curl.post
      curl.post = function(url, args)
        calls = calls + 1
        if calls == 1 then
          table.insert(captured, { body = vim.deepcopy(args.body), headers = args.headers })
          error('400: too many images in the request', 0)
        end
        return post(url, args)
      end
      local function go(messages)
        return h.run_async(function()
          local r, e = backend:ask({ model = 'fake-model', system_prompt = 'S', tools = {}, messages = messages, no_network_wait = true })
          return { r = r, e = e }
        end)
      end
      local out = go({ { role = 'user', content = 'two', images = { img, img2 } } })
      assert.are.equal('a cat', out.r.content)
      local function count(body)
        local n = 0
        for _, p in ipairs(type(body.messages[2].content) == 'table' and body.messages[2].content or {}) do
          n = n + (p.type == 'image_url' and 1 or 0)
        end
        return n
      end
      assert.are.equal(2, count(captured[1].body))
      assert.are.equal(1, count(captured[2].body))
      assert.is_truthy(vim.json.encode(captured[2].body):find('second.png]', 1, true))
      assert.is_truthy(table.concat(out.r.notices or {}, '\n'):find('sent again with the newest 1', 1, true))
      assert.are.equal(1, backend:image_limit_for('fake-model'))
      -- images still go to it, one per request
      go({ { role = 'user', content = 'again', images = { img, img2 } } })
      assert.are.equal(1, count(captured[3].body))
    end)

    it('after a refused smaller batch, one image is tried before images stop for the model', function()
      local backend = Backend.new()
      backend.model_info = function()
        return { id = 'fake-model', vision = true, vision_limits = { max_prompt_images = 2 } }
      end
      local imgs = {}
      for k = 1, 3 do
        local c = vim.deepcopy(img)
        c.n, c.label = k, 'i' .. k .. '.png'
        imgs[k] = c
      end
      local calls = 0
      local post = curl.post
      curl.post = function(url, args)
        calls = calls + 1
        if calls <= 2 then
          table.insert(captured, { body = vim.deepcopy(args.body), headers = args.headers })
          error('400: too many images', 0)
        end
        return post(url, args)
      end
      local out = h.run_async(function()
        local r, e = backend:ask({ model = 'fake-model', system_prompt = 'S', tools = {}, messages = { { role = 'user', content = 'three', images = imgs } }, no_network_wait = true })
        return { r = r, e = e }
      end)
      assert.are.equal('a cat', out.r.content)
      local function count(body)
        local n = 0
        for _, p in ipairs(type(body.messages[2].content) == 'table' and body.messages[2].content or {}) do
          n = n + (p.type == 'image_url' and 1 or 0)
        end
        return n
      end
      assert.are.same({ 3, 2, 1 }, { count(captured[1].body), count(captured[2].body), count(captured[3].body) })
      assert.are.equal(1, backend:image_limit_for('fake-model'))
      assert.is_nil(backend.no_vision['fake-model'])
    end)

    it('only client errors count as refusing images', function()
      assert.is_true(Backend.is_image_rejection('400: image input is not supported'))
      assert.is_true(Backend.is_image_rejection('Bad Request: invalid image'))
      assert.is_true(Backend.is_image_rejection('413 payload too large: image'))
      assert.is_false(Backend.is_image_rejection('500 internal error while processing image'))
      assert.is_false(Backend.is_image_rejection('403 forbidden: vision is disabled by policy'))
      assert.is_false(Backend.is_image_rejection('429 too many requests (image)'))
      assert.is_false(Backend.is_image_rejection('image could not be processed'))
      assert.is_false(Backend.is_image_rejection('400 bad request: max_tokens too large'))
    end)

    it('says so when the wrapper found no message for the images', function()
      local b = Backend.new()
      local notices = {}
      b:_image_notices({ images = 2, images_skipped = {}, images_sent = 0, sent_model = 'm' }, { model = 'm' }, notices)
      assert.is_truthy(table.concat(notices, '\n'):find('did not find their message', 1, true))
    end)

    it('other errors with images say the model may not accept them', function()
      fail = '400 bad request'
      local out = ask({ { role = 'user', content = 'what is it?', images = { img } } })
      assert.is_nil(out.r)
      assert.is_truthy(out.e:find('may not accept them', 1, true))
    end)
  end)
end)

describe('paste_image key', function()
  local agent
  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly | silent! only')
  end)

  it('saves the clipboard image and inserts #image:clip:<id> at the cursor; the message sends it', function()
    local root = h.workspace({ ['c.png'] = png(30, 20) })
    local backend = Mock.new({ { content = 'seen' } })
    agent = require('coagent')
    agent._reset()
    agent.setup({ backend = backend, root = root, session = { persist = false }, ui = { render_throttle_ms = 0 } })
    vim.o.columns, vim.o.lines = 160, 48
    agent.open()
    local view = agent.view()
    local orig = Images.clipboard_command
    local ok, err = pcall(function()
      Images.clipboard_command = function()
        return { 'cat', root .. '/c.png' }, 'raw'
      end
      view.input:set_text('what is')
      vim.api.nvim_win_set_cursor(view.wins.input, { 1, 6 })
      view:paste_image()
      local text = view.input:text()
      local id = text:match('^what is #image:clip:(%x+) $')
      assert.is_truthy(id, text)
      -- the clipboard changes before sending: the pasted image is still the one sent
      Images.clipboard_command = function()
        return { 'sh', '-c', 'exit 1' }, 'raw'
      end
      view.input:submit()
      h.wait(function()
        return agent.controller():state() == 'COMPLETED'
      end)
      local sent = backend.requests[1].messages[1]
      assert.are.equal(1, #sent.images)
      assert.are.equal(30, sent.images[1].width)
      assert.are.equal(id, sent.images[1].id)
    end)
    Images.clipboard_command = orig
    assert(ok, err)
  end)
end)

describe('images under a lead', function()
  local root
  before_each(function()
    root = h.workspace({ ['a.png'] = png(40, 30), ['b.png'] = png(50, 30), ['c.png'] = png(60, 30) })
  end)

  local function build(lead_script, worker_script, worker_info)
    local ln, wn = 0, 0
    local backend = Mock.new(function(messages, _, req)
      if req.model == 'strong' then
        ln = ln + 1
        return lead_script(ln, messages, req)
      end
      wn = wn + 1
      return worker_script(wn, messages, req)
    end)
    if worker_info then
      backend.model_info = function(_, model)
        return model ~= 'strong' and worker_info or nil
      end
      -- a per-request limit as learned from a refusal
      backend.image_limit_for = function(_, model)
        return model ~= 'strong' and worker_info.learned_limit or nil
      end
    end
    local c = require('coagent.agent').build({ config = h.config(root, { roles = { preset = 'lead', lead_model = 'strong' } }), backend = backend })
    local r = { c = c, backend = backend }
    c.events:on('done', function(s)
      r.done = s
    end)
    return r
  end

  local function wait_done(r)
    h.wait(function()
      return r.done ~= nil
    end, 10000)
    assert(r.done, 'not done: ' .. r.c:state())
  end

  it('numbers images across the session and passes the ones the lead names to the worker', function()
    local report
    local r = build(function(n, messages)
      if n == 1 then
        return { content = 'noted' }
      elseif n == 2 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'Make the page look like image 2.', images = { 2, 9 } } } } }
      end
      report = messages[#messages].content
      return { content = 'done' }
    end, function()
      return { content = 'Looked at it.' }
    end)
    r.c:submit('here is #image:a.png')
    wait_done(r)
    r.done = nil
    r.c:submit('and #image:b.png')
    wait_done(r)
    local msgs = r.c.session.messages
    local ns = {}
    for _, m in ipairs(msgs) do
      for _, i in ipairs(m.images or {}) do
        table.insert(ns, i.n .. ':' .. i.label)
      end
    end
    assert.are.same({ '1:a.png', '2:b.png' }, ns)
    local worker_req
    for _, q in ipairs(r.backend.requests) do
      if q.model ~= 'strong' then
        worker_req = q
      end
    end
    local first = worker_req.messages[1]
    assert.are.equal(1, #first.images)
    assert.are.equal('b.png', first.images[1].label)
    assert.is_truthy(first.content:find('[image 2: b.png]', 1, true))
    assert.is_truthy(report:find('Images given to the worker: 2 (b.png)', 1, true))
    assert.is_truthy(report:find('image 9: there is no such image', 1, true))
  end)

  it('a worker model known not to take images gets a note instead, and the lead is told', function()
    local report
    local r = build(function(n, messages)
      if n == 1 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'Check image 1.', images = { 1 } } } } }
      end
      report = messages[#messages].content
      return { content = 'done' }
    end, function()
      return { content = 'ok' }
    end, { id = 'blind', vision = false })
    r.c:submit('see #image:a.png')
    wait_done(r)
    local worker_req
    for _, q in ipairs(r.backend.requests) do
      if q.model ~= 'strong' then
        worker_req = q
      end
    end
    assert.is_nil(worker_req.messages[1].images)
    assert.is_truthy(worker_req.messages[1].content:find('cannot be shown', 1, true))
    assert.is_truthy(report:find('not given: the worker model', 1, true))
  end)

  it('reads the images past the worker model\'s per-request limit first and hands the worker their notes', function()
    local W = require('coagent.agent.worker')
    local report
    local r = build(function(n, messages)
      if n == 1 then
        return { tool_calls = { { name = 'worker', arguments = { task = 'Make the page look like image 2.', images = { 2, 1, 3 } } } } }
      end
      report = messages[#messages].content
      return { content = 'done' }
    end, function(n, messages, req)
      if req.system_prompt == W.READER then
        return { content = 'notes on ' .. messages[1].images[1].label }
      end
      return { content = 'Matched it.' }
    end, { id = 'one-at-a-time', vision = true, learned_limit = 1 })
    r.c:submit('see #image:a.png #image:b.png #image:c.png')
    wait_done(r)
    local reads, work = {}, {}
    for _, q in ipairs(r.backend.requests) do
      if q.model ~= 'strong' then
        table.insert(q.system_prompt == W.READER and reads or work, q)
      end
    end
    assert.are.equal(2, #reads)
    assert.are.equal('a.png', reads[1].messages[1].images[1].label)
    assert.are.same({}, reads[1].tools)
    assert.are.equal('c.png', reads[2].messages[1].images[1].label)
    assert.is_truthy(reads[2].messages[1].content:find('notes on a.png', 1, true))
    local first = work[1].messages[1]
    assert.are.equal(1, #first.images)
    assert.are.equal('b.png', first.images[1].label)
    assert.is_truthy(first.content:find('Notes on [image 1: a.png]:\nnotes on a.png', 1, true))
    assert.is_truthy(first.content:find('Notes on [image 3: c.png]:\nnotes on c.png', 1, true))
    assert.is_truthy(report:find('Images given to the worker: 2 (b.png)', 1, true))
    assert.is_truthy(report:find('Image 1 (a.png): read in a separate step first', 1, true))
  end)

  it('splits images by the per-request limit, keeping the lead\'s order', function()
    local W = require('coagent.agent.worker')
    local imgs = { { n = 1 }, { n = 2 }, { n = 3 }, { n = 4 }, { n = 5 } }
    local direct, batches = W.split_images(imgs, 2)
    assert.are.same({ 1, 2 }, vim.tbl_map(function(i) return i.n end, direct))
    assert.are.same({ { 3, 4 }, { 5 } }, vim.tbl_map(function(b) return vim.tbl_map(function(i) return i.n end, b) end, batches))
    direct, batches = W.split_images(imgs, nil)
    assert.are.equal(5, #direct)
    assert.are.equal(0, #batches)
    assert.is_nil(W.images_per_request({ backend = {} }, 'm'))
    assert.are.equal(1, W.images_per_request({ backend = { image_limit_for = function() return 1 end } }, 'm'))
  end)

  it('read_images: the worker model writes notes a batch at a time, and the lead gets them', function()
    local W = require('coagent.agent.worker')
    local result
    local r = build(function(n, messages, req)
      if n == 1 then
        local names = vim.tbl_map(function(t) return t.name end, req.tools or {})
        assert(vim.tbl_contains(names, 'read_images'), 'read_images offered with images')
        return { tool_calls = { { name = 'read_images', arguments = { images = { 1, 3 }, question = 'What do the dialogs say?' } } } }
      end
      result = messages[#messages].content
      return { content = 'done' }
    end, function(n, messages, req)
      assert.are.equal(W.READER, req.system_prompt)
      return { content = 'it says ' .. messages[1].images[1].label }
    end, { id = 'one-at-a-time', vision = true, learned_limit = 1 })
    r.c:submit('see #image:a.png #image:b.png #image:c.png')
    wait_done(r)
    local reads = vim.tbl_filter(function(q) return q.model ~= 'strong' end, r.backend.requests)
    assert.are.equal(2, #reads)
    assert.is_truthy(reads[1].messages[1].content:find('What do the dialogs say?', 1, true))
    assert.is_truthy(reads[2].messages[1].content:find('it says a.png', 1, true))
    assert.is_truthy(result:find('2 requests, 1 image per request', 1, true), result)
    assert.is_truthy(result:find('Notes on [image 1: a.png]:\nit says a.png', 1, true))
    assert.is_truthy(result:find('Notes on [image 3: c.png]:\nit says c.png', 1, true))
  end)

  it('read_images: separately leaves the earlier notes out; a blind worker model points to reader self', function()
    local result
    local r = build(function(n, messages)
      if n == 1 then
        return { tool_calls = { { name = 'read_images', arguments = { images = { 1, 2 }, question = 'q', separately = true } } } }
      elseif n == 2 then
        result = messages[#messages].content
        return { tool_calls = { { name = 'read_images', arguments = { images = { 1 }, question = 'q' } } } }
      end
      result = result .. '\n---\n' .. messages[#messages].content
      return { content = 'done' }
    end, function(_, messages)
      return { content = 'saw ' .. messages[1].images[1].label }
    end, { id = 'seeing', vision = true })
    r.c:submit('see #image:a.png #image:b.png')
    wait_done(r)
    local reads = vim.tbl_filter(function(q) return q.model ~= 'strong' end, r.backend.requests)
    assert.is_nil(reads[2].messages[1].content:find('saw a.png', 1, true))
    assert.is_truthy(result:find('each on its own', 1, true))
    -- now the worker model takes no images
    r.done = nil
    local r2 = build(function(n, messages)
      if n == 1 then
        return { tool_calls = { { name = 'read_images', arguments = { images = { 1 }, question = 'q' } } } }
      end
      result = messages[#messages].content
      return { content = 'done' }
    end, function()
      error('the blind worker model must not be asked')
    end, { id = 'blind', vision = false })
    r2.c:submit('see #image:a.png')
    wait_done(r2)
    assert.is_truthy(result:find('No image was read', 1, true), result)
    assert.is_truthy(result:find('reader "self"', 1, true), result)
  end)

  it('read_images with reader self reads with the conversation\'s model, all in one request while no limit was seen', function()
    local W = require('coagent.agent.worker')
    local n, result = 0, nil
    local backend = Mock.new(function(messages, _, req)
      n = n + 1
      if req.system_prompt == W.READER then
        return { content = 'self saw ' .. messages[1].images[1].label }
      elseif n == 1 then
        return { tool_calls = { { name = 'read_images', arguments = { images = { 1, 2 }, question = 'q', reader = 'worker' } } } }
      end
      result = messages[#messages].content
      return { content = 'done' }
    end)
    local c = require('coagent.agent').build({ config = h.config(root), backend = backend })
    c:submit('see #image:a.png #image:b.png')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    assert.is_truthy(result:find('there is no worker model', 1, true), result)
    assert.is_truthy(result:find('1 request, 2 images per request', 1, true), result)
    assert.is_truthy(result:find('Notes on [image 1: a.png], [image 2: b.png]:\nself saw a.png', 1, true), result)
  end)

  it('read_images is not offered while the session has no images', function()
    local backend = Mock.new({ { content = 'ok' } })
    local c = require('coagent.agent').build({ config = h.config(root), backend = backend })
    c:submit('hello')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local names = vim.tbl_map(function(t) return t.name end, backend.requests[1].tools or {})
    assert.is_false(vim.tbl_contains(names, 'read_images'))
    assert.is_true(vim.tbl_contains(names, 'read_file'))
  end)

  it('the lead gets the images by name only; images.to_lead = true sends them', function()
    local r = build(function()
      return { content = 'ok' }
    end, function()
      return { content = 'ok' }
    end)
    r.c:submit('see #image:a.png')
    wait_done(r)
    local lead_req = r.backend.requests[1]
    assert.are.equal('strong', lead_req.model)
    local last = lead_req.messages[#lead_req.messages]
    assert.is_nil(last.images)
    assert.is_truthy(last.content:find('([image 1: a.png] not shown to you', 1, true), last.content)
    -- the session keeps the image (workers and read_images still get it)
    local kept
    for _, m in ipairs(r.c.session.messages) do
      kept = kept or (m.images and m.images[1])
    end
    assert.are.equal('a.png', kept.label)
    local note
    for _, it in ipairs(r.c.session.items) do
      if it.type == 'notice' and it.text:find('not sent to the lead', 1, true) then
        note = it.text
      end
    end
    assert.is_truthy(note)

    local ln = 0
    local backend = Mock.new(function()
      ln = ln + 1
      return { content = 'ok' }
    end)
    local c = require('coagent.agent').build({ config = h.config(root, { roles = { preset = 'lead', lead_model = 'strong' }, images = { to_lead = true } }), backend = backend })
    c:submit('see #image:a.png')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local m = backend.requests[1].messages[#backend.requests[1].messages]
    assert.are.equal(1, #m.images)
  end)

  it('warns when the model that reads the conversation does not take images', function()
    local backend = Mock.new({ { content = 'ok' } })
    backend.model_info = function()
      return { id = 'mock-model', vision = false }
    end
    local c = require('coagent.agent').build({ config = h.config(root), backend = backend })
    c:submit('see #image:a.png')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local warned
    for _, it in ipairs(c.session.items) do
      if it.type == 'notice' and it.level == 'warn' then
        warned = it.text
      end
    end
    assert.is_truthy(warned and warned:find('does not accept images', 1, true), tostring(warned))
  end)
end)
