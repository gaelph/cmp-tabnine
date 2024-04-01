local conf = require('cmp_tabnine.config')
local requests = require('cmp_tabnine.requests')
local binary = require('cmp_tabnine.binary')
local log = require('cmp_tabnine.log')

local function json_decode(data)
  local status, result = pcall(vim.fn.json_decode, data)
  if status then
    return result
  else
    return nil, result
  end
end

local Source = {
  job = 0,
  semaphore = nil,
  sender = nil,
  receiver = nil,
  -- cache the hub url. Set every time on_exit is called, assuming it wont
  -- change till next run of the tabnine process
  hub_url = 'Unknown',
}
local last_instance = nil

function Source.new()
  last_instance = setmetatable({}, { __index = Source })
  last_instance.binary = binary
  last_instance.binary:start()
  return last_instance
end

function Source.get_hub_url(self, callback)
  local req = requests.open_hub_request(true)
  self.binary:request(req, function(res)
    local response = requests.open_hub_response(res)
    callback(response)
  end)
end

function Source.open_tabnine_hub(self, callback)
  local req = requests.open_hub_request(false)

  if self == nil and last_instance ~= nil then
    -- this happens when nvim < 0.7 and vim.api.nvim_add_user_command does not exist
    self = last_instance
  else
    return
  end

  self.binary:request(req, function()
    callback()
  end)
end

function Source.is_available(self)
  return self.binary ~= nil
end

function Source.get_debug_name()
  return 'TabNine'
end

function Source.get_trigger_characters()
  return { '@', '.', '(', '{', ' ' }
end

function Source._do_complete(self, ctx, callback)
  local req = requests.auto_complete_request(ctx, conf)

  self.binary:request(req, function(res)
    local response = requests.auto_complete_response(res, ctx, conf)
    callback(response)
  end)
end

function Source.prefetch(self, file_path)
  local req = requests.prefetch_request(file_path)

  self.binary:request(req, function() end)
end

--- complete
function Source.complete(self, ctx, callback)
  if conf:get('ignored_file_types')[vim.bo.filetype] then
    return
  end

  self:_do_complete(ctx, callback)
end

return Source
