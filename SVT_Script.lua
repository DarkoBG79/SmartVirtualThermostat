-- Smart Virtual Thermostat for Domoticz, by logread
--[[
Version 0.1 Jan 16 2017
Developed by logread, based on the Vera plugin from Antor, but significantly rewritten due to Domoticz peculiarities

Installation: see doc on ???

This program is free software: you can redistribute it and/or modify it under the condition
that it is for private or home useage and this whole comment is reproduced in the source code file.
Commercial utilisation is not authorized without the appropriate written agreement from "logread",
contact by PM on http://www.domoticz.com/forum.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--]]

commandArray = {}

--###################### BEGINNING OF USER PARAMETERS #####################

-- Domoticz devices used by script.
-- the following devices MUST be created by running the "SVT_Setup.lua" script 
  local thermostat = "Smart_Thermostat" -- virtual, type switch
  local forcedheating = "Forced_Heating" -- virtual, type switch
  local tempthermostat = "Temp_Thermostat" -- virtual, type temperature
  local setpoints = {"Day_SetPoint", "Night_SetPoint"} -- virtual type thermostat setpoint. Need BOTH !
-- the following devices need to exist in the host Domoticz setup
  local heaters = {"Heater"} -- can obviously be virtual or physical
  local sensorsin = {"Temp_Inside"}
-- the following devices are optional
  local sensorsout = {"Temp_Outside"}
  local sensorspause = {"Door"}
-- end of list of devices to be adjusted / created by user

-- scripts constants - can be modified by user
local dirtydata = 3600 -- number of seconds since last update, used to determine if a given sensor is alive or presumed dead
local powermin = 0 -- minimum heating at each calculation cycle (0-100)
local deltamax = 0.2 -- allowed temp excess over setpoint temperature
local debug = true -- turns on/off logging for debugging purposes

-- ###################### END OF USER PARAMETERS #####################

-- Domoticz "user variables" used by script
-- Will be created automatically by running "SVT_Setup.lua" script
local uv = {
  Internals = {name = "SVT_Internals", type = 2, default = "0,0,0,0,0,0,60,1"},
  DayStartHour = {name = "SVT_DayStartHour", type = 4, default = "07:00"},
  NightStartHour = {name = "SVT_NightStartHour", type = 4, default = "22:00"},
  CalcInterval = {name = "SVT_CalculationInterval", type = 0, default = 1200}, -- 20 minutes
  ForcedHeatingDuration = {name = "SVT_ForcedHeatingDuration", type = 0, default = 3600}, -- 1 hour
  PauseDelay = {name = "SVT_PauseDelay", type = 0, default = 60}, -- delay set to 60 seconds for instance
  AutoLearning = {name = "SVT_AutoLearning", type = 2, default = "0,1,1,0,0,0"}
  }
-- end of Domoticz user variables created by "SVT_Setup.lua" script

-- script constants or variables, not for user modification
local data = {} -- Table that holds the runtime variables (filled by GetData function)
local datafields = {"LastCalc", "EndHeatTime", "IsPaused","Heating","ForcedHeating","ForcedHeatingTime","ConstC","ConstT"}
local intemp
local outtemp
local setpoint
local pause, pausechanged
local AutoLearning
local now = os.time()

-- UTILITY FUNCTIONS

-- converts a Domoticz date string to a Unix epoch
local function datetoepoch(datestring)
	local template = "(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)"
	local year, month, day, hour, minutes, seconds = datestring:match(template)
	return os.time{year=year, month=month, day=day, hour=hour, min=minutes, sec=seconds}
end

local function variable_get(variable)
  local value = uservariables[variable.name]
  if value then
    return value
  else
    print("SVT: user variable '" .. variable.name .. "' does not exist !!! using default value...") 
    return variable.default
  end
end

local function variable_set(variable, value)
  if value ~= variable_get(variable) then
    local tempstr = "Variable:" .. variable.name
    commandArray[tempstr] = tostring(value)
    return true
  else
    return false -- no change
  end
end

local function debuglog(message)
  if not(debug) then return end
  message = tostring(message) or ""
  print("SVT Debug: " .. message)
end

local function DebugTable(name, table)
  if not(debug) then return end
  for index, value in pairs(table) do
    if type(value) == "table" then
      DebugTable(index, value)
    else
      debuglog("table " .. name .. "[" .. index .. "]=" .. tostring(value))
    end
  end
end

local function TableToNumbersString(t)
  t = t or {}
  return table.concat(t, ",")
end

local function NumbersStringToTable(tempstr)
  tempstr = tempstr or ""
  local t = {}
  for v in string.gmatch(tempstr, "(-?[0-9.]+)") do
    table.insert(t, tonumber(v))
  end
  return t
end

local function round(num, idp)
  local mult = 10^(idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

-- THERMOSTAT FUNCTIONS

local function GetData()
  local t = NumbersStringToTable(variable_get(uv.Internals))
  for index, key in ipairs(datafields) do data[key] = t[index] end
  AutoLearning = NumbersStringToTable(variable_get(uv.AutoLearning))
end

local function SaveData()
  local t = {}
  for index, key in ipairs(datafields) do t[index] = data[key] end
  variable_set(uv.Internals, TableToNumbersString(t))
  variable_set(uv.AutoLearning, TableToNumbersString(AutoLearning))
end

local function GetTemp(sensors)
  local nbsensors = 0 
  local sumtemps = 0
  for _, device in pairs(sensors) do
    if otherdevices[device] then
      if datetoepoch(otherdevices_lastupdate[device]) - now <= dirtydata then
        nbsensors = nbsensors + 1
        sumtemps = sumtemps + tonumber(otherdevices[device])
      end
    end
  end
  if nbsensors > 0 then
    return math.floor(sumtemps / nbsensors * 10 + 0.5) /10
  else
    return nil
  end
end

local function GetPause()
  local ispause = 0
  local trigger = 0
  local lastupdate = 0
  for _, device in pairs(sensorspause) do
    if otherdevices[device] then
      if otherdevices[device] == "Open" or otherdevices[device] == "On" then trigger = trigger + 1 end
      lastupdate = math.max(lastupdate, datetoepoch(otherdevices_lastupdate[device]))
    end
  end
  local delai = (now - lastupdate) >= variable_get(uv.PauseDelay)
  if trigger >= 1 and delai then ispause = 1 end
  if trigger == 0 and not(delai) then ispause = 1 end -- sensors are off but not for long enough
  local changed = ispause ~= data.IsPaused
  data.IsPaused = ispause
  return ispause ~= 0, changed
end

local function GetSetPoint()
  local starthour = string.gsub(variable_get(uv.DayStartHour), ":", "") or "0700"
  starthour = tonumber(starthour)
  local endhour = string.gsub(variable_get(uv.NightStartHour), ":", "") or "2200"
  endhour = tonumber(endhour)
  local nowtime = os.date("*t", now)
  local nowhour = nowtime.hour * 100 + nowtime.min
  if (nowhour >= starthour) and (nowhour <= endhour) then
      return tonumber(otherdevices[setpoints[1]]) or 20 -- this is day setpoint
  else
      return tonumber(otherdevices[setpoints[2]]) or 19 -- this is night setpoint
  end
end

local function Heat(action)
  action = action or "Off"
  for _, device in pairs(heaters) do
    if otherdevices[device] ~= action then commandArray[device] = action end
  end
  if action == "On" then
    data.Heating = 1
  else
    data.Heating = 0
    data.EndHeatTime = 0
    if otherdevices[forcedheating] ~= "Off" then commandArray[forcedheating] = "Off" end
    data.ForcedHeatingTime = 0 -- just for cosmetics of user variable Internals
    data.ForcedHeating = 0
  end
  SaveData()
end

local function AutoCallib()
  if #AutoLearning ~= 6 then
    AutoLearning = NumbersStringToTable("0,1,1,0,0,0")
    return true
  elseif AutoLearning[1] ~= 1 then
    -- data not initilised
    return false
  elseif AutoLearning[6] == 0 then
    -- Heater was off, nothing to learn
    return false
  elseif AutoLearning[6] == 100 and setpoint > intemp then
    -- Heater was on max but consigne was not reached so we dont learn
    return false
  elseif intemp > AutoLearning[4] and setpoint > AutoLearning[4]  then
    -- Learn ConstC
    debuglog("Learning ConstC...")
    local ConstC = data.ConstC * ((setpoint - AutoLearning[4]) / (intemp - AutoLearning[4] )) * (now - data.LastCalc) / variable_get(uv.CalcInterval)
    data.ConstC = round((data.ConstC * AutoLearning[2] + ConstC) / (AutoLearning[2] +1),1)
    debuglog("ConstC = " .. data.ConstC)
    AutoLearning[2] = math.min(AutoLearning[2] +1 , 50)
    return true
  elseif setpoint > AutoLearning[5] then
    -- Learn ConstT
    debuglog("Learning ConstT...")
    local ConstT = data.ConstT + (( setpoint - intemp) / ( setpoint - AutoLearning[5] )) * data.ConstC * (now - data.LastCalc) / variable_get(uv.CalcInterval)
    data.ConstT = round((data.ConstT * AutoLearning[3] + ConstT) / (AutoLearning[3] +1),1)
    if data.ConstT  < 0 then data.ConstT = 0 end
    debuglog("ConstT = " .. data.ConstT)
    AutoLearning[3] = math.min(AutoLearning[3] +1 , 50)
    return true
  else
    return false
  end
end
 
local function AutoChangeOver(learn)
  outtemp = outtemp or setpoint -- if no external temp then we neutralize that factor
  if learn~=nil and learn == true then AutoCallib() end
  local power = round((setpoint - intemp) * data.ConstC + (setpoint - outtemp) * data.ConstT,1)
  if (power < 0) then power = 0 end -- Limite basse
  if (power > 100) then power = 100 end -- Limite haute
  if (power > 0) and (power <= powermin) then power = powermin end -- Seuil mini de power
  local heatduration = power * (variable_get(uv.CalcInterval)/100)
  heatduration = math.floor(heatduration)
  if power == 0 then
    data.Heating = 0
    data.EndHeatTime = 0
  else
    data.Heating = 1
    data.EndHeatTime = now + heatduration
  end
  data.LastCalc = now
--  variable_set(uv.LastCalc, data.LastCalc)
  if AutoLearning[1] < 2 then
    AutoLearning[1] = 1
    AutoLearning[4] = intemp
    AutoLearning[5] = outtemp
    AutoLearning[6] = power
  end
  debuglog("power = " .. power)
  debuglog("heatduration = " .. heatduration)
end

local function UpdateStatus()
  intemp = GetTemp(sensorsin)
  outtemp = GetTemp(sensorsout)
  if intemp then
    if tonumber(otherdevices[tempthermostat]) ~= intemp then
      commandArray['UpdateDevice'] = otherdevices_idx[tempthermostat] .. '|0|' .. intemp
    end
    GetData()
    -- test function
    if otherdevices[thermostat] == "On" then
      pause, pausechanged = GetPause()
      setpoint = GetSetPoint()
      if otherdevices[forcedheating] == "On" then -- we deal with forced heating situation
        if datetoepoch(otherdevices_lastupdate[forcedheating]) > data.ForcedHeatingTime then -- newly set
          data.ForcedHeatingTime = now
          data.ForcedHeating = 1
          data.EndHeatTime = now + variable_get(uv.ForcedHeatingDuration)
          data.Heating = 1
        end
      elseif pause then -- we deal with a pause situation
        data.Heating = 0
      elseif not(pause) and pausechanged then -- the pause just stopped... reset normal situation but no learning
        AutoChangeOver(false)
      else -- automatic mode
        if data.LastCalc <= now - variable_get(uv.CalcInterval) then
          debuglog("Calculation !")
          AutoChangeOver(true)
        elseif intemp >= setpoint + deltamax then
          debuglog("Temp exceeds setpoint... no heating")
          data.Heating = 0
        end
      end
      -- the actual "heat or no heat" question
      if data.Heating == 1 and now <= data.EndHeatTime then
        Heat("On")
      else
        Heat("Off")
      end
    else 
      -- thermostat is off but turn off heaters only if last update of any heater was later than thermostat shutdown
      -- so that user can force a heater on despite thermostat being off
      local lastupdate = 0
      for _, device in pairs(heaters) do
        lastupdate = math.max(lastupdate, datetoepoch(otherdevices_lastupdate[device]))
      end
      if datetoepoch(otherdevices_lastupdate[thermostat]) > lastupdate then Heat("Off") end
      -- turn off forcedheating device if it was still on despite thermostat being off
      if otherdevices[forcedheating] ~= "Off" then commandArray[forcedheating] = "Off" end
    end
  else
    print("SVT: Error reading temps... Thermostat disabled")
    Heat("Off")
    if otherdevices[thermostat] ~= "Off" then commandArray[thermostat] = "Off" end
  end
end

-- MAIN PROGRAM BODY

-- code to run every time event (i.e. every minute)

UpdateStatus()
DebugTable("commandArray", commandArray)

return commandArray
