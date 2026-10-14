local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally

local scan : PgraceVehicleDestinationScan = {}

local type Entry = PgraceVehicleDestinationTally.Entry

local LOG_PREFIX = "[vehicle_destination] "

-- Logged once per session, so a broken car or edge doesn't flood the log on every refresh.
local loggedCarError = false
local loggedEdgeError = false

-- Search radius around the camera's look-at point: a multiple of the eye's distance (a tilted view sees far past
-- the look-at point), clamped.
local RADIUS_PER_DISTANCE = 2.5
local MIN_RADIUS = 300.0
local MAX_RADIUS = 8000.0

-- PROBE (remove before release): the farthest drawn car's edge from the look-at point, as a multiple of the eye's
-- distance, to size RADIUS_PER_DISTANCE.
local probeMaxRatio = 0.0

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

-- PROBE (remove before release)
local function probeEdgeRatio(edge : Engine.Entity, center : Vec3f, distance : number)
	local baseEdge = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	for __, node in ipairs({ baseEdge.node0, baseEdge.node1 }) do
		local baseNode = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		local dx, dy = baseNode.position.x - center.x, baseNode.position.y - center.y
		probeMaxRatio = math.max(probeMaxRatio, math.sqrt(dx * dx + dy * dy) / distance)
	end
end

-- A person on the street: counted if driving (and, with onlyVisible, drawn on screen). Returns whether it was drawn.
local function readOne(person : Engine.Entity, result : PgraceVehicleDestinationScan.Result, drive : MoveMode,
		onlyVisible : boolean) : boolean
	if not api.engine.entityExists(person) then
		return false
	end
	local simPerson = api.engine.getComponent(person, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
	if simPerson == nil or simPerson.lastMoveMode ~= drive then
		return false
	end
	result.drivers = result.drivers + 1
	-- A driving person is the car itself (it has LAND_VEHICLE and MOVE_PATH), so isVisible works on it.
	local drawn = api.gui.byEntity.isVisible(person)
	if drawn then
		result.drawn = result.drawn + 1
	end
	if drawn or not onlyVisible then
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
	return drawn
end

-- os.clock() is process CPU time, so it may over-read while worker threads are busy (Trim the Fat uses the same
-- measure).
function scan.cars(onlyVisible : boolean) : PgraceVehicleDestinationScan.Result
	local start = os.clock()
	local drive = api.type["enum"].MoveMode.DRIVE
	if drive == nil then
		error("MoveMode.DRIVE missing")
	end

	-- SIM_ENTITY_MOVING can't be looped over ("Cannot loop over this component type"), so take the street edges
	-- around the camera's look-at point and ask each for the people moving on it. The circle is generous; isVisible
	-- decides what's on screen.
	local center = api.gui.camera.getCenter()
	local eye = api.gui.camera.getEye()
	local dx, dy, dz = eye.x - center.x, eye.y - center.y, eye.z - center.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	local radius = math.min(math.max(distance * RADIUS_PER_DISTANCE, MIN_RADIUS), MAX_RADIUS)
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(center.x, center.y), radius,
		api.type.ComponentType.BASE_EDGE_STREET)

	local result : PgraceVehicleDestinationScan.Result = {
		entries = {}, edges = #edges, radius = math.floor(radius + 0.5), moving = 0, drivers = 0, drawn = 0, ms = 0,
	}
	local seen : {Engine.Entity : boolean} = {}
	local simPersonSystem = api.engine.system.simPersonSystem
	probeMaxRatio = 0.0 -- PROBE (remove before release)
	for __, edge in ipairs(edges) do
		local ok, peopleOrError = pcall(simPersonSystem.getSimPersonsMovingForTransportNetwork, edge)
		if ok then
			local anyDrawn = false -- PROBE (remove before release)
			for __, person in ipairs(peopleOrError as {Engine.Entity}) do
				if not seen[person] then
					seen[person] = true
					result.moving = result.moving + 1
					local readOk, drawnOrError = pcall(readOne, person, result, drive, onlyVisible)
					if not readOk and not loggedCarError then
						loggedCarError = true
						debugPrint(LOG_PREFIX .. "entity " .. tostring(person) .. " error: " .. tostring(drawnOrError))
					end
					anyDrawn = anyDrawn or (readOk and drawnOrError == true) -- PROBE (remove before release)
				end
			end
			if anyDrawn and distance > 0 then -- PROBE (remove before release)
				pcall(probeEdgeRatio, edge, center, distance) -- PROBE (remove before release)
			end -- PROBE (remove before release)
		elseif not loggedEdgeError then
			loggedEdgeError = true
			debugPrint(LOG_PREFIX .. "edge " .. tostring(edge) .. " error: " .. tostring(peopleOrError))
		end
	end
	result.ms = math.floor((os.clock() - start) * 1000 + 0.5)

	debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.edges) .. " street edges in " .. tostring(result.radius)
		.. " m, " .. tostring(result.moving) .. " moving, " .. tostring(result.drivers) .. " drivers, "
		.. tostring(result.drawn) .. " drawn, " .. tostring(#result.entries) .. " counted, " .. tostring(result.ms) .. " ms")
	debugPrint(LOG_PREFIX .. "probe radius: eye distance " .. tostring(math.floor(distance + 0.5)) -- PROBE (remove before release)
		.. " m, farthest drawn edge at " .. string.format("%.2f", probeMaxRatio) .. "x") -- PROBE (remove before release)
	return result
end

return scan
