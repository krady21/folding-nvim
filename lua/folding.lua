local api = vim.api
local lsp = vim.lsp

local M = {}

-- Informative table keeping track of language servers that implement textDocument/foldingRange.
-- Not used at runtime (capability is resolved dynamically)
M.servers_supporting_folding = {
  pyls = true,
  pyright = false,
  sumneko_lua = true,
  texlab = true,
  clangd = false,
  julials = false,
}

M.active_folding_clients = {}

function M.on_attach()
  M.setup_plugin()
  M.update_folds()
end


function M.setup_plugin()
  local gid = api.nvim_create_augroup("FoldingCommand", {})

  local bufnr = api.nvim_get_current_buf()
  for _, event in ipairs({ "BufEnter", "BufWritePost" }) do
    api.nvim_create_autocmd(event, {
      callback = function() M.update_folds() end,
      buffer = bufnr,
      group = gid,
    })
  end

  local clients = lsp.get_active_clients({ bufnr = bufnr })

  for _, client in pairs(clients) do
    local client_id = client['id']
    if M.active_folding_clients[client_id] == nil then
      local server_supports_folding = vim.tbl_get(client, 'server_capabilities', 'foldingRangeProvider')
      if not server_supports_folding then
        vim.notify_once(string.format("%s does not provide folding requests", client.name), vim.log.levels.WARN, { title = "folding-nvim" })
      end

      M.active_folding_clients[client_id] = server_supports_folding
    end
  end
end



function M.update_folds()
  local current_window = api.nvim_get_current_win()
  local in_diff_mode = api.nvim_win_get_option(current_window, 'diff')
  if in_diff_mode then
    -- In diff mode, use diff folding.
    api.nvim_win_set_option(current_window, 'foldmethod', 'diff')
  else
    local clients = lsp.get_active_clients({ bufnr = api.nvim_get_current_buf() })
    for client_id, client in pairs(clients) do
      if M.active_folding_clients[client_id] then
        -- XXX: better to pass callback in this method or add it directly in the config?
        -- client.config.callbacks['textDocument/foldingRange'] = M.fold_handler
        local current_bufnr = api.nvim_get_current_buf()
        local params = { uri = vim.uri_from_bufnr(current_bufnr) }
        client.request('textDocument/foldingRange', {textDocument = params}, M.fold_handler, current_bufnr)
      end
    end
  end
end


function M.fold_handler(err, result, ctx, config)
  -- params: err, method, result, client_id, bufnr
  -- XXX: handle err?
  local current_bufnr = api.nvim_get_current_buf()
  -- Discard the folding result if buffer focus has changed since the request was
  -- done.
  if current_bufnr == ctx.bufnr then
    if err == nil and result == nil then
      -- client wont return a valid result in early stages after initialization
      -- XXX: this is dirty
      vim.wait(100)
      M.update_folds()
    else
      for _, fold in ipairs(result) do
        fold['startLine'] = M.adjust_foldstart(fold['startLine'])
        fold['endLine'] = M.adjust_foldend(fold['endLine'])
      end
      table.sort(result, function(a, b) return a['startLine']  < b['startLine'] end)
      vim.b.folds = result

      local current_window = api.nvim_get_current_win()
      api.nvim_win_set_option(current_window, 'foldmethod', 'expr')
      api.nvim_win_set_option(current_window, 'foldexpr', 'folding_nvim#foldexpr()')
    end
  end
end


function M.adjust_foldstart(line_no)
  return line_no + 1
end


function M.adjust_foldend(line_no)
  local bufnr = api.nvim_get_current_buf()
  local filetype = api.nvim_buf_get_option(bufnr, 'filetype')
  if filetype == 'lua' then
    return line_no + 2
  else
    return line_no + 1
  end
end


function M.get_fold_indic(lnum)
  local fold_level = 0
  local is_foldstart = false
  local is_foldend = false

  for _, table in ipairs(vim.b.folds or {}) do
    local start_line = table['startLine']
    local end_line = table['endLine']

    -- can exit early b/c folds get pre-orderered manually
    if lnum < start_line then
      break
    end

    if lnum >= start_line and lnum <= end_line then
      fold_level = fold_level + 1
      if lnum == start_line then
        is_foldstart = true
      end
      if lnum == end_line then
        is_foldend = true
      end
    end
  end

  if is_foldend and is_foldstart then
    -- If line marks both start and end of folds (like ``else`` statement),
    -- merge the two folds into one by returning the current foldlevel
    -- without any marker.
    return fold_level
  elseif is_foldstart then
    return string.format(">%d", fold_level)
  elseif is_foldend then
    return string.format("<%d", fold_level)
  else
    return fold_level
  end
end


return M
