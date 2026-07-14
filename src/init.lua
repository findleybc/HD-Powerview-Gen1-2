--[[
  Copyright 2022 Bruno Maranhao

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  Power View Shade Driver for LAN-based Generation 1 & 2 Hub devices

--]]

-- Edge libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"                 -- just for time
local socket = require "cosock.socket"          -- just for time
local json  = require "st.json"
local cosock = require 'cosock'
local http  = cosock.asyncify 'socket.http' -- require "socket.http"
local ltn12 = require "ltn12"
local log = require "log"
local base64 = require "st.base64"

--brian added
local inspect = require("inspect")
local mdns = require('st.mdns')


-- Custom Capabiities
local cap_createdev = capabilities["partyvoice23922.createanother"]
local cap_calibrate = capabilities["winterplate04871.calibrate"]
local cap_jog = capabilities["winterplate04871.jog"]

-- Module variables
local thisDriver = {}
local initialized = false

local function sendCommand(hubIP, shadeID, payload)
  local request_body = json.encode(payload)
  local response_body = {}

  local url = "http://" .. hubIP .. "/api/shades/" .. shadeID
  local res, code, response_headers = http.request{
    url = url,
    method = "PUT",
    headers =
    {
      ["Content-Type"] = "application/json";
      ["Content-Length"] = #request_body;
    },
      source = ltn12.source.string(request_body),
      sink = ltn12.sink.table(response_body),
    }
end

local function updatePosition(device)
  local request_body = {}
  local response_body = {}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  local url = "http://" .. hubIP .. "/api/shades/" .. shadeID .. "?refresh=true"
  log.debug("Updating shade position for device: " .. device.device_network_id .. " with URL: " .. url)
  local res, code, response_headers = http.request{
    url = url,
    method = "GET",
    headers =
    {
      ["Content-Type"] = "application/json";
      ["Content-Length"] = #request_body;
    },
      --source = ltn12.source.string(request_body),
      sink = ltn12.sink.table(response_body),
    }
     log.debug ("HTTP GET Response Code: " .. inspect(response_body))
     --log.debug("sink: " .. inspect(ltn12.sink.table(response_body)))
    -- log.debug(response_body[1])
    local shadeLevel = math.floor(tonumber(string.match(string.match(response_body[1], '"position1":%d+'),"%d+$"))/65535*100)
    local batLevel = math.floor(tonumber(string.match(string.match(response_body[1], '"batteryStrength":%d+'),"%d+$"))/2)
    log.debug("Shade position updated to: " .. shadeLevel .. "%, Battery level: " .. batLevel .. "%")
      device:emit_event(capabilities.battery.battery(batLevel)) 

    device:emit_event(capabilities.windowShadeLevel.shadeLevel(shadeLevel))
    if shadeLevel == 0 then
      device:emit_event(capabilities.windowShade.windowShade('closed'))
    else
      device:emit_event(capabilities.windowShade.windowShade('open'))
    end
end

