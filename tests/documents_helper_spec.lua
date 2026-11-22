-- The bundled Python helper (python/coagent_markitdown.py) run for real with
-- the system python3: image extraction from OOXML packages (standard library
-- only), its limits and hostile packages, and conversion through a stand-in
-- `markitdown` module (the real MarkItDown is in documents_integration_spec).
-- Skipped when python3 is not installed.
local h = require('tests.helpers')
local Documents = require('coagent.agent.documents')
local Workspace = require('coagent.tools.workspace')

local PY = vim.fn.exepath('python3')
local FIXTURES = vim.fn.getcwd() .. '/tests/fixtures/documents/make_ooxml.py'

local function helper(args, env)
  local argv = { PY, '-S', Documents.helper() }
  vim.list_extend(argv, args)
  return vim.system(argv, { text = true, env = vim.tbl_extend('force', { PYTHONDONTWRITEBYTECODE = '1' }, env or {}) }):wait(30000)
end

local function meta(dir)
  return vim.json.decode(h.read(dir .. '/meta.json'))
end

if PY == '' then
  describe('document helper', function()
    pending('python3 is not installed')
  end)
  return
end

describe('document helper', function()
  local src, out

  before_each(function()
    src = vim.fn.tempname()
    out = vim.fn.tempname()
    vim.fn.mkdir(out, 'p')
    local res = vim.system({ PY, FIXTURES, src }):wait(30000)
    assert(res.code == 0, res.stderr)
  end)

  it('extracts PPTX images per slide in presentation order, and nothing outside the package', function()
    local res = helper({ 'images', '--input', src .. '/deck.pptx', '--out', out, '--format', 'pptx' })
    assert.are.equal(0, res.code, res.stdout .. res.stderr)
    local m = meta(out)
    assert.are.equal(2, #m.images)
    -- slide2.xml is the first slide; the same picture is on both slides once
    assert.are.equal('Shown first', m.images[1].alt)
    assert.are.same({ { label = 'slide 1', section = '1' }, { label = 'slide 2', section = '2' } }, m.images[1].locations)
    assert.are.equal('Blue square', m.images[2].alt)
    assert.are.same({ { label = 'slide 2', section = '2' } }, m.images[2].locations)
    assert.is_truthy(m.images[1].file:match('^images/001%-%x+%.png$'), m.images[1].file)
    -- original bytes
    assert.are.equal('\137PNG', h.read(out .. '/' .. m.images[1].file):sub(1, 4))
    assert.are.same({ '1 image reference(s) pointing outside the package were ignored', '1 linked (external) image(s) were not fetched' }, m.notes)
    -- nothing but images/ and meta.json was written; no evil.png anywhere
    local names = {}
    for name in vim.fs.dir(vim.fs.dirname(out), { depth = 4 }) do
      if name:find('evil', 1, true) then
        table.insert(names, name)
      end
    end
    assert.are.same({}, names)
    local files = {}
    for name in vim.fs.dir(out) do
      table.insert(files, name)
    end
    table.sort(files)
    assert.are.same({ 'images', 'meta.json' }, files)
  end)

  it('lists DOCX images in document order and XLSX images by sheet', function()
    assert.are.equal(0, helper({ 'images', '--input', src .. '/report.docx', '--out', out, '--format', 'docx' }).code)
    local m = meta(out)
    assert.are.same({ 'Logo', 'Chart' }, { m.images[1].alt, m.images[2].alt })
    assert.are.same({ 'png', 'jpeg' }, { m.images[1].ext, m.images[2].ext })
    assert.are.same({ { label = 'document' } }, m.images[1].locations)
    local out2 = vim.fn.tempname()
    vim.fn.mkdir(out2, 'p')
    assert.are.equal(0, helper({ 'images', '--input', src .. '/book.xlsx', '--out', out2, '--format', 'xlsx' }).code)
    m = meta(out2)
    assert.are.same({ 'Data', 'Charts' }, m.sheets)
    assert.are.same({ { label = 'sheet "Charts"', section = 'Charts' } }, m.images[1].locations)
    -- a package without images
    local out3 = vim.fn.tempname()
    vim.fn.mkdir(out3, 'p')
    assert.are.equal(0, helper({ 'images', '--input', src .. '/plain.docx', '--out', out3, '--format', 'docx' }).code)
    assert.are.same({}, meta(out3).images)
    assert.is_nil(vim.uv.fs_stat(out3 .. '/images'))
  end)

  it('keeps to the image limits', function()
    local res = helper({ 'images', '--input', src .. '/deck.pptx', '--out', out, '--format', 'pptx', '--max-images', '1' })
    assert.are.equal(0, res.code)
    local m = meta(out)
    assert.are.equal(1, #m.images)
    assert.is_truthy(table.concat(m.notes, '\n'):find('more than 1 images', 1, true))
    local out2 = vim.fn.tempname()
    vim.fn.mkdir(out2, 'p')
    helper({ 'images', '--input', src .. '/deck.pptx', '--out', out2, '--format', 'pptx', '--max-image-bytes', '10' })
    m = meta(out2)
    assert.are.same({}, m.images)
    assert.is_truthy(table.concat(m.notes, '\n'):find('larger than documents.max_image_bytes', 1, true))
    local out3 = vim.fn.tempname()
    vim.fn.mkdir(out3, 'p')
    helper({ 'images', '--input', src .. '/deck.pptx', '--out', out3, '--format', 'pptx', '--max-total-image-bytes', '80' })
    assert.are.equal(1, #meta(out3).images)
  end)

  it('without pdfminer.six or Pillow it says what is missing', function()
    local pdf = src .. '/x.pdf'
    h.write(pdf, '%PDF-1.4\n%%EOF\n')
    local res = helper({ 'images', '--input', pdf, '--out', out, '--format', 'pdf' }, { PYTHONPATH = vim.fn.tempname() })
    assert.are.equal(0, res.code, res.stdout .. res.stderr)
    local m = meta(out)
    -- the system python3 may have pdfminer.six; then the empty PDF has no images
    assert.are.same({}, m.images)
    if #m.notes > 0 then
      assert.is_truthy(m.notes[1]:find('pdfminer.six is not installed', 1, true) or m.notes[1]:find('could not be read', 1, true), m.notes[1])
    end
    local has_pil = vim.system({ PY, '-S', '-c', 'import PIL' }):wait().code == 0
    if not has_pil then
      h.write(src .. '/a.tiff', 'II*\0')
      res = helper({ 'topng', '--input', src .. '/a.tiff', '--out', out .. '/a.png' })
      assert.are.equal(2, res.code)
      assert.are.equal('missing_pillow', vim.json.decode(res.stdout).kind)
    end
  end)

  it('turns EMF into PNG with LibreOffice (a stand-in soffice here)', function()
    local work = vim.fn.tempname()
    vim.fn.mkdir(work, 'p')
    h.write(work .. '/001-a.emf', 'EMF')
    h.write(work .. '/pic.png', '\137PNG\r\n\26\n' .. string.rep('\0', 40))
    local lo = work .. '/soffice'
    h.write(lo, table.concat({
      '#!/bin/sh',
      'echo "$@" > ' .. vim.fn.shellescape(work .. '/lo-args'),
      'while [ $# -gt 0 ]; do [ "$1" = --outdir ] && od="$2"; last="$1"; shift; done',
      'cp ' .. vim.fn.shellescape(work .. '/pic.png') .. ' "$od/$(basename "$last" .emf).png"',
    }, '\n'))
    vim.uv.fs_chmod(lo, tonumber('755', 8))
    -- with -S: no Pillow from site-packages, the PNG is LibreOffice's as it is
    local res = helper({ 'topng', '--input', work .. '/001-a.emf', '--out', work .. '/001-a.emf.png', '--soffice', lo })
    assert.are.equal(0, res.code, res.stdout .. res.stderr)
    assert.are.equal('\137PNG', h.read(work .. '/001-a.emf.png'):sub(1, 4))
    assert.is_truthy(h.read(work .. '/lo-args'):find('--convert-to png', 1, true))
    res = helper({ 'topng', '--input', work .. '/001-a.emf', '--out', work .. '/b.png' })
    assert.are.equal(2, res.code)
    assert.are.equal('missing_soffice', vim.json.decode(res.stdout).kind)
  end)

  it('pages: says what is missing (LibreOffice for PPTX, pypdfium2 for rendering)', function()
    local res = helper({ 'pages', '--input', src .. '/deck.pptx', '--out', out, '--format', 'pptx', '--pages', '1' })
    assert.are.equal(2, res.code)
    assert.are.equal('missing_soffice', vim.json.decode(res.stdout).kind)
    -- -S: no site-packages, so no pypdfium2
    h.write(src .. '/x.pdf', '%PDF-1.4\n%%EOF\n')
    res = helper({ 'pages', '--input', src .. '/x.pdf', '--out', out, '--format', 'pdf', '--pages', '1' })
    assert.are.equal(2, res.code)
    assert.are.equal('missing_pdfium', vim.json.decode(res.stdout).kind)
  end)

  it('probes MarkItDown: missing, or its version', function()
    local res = helper({ 'probe' }, { PYTHONPATH = vim.fn.tempname() })
    assert.are.equal(0, res.code)
    assert.are.equal(vim.NIL, vim.json.decode(res.stdout).markitdown)
    local fake = vim.fn.tempname()
    h.write(fake .. '/markitdown/__init__.py', '__version__ = "9.9.9"\n')
    res = helper({ 'probe' }, { PYTHONPATH = fake })
    assert.are.equal('9.9.9', vim.json.decode(res.stdout).markitdown)
  end)

  describe('with a stand-in MarkItDown', function()
    local fake, saved

    before_each(function()
      fake = vim.fn.tempname()
      h.write(fake .. '/markitdown/__init__.py', table.concat({
        'import os',
        '__version__ = "9.9.9"',
        'class _Result:',
        '    def __init__(self, text):',
        '        self.markdown = text',
        'class MarkItDown:',
        '    def __init__(self, **kw):',
        '        # no plugins, no LLM client, no Document Intelligence',
        '        assert kw == {"enable_plugins": False}, kw',
        '    def convert_local(self, path):',
        '        if path.endswith("broken.pdf"):',
        '            raise ValueError("cannot parse")',
        '        return _Result("converted " + os.path.basename(path) + "\\n![logo](data:image/png;base64...)\\n")',
      }, '\n'))
      saved = vim.env.PYTHONPATH
      vim.env.PYTHONPATH = fake
      Documents._reset()
    end)

    after_each(function()
      vim.env.PYTHONPATH = saved
    end)

    it('converts and extracts in one run; the cache entry is private and has no data: URI', function()
      local root = h.workspace({})
      vim.fn.mkdir(root .. '/docs', 'p')
      vim.uv.fs_copyfile(src .. '/report.docx', root .. '/docs/report.docx')
      local cache = vim.fn.tempname()
      local o = { enabled = true, python = PY, cache = { dir = cache } }
      local ws = Workspace.new(root, {})
      local doc, err = unpack(h.run_async(function()
        return { Documents.load(ws:check('docs/report.docx'), { documents = o }) }
      end))
      assert(doc, err)
      assert.are.equal('9.9.9', doc.version)
      assert.are.same({ 'converted report.docx', '![logo](embedded image)' }, doc.lines)
      assert.are.equal(2, #doc.images)
      assert.is_truthy(vim.uv.fs_stat(doc.images[1].path))
      assert.are.equal(tonumber('700', 8), vim.uv.fs_stat(cache).mode % 512)
      assert.are.equal(tonumber('700', 8), vim.uv.fs_stat(doc.dir).mode % 512)
      assert.is_nil(h.read(doc.dir .. '/content.md'):find('data:', 1, true))
      -- the helper's working folder is gone; no __pycache__ next to the helper
      local left = {}
      for name in vim.fs.dir(doc.dir) do
        table.insert(left, name)
      end
      table.sort(left)
      assert.are.same({ 'content.md', 'images', 'meta.json' }, left)
      assert.is_nil(vim.uv.fs_stat(vim.fs.dirname(Documents.helper()) .. '/__pycache__'))
      -- a conversion error is reported, nothing is cached
      h.write(root .. '/docs/broken.pdf', '%PDF')
      local none, err2 = unpack(h.run_async(function()
        return { Documents.load(ws:check('docs/broken.pdf'), { documents = o }) }
      end))
      assert.is_nil(none)
      assert.is_truthy(err2:find('conversion failed: ValueError: cannot parse', 1, true), err2)
    end)

    it('.doc goes through LibreOffice with a throwaway profile; a missing soffice is reported', function()
      local work = vim.fn.tempname()
      vim.fn.mkdir(work, 'p')
      h.write(work .. '/legacy.doc', 'old')
      -- a stand-in soffice: records its arguments, writes <stem>.docx to --outdir
      local fake_lo = work .. '/soffice'
      h.write(fake_lo, table.concat({
        '#!/bin/sh',
        'echo "$@" > ' .. vim.fn.shellescape(work .. '/lo-args'),
        'while [ $# -gt 0 ]; do [ "$1" = --outdir ] && od="$2"; last="$1"; shift; done',
        'cp ' .. vim.fn.shellescape(src .. '/report.docx') .. ' "$od/$(basename "$last" .doc).docx"',
      }, '\n'))
      vim.uv.fs_chmod(fake_lo, tonumber('755', 8))
      local out1 = vim.fn.tempname()
      vim.fn.mkdir(out1, 'p')
      local res = helper({ 'convert', '--input', work .. '/legacy.doc', '--out', out1, '--format', 'doc', '--images', '--soffice', fake_lo }, { PYTHONPATH = fake })
      assert.are.equal(0, res.code, res.stdout .. res.stderr)
      assert.are.equal('converted legacy.docx\n![logo](data:image/png;base64...)\n', h.read(out1 .. '/content.md'))
      local m = meta(out1)
      assert.are.equal('docx (LibreOffice)', m.converted_from)
      assert.are.equal(2, #m.images)
      local args = h.read(work .. '/lo-args')
      assert.is_truthy(args:find('-env:UserInstallation=file://', 1, true), args)
      assert.is_truthy(args:find('--headless --norestore', 1, true), args)
      local out2 = vim.fn.tempname()
      vim.fn.mkdir(out2, 'p')
      res = helper({ 'convert', '--input', work .. '/legacy.doc', '--out', out2, '--format', 'doc', '--soffice', work .. '/missing' }, { PYTHONPATH = fake })
      assert.are.equal(2, res.code)
      assert.are.equal('missing_soffice', vim.json.decode(res.stdout).kind)
    end)
  end)
end)
