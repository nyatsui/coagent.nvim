-- Documents converted by the REAL MarkItDown (no network). Skipped unless
-- MarkItDown is installed: the Python is $COAGENT_MARKITDOWN_PYTHON, else
-- ~/.local/share/coagent-markitdown/bin/python, else python3.
--   COAGENT_MARKITDOWN_PYTHON=/path/to/venv/bin/python make test-file F=tests/documents_integration_spec.lua
local h = require('tests.helpers')
local context = require('coagent.agent.context')
local Documents = require('coagent.agent.documents')
local Workspace = require('coagent.tools.workspace')

local function find_python()
  for _, p in ipairs({ vim.env.COAGENT_MARKITDOWN_PYTHON or '', vim.fs.normalize(Documents.VENV .. '/bin/python'), 'python3' }) do
    if p ~= '' and vim.fn.executable(p) == 1 then
      local res = vim.system({ p, Documents.helper(), 'probe' }, { text = true, env = { PYTHONDONTWRITEBYTECODE = '1' } }):wait(30000)
      local ok, info = pcall(vim.json.decode, res.stdout or '')
      if res.code == 0 and ok and type(info) == 'table' and type(info.markitdown) == 'string' then
        return p, info.markitdown
      end
    end
  end
end

local PY, VERSION = find_python()

if not PY then
  describe('documents with MarkItDown', function()
    pending('MarkItDown is not installed (set COAGENT_MARKITDOWN_PYTHON to a Python that has it)')
  end)
  return
end

