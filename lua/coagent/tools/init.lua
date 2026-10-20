--- Tool registry.
---
--- A tool is { name, kind = 'read'|'write'|'exec', description, schema,
---   title(args, prepared) -> string,          -- one-line timeline label
---   prepare(args, ctx) -> prepared | nil, err, -- validation + preview (diff), no side effects
---   run(args, ctx, prepared, approval) -> { ok, output, summary?, display?, meta? } }
--- Users can add tools with `require('coagent').register_tool(tool)`.
local M = {}

local fs = require('coagent.tools.fs')
local shell = require('coagent.tools.shell')
local lsp = require('coagent.tools.lsp')
local background = require('coagent.tools.background')

local builtin = {
  fs.list_dir,
  fs.glob,
  fs.search,
  fs.read_file,
  require('coagent.agent.subagent').tool,
  require('coagent.agent.skills').tool,
  require('coagent.agent.experiments').tool,
  require('coagent.agent.delegate').tool,
  require('coagent.agent.ledger').tool,
  require('coagent.agent.loop').tool,
  require('coagent.agent.archive').tool,
  lsp.lsp_definition,
  lsp.lsp_references,
  lsp.lsp_symbols,
  lsp.lsp_hover,
  fs.diagnostics,
  shell.git_status,
  shell.git_diff,
  fs.edit_file,
  fs.write_file,
  fs.delete_file,
  shell.run_command,
  background.start_process,
  background.wait_process,
  background.read_process_output,
  background.list_processes,
  background.stop_process,
}

---@class Coagent.Registry
local Registry = {}
Registry.__index = Registry

function M.new()
  local self = setmetatable({ tools = {}, order = {} }, Registry)
  for _, t in ipairs(builtin) do
    self:register(t)
  end
  return self
end

function Registry:register(tool)
  assert(type(tool.name) == 'string', 'tool.name required')
  assert(tool.kind == 'read' or tool.kind == 'write' or tool.kind == 'exec', 'tool.kind must be read|write|exec')
  assert(type(tool.run) == 'function', 'tool.run required')
  tool.prepare = tool.prepare or function()
    return {}
  end
  tool.title = tool.title or function()
    return tool.name
  end
  if not self.tools[tool.name] then
    table.insert(self.order, tool.name)
  end
  self.tools[tool.name] = tool
end

function Registry:get(name)
  return self.tools[name]
end

--- JSON Schema objects must encode as JSON objects. vim.json.encode turns an
--- empty Lua table into `[]`, which the Copilot API rejects ("[] is not of type
--- 'object'"), so empty `properties` become vim.empty_dict().
---@param schema table?
---@return table
local function normalize_schema(schema)
  if type(schema) ~= 'table' then
    return { type = 'object', properties = vim.empty_dict() }
  end
  local function walk(node)
    if type(node) ~= 'table' then
      return node
    end
    local out = {}
    for k, v in pairs(node) do
      if k == 'properties' and type(v) == 'table' and next(v) == nil then
        out[k] = vim.empty_dict()
      else
        out[k] = walk(v)
      end
    end
    if out.type == 'object' and out.properties == nil then
      out.properties = vim.empty_dict()
    end
    return out
  end
  return walk(schema)
end
M.normalize_schema = normalize_schema

--- Tool definitions for the model, filtered by a predicate on kind.
---@param offers fun(kind:string):boolean
---@return table[]
function Registry:schemas(offers)
  local out = {}
  for _, name in ipairs(self.order) do
    local t = self.tools[name]
    if offers(t.kind) then
      table.insert(out, { name = t.name, description = t.description, schema = normalize_schema(t.schema) })
    end
  end
  return out
end

return M
