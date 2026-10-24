-- /skills extract: drafts SKILL.md files from conversations, the ledger and
-- the experiment log; nothing is saved until :w.
local h = require('tests.helpers')
local Mock = require('coagent.backend.mock')
local X = require('coagent.agent.skill_extract')
local Skills = require('coagent.agent.skills')

describe('/skills extract', function()
  local agent, backend, userdir, reply

  local function setup()
    userdir = vim.fn.tempname()
    vim.fn.mkdir(userdir .. '/gpu-train', 'p')
    h.write(userdir .. '/gpu-train/SKILL.md', '---\nname: gpu-train\ndescription: old way to train\n---\n\n1. python train.py\n')
    backend = Mock.new(function(_, _, req)
      if req.system_prompt == X.PROMPT then
        return { content = vim.json.encode(reply) }
      end
      return { content = 'ok' }
    end)
    agent = require('coagent')
    agent._reset()
    agent.setup({
      backend = backend,
      root = h.workspace({ ['train.py'] = 'print(1)\n' }),
      session = { persist = false },
      ledger = { dir = vim.fn.tempname() },
      skills = { paths = { userdir } },
    })
    return agent.controller()
  end

  after_each(function()
    if agent then
      agent._reset()
    end
    vim.cmd('silent! tabonly! | silent! only!')
  end)

  local function drafts_open()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].coagent_skill_draft then
        out[vim.b[b].coagent_skill_draft] = b
      end
    end
    return out
  end

  it('drafts new skills and updates of existing ones as unsaved buffers; :w saves and reloads', function()
    local c = setup()
    c.ledger:ensure()
    c.ledger:add_finding({ title = 'lr 1e-3 diverges', finding = 'use 3e-4', source = 'you' })
    c:_add({ type = 'user', text = 'GPU サーバーで学習して、ベストと比べて。' })
    c:_add({ type = 'assistant', text = 'CUDA_VISIBLE_DEVICES=1 python train.py --lr 3e-4 で実行しました。' })
    reply = {
      skills = {
        { name = 'gpu-train', update_of = 'gpu-train', description = 'GPU サーバーで学習する: "best" と比較', body = '# GPU 学習\n1. `CUDA_VISIBLE_DEVICES=1 python train.py --lr 3e-4`\n2. lr 1e-3 は発散する', why = 'twice in the chat' },
        { name = 'eval-plot', description = 'When asked to evaluate and plot: run eval and save figures', body = '1. python eval.py\n2. python plot.py', why = 'recurring' },
        { name = 'Bad Name!', description = 'x', body = 'y' },
      },
    }
    assert.is_true(agent.skills('extract'))
    assert.is_true(h.wait(function()
      return drafts_open()['eval-plot'] ~= nil
    end))
    local req = backend.requests[#backend.requests]
    local user = req.messages[1].content
    assert.is_truthy(user:find('<existing_skills>', 1, true))
    assert.is_truthy(user:find('name: gpu-train', 1, true))
    assert.is_truthy(user:find('lr 1e-3 diverges', 1, true), 'ledger findings')
    assert.is_truthy(user:find('GPU サーバーで学習して', 1, true), 'the conversation')
    local open = drafts_open()
    assert.is_nil(open['bad name!'])
    -- nothing saved yet
    assert.is_nil(vim.uv.fs_stat(userdir .. '/eval-plot'))
    assert.is_true(vim.bo[open['eval-plot']].modified)
    assert.are.equal('1. python train.py\n', h.read(userdir .. '/gpu-train/SKILL.md'):match('\n\n(.*)$'))
    -- the update targets the existing file; its description survives quoting
    assert.are.equal(vim.uv.fs_realpath(userdir .. '/gpu-train/SKILL.md'), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(open['gpu-train'])))
    vim.api.nvim_buf_call(open['eval-plot'], function()
      vim.cmd('silent write')
    end)
    vim.api.nvim_buf_call(open['gpu-train'], function()
      vim.cmd('silent write')
    end)
    assert.is_truthy(vim.uv.fs_stat(userdir .. '/eval-plot/SKILL.md'))
    local s = c.skills:get('gpu-train')
    assert.are.equal('GPU サーバーで学習する: "best" と比較', s.description)
    assert.is_truthy(c.skills:get('eval-plot'))
    local meta, body = Skills.parse(h.read(userdir .. '/gpu-train/SKILL.md'))
    assert.are.equal('gpu-train', meta.name)
    assert.is_truthy(body:find('lr 1e-3 は発散する', 1, true))
  end)

  it('to the repository with "repo"; says so when nothing recurs', function()
    local c = setup()
    c:_add({ type = 'user', text = 'hi' })
    reply = { skills = { { name = 'run-tests', description = 'run the tests', body = '1. make test' } } }
    agent.skills('extract repo tests')
    assert.is_true(h.wait(function()
      return drafts_open()['run-tests'] ~= nil
    end))
    assert.are.equal(c.ws.root .. '/.agents/skills/run-tests/SKILL.md', vim.api.nvim_buf_get_name(drafts_open()['run-tests']))
    assert.is_truthy(backend.requests[#backend.requests].messages[1].content:find('Focus: tests', 1, true))
    vim.cmd('silent! tabonly! | silent! only!')
    reply = { skills = {} }
    agent.skills('extract')
    assert.is_true(h.wait(function()
      for _, it in ipairs(c.session.items) do
        if it.type == 'notice' and (it.text or ''):find('no recurring procedure found', 1, true) then
          return true
        end
      end
    end))
  end)
end)