local function jog(driver, device, command) -- the function activated by a momentary button in the shade device titled "Jog"
  local payload = {shade = {motion = "jog"}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
end

local function calibrate(driver, device, command) -- the function activated by a momentary button in the shade device titled "Calibrate"
  local payload = {shade = {motion = "calibrate"}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
  updatePosition(device)
end

local function setShadeLevel(driver, device, command) -- the function activated by a dimmer in the shade device titled "Position"
  log.info("Setting shade position...")
  local shadeLevel = command.args.shadeLevel
  local positionN = math.floor(65535*shadeLevel/100)
  local payload = {shade = {positions = {posKind1 = 1, position1 = positionN}}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(shadeLevel))
  if shadeLevel == 0 then
    device:emit_event(capabilities.windowShade.windowShade('closed'))
  else
    device:emit_event(capabilities.windowShade.windowShade('open'))
  end
end

local function open(driver, device, command) -- the function activated by selecting Open in the shade device
  local payload = {shade = {positions = {posKind1 = 1, position1 = 65535}}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
end

local function close(driver, device, command) -- the function activated by selecting Close in the shade device
  local payload = {shade = {positions = {posKind1 = 1, position1 = 0}}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
end

local function pause(driver, device, command) -- the function activated by selecting Pause in the shade device
  local payload = {shade = {motion = "stop"}}
  local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
  sendCommand(hubIP, shadeID, payload)
  updatePosition(device)
end

local function create_device(driver)

  local MFG_NAME = 'SmartThings Community'
  local MODEL = 'PowerView Shade'
  local VEND_LABEL = 'PowerView Shade'
  local ID = 'PowerViewShade_' .. socket.gettime()
  local PROFILE = 'powerViewShade.v1'

  log.info (string.format('Creating new device: label=<%s>, id=<%s>', VEND_LABEL, ID))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                            }
                      
  assert (driver:try_create_device(create_device_msg), "failed to create device")

end

local function isValidIPv4(ip)
  if type(ip) ~= "string" then return false end
  
  -- Check basic IPv4 pattern
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end

  -- Parse and validate each octet
  local octets = {tonumber(a), tonumber(b), tonumber(c), tonumber(d)}
  for _, octet in ipairs(octets) do
    if not octet or octet < 0 or octet > 255 then
      return false
    end
  end

  -- Prevent leading zeros (e.g., 192.168.01.1 is invalid)
  if string.format("%d.%d.%d.%d", a, b, c, d) ~= ip then
    return false
  end

  return true
end


local function get_shadesfromIP(IPaddress)
  local request_body = {}
  local response_body = {}
  local url = "http://" .. IPaddress .. "/api/shades/" .. "?refresh=true"
  log.debug("Finding shade in hub: " .. IPaddress .. " with URL: " .. url)
  local res, code, response_headers = http.request{
    url = url,
    method = "GET",
    headers =
    {
      ["Content-Type"] = "application/json";
      ["Content-Length"] = #request_body;
    },
      --source = ltn12.source.string(request_body),
      sink = ltn12.sink.table(response_body),
    }
     log.debug ("HTTP GET Response Code: " .. inspect(response_body))
     local data = json.decode(response_body[1])
     if not data then
       log.error("Failed to decode JSON response")
       return
     else
    local shadeDirectory = {}
      for index, shade in ipairs(data.shadeData) do
    log.debug ("data: " .. inspect(shade))
    -- 3. Use the ID as the table key and the Name as the value
    shadeDirectory[shade.id] = shade.name
      end
      log.debug("Shade names from data: " .. inspect(shadeDirectory))
       log.debug("Decoded JSON data: " .. inspect(data))
       log.debug("Shade IDs found: " .. inspect(data.shadeIds))
      return shadeDirectory
     end

end

local function mdns_discovery() --mdns used to get ip address for HUB. will be used to discovery
  local discover_responses = mdns.discover("_powerview._tcp", "local") or {}
  for idx, found in ipairs(discover_responses.found) do
    -- sanity check that the answer contains a response to the correct service type,
    -- and we only want to process ipv4
    if found ~= nil
      and isValidIPv4(found.host_info.address) then
        log.debug("Found HD-Shades on the local network at IP: " .. found.host_info.address)
        -- get shadeIDs from shade ip addresses
        local shadeIDs = get_shadesfromIP(found.host_info.address)
        log.debug("Shade IDs found: " .. inspect(shadeIDs))
        return found.host_info.address, shadeIDs
    end
  end
end

-- CAPABILITY HANDLERS

local function handle_calibrate(driver, device, command)

  calibrate(driver, device, command)

end

local function handle_jog(driver, device, command)

  jog(driver, device, command)

end

local function handle_createdev(driver, device, command)

  create_device(driver)

end

------------------------------------------------------------------------
--                REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)
  
    log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  -- Define the polling interval in seconds (e.g., 300 seconds = 5 minutes)
    local POLLING_INTERVAL = 120 -- change to 120 for producion use, 10 for testing

    -- Start a scheduled timer on the device's thread
    device.thread:call_on_schedule(
        POLLING_INTERVAL,
        function ()
            -- Ensure preferences are set before attempting an HTTP request
            local hubIP, shadeID = string.match(device.device_network_id, "(.*)_(.*)")
            if device.preferences and hubIP and shadeID then
                log.debug("Timer executing: Polling shade position for " .. device.device_network_id)
                updatePosition(device)
                --Debuging mdns discovery_handler
                --mdns_discovery()
            else
                log.warn("Timer skipped: hubIP or shadeID not yet configured in device preferences.")
            end
        end, 
        "shade_polling_timer"
    )
    log.debug('Exiting device initialization')
end
-- Called when device was just created in SmartThings
local function device_added (driver, device)
  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")
  
  device:emit_event(capabilities.windowShade.windowShade('unknown'))
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))

 
end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

  log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)
  
  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")
  
  local device_list = driver:get_devices()
  
  if #device_list == 0 then
    log.warn ('All devices removed; driver disabled')
  end
  
end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked ***')

end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked')

end


-- Create Initial Device
local function discovery_handler(driver, _, should_continue)
  log.debug("Device discovery invoked")

  --mdns discovery()

  local device_IP_address, shadeIDs = mdns_discovery() -- Call the mdns_discovery function to find the IP address of the HD-Shades hub
  log.debug("shadIDs from mdns_discover: in discovery_handler: " .. inspect(shadeIDs))
  for id, name in pairs(shadeIDs or {}) do
    log.debug("pairs: " .. id .. ", " .. base64.decode(name))
    local ID = device_IP_address .. "_" .. id
    log.debug("Creating device for Shade ID: " .. id .. " with Device Network ID: " .. ID)
    local VEND_LABEL = base64.decode(name)
    local MFG_NAME = 'SmartThings Community'
    local MODEL = 'PowerView Shade'
    local PROFILE = 'powerViewShade.v1'
    local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                            }

    local created_device, err = driver:try_create_device(create_device_msg)
    if err ~= nil then
      print("Failed to create device: ", err)
    elseif created_device ~= nil then
      print("Device created successfully or already exists! "..inspect(created_device))
    end
  end
    log.debug("Exiting discovery")
end


-----------------------------------------------------------------------
--        DRIVER MAINLINE: Build driver context table
-----------------------------------------------------------------------
thisDriver = Driver("thisDriver", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = open,
      [capabilities.windowShade.commands.close.NAME] = close,
      [capabilities.windowShade.commands.pause.NAME] = pause,
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = setShadeLevel,
    },
    [cap_calibrate.ID] = {
      [cap_calibrate.commands.push.NAME] = handle_calibrate,
    },
    [cap_jog.ID] = {
      [cap_jog.commands.push.NAME] = handle_jog,
    },
    [cap_createdev.ID] = {
      [cap_createdev.commands.push.NAME] = handle_createdev,
    },
  }
})

log.info ('HD PowerView Shade Gen 1 or 2 v1.0 Started')


thisDriver:run()
