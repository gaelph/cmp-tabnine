local Job = require('plenary.job')
local async = require('plenary.async')
local conf = require('cmp_tabnine.config')
local requests = require('cmp_tabnine.requests')
local binary = require('cmp_tabnine.binary')

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
  local bin, version = binary()
  last_instance.tabnine_version = version

  local sender, receiver = async.control.channel.mpsc()
  last_instance.sender = sender
  last_instance.receiver = receiver

  last_instance.semaphore = async.control.Semaphore.new(1)

  last_instance:_start_binary(bin)
  return last_instance
end

function Source.get_hub_url(self)
  if self == nil then
    -- this happens when nvim < 0.7 and vim.api.nvim_add_user_command does not exist
    self = last_instance
  end
  return self.hub_url
end

Source.open_tabnine_hub = async.wrap(function(self, quiet, callback)
  local req = requests.open_hub_request(quiet)
  req.version = self.tabnine_version

  if self == nil then
    -- this happens when nvim < 0.7 and vim.api.nvim_add_user_command does not exist
    self = last_instance
  end

  async.run(function()
    return self:_send_request(req)
  end, function(response)
    callback(requests.open_hub_response(response))
  end)
end, 3)

function Source.is_available(self)
  return (self.job ~= 0)
end

function Source.get_debug_name()
  return 'TabNine'
end

Source._send_request = async.wrap(function(self, req, callback)
  if not self.job then
    vim.notify('TabNine binary might not be running')
    callback()
  end

  async.run(function()
    local permit = self.semaphore:acquire()

    pcall(self.job.send, self.job, vim.fn.json_encode(req) .. '\n')

    local response = self.receiver.recv()

    permit:forget()
    return response
  end, callback)
end, 3)

function Source._do_complete(self, ctx, callback)
  if not Job.is_job(self.job) then
    return
  end

  local req = requests.auto_complete_request(ctx, conf)
  req.version = self.tabnine_version

  async.run(
    function()
      -- if there is an error, e.g., the channel is dead, we expect on_exit will be
      -- called in the future and restart the server
      -- we use pcall as we do not want to spam the user with error messages
      return self:_send_request(req)
    end,
    vim.schedule_wrap(function(response)
      response = json_decode(response)
      callback(requests.auto_complete_response(response, ctx, conf))
    end)
  )
end

function Source.prefetch(self, file_path)
  async.run(function()
    local req = requests.prefetch_request(file_path)
    req.version = self.tabnine_version

    self:_send_request(req)
  end)
end

--- complete
function Source.complete(self, ctx, callback)
  if conf:get('ignored_file_types')[vim.bo.filetype] then
    return
  end
  async.run(function()
    return self:_do_complete(ctx)
  end, callback)
end

function Source._start_binary(self, bin)
  if not bin then
    return
  end

  self.job = Job:new({
    command = bin,
    args = {
      '--client=cmp.vim',
    },
    enable_handlers = true,
    on_stderr = nil,
    on_stdout = function(_, output, job)
      self:on_stdout(job, output)
    end,
  })

  self.job:after(function(code, _)
    if code ~= 143 then
      self:_start_binary(bin)
    else
      self.job = 0
    end
  end)

  self.job:start()

  async.run(function()
    return self:open_tabnine_hub(true)
  end, function(hub_url)
    self.hub_url = hub_url
  end)
end

function Source.on_stdout(self, _, data)
  if not self.sender then
    return
  end

  if data ~= nil and data ~= '' and data ~= 'null' then
    self.sender.send(data)
  end
end

return Source
