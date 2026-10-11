--- Highlight groups. All link to standard groups (default = true) so they
--- follow the colorscheme and work in 256-color and true-color terminals.
local M = {}

M.groups = {
  CoagentUser = { link = 'Title' },
  CoagentAssistant = { link = 'Function' },
  CoagentOk = { link = 'DiagnosticOk' },
  CoagentError = { link = 'DiagnosticError' },
  CoagentWarn = { link = 'DiagnosticWarn' },
  CoagentInfo = { link = 'DiagnosticInfo' },
  CoagentRunning = { link = 'DiagnosticInfo' },
  CoagentApproval = { link = 'WarningMsg' },
  CoagentDim = { link = 'Comment' },
  CoagentTool = { link = 'Normal' },
  CoagentKey = { link = 'Special' },
  CoagentSummary = { link = 'Special' },
  CoagentDiffAdd = { link = 'Added' },
  CoagentDiffDelete = { link = 'Removed' },
  CoagentDiffHunk = { link = 'Changed' },
  CoagentBar = { link = 'StatusLine' },
  CoagentBarState = { link = 'StatusLine' },
  CoagentBarBusy = { link = 'DiagnosticInfo' },
  CoagentBarAlert = { link = 'WarningMsg' },
  CoagentPlaceholder = { link = 'Comment' },
  CoagentAccepted = { link = 'DiagnosticOk' },
  CoagentRejected = { link = 'DiagnosticError' },
  -- inline edit preview (whole-line backgrounds)
  CoagentInlineAdd = { link = 'DiffAdd' },
  CoagentInlineDelete = { link = 'DiffDelete' },
  CoagentInlinePending = { link = 'Visual' },
}

function M.setup()
  for name, def in pairs(M.groups) do
    local target = def.link
    -- 'Added'/'Removed'/'Changed' exist since Neovim 0.10; fall back for older colorschemes.
    if vim.fn.hlexists(target) == 0 then
      target = ({ Added = 'DiffAdd', Removed = 'DiffDelete', Changed = 'DiffChange' })[target] or 'Normal'
    end
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

return M
