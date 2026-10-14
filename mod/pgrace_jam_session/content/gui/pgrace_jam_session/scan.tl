local tally = ug_require "pgrace_jam_session::/gui/pgrace_jam_session/tally.tl" as PgraceJamSessionTally

local scan : PgraceJamSessionScan = {}

local type Entry = PgraceJamSessionTally.Entry

local LOG_PREFIX = "[jam_session] "

-- Logged once per session, so a broken car or edge doesn't flood the log on every refresh.
local loggedCarError = false
local loggedEdgeError = false
local loggedFootprintError = false
local loggedTileError = false

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

-- The town of a town building, and its name (from `names`, filled as towns are first seen); nil if it isn't one.
local function townOf(building : Engine.Entity, names : {Engine.Entity : string}) : Engine.Entity, string
	if building == nil or building < 0 or not api.engine.entityExists(building) then
		return nil, nil
	end
	local townBuilding = api.engine.getComponent(building, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
	local town = townBuilding ~= nil and townBuilding.town or nil
	if town == nil or town < 0 or not api.engine.entityExists(town) then
		return nil, nil
	end
	local name = names[town]
	if name == nil then
		name = api.engine.util.getEntityName(town)
		names[town] = name
	end
	return town, name
end

local function entryFor(simPerson : Engine.Component.SimPerson, names : {Engine.Entity : string}) : Entry
	local target = simPerson.targetOrAtEntity
	local entry : Entry = { purpose = tally.purposeOf(target, simPerson.destinations) }
	entry.town, entry.townName = townOf(target, names)
	-- The base game's rule (tally.originOf). lastNonResType is a LandUseType: 1 shopping, 2 work.
	local origin = tally.originOf(target, simPerson.destinations, simPerson.lastNonResType as integer)
	entry.from, entry.fromName = townOf(origin, names)
	return entry
end

-- The search area is looked up in tiles about this wide, one tile per unit of work: a single lookup of a city-wide
-- circle took 60 ms.
local TILE_SIZE = 1000.0

-- A person on the street: an entry if driving, flagged with whether it's drawn on screen. Returns true (for pcall).
local function readOne(person : Engine.Entity, result : PgraceJamSessionScan.Result, drive : MoveMode,
		names : {Engine.Entity : string}) : boolean
	if not api.engine.entityExists(person) then
		return true
	end
	local simPerson = api.engine.getComponent(person, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
	if simPerson == nil or simPerson.lastMoveMode ~= drive then
		return true
	end
	-- A driving person is the car itself (it has LAND_VEHICLE and MOVE_PATH), so isVisible works on it. Counted as a
	-- driver only once it's read, so drivers matches the entries.
	local drawn = api.gui.byEntity.isVisible(person)
	result.drivers = result.drivers + 1
	if drawn then
		result.drawn = result.drawn + 1
	end
	local ok, entryOrError = pcall(entryFor, simPerson, names)
	local entry : Entry = { town = nil }
	if ok then
		entry = entryOrError as Entry
	elseif not loggedCarError then
		loggedCarError = true
		debugPrint(LOG_PREFIX .. "car " .. tostring(person) .. " error: " .. tostring(entryOrError))
	end
	entry.drawn = drawn
	result.entries[#result.entries + 1] = entry
	return true
end

-- Internal state of a scan, behind the opaque Job type.
local record JobState
	drive : MoveMode
	clock : Clock
	-- Microseconds of work so far (only the time spent in step).
	workUs : integer
	steps : integer
	-- Tile circles still to look up ({x, y, radius}), and how many of them are done.
	tiles : {{number}}
	tilesDone : integer
	-- Street edges found so far, deduplicated, and how many of them are done.
	edges : {Engine.Entity}
	edgeSeen : {Engine.Entity : boolean}
	edgesDone : integer
	-- People already read (a car can sit on two edges' lists).
	seen : {Engine.Entity : boolean}
	names : {Engine.Entity : string}
	result : PgraceJamSessionScan.Result
end

-- Tiles covering the search circle: a grid of TILE_SIZE cells over its bounding square, each looked up as the circle
-- around the cell, skipping cells that can't touch the search circle.
local function tilesFor(circle : Circle) : {{number}}
	local tiles : {{number}} = {}
	local cells = math.max(1, math.ceil(2 * circle.radius / TILE_SIZE))
	local size = 2 * circle.radius / cells
	local tileRadius = size * math.sqrt(0.5)
	for i = 0, cells - 1 do
		for j = 0, cells - 1 do
			local x = circle.x - circle.radius + (i + 0.5) * size
			local y = circle.y - circle.radius + (j + 0.5) * size
			local dx, dy = x - circle.x, y - circle.y
			if math.sqrt(dx * dx + dy * dy) <= circle.radius + tileRadius then
				tiles[#tiles + 1] = { x, y, tileRadius }
			end
		end
	end
	return tiles
end

-- Reads the camera and works out the search area; the street lookups and the cars are left to step. Main thread only.
function scan.start() : PgraceJamSessionScan.Job
	local clock = api.type.Clock.new()
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
	local circle : Circle = { x = center.x, y = center.y,
		radius = math.min(math.max(distance * RADIUS_PER_DISTANCE, MIN_RADIUS), MAX_RADIUS) }
	local footprintOk, footprintOrError = pcall(screenFootprint, center, MAX_RADIUS)
	if footprintOk and footprintOrError ~= nil then
		circle = footprintOrError as Circle
		circle.radius = math.max(circle.radius, MIN_RADIUS)
	elseif not footprintOk and not loggedFootprintError then
		loggedFootprintError = true
		debugPrint(LOG_PREFIX .. "footprint error: " .. tostring(footprintOrError))
	end

	local job : JobState = {
		drive = drive, clock = clock, workUs = 0, steps = 0,
		tiles = tilesFor(circle), tilesDone = 0,
		edges = {}, edgeSeen = {}, edgesDone = 0,
		seen = {}, names = {},
		result = {
			entries = {}, center = api.type.Vec3f.new(center.x, center.y, center.z), edges = 0,
			radius = math.floor(circle.radius + 0.5), moving = 0, drivers = 0, drawn = 0, ms = 0,
		},
	}
	job.workUs = clock:getTime()
	return job as any as PgraceJamSessionScan.Job
end

local function lookUpTile(job : JobState, tile : {number})
	local ok, edgesOrError = pcall(api.engine.util.octree.findEntitiesInCircle, api.type.Vec2f.new(tile[1], tile[2]),
		tile[3], api.type.ComponentType.BASE_EDGE_STREET)
	if not ok then
		if not loggedTileError then
			loggedTileError = true
			debugPrint(LOG_PREFIX .. "tile error: " .. tostring(edgesOrError))
		end
		return
	end
	for __, edge in ipairs(edgesOrError as {Engine.Entity}) do
		if not job.edgeSeen[edge] then
			job.edgeSeen[edge] = true
			job.edges[#job.edges + 1] = edge
		end
	end
end

local function readEdge(job : JobState, edge : Engine.Entity)
	local ok, peopleOrError = pcall(api.engine.system.simPersonSystem.getSimPersonsMovingForTransportNetwork, edge)
	if not ok then
		if not loggedEdgeError then
			loggedEdgeError = true
			debugPrint(LOG_PREFIX .. "edge " .. tostring(edge) .. " error: " .. tostring(peopleOrError))
		end
		return
	end
	local result = job.result
	for __, person in ipairs(peopleOrError as {Engine.Entity}) do
		if not job.seen[person] then
			job.seen[person] = true
			result.moving = result.moving + 1
			local readOk, err = pcall(readOne, person, result, job.drive, job.names)
			if not readOk and not loggedCarError then
				loggedCarError = true
				debugPrint(LOG_PREFIX .. "entity " .. tostring(person) .. " error: " .. tostring(err))
			end
		end
	end
end

-- Does work until `budgetUs` microseconds have passed (at least one unit: a tile, or an edge and its people).
-- Returns true when the scan is done; then job's result is complete. Main thread only (isVisible).
function scan.step(publicJob : PgraceJamSessionScan.Job, budgetUs : integer) : boolean
	local job = publicJob as any as JobState
	local stepStart = job.clock:getTime()
	job.steps = job.steps + 1
	repeat
		if job.tilesDone < #job.tiles then
			job.tilesDone = job.tilesDone + 1
			lookUpTile(job, job.tiles[job.tilesDone])
		elseif job.edgesDone < #job.edges then
			job.edgesDone = job.edgesDone + 1
			readEdge(job, job.edges[job.edgesDone])
		else
			break
		end
	until job.clock:getTime() - stepStart >= budgetUs
	local now = job.clock:getTime()
	job.workUs = job.workUs + (now - stepStart)
	local done = job.tilesDone >= #job.tiles and job.edgesDone >= #job.edges
	if done then
		local result = job.result
		result.edges = #job.edges
		result.ms = math.floor(job.workUs / 1000 + 0.5)
		debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.edges) .. " street edges in " .. tostring(result.radius)
			.. " m (" .. tostring(#job.tiles) .. " tiles), " .. tostring(result.moving) .. " moving, "
			.. tostring(result.drivers) .. " drivers, " .. tostring(result.drawn) .. " drawn; " .. tostring(result.ms)
			.. " ms of work over " .. tostring(job.steps) .. " frames, "
			.. tostring(math.floor(now / 1000 + 0.5)) .. " ms in all")
	end
	return done
end

-- Share of the work done, 0 to 1. The tiles come first and stand for a fifth of it (their edge count isn't known
-- until they're looked up).
function scan.progress(publicJob : PgraceJamSessionScan.Job) : number
	local job = publicJob as any as JobState
	local tiles = #job.tiles > 0 and job.tilesDone / #job.tiles or 1
	if job.tilesDone < #job.tiles then
		return 0.2 * tiles
	end
	return 0.2 + 0.8 * (#job.edges > 0 and job.edgesDone / #job.edges or 1)
end

function scan.result(publicJob : PgraceJamSessionScan.Job) : PgraceJamSessionScan.Result
	return (publicJob as any as JobState).result
end

return scan
