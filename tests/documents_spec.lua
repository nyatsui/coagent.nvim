-- Documents read as Markdown (documents.enabled): @file / #file, the
-- read_document tool, the cache, embedded images and #docimage, and the
-- errors. The converter is a stub: a fake "python" shell script that answers
-- the helper's probe and writes the result files the real helper would (no
-- Python, MarkItDown or LibreOffice needed, nothing leaves the machine).
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local context = require('coagent.agent.context')
local Documents = require('coagent.agent.documents')
local Images = require('coagent.agent.images')
local Workspace = require('coagent.tools.workspace')
local Registry = require('coagent.tools')

local PROTECTED = require('coagent.config').defaults().auto.protected_globs

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function png(w, h_)
  return '\137PNG\r\n\26\n' .. '\0\0\0\13IHDR' .. be32(w) .. be32(h_) .. '\8\2\0\0\0' .. 'crc!' .. string.rep('\0', 16)
end

local MD = {
  pptx = table.concat({
    '<!-- Slide number: 1 -->',
    '# Intro',
    'Hello slides',
    '',
    '<!-- Slide number: 2 -->',
    '# Architecture',
    '![System diagram](Picture2.jpg)',
    '',
    '<!-- Slide number: 3 -->',
    '# Results',
    'accuracy 0.93',
  }, '\n'),
  xlsx = '## Data\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n## Summary\n| total | 3 |\n| --- | --- |\n',
  xls = '## Old\n| x |\n| --- |\n| 7 |\n',
  pdf = 'Page one text\n\fPage two text\n',
  docx = 'Report\r\n\r\nFirst paragraph.\r\n\r\n![logo](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA)\r\n\r\nAfter picture. <img src="data:image/gif;base64,R0lGOD">\r\n',
  doc = 'Legacy text from a doc\n',
}

local META = {
  pptx = {
    markitdown = '0.1.9',
    images = {
      { n = 1, file = 'images/001-aaaa.png', ext = 'png', bytes = 60, alt = 'System diagram', locations = { { label = 'slide 2', section = '2' } } },
      { n = 2, file = 'images/002-bbbb.emf', ext = 'emf', bytes = 10, alt = '', locations = { { label = 'slide 3', section = '3' } } },
      -- a path outside images/ is never used
      { n = 3, file = '../../etc/passwd', ext = 'png', bytes = 1, alt = 'evil', locations = {} },
    },
    notes = { '1 linked (external) image(s) were not fetched' },
  },
  xlsx = { markitdown = '0.1.9', sheets = { 'Data', 'Summary' }, images = {} },
  xls = { markitdown = '0.1.9', images = {} },
  pdf = {
    markitdown = '0.1.9',
    images = {
      { n = 1, file = 'images/001-dddd.png', ext = 'png', bytes = 60, alt = '', locations = { { label = 'page 1' }, { label = 'page 2' } } },
      -- a CMYK JPEG: a type the model takes, but not as it is
      { n = 2, file = 'images/002-eeee.jpg', ext = 'jpg', bytes = 60, alt = '', locations = { { label = 'page 2' } }, convert = true },
    },
  },
  docx = { markitdown = '0.1.9', images = { { n = 1, file = 'images/001-cccc.png', ext = 'png', bytes = 60, alt = 'logo', locations = { { label = 'document' } } } } },
  doc = { markitdown = '0.1.9', converted_from = 'docx (LibreOffice)', images = {} },
}

