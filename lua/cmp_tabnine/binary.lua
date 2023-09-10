local Path = require('plenary.path')
local uv = vim.loop
local fn = vim.fn
local json = vim.json
local TabnineBinary = {}
local log = require('cmp_tabnine.log')

local api_version = '4.4.223'
local sep = Path.path.sep

local is_win = (function()
  if jit then
    local os = string.lower(jit.os)
    if os ~= 'windows' then
      return true
    else
      return false
    end
  else
    return package.config:sub(1, 1) == '\\'
  end
end)()

local function script_path()
  local str = debug.getinfo(2, 'S').source:sub(2)
  str = str:gsub('/', sep)
  return Path:new(str:match('(.*' .. sep .. ')'))
end

-- do this once on init, otherwise on restart this dows not work
local binaries_folder = script_path():parent():parent() .. sep .. 'binaries'

-- this function is taken from https://github.com/yasuoka/stralnumcmp/blob/master/stralnumcmp.lua
local function compare_semver(a, b)
  local a0, b0, an, bn, as, bs, c
  a0 = a
  b0 = b
  while a:len() > 0 and b:len() > 0 do
    an = a:match('^%d+')
    bn = b:match('^%d+')
    as = an or a:match('^%D+')
    bs = bn or b:match('^%D+')

    if an and bn then
      c = tonumber(an) - tonumber(bn)
    else
      c = (as < bs) and -1 or ((as > bs) and 1 or 0)
    end
    if c ~= 0 then
      return c
    end
    a = a:sub((an and an:len() or as:len()) + 1)
    b = b:sub((bn and bn:len() or bs:len()) + 1)
  end
  return (a0:len() - b0:len())
end

---Returns the path to the binary
---@return string
local function binary_path()
  local versions_folders = vim.fn.glob(binaries_folder .. '/*', false, true)
  local versions = {}

  for _, dirpath in ipairs(versions_folders) do
    for version in string.gmatch(dirpath, '([0-9.]+)$') do
      if version then
        table.insert(versions, { path = dirpath, version = version })
      end
    end
  end

  table.sort(versions, function(a, b)
    return compare_semver(a.version, b.version) < 0
  end)

  local latest = versions[#versions]
  if not latest then
    vim.notify(string.format('cmp-tabnine: Cannot find installed TabNine. Please run install.%s', (is_win and 'ps1' or 'sh')))
    return ''
  end

  local platform = nil

  if vim.fn.has('win64') == 1 then
    platform = 'x86_64-pc-windows-gnu'
  elseif vim.fn.has('win32') == 1 then
    platform = 'i686-pc-windows-gnu'
  else
    local arch, _ = string.gsub(vim.fn.system({ 'uname', '-m' }), '\n$', '')
    if vim.fn.has('mac') == 1 then
      if arch == 'arm64' then
        platform = 'aarch64-apple-darwin'
      else
        platform = 'x86_64-apple-darwin'
      end
    elseif vim.fn.has('unix') == 1 then
      platform = arch .. '-unknown-linux-musl'
    end
  end
  return latest.path .. '/' .. platform .. '/' .. 'TabNine'
end

function TabnineBinary:start()
  self.stdin = uv.new_pipe()
  self.stdout = uv.new_pipe()
  self.stderr = uv.new_pipe()
  self.handle, self.pid = uv.spawn(binary_path(), {
    args = {
      '--client',
      'nvim',
      '--client-metadata',
      'ide-restart-counter=' .. self.restart_counter,
    },
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function()
    self.handle, self.pid = nil, nil
    uv.read_stop(self.stdout)
  end)

  uv.read_start(
    self.stdout,
    vim.schedule_wrap(function(error, chunk)
      if chunk then
        log.debug(chunk)
        for _, line in pairs(fn.split(chunk, '\n')) do
          local callback = table.remove(self.callbacks)
          if not callback.cancelled then
            log.debug(line)
            callback.callback(vim.json.decode(line))
          end
        end
      elseif error then
        log.error(error)
        print('tabnine binary read_start error', error)
      end
    end)
  )
end

function TabnineBinary:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
  self.restart_counter = 0
  self.handle = nil
  self.pid = nil
  self.callbacks = {}

  return o
end

function TabnineBinary:request(request, on_response)
  if not self.pid then
    self.restart_counter = self.restart_counter + 1
    self:start()
  end
  uv.write(self.stdin, json.encode({ request = request.request, version = api_version }) .. '\n')
  local callback = { cancelled = false, callback = on_response }
  local function cancel()
    callback.cancelled = true
  end

  table.insert(self.callbacks, 1, callback)
  return cancel
end

return TabnineBinary:new()
