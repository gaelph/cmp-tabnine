local cmp = require('cmp')

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
  local max_lines = conf:get('max_lines')
  local cursor = ctx.context.cursor
  local cur_line = ctx.context.cursor_line
  local cur_line_before = string.sub(cur_line, 1, cursor.col - 1)
  local cur_line_after = string.sub(cur_line, cursor.col) -- include current character

  local region_includes_beginning = false
  local region_includes_end = false
  if cursor.line - max_lines <= 1 then
    region_includes_beginning = true
  end
  if cursor.line + max_lines >= vim.fn['line']('$') then
    region_includes_end = true
  end

  local lines_before = vim.api.nvim_buf_get_lines(0, math.max(0, cursor.line - max_lines), cursor.line, false)
  table.insert(lines_before, cur_line_before)
  local before = table.concat(lines_before, '\n')

  local lines_after = vim.api.nvim_buf_get_lines(0, cursor.line + 1, cursor.line + max_lines, false)
  table.insert(lines_after, 1, cur_line_after)
  local after = table.concat(lines_after, '\n')

  local req = {}
  req.request = {
    Autocomplete = {
      before = before,
      after = after,
      region_includes_beginning = region_includes_beginning,
      region_includes_end = region_includes_end,
      filename = vim.uri_from_bufnr(0):gsub('file://', ''),
      max_num_results = conf:get('max_num_results'),
      correlation_id = ctx.context.id,
      line = cursor.line,
      offset = #before + 1,
      character = cursor.col,
      indentation_size = (vim.api.nvim_buf_get_option(0, 'tabstop') or 4),
    },
  }

  return req
end

function M.auto_complete_response(response, ctx, conf)
  local cursor = ctx.context.cursor

  local items = {}
  local old_prefix = response.old_prefix
  local results = response.results

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

function M.prefecth_request(filename)
  local req = {}
  req.request = {
    Prefetch = {
      filename = filename,
    },
  }
  return req
end

function M.prefecth_response(_) end

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
    return nil
  end
end

return M