local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally

local scan : PgraceVehicleDestinationScan = {}

local type Entry = PgraceVehicleDestinationTally.Entry

local LOG_PREFIX = "[vehicle_destination] "

-- Logged once per session, so a broken car or edge doesn't flood the log on every refresh.
local loggedCarError = false
local loggedEdgeError = false
local loggedFootprintError = false

-- Search radius around the camera's look-at point: a multiple of the eye's distance (a tilted view sees far past
-- the look-at point), clamped.
local RADIUS_PER_DISTANCE = 2.5
local MIN_RADIUS = 300.0
local MAX_RADIUS = 8000.0

-- The search circle is grown by this much past the screen's footprint on the ground (hills, long edges).
local FOOTPRINT_MARGIN = 1.1
local FOOTPRINT_MARGIN_METRES = 50.0

-- Screen points whose rays outline the view: corners and edge midpoints, as fractions of the screen.
local OUTLINE : {{number}} = {
	{ 0, 0 }, { 0.5, 0 }, { 1, 0 }, { 1, 0.5 }, { 1, 1 }, { 0.5, 1 }, { 0, 1 }, { 0, 0.5 },
}

local record Circle
	x : number
	y : number
	radius : number
end

-- Where the ray through screen pixel (px, py) meets the plane z = groundZ, as x, y; nil if it doesn't (pointing at
-- the sky). screen2World takes a depth in [0, 1]; the near and far ends of the ray give its direction, whichever end
-- the depths map to. Main thread only.
local function groundPoint(px : number, py : number, groundZ : number) : number, number
	local a = api.gui.camera.screen2World(api.type.Vec3f.new(px, py, 0))
	local b = api.gui.camera.screen2World(api.type.Vec3f.new(px, py, 1))
	local dz = b.z - a.z
	if math.abs(dz) < 1e-6 then
		return nil, nil
	end
	local t = (groundZ - a.z) / dz
	if t < 0 then
		return nil, nil
	end
	return a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)
end

