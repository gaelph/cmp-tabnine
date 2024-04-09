local cmp = require('cmp')
local log = require('cmp_tabnine.log')

local M = {}

local function escape_tabstop_sign(str)
  return str:gsub('%$', '\\$')
end

local function build_snippet(prefix, placeholder, suffix, add_final_tabstop)
  local snippet = escape_tabstop_sign(prefix) .. placeholder .. escape_tabstop_sign(suffix)
  if add_final_tabstop then
    return snippet .. '$0'
  else
    return snippet
  end
end

function M.auto_complete_request(ctx, conf)
  local before_table = vim.api.nvim_buf_get_text(0, 0, 0, vim.fn.line('.') - 1, vim.fn.col('.') - 1, {})
  local before = table.concat(before_table, '\n')

  local after_table = vim.api.nvim_buf_get_text(0, vim.fn.line('.') - 1, vim.fn.col('.') - 1, vim.fn.line('$') - 1, vim.fn.col('$,$') - 1, {})
  local after = table.concat(after_table, '\n')

  local req = {}
  req.request = {
    Autocomplete = {
      before = before,
      after = after,
      filename = vim.fn.expand('%:t'),
      region_includes_beginning = true,
      region_includes_end = false,
      max_num_results = conf:get('max_num_results'),
      correlation_id = ctx.context.id,
    },
  }

  log.debug(req)

  return req
end

function M.auto_complete_response(response, ctx, conf)
  local cursor = ctx.context.cursor

  local items = {}
  local old_prefix = response.old_prefix
  local results = response.results
  local user_message = response.user_message

  if #user_message > 0 then
    log.warn(response.user_message)
    local message = table.concat(response.user_message, '\n')
    vim.notify('Cmp-TabNine\n' .. message, vim.log.levels.INFO)
  end

  local show_strength = conf:get('show_prediction_strength')
  local base_priority = conf:get('priority')

  if results ~= nil then
    for _, result in ipairs(results) do
      local newText = result.new_prefix .. result.new_suffix

      local old_suffix = result.old_suffix
      if string.sub(old_suffix, -1) == '\n' then
        old_suffix = string.sub(old_suffix, 1, -2)
      end

      local range = {
        start = { line = cursor.line, character = cursor.col - #old_prefix - 1 },
        ['end'] = { line = cursor.line, character = cursor.col + #old_suffix - 1 },
      }

      local item = {
        label = newText,
        filterText = newText,
        data = result,
        textEdit = {
          newText = newText,
          insert = range, -- May be better to exclude the trailing part of old_suffix since it's 'replaced'?
          replace = range,
        },
        sortText = newText,
        dup = 0,
      }
      -- This is a hack fix for cmp not displaying items of TabNine::config_dir, version, etc. because their
      -- completion items get scores of 0 in the matching algorithm
      if #old_prefix == 0 then
        item['filterText'] = string.sub(ctx.context.cursor_before_line, ctx.offset) .. newText
      end

      if #result.new_suffix > 0 then
        item['insertTextFormat'] = cmp.lsp.InsertTextFormat.Snippet
        item['label'] = build_snippet(result.new_prefix, conf:get('snippet_placeholder'), result.new_suffix, false)
        item['textEdit'].newText = build_snippet(result.new_prefix, '$1', result.new_suffix, true)
      end

      if result.detail ~= nil then
        local percent = tonumber(string.sub(result.detail, 0, -2))
        if percent ~= nil then
          item['priority'] = base_priority + percent * 0.001
          if show_strength then
            item['labelDetails'] = {
              detail = result.detail,
            }
          end
          item['sortText'] = string.format('%02d', 100 - percent) .. item['sortText']
        else
          item['detail'] = result.detail
        end
      end

      if result.kind then
        item['kind'] = result.kind
      end

      if result.documentation then
        item['documentation'] = result.documentation
      end

      if result.new_prefix:find('.*\n.*') then
        item['data']['multiline'] = true
        item['documentation'] = result.new_prefix
      end

      if result.deprecated then
        item['deprecated'] = result.deprecated
      end
      table.insert(items, item)
    end

    -- sort by returned importance b4 limiting number of results
    table.sort(items, function(a, b)
      if not a.priority then
        return false
      elseif not b.priority then
        return true
      else
        return (a.priority > b.priority)
      end
    end)

    items = { unpack(items, 1, conf:get('max_num_results')) }
  end

  return items
end

function M.prefetch_request(filename)
  local req = {}
  req.request = {
    Prefetch = {
      filename = filename,
    },
  }
  return req
end

function M.prefetch_response(_) end

function M.open_hub_request(quiet)
  local req = {}
  req.request = {
    Configuration = {
      quiet = quiet,
    },
  }

  return req
end

function M.open_hub_response(response)
  if (response.message or ''):find('http://127.0.0.1') then
    return response.message:match('.*(http://127.0.0.1.*)')
  else
    return 'Unknown'
  end
end

return M
