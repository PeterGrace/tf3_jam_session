local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally

local scan : PgraceVehicleDestinationScan = {}

local type Entry = PgraceVehicleDestinationTally.Entry

local LOG_PREFIX = "[vehicle_destination] "

-- Logged once per session, so a broken car doesn't flood the log on every refresh.
local loggedCarError = false
local loggedEdgeError = false

-- Search radius around the camera's look-at point: a multiple of the eye's distance (a tilted view sees far past
-- the look-at point), clamped.
local RADIUS_PER_DISTANCE = 2.5
local MIN_RADIUS = 300.0
local MAX_RADIUS = 8000.0

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

local function readOne(person : Engine.Entity, result : PgraceVehicleDestinationScan.Result, drive : MoveMode) : boolean
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
			probeDriversLeft = probeDriversLeft - 1 -- PROBE (remove before release)
			local t1 = os.clock() -- PROBE (remove before release)
			pcall(probeDetails, person, simPerson) -- PROBE (remove before release)
			probeMs = probeMs + (os.clock() - t1) * 1000 -- PROBE (remove before release)
		end -- PROBE (remove before release)
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
	else -- PROBE (remove before release): the whole else branch
		local t2 = os.clock() -- PROBE (remove before release)
		if probeOthersLeft > 0 then -- PROBE (remove before release)
			probeOthersLeft = probeOthersLeft - 1 -- PROBE (remove before release)
			pcall(probeDetails, person, simPerson) -- PROBE (remove before release)
		end -- PROBE (remove before release)
		if api.gui.byEntity.isVisible(person) then -- PROBE (remove before release)
			visibleNonDrivers = visibleNonDrivers + 1 -- PROBE (remove before release)
		end -- PROBE (remove before release)
		probeMs = probeMs + (os.clock() - t2) * 1000 -- PROBE (remove before release)
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

	-- SIM_ENTITY_MOVING can't be looped over ("Cannot loop over this component type"), so take the street edges
	-- around the camera's look-at point and ask each for the people moving on it. The circle is generous; isVisible
	-- decides what's on screen.
	local center = api.gui.camera.getCenter()
	local eye = api.gui.camera.getEye()
	local dx, dy, dz = eye.x - center.x, eye.y - center.y, eye.z - center.z
	local radius = math.min(math.max(math.sqrt(dx * dx + dy * dy + dz * dz) * RADIUS_PER_DISTANCE, MIN_RADIUS), MAX_RADIUS)
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(center.x, center.y), radius,
		api.type.ComponentType.BASE_EDGE_STREET)
	local seen : {Engine.Entity : boolean} = {}
	local moving : {Engine.Entity} = {}
	local simPersonSystem = api.engine.system.simPersonSystem
	for __, edge in ipairs(edges) do
		local ok, peopleOrError = pcall(simPersonSystem.getSimPersonsMovingForTransportNetwork, edge)
		if ok then
			for __, person in ipairs(peopleOrError as {Engine.Entity}) do
				if not seen[person] then
					seen[person] = true
					moving[#moving + 1] = person
				end
			end
		elseif not loggedEdgeError then
			loggedEdgeError = true
			debugPrint(LOG_PREFIX .. "edge " .. tostring(edge) .. " error: " .. tostring(peopleOrError))
		end
	end

	local result : PgraceVehicleDestinationScan.Result = {
		entries = {}, edges = #edges, radius = math.floor(radius + 0.5), moving = #moving, drivers = 0, ms = 0,
	}
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

	debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.edges) .. " street edges in " .. tostring(result.radius)
		.. " m, " .. tostring(result.moving) .. " moving, " .. tostring(result.drivers)
		.. " drivers, " .. tostring(#result.entries) .. " visible, " .. tostring(result.ms) .. " ms (probe "
		.. tostring(math.floor(probeMs + 0.5)) .. " ms)")
	return result
end

return scan