-- A circle around the ground the screen shows, or nil if it can't be worked out. Rays that miss the ground (above
-- the horizon) or land past maxRadius count as maxRadius from the look-at point, in their direction.
local function screenFootprint(center : Vec3f, maxRadius : number) : Circle
	local size = api.gui.camera.getSize()
	if size == nil or size.x <= 0 or size.y <= 0 then
		return nil
	end
	local xs : {number} = {}
	local ys : {number} = {}
	for __, f in ipairs(OUTLINE) do
		local px, py = f[1] * size.x, f[2] * size.y
		local x, y = groundPoint(px, py, center.z)
		if x == nil then
			-- Towards the sky: take the direction of the ray's far end, from the look-at point.
			local far = api.gui.camera.screen2World(api.type.Vec3f.new(px, py, 1))
			x, y = far.x, far.y
		end
		local dx, dy = x - center.x, y - center.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d > maxRadius then
			x, y = center.x + dx / d * maxRadius, center.y + dy / d * maxRadius
		end
		xs[#xs + 1], ys[#ys + 1] = x, y
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for i = 1, #xs do
		minX, maxX = math.min(minX, xs[i]), math.max(maxX, xs[i])
		minY, maxY = math.min(minY, ys[i]), math.max(maxY, ys[i])
	end
	local cx, cy = 0.5 * (minX + maxX), 0.5 * (minY + maxY)
	local radius = 0.0
	for i = 1, #xs do
		local dx, dy = xs[i] - cx, ys[i] - cy
		radius = math.max(radius, math.sqrt(dx * dx + dy * dy))
	end
	return { x = cx, y = cy, radius = math.min(radius * FOOTPRINT_MARGIN + FOOTPRINT_MARGIN_METRES, maxRadius) }
end

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
local function probeEdgeRatio(edge : Engine.Entity, center : Circle, distance : number)
	local baseEdge = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	for __, node in ipairs({ baseEdge.node0, baseEdge.node1 }) do
		local baseNode = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		local dx, dy = baseNode.position.x - center.x, baseNode.position.y - center.y
		probeMaxRatio = math.max(probeMaxRatio, math.sqrt(dx * dx + dy * dy) / distance)
	end
end

-- A person on the street: an entry if driving, flagged with whether it's drawn on screen. Returns whether it was drawn.
local function readOne(person : Engine.Entity, result : PgraceVehicleDestinationScan.Result, drive : MoveMode) : boolean
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
	local ok, entryOrError = pcall(entryFor, simPerson)
	local entry : Entry = { town = nil }
	if ok then
		entry = entryOrError as Entry
	elseif not loggedCarError then
		loggedCarError = true
		debugPrint(LOG_PREFIX .. "car " .. tostring(person) .. " error: " .. tostring(entryOrError))
	end
	entry.drawn = drawn
	result.entries[#result.entries + 1] = entry
	return drawn
end

-- os.clock() is process CPU time, so it may over-read while worker threads are busy (Trim the Fat uses the same
-- measure).
function scan.cars() : PgraceVehicleDestinationScan.Result
	local start = os.clock()
	local drive = api.type["enum"].MoveMode.DRIVE
	if drive == nil then
		error("MoveMode.DRIVE missing")
	end

	-- SIM_ENTITY_MOVING can't be looped over ("Cannot loop over this component type"), so take the street edges in a
	-- circle around the ground the screen shows and ask each for the people moving on it; isVisible decides what's
	-- on screen. If the footprint can't be worked out, a circle around the look-at point sized by the eye's distance.
	local center = api.gui.camera.getCenter()
	local eye = api.gui.camera.getEye()
	local dx, dy, dz = eye.x - center.x, eye.y - center.y, eye.z - center.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	local fallback : Circle = { x = center.x, y = center.y,
		radius = math.min(math.max(distance * RADIUS_PER_DISTANCE, MIN_RADIUS), MAX_RADIUS) }
	local footprintOk, footprintOrError = pcall(screenFootprint, center, MAX_RADIUS)
	local circle = fallback
	if footprintOk and footprintOrError ~= nil then
		circle = footprintOrError as Circle
		circle.radius = math.max(circle.radius, MIN_RADIUS)
	elseif not footprintOk and not loggedFootprintError then
		loggedFootprintError = true
		debugPrint(LOG_PREFIX .. "footprint error: " .. tostring(footprintOrError))
	end
	local radius = circle.radius
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(circle.x, circle.y), radius,
		api.type.ComponentType.BASE_EDGE_STREET)

	local result : PgraceVehicleDestinationScan.Result = {
		entries = {}, center = center, edges = #edges, radius = math.floor(radius + 0.5), moving = 0, drivers = 0, drawn = 0,
		ms = 0,
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
					local readOk, drawnOrError = pcall(readOne, person, result, drive)
					if not readOk and not loggedCarError then
						loggedCarError = true
						debugPrint(LOG_PREFIX .. "entity " .. tostring(person) .. " error: " .. tostring(drawnOrError))
					end
					anyDrawn = anyDrawn or (readOk and drawnOrError == true) -- PROBE (remove before release)
				end
			end
			if anyDrawn and distance > 0 then -- PROBE (remove before release)
				pcall(probeEdgeRatio, edge, circle, circle.radius) -- PROBE (remove before release)
			end -- PROBE (remove before release)
		elseif not loggedEdgeError then
			loggedEdgeError = true
			debugPrint(LOG_PREFIX .. "edge " .. tostring(edge) .. " error: " .. tostring(peopleOrError))
		end
	end
	result.ms = math.floor((os.clock() - start) * 1000 + 0.5)

	debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.edges) .. " street edges in " .. tostring(result.radius)
		.. " m, " .. tostring(result.moving) .. " moving, " .. tostring(result.drivers) .. " drivers, "
		.. tostring(result.drawn) .. " drawn, " .. tostring(result.ms) .. " ms")
	debugPrint(LOG_PREFIX .. "probe footprint: " .. (circle == fallback and "FALLBACK" or "ok") -- PROBE (remove before release)
		.. " eye distance " .. tostring(math.floor(distance + 0.5)) .. " m, old radius " -- PROBE (remove before release)
		.. tostring(math.floor(fallback.radius + 0.5)) .. " m, circle off look-at by " -- PROBE (remove before release)
		.. tostring(math.floor(math.sqrt((circle.x - center.x) ^ 2 + (circle.y - center.y) ^ 2) + 0.5)) -- PROBE (remove before release)
		.. " m, farthest drawn edge at " .. string.format("%.2f", probeMaxRatio) .. " of the radius") -- PROBE (remove before release)
	return result
end

return scan
