local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally

local scan : PgraceVehicleDestinationScan = {}

local type Entry = PgraceVehicleDestinationTally.Entry

local LOG_PREFIX = "[vehicle_destination] "

-- Logged once per session, so a broken car doesn't flood the log on every refresh.
local loggedCarError = false

-- PROBE (remove before release): per-scan sample budgets, reset at the start of each scan.
local probeDriversLeft = 0
local probeOthersLeft = 0
local probeMs = 0.0
local modeCounts : {string : integer} = {}
local visibleNonDrivers = 0

local function entryFor(simPerson : Engine.Component.SimPerson) : Entry
	local target = simPerson.targetOrAtEntity
	local purpose = tally.purposeOf(target, simPerson.destinations)
	if target == nil or target < 0 or not api.engine.entityExists(target) then
		return { town = nil, purpose = purpose }
	end
	local building = api.engine.getComponent(target, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
	if building == nil or building.town == nil or building.town < 0 or not api.engine.entityExists(building.town) then
		return { town = nil, purpose = purpose }
	end
	return { town = building.town, townName = api.engine.util.getEntityName(building.town), purpose = purpose }
end

-- PROBE (remove before release): what a driving person looks like.
local function probeDetails(person : Engine.Entity, simPerson : Engine.Component.SimPerson)
	local has = function(ct : Engine.ComponentType) : string
		return api.engine.getComponent(person, ct) ~= nil and "y" or "n"
	end
	local c = api.type.ComponentType
	local target = simPerson.targetOrAtEntity
	local targetIsBuilding = target ~= nil and target >= 0 and api.engine.entityExists(target)
		and api.engine.getComponent(target, c.TOWN_BUILDING) ~= nil
	local dests : {string} = {}
	for i, d in ipairs(simPerson.destinations or {}) do
		dests[i] = tostring(d)
	end
	local vehicleVisible = "err"
	local ok, v = pcall(api.gui.byEntity.isVehicleVisible, person)
	if ok then
		vehicleVisible = tostring(v)
	end
	debugPrint(LOG_PREFIX .. "probe car " .. tostring(person)
		.. " mode=" .. tostring(simPerson.lastMoveMode)
		.. " isVisible=" .. tostring(api.gui.byEntity.isVisible(person))
		.. " isVehicleVisible=" .. vehicleVisible
		.. " target=" .. tostring(target) .. " targetIsTownBuilding=" .. tostring(targetIsBuilding)
		.. " destinations={" .. table.concat(dests, ",") .. "}"
		.. " MOVE_PATH=" .. has(c.MOVE_PATH) .. " MODEL_PERSON=" .. has(c.MODEL_PERSON)
		.. " SIM_ENTITY_AT_VEHICLE=" .. has(c.SIM_ENTITY_AT_VEHICLE) .. " LAND_VEHICLE=" .. has(c.LAND_VEHICLE))
end

local function readOne(person : Engine.Entity, result : PgraceVehicleDestinationScan.Result, drive : any) : boolean
	if not api.engine.entityExists(person) then
		return true
	end
	local simPerson = api.engine.getComponent(person, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
	if simPerson == nil then
		return true
	end
	local t0 = os.clock() -- PROBE (remove before release)
	local modeKey = tostring(simPerson.lastMoveMode) -- PROBE (remove before release)
	modeCounts[modeKey] = (modeCounts[modeKey] or 0) + 1 -- PROBE (remove before release)
	probeMs = probeMs + (os.clock() - t0) * 1000 -- PROBE (remove before release)
	if simPerson.lastMoveMode == drive then
		result.drivers = result.drivers + 1
		if probeDriversLeft > 0 then -- PROBE (remove before release)
			probeDriversLeft = probeDriversLeft - 1
			local t1 = os.clock()
			pcall(probeDetails, person, simPerson)
			probeMs = probeMs + (os.clock() - t1) * 1000
		end
		if api.gui.byEntity.isVisible(person) then
			local ok, entryOrError = pcall(entryFor, simPerson)
			if ok then
				result.entries[#result.entries + 1] = entryOrError as Entry
			else
				result.entries[#result.entries + 1] = { town = nil }
				if not loggedCarError then
					loggedCarError = true
					debugPrint(LOG_PREFIX .. "car " .. tostring(person) .. " error: " .. tostring(entryOrError))
				end
			end
		end
	else
		local t2 = os.clock() -- PROBE (remove before release)
		if probeOthersLeft > 0 then
			probeOthersLeft = probeOthersLeft - 1
			pcall(probeDetails, person, simPerson)
		end
		if api.gui.byEntity.isVisible(person) then
			visibleNonDrivers = visibleNonDrivers + 1
		end
		probeMs = probeMs + (os.clock() - t2) * 1000
	end
	return true
end

-- os.clock() is process CPU time, so it may over-read while worker threads are busy (Trim the Fat uses the same
-- measure). Probe-only work is timed separately (probeMs) and left out of result.ms.
function scan.visibleCars() : PgraceVehicleDestinationScan.Result
	local start = os.clock()
	local drive = api.type["enum"].MoveMode.DRIVE
	if drive == nil then
		error("MoveMode.DRIVE missing")
	end
	probeDriversLeft = 3 -- PROBE (remove before release)
	probeOthersLeft = 2 -- PROBE (remove before release)
	probeMs = 0.0 -- PROBE (remove before release)
	modeCounts = {} -- PROBE (remove before release)
	visibleNonDrivers = 0 -- PROBE (remove before release)

	local moving : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(e : Engine.Entity)
		moving[#moving + 1] = e
	end, api.type.ComponentType.SIM_ENTITY_MOVING)

	local result : PgraceVehicleDestinationScan.Result = { entries = {}, moving = #moving, drivers = 0, ms = 0 }
	for __, person in ipairs(moving) do
		local ok, err = pcall(readOne, person, result, drive)
		if not ok and not loggedCarError then
			loggedCarError = true
			debugPrint(LOG_PREFIX .. "entity " .. tostring(person) .. " error: " .. tostring(err))
		end
	end
	local totalMs = (os.clock() - start) * 1000
	result.ms = math.floor(math.max(totalMs - probeMs, 0) + 0.5)

	-- PROBE (remove before release): move modes seen, and how many people on screen aren't drivers.
	local modes : {string} = {}
	for mode, count in pairs(modeCounts) do
		modes[#modes + 1] = mode .. "=" .. tostring(count)
	end
	debugPrint(LOG_PREFIX .. "probe modes " .. table.concat(modes, " ") .. " DRIVE=" .. tostring(drive)
		.. " visibleNonDrivers=" .. tostring(visibleNonDrivers))

	debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.moving) .. " moving, " .. tostring(result.drivers)
		.. " drivers, " .. tostring(#result.entries) .. " visible, " .. tostring(result.ms) .. " ms (probe "
		.. tostring(math.floor(probeMs + 0.5)) .. " ms)")
	return result
end

return scan