describe('documents with MarkItDown ' .. VERSION, function()
  local root, ws, o

  -- the documents are built once (plenary's busted has no setup())
  before_each(function()
    if root then
      return
    end
    Documents._reset()
    root = h.workspace({})
    local res = vim.system({ PY, vim.fn.getcwd() .. '/tests/fixtures/documents/make_real.py', root .. '/docs' }, { text = true, env = { PYTHONDONTWRITEBYTECODE = '1' } }):wait(60000)
    assert(res.code == 0, res.stderr)
    ws = Workspace.new(root, {})
    o = { enabled = true, python = PY, cache = { dir = vim.fn.tempname() } }
  end)

  local function load(path)
    return unpack(h.run_async(function()
      return { Documents.load(ws:check(path), { documents = o }) }
    end, 60000))
  end

  it('reads a PDF by line ranges (no pages) and extracts its image with the pages it is on', function()
    local doc, err = load('docs/paper.pdf')
    assert(doc, err)
    assert.is_truthy(doc.markdown:find('Page one says hello', 1, true), doc.markdown)
    assert.is_truthy(doc.markdown:find('Page two says goodbye', 1, true))
    assert.are.same({}, doc.sections)
    assert.is_truthy(Documents.read(doc, {}, 24000).output:find('No page numbers', 1, true))
    assert.are.equal(1, #doc.images, vim.inspect(doc.notes))
    assert.are.equal('png', doc.images[1].ext)
    assert.are.same({ { label = 'page 1' }, { label = 'page 2' } }, doc.images[1].locations)
    local data = h.read(doc.images[1].path)
    assert.are.same({ 4, 3 }, { require('coagent.agent.images').dims(data, 'image/png') })
  end)

  it('renders PDF pages as pictures with the text of each page (pypdfium2)', function()
    if vim.system({ PY, '-c', 'import pypdfium2, PIL' }):wait().code ~= 0 then
      pending('pypdfium2 is not installed with MarkItDown')
      return
    end
    local res, err = unpack(h.run_async(function()
      return { Documents.page_images(ws:check('docs/paper.pdf'), '1-3', { documents = o }) }
    end, 60000))
    assert(res, err)
    assert.are.equal(2, res.count)
    assert.are.equal(2, #res.pages)
    assert.is_truthy(res.pages[2].text:find('Page two says goodbye', 1, true), res.pages[2].text)
    local img = res.pages[1].image
    assert.are.equal('image/png', img.mime)
    -- US Letter, longest side 1568 px
    assert.are.equal(1568, math.max(img.width, img.height))
    assert.are.same({ 'page 3: the document has 2' }, res.notes)
  end)

  it('lays out PPTX slides with LibreOffice and pairs them with the slide text', function()
    if not Documents.find_soffice('soffice') or not vim.uv.fs_stat(root .. '/docs/deck.pptx') or vim.system({ PY, '-c', 'import pypdfium2' }):wait().code ~= 0 then
      pending('LibreOffice, python-pptx or pypdfium2 is not installed')
      return
    end
    local res, err = unpack(h.run_async(function()
      return { Documents.page_images(ws:check('docs/deck.pptx'), '2', { documents = o }) }
    end, 120000))
    assert(res, err)
    assert.are.equal(2, res.count)
    assert.is_truthy(res.pages[1].text:find('Architecture', 1, true), res.pages[1].text)
    assert.are.equal('image/png', res.pages[1].image.mime)
  end)

  it('lays out DOCX pages with LibreOffice, Japanese text included', function()
    if not Documents.find_soffice('soffice') or vim.system({ PY, '-c', 'import pypdfium2' }):wait().code ~= 0 then
      pending('LibreOffice or pypdfium2 is not installed')
      return
    end
    local res, err = unpack(h.run_async(function()
      return { Documents.page_images(ws:check('docs/report.docx'), '1', { documents = o }) }
    end, 120000))
    assert(res, err)
    assert.are.equal(1, res.count)
    assert.are.equal('page 1 (LibreOffice layout)', res.pages[1].label)
    -- the page text comes from the laid-out PDF: missing fonts would drop it
    assert.is_truthy(res.pages[1].text:find('売上', 1, true), res.pages[1].text)
    assert.are.equal('image/png', res.pages[1].image.mime)
  end)

  it('turns an EMF picture into a PNG of the picture, not of a whole page (LibreOffice)', function()
    local soffice = Documents.find_soffice('soffice')
    if not soffice then
      pending('LibreOffice is not installed')
      return
    end
    -- an EMF made by LibreOffice from a 200 x 100 SVG
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    h.write(dir .. '/shape.svg', '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#3366cc"/></svg>')
    local res = vim.system({ soffice, '-env:UserInstallation=file://' .. dir .. '/profile', '--headless', '--convert-to', 'emf', '--outdir', dir, dir .. '/shape.svg' }, { cwd = dir }):wait(120000)
    if res.code ~= 0 or not vim.uv.fs_stat(dir .. '/shape.emf') then
      pending('LibreOffice could not write an EMF')
      return
    end
    vim.uv.fs_rename(dir .. '/shape.emf', dir .. '/001-x.emf')
    local r = h.run_async(function()
      return { Documents.attachable({ n = 1, ext = 'emf', path = dir .. '/001-x.emf' }, { documents = o }) }
    end, 120000)
    assert(r[1], r[2])
    local img = assert(require('coagent.agent.images').from_file(r[1], 'shape'))
    assert.are.equal('image/png', img.mime)
    -- about 2:1 like the drawing (an A4 page would be taller than wide)
    assert.is_true(img.width > img.height * 1.5, img.width .. 'x' .. img.height)
  end)

  it('turns an image the model cannot take into PNG (Pillow)', function()
    local res = vim.system({ PY, '-c', 'import PIL' }):wait()
    if res.code ~= 0 or not vim.uv.fs_stat(root .. '/docs/shot.tiff') then
      pending('Pillow is not installed with MarkItDown')
      return
    end
    local cache = vim.fn.tempname()
    vim.fn.mkdir(cache, 'p')
    vim.uv.fs_copyfile(root .. '/docs/shot.tiff', cache .. '/001-x.tiff')
    local r = h.run_async(function()
      return { Documents.attachable({ n = 1, ext = 'tiff', path = cache .. '/001-x.tiff' }, { documents = o }) }
    end, 60000)
    local path, err, converted = r[1], r[2], r[3]
    assert(path, err)
    assert.is_true(converted)
    local img = assert(require('coagent.agent.images').from_file(path, 'shot'))
    assert.are.same({ 'image/png', 64, 32 }, { img.mime, img.width, img.height })
  end)

  it('reads a DOCX with its image listed and no data: URI', function()
    local doc, err = load('docs/report.docx')
    assert(doc, err)
    assert.is_truthy(doc.markdown:find('Quarterly report', 1, true), doc.markdown)
    assert.is_nil(doc.markdown:find('data:', 1, true))
    assert.are.equal(1, #doc.images)
    assert.are.equal('Company logo', doc.images[1].alt)
    local _, atts, errors, _, images = unpack(h.run_async(function()
      return { context.resolve_references('@docs/report.docx #docimage:docs/report.docx:1', { ws = ws, source = {}, documents = o }) }
    end, 60000))
    assert.are.same({}, errors)
    assert.is_truthy(atts[1]:find('Revenue grew', 1, true))
    assert.are.equal(1, #images)
    assert.are.same({ 10, 10 }, { images[1].width, images[1].height })
  end)

  it('reads a PPTX slide by slide with the images placed on their slide', function()
    if not vim.uv.fs_stat(root .. '/docs/deck.pptx') then
      pending('python-pptx is not installed with MarkItDown')
      return
    end
    local doc, err = load('docs/deck.pptx')
    assert(doc, err)
    assert.are.same({ '1', '2' }, vim.tbl_map(function(s)
      return s.name
    end, doc.sections))
    assert.are.equal('Architecture', doc.sections[2].title)
    assert.are.equal(1, #doc.images)
    assert.are.same({ { label = 'slide 2', section = '2' } }, doc.images[1].locations)
    local res = Documents.read(doc, { section = '2' }, 24000)
    assert.is_truthy(res.output:find('System diagram', 1, true), res.output)
    assert.is_nil(res.output:find('next year', 1, true))
  end)

  it('reads an XLSX sheet by name', function()
    if not vim.uv.fs_stat(root .. '/docs/book.xlsx') then
      pending('openpyxl is not installed with MarkItDown')
      return
    end
    local doc, err = load('docs/book.xlsx')
    assert(doc, err)
    assert.are.same({ 'Sales', 'Notes' }, vim.tbl_map(function(s)
      return s.name
    end, doc.sections))
    local res = Documents.read(doc, { section = 'Notes' }, 24000)
    assert.is_truthy(res.output:find('checked', 1, true), res.output)
    assert.is_nil(res.output:find('north', 1, true))
    for _, img in ipairs(doc.images) do
      assert.are.equal('Sales', img.locations[1].section)
    end
  end)

  it('reuses the cache on the second read', function()
    local a = assert(load('docs/paper.pdf'))
    Documents._reset()
    local t = vim.uv.hrtime()
    local b = assert(load('docs/paper.pdf'))
    assert.are.equal(a.key, b.key)
    -- no conversion: well under a Python start with MarkItDown's imports
    assert.is_true((vim.uv.hrtime() - t) / 1e6 < 2000)
  end)
end)