--- A fake python + helper outputs in `dir`. Settings files in `dir`:
---   probe.json (the probe's answer), sleep (seconds before converting),
---   error.json (printed with exit 2), calls.log (one line per conversion).
local function fake_converter(dir)
  vim.fn.mkdir(dir, 'p')
  for fmt, md in pairs(MD) do
    h.write(dir .. '/' .. fmt .. '.md', md)
    h.write(dir .. '/' .. fmt .. '.json', vim.json.encode(META[fmt]))
  end
  h.write(dir .. '/pptx-images/001-aaaa.png', png(32, 16))
  h.write(dir .. '/pptx-images/002-bbbb.emf', 'EMF-BYTES')
  h.write(dir .. '/docx-images/001-cccc.png', png(8, 8))
  h.write(dir .. '/pdf-images/001-dddd.png', png(12, 12))
  h.write(dir .. '/pdf-images/002-eeee.jpg', 'CMYK-JPEG')
  h.write(dir .. '/converted.png', png(40, 20))
  -- rendered pages (the fake writes all of them whatever --pages asks)
  h.write(dir .. '/page.png', png(1568, 882))
  local function pages_json(n, texts)
    local pages = {}
    for i = 1, n do
      pages[tostring(i)] = { file = string.format('pages/p%04d.png', i), text = texts and texts[i] or ('text of page ' .. i), width = 1568, height = 882 }
    end
    return vim.json.encode({ count = n, pages = pages })
  end
  h.write(dir .. '/pdf-pages.json', pages_json(2, { 'Page one text', 'Page two text' }))
  h.write(dir .. '/pptx-pages.json', pages_json(3))
  h.write(dir .. '/docx-pages.json', pages_json(1))
  h.write(dir .. '/probe.json', '{"markitdown": "0.1.9", "python": "3.12.0", "helper": "1"}')
  local script = table.concat({
    '#!/bin/sh',
    'D=' .. vim.fn.shellescape(dir),
    'cmd="$2"; shift 2',
    'if [ "$cmd" = probe ]; then cat "$D/probe.json"; exit 0; fi',
    'if [ "$cmd" = pages ]; then',
    '  while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; --format) fmt="$2"; shift ;; --pages) pages="$2"; shift ;; --soffice) soffice="$2"; shift ;; esac; shift; done',
    '  echo "$fmt pages=$pages soffice=${soffice:-}" >> "$D/pages.log"',
    '  if [ -f "$D/pages-error.json" ]; then cat "$D/pages-error.json"; exit 2; fi',
    '  mkdir -p "$out/pages"',
    '  n=$(sed -n \'s/.*"count": *\\([0-9]*\\).*/\\1/p\' "$D/$fmt-pages.json")',
    '  i=1; while [ "$i" -le "$n" ]; do cp "$D/page.png" "$out/pages/$(printf p%04d.png "$i")"; i=$((i+1)); done',
    '  cp "$D/$fmt-pages.json" "$out/pages.json"; exit 0',
    'fi',
    'if [ "$cmd" = topng ]; then',
    '  while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; --input) input="$2"; shift ;; --soffice) soffice="$2"; shift ;; esac; shift; done',
    '  echo "$(basename "$input") soffice=${soffice:-}" >> "$D/topng.log"',
    '  if [ -f "$D/topng-error.json" ]; then cat "$D/topng-error.json"; exit 2; fi',
    '  cp "$D/converted.png" "$out"; exit 0',
    'fi',
    'while [ $# -gt 0 ]; do',
    '  case "$1" in',
    '    --out) out="$2"; shift ;;',
    '    --input) input="$2"; shift ;;',
    '    --format) fmt="$2"; shift ;;',
    '    --soffice) soffice="$2"; shift ;;',
    '    --images) images=1 ;;',
    '  esac',
    '  shift',
    'done',
    'echo "$fmt images=${images:-0} soffice=${soffice:-} cwd=$(pwd)" >> "$D/calls.log"',
    'if [ -f "$D/sleep" ]; then sleep "$(cat "$D/sleep")"; fi',
    'if [ -f "$D/error.json" ]; then cat "$D/error.json"; exit 2; fi',
    'cp "$D/$fmt.md" "$out/content.md"',
    'cp "$D/$fmt.json" "$out/meta.json"',
    'if [ -n "$images" ] && [ -d "$D/$fmt-images" ]; then mkdir "$out/images" && cp "$D/$fmt-images/"* "$out/images/"; fi',
    'exit 0',
  }, '\n')
  h.write(dir .. '/python', script)
  vim.uv.fs_chmod(dir .. '/python', tonumber('755', 8))
  h.write(dir .. '/soffice', '#!/bin/sh\nexit 0\n')
  vim.uv.fs_chmod(dir .. '/soffice', tonumber('755', 8))
  return dir .. '/python'
end

local function calls(dir)
  local s = h.read(dir .. '/calls.log') or ''
  return vim.split(s, '\n', { trimempty = true })
end

local FILES = {
  ['docs/deck.pptx'] = 'PK\3\4 fake pptx',
  ['docs/book.xlsx'] = 'PK\3\4 fake xlsx',
  ['docs/old.xls'] = '\208\207\17\224 fake xls',
  ['docs/paper.pdf'] = '%PDF-1.4\0 fake pdf',
  ['docs/report.docx'] = 'PK\3\4 fake docx',
  ['docs/legacy.doc'] = '\208\207\17\224 fake doc',
  ['.env.pdf'] = '%PDF secret',
  ['notes.txt'] = 'plain text\n',
}

describe('documents', function()
  local root, fake, py, cfg, ws, orig_options

  before_each(function()
    Documents._reset()
    root = h.workspace(FILES)
    fake = vim.fn.tempname()
    py = fake_converter(fake)
    cfg = h.config(root, {
      documents = {
        enabled = true,
        python = py,
        legacy_doc = { converter = fake .. '/soffice' },
        cache = { dir = fake .. '/cache' },
      },
    })
    ws = Workspace.new(root, { protected_globs = PROTECTED })
    orig_options = require('coagent.config').options
  end)

  after_each(function()
    require('coagent.config').options = orig_options
  end)

  local function resolve(text, extra)
    local res = h.run_async(function()
      return { context.resolve_references(text, vim.tbl_extend('force', { ws = ws, source = {}, documents = cfg.documents }, extra or {})) }
    end)
    return res[1], res[2], res[3], res[4], res[5]
  end

  local function load(path, o)
    return h.run_async(function()
      return { Documents.load(ws:check(path), { documents = o or cfg.documents }) }
    end)
  end

  local function tool_ctx(extra)
    return vim.tbl_extend('force', { ws = ws, config = cfg }, extra or {})
  end

  local function read_document(args, ctx)
    ctx = ctx or tool_ctx()
    local prepared, err = Documents.tool.prepare(args, ctx)
    if not prepared then
      return { ok = false, output = 'Error: ' .. err }
    end
    return h.run_async(function()
      return Documents.tool.run(args, ctx, prepared)
    end)
  end

  it('converts each format through the helper and finds slides and sheets', function()
    for path, fmt in pairs({ ['docs/deck.pptx'] = 'pptx', ['docs/book.xlsx'] = 'xlsx', ['docs/old.xls'] = 'xls', ['docs/paper.pdf'] = 'pdf', ['docs/report.docx'] = 'docx', ['docs/legacy.doc'] = 'doc' }) do
      local doc, err = unpack(load(path))
      assert(doc, err)
      assert.are.equal(fmt, doc.format)
      assert.are.equal(path, doc.rel)
    end
    local log = calls(fake)
    assert.are.equal(6, #log)
    -- a private, empty working directory in the cache folder; images asked for
    for _, l in ipairs(log) do
      assert.is_truthy(l:find('images=1', 1, true), l)
      assert.is_truthy(l:find('cwd=' .. vim.uv.fs_realpath(fake) .. '/cache/.tmp-', 1, true), l)
    end
    -- .doc goes through LibreOffice (the converter found by its path)
    local doclog = vim.tbl_filter(function(l)
      return vim.startswith(l, 'doc ')
    end, log)[1]
    assert.is_truthy(doclog:find('soffice=' .. fake .. '/soffice', 1, true), doclog)

    local deck = load('docs/deck.pptx')[1]
    assert.are.same({ { '1', 'Intro', 1, 4 }, { '2', 'Architecture', 5, 8 }, { '3', 'Results', 9, 11 } }, vim.tbl_map(function(s)
      return { s.name, s.title, s.s, s.e }
    end, deck.sections))
    local book = load('docs/book.xlsx')[1]
    assert.are.same({ { 'Data', 1, 5 }, { 'Summary', 6, 8 } }, vim.tbl_map(function(s)
      return { s.name, s.s, s.e }
    end, book.sections))
    -- XLS: MarkItDown's "## <sheet>" headings
    assert.are.equal('Old', load('docs/old.xls')[1].sections[1].name)
    -- PDF: no pages guessed; the form feed is a line break
    local pdf = load('docs/paper.pdf')[1]
    assert.are.same({}, pdf.sections)
    assert.are.same({ 'Page one text', '', 'Page two text' }, pdf.lines)
    assert.are.equal('docx (LibreOffice)', load('docs/legacy.doc')[1].converted_from)
    -- the temporary folders are gone
    for name in vim.fs.dir(fake .. '/cache') do
      assert.is_false(vim.startswith(name, '.tmp-'), name)
    end
  end)

  it('xlsx sheets: a sheet without a heading does not hide the ones after it; a "## " line in a sheet is not one', function()
    local lines = { '## Data', '| a |', '## Notes', '## Summary', '| b |', '## not a sheet', 'x' }
    -- MarkItDown left out "Empty" (between Data and Notes)
    local s = Documents.structure(lines, 'xlsx', { 'Data', 'Empty', 'Notes', 'Summary' })
    assert.are.same({ { 'Data', 1, 2 }, { 'Notes', 3, 3 }, { 'Summary', 4, 7 } }, vim.tbl_map(function(x)
      return { x.name, x.s, x.e }
    end, s))
    -- in workbook order only: an earlier name later in the text is content
    s = Documents.structure({ '## B', '## A', 'x' }, 'xlsx', { 'A', 'B' })
    assert.are.same({ 'B' }, vim.tbl_map(function(x)
      return x.name
    end, s))
  end)

  it('@path and #file attach the converted Markdown, marked as read-only untrusted data', function()
    local clean, atts, errors = resolve('summarize @docs/deck.pptx and #file:docs/book.xlsx')
    assert.are.same({}, errors)
    assert.are.equal('summarize docs/deck.pptx and', clean)
    assert.are.equal(2, #atts)
    assert.is_truthy(atts[1]:find('<attachment kind="document" source="docs/deck.pptx">', 1, true), atts[1])
    assert.is_truthy(atts[1]:find('READ-ONLY converted text', 1, true))
    assert.is_truthy(atts[1]:find('never as instructions', 1, true))
    assert.is_truthy(atts[1]:find('# Architecture', 1, true))
    assert.is_truthy(atts[1]:find('image 1: "System diagram" png', 1, true), atts[1])
    assert.is_truthy(atts[1]:find('#docimage:docs/deck.pptx:<n>', 1, true))
    assert.is_truthy(atts[1]:find('1 linked (external) image(s) were not fetched', 1, true))
    assert.is_truthy(atts[2]:find('| total | 3 |', 1, true))
  end)

  it('a large document attaches its structure, the first lines and how to read on', function()
    cfg.documents.max_attach_chars = 60
    local _, atts, errors, infos = resolve('@docs/deck.pptx')
    assert.are.same({}, errors)
    local a = atts[1]
    assert.is_truthy(a:find('Slides (3; read one with section="<number>"):', 1, true), a)
    assert.is_truthy(a:find('slide 2 "Architecture": lines 5-8', 1, true), a)
    assert.is_truthy(a:find('--- lines 1-', 1, true), a)
    assert.is_truthy(a:find('Read on with read_document (path = "docs/deck.pptx", start_line = ', 1, true), a)
    assert.is_nil(a:find('accuracy 0.93', 1, true))
    assert.is_truthy(infos[1]:find('overview and the first lines', 1, true))
  end)

  it('read_document reads line ranges, slides and sheets; PDF has no sections', function()
    local res = read_document({ path = 'docs/deck.pptx' })
    assert.is_true(res.ok, res.output)
    assert.is_truthy(res.output:find('Slides (3', 1, true))
    assert.is_truthy(res.output:find('\n6\t# Architecture\n', 1, true), res.output)
    assert.is_truthy(res.output:find('[all 11 lines]', 1, true))
    res = read_document({ path = 'docs/deck.pptx', section = '2' })
    assert.is_truthy(res.output:find('Slide 2 "Architecture" (lines 5-8)', 1, true), res.output)
    assert.is_nil(res.output:find('\t# Results', 1, true))
    assert.is_truthy(res.output:find('image 1: "System diagram"', 1, true))
    -- images of other slides are not listed with this one
    assert.is_nil(res.output:find('image 2:', 1, true))
    res = read_document({ path = 'docs/deck.pptx', section = 'slide 3' })
    assert.is_truthy(res.output:find('11\taccuracy 0.93', 1, true), res.output)
    assert.is_truthy(res.output:find('(emf: sent as PNG after a local conversion)', 1, true), res.output)
    res = read_document({ path = 'docs/book.xlsx', section = 'summary' })
    assert.is_truthy(res.output:find('Sheet "Summary" (lines 6-8)', 1, true), res.output)
    res = read_document({ path = 'docs/book.xlsx', section = 'Nope' })
    assert.is_false(res.ok)
    assert.is_truthy(res.output:find('Available: Data, Summary', 1, true))
    res = read_document({ path = 'docs/deck.pptx', start_line = 9, end_line = 10 })
    assert.is_truthy(res.output:find('9\t<!-- Slide number: 3 -->\n10\t# Results\n[lines 9-10 of 11]', 1, true), res.output)
    res = read_document({ path = 'docs/paper.pdf', section = '1' })
    assert.is_false(res.ok)
    assert.is_truthy(res.output:find('PDF/DOCX pages are not known', 1, true))
    res = read_document({ path = 'docs/paper.pdf' })
    assert.is_truthy(res.output:find('No page numbers', 1, true))
    -- not a document / missing
    assert.is_truthy(read_document({ path = 'notes.txt' }).output:find('use read_file', 1, true))
    assert.is_truthy(read_document({ path = 'missing.pdf' }).output:find('not found', 1, true))
  end)

  it('keeps to max_tool_output_bytes and says where to continue', function()
    local long = {}
    for i = 1, 400 do
      long[i] = 'line ' .. i .. ' ' .. string.rep('x', 60)
    end
    h.write(fake .. '/pdf.md', table.concat(long, '\n'))
    cfg.limits.max_tool_output_bytes = 4096
    local res = read_document({ path = 'docs/paper.pdf' })
    assert.is_true(#res.output <= 4096, #res.output)
    local next_line = tonumber(res.output:match('continue with start_line=(%d+)'))
    assert.is_truthy(next_line, res.output)
    res = read_document({ path = 'docs/paper.pdf', start_line = next_line })
    assert.is_truthy(res.output:find('\n' .. next_line .. '\tline ' .. next_line .. ' ', 1, true), res.output)
    -- a section: the continuation keeps its end
    local res2 = read_document({ path = 'docs/paper.pdf', start_line = 1, end_line = 400 })
    assert.is_truthy(res2.output:find('continue with start_line=', 1, true))
  end)

  it('reuses the cache and converts again when the file or the settings change', function()
    assert(load('docs/deck.pptx')[1])
    Documents._reset() -- not from memory: from the cache folder
    local doc = assert(load('docs/deck.pptx')[1])
    assert.are.equal(1, #calls(fake))
    assert.is_truthy(vim.uv.fs_stat(doc.dir .. '/content.md'))
    -- changed file -> new key
    h.write(root .. '/docs/deck.pptx', 'PK\3\4 fake pptx, edited')
    local doc2 = assert(load('docs/deck.pptx')[1])
    assert.are_not.equal(doc.key, doc2.key)
    assert.are.equal(2, #calls(fake))
    -- other settings -> new key
    cfg.documents.extract_images = false
    local doc3 = assert(load('docs/deck.pptx')[1])
    assert.are.equal(3, #calls(fake))
    assert.are.same({}, doc3.images)
    assert.is_truthy(calls(fake)[3]:find('images=0', 1, true))
    -- another MarkItDown version -> new key
    Documents._reset()
    h.write(fake .. '/probe.json', '{"markitdown": "0.2.0"}')
    cfg.documents.extract_images = true
    assert(load('docs/deck.pptx')[1])
    assert.are.equal(4, #calls(fake))
  end)

  it('prunes entries past keep_days and the least recently used past max_bytes', function()
    local a = assert(load('docs/deck.pptx')[1])
    local b = assert(load('docs/book.xlsx')[1])
    local old = os.time() - 40 * 86400
    vim.uv.fs_utime(a.dir .. '/meta.json', old, old)
    Documents.prune(cfg.documents)
    assert.is_nil(vim.uv.fs_stat(a.dir))
    assert.is_truthy(vim.uv.fs_stat(b.dir))
    local c = assert(load('docs/paper.pdf')[1])
    vim.uv.fs_utime(b.dir .. '/meta.json', os.time() - 100, os.time() - 100)
    cfg.documents.cache.max_bytes = 1
    Documents.prune(cfg.documents, c.key)
    assert.is_nil(vim.uv.fs_stat(b.dir))
    assert.is_truthy(vim.uv.fs_stat(c.dir))
  end)

  it('cache.enabled = false keeps the result out of the cache folder', function()
    cfg.documents.cache.enabled = false
    local doc = assert(load('docs/deck.pptx')[1])
    assert.is_nil(vim.uv.fs_stat(fake .. '/cache/' .. doc.key))
    assert.is_truthy(vim.uv.fs_stat(doc.dir .. '/content.md'))
  end)

  it('lists embedded images (or none) and #docimage attaches one through the image path', function()
    local deck = assert(load('docs/deck.pptx')[1])
    -- the entry outside images/ is dropped
    assert.are.equal(2, #deck.images)
    assert.are.same({ 'png', 'emf' }, { deck.images[1].ext, deck.images[2].ext })
    assert.are.same({}, assert(load('docs/book.xlsx')[1]).images)
    local clean, atts, errors, _, images = resolve('what is in #docimage:docs/deck.pptx:1 ?')
    assert.are.same({}, errors)
    assert.are.same({}, atts)
    assert.are.equal(1, #images)
    assert.are.equal('docs/deck.pptx image 1 (slide 2)', images[1].label)
    assert.are.same({ 32, 16 }, { images[1].width, images[1].height })
    assert.are.equal('what is in [image 1: docs/deck.pptx image 1 (slide 2)] ?', clean)
    -- copied into the image store, like #image
    assert.is_truthy(vim.startswith(images[1].path, Images.dir()))
    -- numbers past the list; XLS has no images; no number
    local _, _, e2 = resolve('#docimage:docs/deck.pptx:9 #docimage:docs/old.xls:1 #docimage:docs/deck.pptx')
    assert.is_truthy(e2[1]:find('has 2 embedded images', 1, true), e2[1])
    assert.is_truthy(e2[2]:find('has 0 embedded images (images are not extracted from XLS files)', 1, true), e2[2])
    assert.is_truthy(e2[3]:find('requires a document and an image number', 1, true), e2[3])
  end)

  it('converts an image the model cannot take to PNG once, when it is attached', function()
    -- EMF: the helper's topng, with LibreOffice offered for EMF / WMF
    local _, _, errors, infos, images = resolve('#docimage:docs/deck.pptx:2')
    assert.are.same({}, errors)
    assert.are.equal(1, #images)
    assert.are.equal('docs/deck.pptx image 2 (slide 3)', images[1].label)
    assert.are.same({ 40, 20 }, { images[1].width, images[1].height })
    assert.is_truthy(infos[1]:find('EMF image converted to PNG', 1, true), infos[1])
    local log = vim.split(h.read(fake .. '/topng.log'), '\n', { trimempty = true })
    assert.are.same({ '002-bbbb.emf soffice=' .. fake .. '/soffice' }, log)
    -- the PNG is kept beside it: no second conversion
    Documents._reset()
    local _, _, e2, _, again = resolve('#docimage:docs/deck.pptx:2')
    assert.are.same({}, e2)
    assert.are.equal(1, #again)
    assert.are.equal(1, #vim.split(h.read(fake .. '/topng.log'), '\n', { trimempty = true }))
    -- PDF images: by page; a CMYK JPEG is converted too, a PNG is sent as it is
    local pdf = assert(load('docs/paper.pdf')[1])
    assert.are.same({ 'page 1', 'page 2' }, vim.tbl_map(function(l)
      return l.label
    end, pdf.images[1].locations))
    local _, _, e3, _, imgs = resolve('#docimage:docs/paper.pdf:1 #docimage:docs/paper.pdf:2')
    assert.are.same({}, e3)
    assert.are.same({ 'docs/paper.pdf image 1 (page 1, page 2)', 'docs/paper.pdf image 2 (page 2)' }, { imgs[1].label, imgs[2].label })
    assert.are.same({ 12, 12 }, { imgs[1].width, imgs[1].height })
    assert.are.same({ 40, 20 }, { imgs[2].width, imgs[2].height })
    assert.is_truthy(read_document({ path = 'docs/paper.pdf' }).output:find('image 2: jpg, 60 B, page 2 (jpg: sent as PNG after a local conversion)', 1, true))
    -- a conversion that fails says why and how to fix it
    h.write(fake .. '/topng-error.json', '{"error": "converting TIFF images to PNG needs Pillow", "kind": "missing_pillow"}')
    os.remove(pdf.images[2].path .. '.png')
    local _, _, e4, _, none = resolve('#docimage:docs/paper.pdf:2')
    assert.are.same({}, none)
    assert.is_truthy(e4[1]:find('could not be turned into PNG', 1, true), e4[1])
    assert.is_truthy(e4[1]:find('-m pip install pillow', 1, true), e4[1])
    -- no leftovers of the conversion in the cache entry
    for name in vim.fs.dir(vim.fs.dirname(pdf.images[2].path)) do
      assert.is_false(vim.startswith(name, '.topng-'), name)
    end
  end)

  describe('pages as pictures (read_images with a document)', function()
    local function log()
      return vim.split(h.read(fake .. '/pages.log') or '', '\n', { trimempty = true })
    end

    local function pages(path, spec)
      local r = h.run_async(function()
        return { Documents.page_images(ws:check(path), spec, { documents = cfg.documents }) }
      end)
      return r[1], r[2]
    end

    it('parses page lists and keeps to max_pages_per_read', function()
      assert.are.same({ 1, 3, 4 }, Documents.parse_pages('4, 1,3-4', 10))
      assert.are.same({ 2, 5 }, Documents.parse_pages({ 5, 2 }, 10))
      assert.is_truthy(select(2, Documents.parse_pages('1-11', 10)):find('at most 10', 1, true))
      assert.is_truthy(select(2, Documents.parse_pages('first', 10)):find('not a page list', 1, true))
      assert.is_truthy(select(2, Documents.parse_pages('', 10)):find('pages is required', 1, true))
    end)

    it('renders PDF pages once, each with the text of that page', function()
      local res, err = pages('docs/paper.pdf', '2,1,7')
      assert(res, err)
      assert.are.same({ 1, 2 }, vim.tbl_map(function(p)
        return p.n
      end, res.pages))
      assert.are.same({ 'Page one text', 'paper.pdf page 1', 1568, 882 }, { res.pages[1].text, res.pages[1].image.tag, res.pages[1].image.width, res.pages[1].image.height })
      assert.are.same({ 'page 7: the document has 2' }, res.notes)
      -- a PDF needs no LibreOffice; the pages that exist are cached
      assert.are.same({ 'pdf pages=1,2,7 soffice=' }, log())
      assert(pages('docs/paper.pdf', '1-2'))
      assert.are.equal(1, #log())
    end)

    it('pairs PPTX slides with MarkItDown\'s text of the slide; LibreOffice lays them out', function()
      local res = assert(pages('docs/deck.pptx', '3'))
      assert.are.equal('slide 3', res.pages[1].label)
      assert.are.equal('<!-- Slide number: 3 -->\n# Results\naccuracy 0.93', res.pages[1].text)
      assert.is_truthy(log()[1]:find('soffice=' .. fake .. '/soffice', 1, true), log()[1])
      -- DOCX pages are LibreOffice's pagination, and say so
      local d = assert(pages('docs/report.docx', '1'))
      assert.are.equal('page 1 (LibreOffice layout)', d.pages[1].label)
      -- not for spreadsheets
      local _, xerr = pages('docs/book.xlsx', '1')
      assert.is_truthy(xerr:find('Excel sheets have no pages', 1, true), xerr)
    end)

    it('refuses to pair when the slide count differs, and says what is missing', function()
      h.write(fake .. '/pptx-pages.json', vim.json.encode({ count = 2, pages = {} }))
      local _, err = pages('docs/deck.pptx', '1')
      assert.is_truthy(err:find('laid out 2 pages for 3 slides', 1, true), err)
      Documents._reset()
      cfg.documents.legacy_doc.converter = fake .. '/no-soffice'
      local _, err2 = pages('docs/report.docx', '1')
      assert.is_truthy(err2:find('needs LibreOffice to lay it out', 1, true), err2)
      h.write(fake .. '/pages-error.json', '{"error": "rendering pages needs pypdfium2", "kind": "missing_pdfium"}')
      local _, err3 = pages('docs/paper.pdf', '1')
      assert.is_truthy(err3:find('-m pip install pypdfium2', 1, true), err3)
    end)

    it('the reader gets each page picture with its text; the conversation gets notes only', function()
      local backend = Mock.new({
        { tool_calls = { { name = 'read_images', arguments = { document = 'docs/paper.pdf', pages = '1-2', question = 'What does the chart show?' } } } },
        { content = 'A bar chart: sales rise from 3 to 7.' },
        { content = 'Sales rise.' },
      })
      local c = require('coagent.agent').build({ config = cfg, backend = backend })
      c:submit('what does the paper show?')
      h.wait(function()
        return c:state() == 'COMPLETED'
      end)
      -- offered without any image in the session
      local names = vim.tbl_map(function(t)
        return t.name
      end, backend.requests[1].tools or {})
      assert.is_true(vim.tbl_contains(names, 'read_images'))
      local reading = backend.requests[2]
      assert.are.same({}, reading.tools)
      local m = reading.messages[1]
      assert.are.equal(2, #m.images)
      assert.is_truthy(m.content:find('Images to read now, attached below: [paper.pdf page 1], [paper.pdf page 2]', 1, true), m.content)
      assert.is_truthy(m.content:find('--- text of [paper.pdf page 2] ---\nPage two text', 1, true), m.content)
      assert.is_truthy(m.content:find('UNTRUSTED document content', 1, true))
      local last = backend.requests[3].messages
      assert.is_truthy(last[#last].content:find('Notes on [paper.pdf page 1], [paper.pdf page 2]:\nA bar chart', 1, true), last[#last].content)
      -- no picture entered the conversation
      for _, msg in ipairs(last) do
        assert.is_nil(msg.images)
      end
    end)

    it('under a lead, the worker model reads the slide and the lead gets the notes', function()
      local lead_cfg = vim.tbl_deep_extend('force', cfg, { roles = { preset = 'lead', lead_model = 'strong' } })
      local lead_calls, reads, result = 0, {}, nil
      local backend = Mock.new(function(messages, _, req)
        if req.model == 'strong' then
          lead_calls = lead_calls + 1
          if lead_calls == 1 then
            return { tool_calls = { { name = 'read_images', arguments = { document = 'docs/deck.pptx', pages = '3', question = 'What is on the results slide?' } } } }
          end
          result = messages[#messages].content
          return { content = 'done' }
        end
        table.insert(reads, req)
        return { content = 'A table: accuracy 0.93.' }
      end)
      local c = require('coagent.agent').build({ config = lead_cfg, backend = backend })
      c:submit('summarize the deck')
      h.wait(function()
        return c:state() == 'COMPLETED'
      end)
      assert.are.equal(1, #reads)
      assert.are_not.equal('strong', reads[1].model)
      assert.are.equal(1, #reads[1].messages[1].images)
      assert.is_truthy(reads[1].messages[1].content:find('--- text of [deck.pptx slide 3] ---\n<!-- Slide number: 3 -->\n# Results', 1, true), reads[1].messages[1].content)
      assert.is_truthy(result:find('Notes on [deck.pptx slide 3]:\nA table: accuracy 0.93.', 1, true), result)
    end)

    it('asks before reading pages of a protected or outside document, like read_document', function()
      local perms = require('coagent.agent.permissions').new(cfg, ws)
      local tool = require('coagent.agent.worker').read_tool
      local ctx = tool_ctx({ read_images = function() end })
      local prepared = assert(tool.prepare({ document = '.env.pdf', pages = '1', question = 'q' }, ctx))
      assert.are.equal('ask', perms:decide(tool, {}, prepared).action)
      prepared = assert(tool.prepare({ document = 'docs/paper.pdf', pages = '1', question = 'q' }, ctx))
      assert.are.equal('allow', perms:decide(tool, {}, prepared).action)
      local _, err = tool.prepare({ document = 'docs/book.xlsx', pages = '1', question = 'q' }, ctx)
      assert.is_truthy(err:find('PDF, PPTX, DOCX and DOC', 1, true))
      _, err = tool.prepare({ document = 'docs/paper.pdf', question = 'q' }, ctx)
      assert.is_truthy(err:find('pages is required', 1, true))
    end)
  end)

  it('never passes data: URIs to the model', function()
    local _, atts = resolve('@docs/report.docx')
    assert.is_nil(atts[1]:find('data:', 1, true), atts[1])
    assert.is_nil(atts[1]:find('base64', 1, true))
    assert.is_truthy(atts[1]:find('![logo](embedded image)', 1, true), atts[1])
    local res = read_document({ path = 'docs/report.docx' })
    assert.is_nil(res.output:find('data:', 1, true))
    assert.is_truthy(res.output:find('image 1: "logo" png', 1, true))
    assert.are.equal('a data-uri-omitted b', Documents.sanitize('a data:text/html;base64,PGI+ b'))
  end)

  it('refuses documents outside the workspace or protected, like other files', function()
    local outside = vim.fn.tempname() .. '.pdf'
    h.write(outside, '%PDF')
    local _, atts, errors = resolve('#file:' .. outside .. ' @.env.pdf #docimage:.env.pdf:1 #docimage:' .. outside .. ':1')
    assert.are.same({}, atts)
    assert.is_truthy(errors[1]:find('is outside the workspace', 1, true), errors[1])
    assert.is_truthy(errors[2]:find('is a protected file', 1, true), errors[2])
    assert.is_truthy(errors[3]:find('is a protected file', 1, true), errors[3])
    assert.is_truthy(errors[4]:find('is outside the workspace', 1, true), errors[4])
    -- a symlink that leaves the workspace counts as outside
    vim.uv.fs_symlink(outside, root .. '/docs/link.pdf')
    local _, _, e2 = resolve('#file:docs/link.pdf')
    assert.is_truthy(e2[1]:find('outside the workspace', 1, true), e2[1])
    assert.are.equal(0, #calls(fake))
    -- the tool: the same approval rules as read_file (protected / outside ask)
    local perms = require('coagent.agent.permissions').new(cfg, ws)
    local prepared = assert(Documents.tool.prepare({ path = '.env.pdf' }, tool_ctx()))
    assert.are.equal('ask', perms:decide(Documents.tool, { path = '.env.pdf' }, prepared).action)
    prepared = assert(Documents.tool.prepare({ path = outside }, tool_ctx()))
    assert.are.equal('ask', perms:decide(Documents.tool, { path = outside }, prepared).action)
    prepared = assert(Documents.tool.prepare({ path = 'docs/paper.pdf' }, tool_ctx()))
    assert.are.equal('allow', perms:decide(Documents.tool, { path = 'docs/paper.pdf' }, prepared).action)
  end)

  it('says how to install MarkItDown when it is missing, and when Python is missing', function()
    h.write(fake .. '/probe.json', '{"markitdown": null, "python": "3.12.0"}')
    local _, err = unpack(load('docs/paper.pdf'))
    assert.is_truthy(err:find('MarkItDown is not installed for ' .. py, 1, true), err)
    assert.is_truthy(err:find("pip install 'markitdown[pdf,docx,pptx,xlsx,xls]'", 1, true), err)
    assert.is_truthy(err:find('python3 -m venv ~/.local/share/coagent-markitdown', 1, true), err)
    assert.are.equal(0, #calls(fake))
    -- the helper's own report (an import failing at conversion time)
    h.write(fake .. '/probe.json', '{"markitdown": "0.1.9"}')
    h.write(fake .. '/error.json', '{"error": "No module named markitdown", "kind": "missing_markitdown"}')
    _, err = unpack(load('docs/paper.pdf'))
    assert.is_truthy(err:find('coagent never installs it', 1, true), err)
    -- a missing optional dependency of MarkItDown
    h.write(fake .. '/error.json', '{"error": "PdfConverter needs pdfminer", "kind": "missing_dependency"}')
    _, err = unpack(load('docs/paper.pdf'))
    assert.is_truthy(err:find("-m pip install 'markitdown[pdf]'", 1, true), err)
    local o = vim.deepcopy(cfg.documents)
    o.python = fake .. '/no-such-python'
    Documents._reset()
    _, err = unpack(load('docs/paper.pdf', o))
    assert.is_truthy(err:find('Python was not found', 1, true), err)
    -- the tool reports it as its result
    local res = read_document({ path = 'docs/paper.pdf' }, tool_ctx({ config = vim.tbl_extend('force', cfg, { documents = o }) }))
    assert.is_false(res.ok)
    assert.is_truthy(res.output:find('Python was not found', 1, true))
  end)

  it('.doc needs LibreOffice: a clear error when soffice is missing or .doc is off', function()
    cfg.documents.legacy_doc.converter = fake .. '/no-soffice'
    local _, err = unpack(load('docs/legacy.doc'))
    assert.is_truthy(err:find('Reading .doc files needs LibreOffice', 1, true), err)
    assert.is_truthy(err:find('brew install --cask libreoffice', 1, true), err)
    assert.is_truthy(err:find('save the file as .docx', 1, true), err)
    cfg.documents.legacy_doc.enabled = false
    _, err = unpack(load('docs/legacy.doc'))
    assert.is_truthy(err:find('legacy_doc.enabled = false', 1, true), err)
    assert.are.equal(0, #calls(fake))
    -- other formats are unaffected
    assert(load('docs/report.docx')[1])
  end)

  it('stops a conversion at the timeout and on cancel, and cleans up', function()
    h.write(fake .. '/sleep', '5')
    cfg.documents.timeout_ms = 300
    local _, err = unpack(load('docs/paper.pdf'))
    assert.is_truthy(err:find('took longer than', 1, true), err)
    assert.is_truthy(err:find('documents.timeout_ms', 1, true))
    cfg.documents.timeout_ms = 60000
    local cancel
    local started = vim.uv.now()
    local res = h.run_async(function()
      vim.defer_fn(function()
        assert(cancel, 'set_cancel was given a function')
        cancel()
      end, 300)
      return { Documents.load(ws:check('docs/paper.pdf'), {
        documents = cfg.documents,
        set_cancel = function(fn)
          cancel = fn or cancel
        end,
      }) }
    end)
    assert.is_nil(res[1])
    assert.is_truthy(res[2]:find('cancelled', 1, true), res[2])
    assert.is_true(vim.uv.now() - started < 4000)
    for name in vim.fs.dir(fake .. '/cache') do
      assert.is_false(vim.startswith(name, '.tmp-'), name)
    end
    -- a size over max_file_bytes is refused before anything runs
    cfg.documents.max_file_bytes = 4
    local _, e2 = unpack(load('docs/report.docx'))
    assert.is_truthy(e2:find('documents.max_file_bytes', 1, true), e2)
  end)

  it('read_file on a document hands it to read_document', function()
    local fs = require('coagent.tools.fs')
    local ctx = tool_ctx()
    local prepared = assert(fs.read_file.prepare({ path = 'docs/book.xlsx' }, ctx))
    local res = h.run_async(function()
      return fs.read_file.run({ path = 'docs/book.xlsx' }, ctx, prepared)
    end)
    assert.is_true(res.ok, res.output)
    assert.is_truthy(res.output:find('read_file on a document', 1, true))
    assert.is_truthy(res.output:find('| total | 3 |', 1, true))
  end)

  it('a task offers read_document and its result reaches the model', function()
    local backend = Mock.new({
      { tool_calls = { { name = 'read_document', arguments = { path = 'docs/deck.pptx', section = '3' } } } },
      { content = 'accuracy is 0.93' },
    })
    local c = require('coagent.agent').build({ config = cfg, backend = backend })
    c:submit('what does the deck say?')
    h.wait(function()
      return c:state() == 'COMPLETED'
    end)
    local names = vim.tbl_map(function(t)
      return t.name
    end, backend.requests[1].tools or {})
    assert.is_true(vim.tbl_contains(names, 'read_document'))
    local last = backend.requests[2].messages
    local tool_msg = last[#last]
    assert.are.equal('tool', tool_msg.role)
    assert.is_truthy(tool_msg.content:find('11\taccuracy 0.93', 1, true), tool_msg.content)
  end)

  describe('when disabled (the default)', function()
    before_each(function()
      cfg.documents.enabled = false
    end)

    it('offers no tool and changes nothing', function()
      local reg = Registry.new()
      local function names(config)
        return vim.tbl_map(function(t)
          return t.name
        end, reg:schemas(function()
          return true
        end, config))
      end
      assert.is_false(vim.tbl_contains(names(cfg), 'read_document'))
      assert.is_false(vim.tbl_contains(names(require('coagent.config').defaults()), 'read_document'))
      cfg.documents.enabled = true
      assert.is_true(vim.tbl_contains(names(cfg), 'read_document'))
      cfg.documents.enabled = false
      -- @file.pdf is a binary file as before; #docimage says what it needs
      local _, atts, errors = resolve('@docs/paper.pdf #docimage:docs/deck.pptx:1')
      assert.are.same({}, atts)
      assert.is_truthy(errors[1]:find('looks like a binary file', 1, true), errors[1])
      assert.is_truthy(errors[2]:find('documents.enabled = true', 1, true), errors[2])
      -- read_file as before
      local fs = require('coagent.tools.fs')
      local ctx = tool_ctx()
      local res = h.run_async(function()
        return fs.read_file.run({ path = 'docs/paper.pdf' }, ctx, assert(fs.read_file.prepare({ path = 'docs/paper.pdf' }, ctx)))
      end)
      assert.is_truthy(res.output:find('looks like a binary file', 1, true))
      -- a call anyway is refused
      local _, perr = Documents.tool.prepare({ path = 'docs/paper.pdf' }, ctx)
      assert.is_truthy(perr:find('documents.enabled = false', 1, true))
      assert.are.equal(0, #calls(fake))
      -- #docimage is not completed
      require('coagent.config').options = vim.tbl_deep_extend('force', require('coagent.config').defaults(), {})
      local _, items = require('coagent.ui.slash').complete_reference('#doc')
      assert.are.same({}, items)
      require('coagent.config').options.documents.enabled = true
      _, items = require('coagent.ui.slash').complete_reference('#doc')
      assert.are.equal('#docimage:', items[1].word)
    end)

    it('a task sends no read_document definition', function()
      local backend = Mock.new({ { content = 'ok' } })
      local c = require('coagent.agent').build({ config = cfg, backend = backend })
      c:submit('hello')
      h.wait(function()
        return c:state() == 'COMPLETED'
      end)
      local names = vim.tbl_map(function(t)
        return t.name
      end, backend.requests[1].tools or {})
      assert.is_false(vim.tbl_contains(names, 'read_document'))
      assert.is_true(vim.tbl_contains(names, 'read_file'))
    end)
  end)

  it('documents settings are flagged as sensitive by /config', function()
    local Settings = require('coagent.agent.settings')
    local lines = Settings.describe({ { path = 'documents.python', value = '/x/python', old = 'python3' } })
    assert.is_truthy(lines[1]:find('changes what runs without asking', 1, true), lines[1])
    assert(Settings.validate('documents.enabled', true))
    assert(Settings.validate('documents.cache.keep_days', 7))
    assert.is_nil((Settings.validate('documents.enabled', 'yes')))
  end)
end)
