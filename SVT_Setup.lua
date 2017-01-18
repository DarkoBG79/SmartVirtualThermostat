-- Setup program for Smart Virtual Thermostat for Domoticz, by logread
--[[
Version 0.1 Jan 18 2017

This program is free software: you can redistribute it and/or modify it under the condition
that it is for private or home useage and this whole comment is reproduced in the source code file.
Commercial utilisation is not authorized without the appropriate written agreement from "logread",
contact by PM on http://www.domoticz.com/forum.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--]]


--###################### BEGINNING OF INSTALL PARAMETERS #####################

-- system parameters for automated uservariables creation via Domoticz json API
-- MUST BE VALID for the relevant system
local ip = "192.168.0.10" -- make sure Domoticz allows password free call on that IP and does not block it
local port = "8080" -- the local port on which to access Domoticz

-- Domoticz devices created by script.
local virtualdev = {
  thermostat = {name = "Smart_Thermostat", type = 6}, -- virtual, type switch
  forcedheating = {name = "Forced_Heating", type = 6}, -- virtual, type switch
  tempthermostat = {name = "Temp_Thermostat", type = 80}, -- virtual, type temperature
  daysetpoint = {name = "Day_SetPoint", type = 8}, -- virtual type thermostat setpoint
  nightsetpoint = {name = "Night_SetPoint", type = 8} -- virtual type thermostat setpoint
  }
-- end of list of automatically created devices

-- Domoticz "user variables" used by script
-- Will be created automatically by running script
local uv = {
  Internals = {name = "SVT_Internals", type = 2, default = "0,0,0,0,0,0,60,1"},
  DayStartHour = {name = "SVT_DayStartHour", type = 4, default = "07:00"},
  NightStartHour = {name = "SVT_NightStartHour", type = 4, default = "22:00"},
  CalcInterval = {name = "SVT_CalculationInterval", type = 0, default = 1200}, -- 20 minutes
  ForcedHeatingDuration = {name = "SVT_ForcedHeatingDuration", type = 0, default = 3600}, -- 1 hour
  PauseDelay = {name = "SVT_PauseDelay", type = 0, default = 60}, -- delay set to 60 seconds for instance
  AutoLearning = {name = "SVT_AutoLearning", type = 2, default = "0,1,1,0,0,0"}
  }
-- end of Domoticz user variables created by script

-- ###################### END OF INSTALL PARAMETERS #####################

local http = require("socket.http")
local json = require("dkjson")

-- UTILITY FUNCTIONS

local function nicelog(message)
	local display = "SVT Install : %s"
	message = message or ""
	if type(message) == "table" then message = table.concat(message) end
	print(string.format(display, message))
end

-- generic call to Domoticz's API
local function DZAPI(APIcall)
	APIcall = table.concat{"http://", ip, ":", port, APIcall}
	nicelog(APIcall)
	local result = ""
	local retdata, retcode = http.request(APIcall)
	if retcode == 200 then
		retdata = json.decode(retdata)
		if retdata.status == "OK" then
			result = "API responded success"
		else
			result = "API responded error !"
		end
	else
		result = "Network error, Domoticz API not reachable !"
  end
	nicelog(result)
	return retdata
end



-- INSTALL FUNCTIONS

local function CreateUserVariable(varname, vartype, value)
  --vartype: 0 = Integer, 1 = Float, 2 = String, 3 = Date, 4 = Time, 5 = DateTime
  value = tostring(value)
  local url = "/json.htm?type=command&param=saveuservariable&vname=%s&vtype=%d&vvalue=%s"
  DZAPI(string.format(url, varname, vartype, value))
end

local function CreateDevice(hwidx, devname, devtype)
  local url = "/json.htm?type=createvirtualsensor&idx=%d&sensorname=%s&sensortype=%d"
  DZAPI(string.format(url, hwidx, devname, devtype))
end

local function getvirtualhw()
  local APIresponse = DZAPI("/json.htm?type=hardware")
  local vhwidx = 0
  if APIresponse.result then 
    for _, hardware in ipairs(APIresponse.result) do
      if hardware.Type == 15 and hardware.Enabled then -- virtual hardware is installed and enabled
        vhwidx = hardware.idx
        nicelog({"Domoticz virtual hardware '", hardware.Name, "' found and enabled... using it"})
        break
      end
    end
  end
  return vhwidx
end

-- MAIN PROGRAM

--[[check that virtual hardware exists. if not then create it and then create the virtual devices
    if these do not exist yet (Domoticz accepts duplicate names BUT need to avoid that)
--]]
local virtualhwidx = getvirtualhw()
if virtualhwidx == 0 then
  nicelog("no Domoticz virtual hardware found, creating it...")
  DZAPI("/json.htm?type=command&param=addhardware&htype=15&port=1&name=VIRTUAL_HARDWARE&enabled=true")
  virtualhwidx = getvirtualhw()
end
if virtualhwidx == 0 then
  nicelog("Domoticz virtual hardware error... SVT devices/variables installation aborted !")
else
  -- create the devices
  local devicestable = DZAPI("/json.htm?type=devices&filter=all&used=true&order=Name") or nil
  for _, device in pairs(virtualdev) do
    -- check if device already exists... If not create it
    local deviceexists = false
    for _, existingdevice in ipairs(devicestable.result) do
      if existingdevice.Name == device.name then deviceexists = true end
    end
    if deviceexists then
      nicelog({"Domoticz virtual device of name '", device.name, "' already exists... skipping creation"})
    else
      nicelog({"creating Domoticz virtual device '", device.name, "'"})
      CreateDevice(virtualhwidx, device.name, device.type)
    end
  end
end

-- create user variables

for _, variable in pairs(uv) do
  nicelog({"creating Domoticz user variable '", variable.name, "'"})
  CreateUserVariable(variable.name, variable.type, variable.default)
end