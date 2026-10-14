local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local tool_react_util = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local color_util = ug_require "::/gui/main/color_util.tl" as ColorUtil
local callout_react_util = ug_require "::/gui/main/callout_react_util.tl" as CalloutReactUtil
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local notification_util = ug_require "::/game_mechanics/notifications/notification_util.tl" as NotificationUtil
local tally = ug_require "pgrace_jam_session::/gui/pgrace_jam_session/tally.tl" as PgraceJamSessionTally
local scan = ug_require "pgrace_jam_session::/gui/pgrace_jam_session/scan.tl" as PgraceJamSessionScan

local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors

local LOG_PREFIX = "[jam_session] "
-- The mod's name, a brand: not translated (as Commuter Compass).
local MOD_NAME = "Jam Session"
local WINDOW_ID = "pgrace_jam_session_window"
local BUTTON_ICON = "::/gui/entity_window/icons/vehicle_car.tga"
local REFRESH_ICON = "::/gui/builtin/window/icons/refresh.tga"
-- F2's "Show Only Visible" toggle (statistics_react_util.createShowOnlyVisibleButton).
local EYE_ICON = "::/gui/statistics/icons/symbol_eye_18.tga"
local LOCATE_ICON = "::/gui/line_vehicle_mgmt/icons/symbol_locate.tga"
local ARROW_ICON = "::/gui/entity_window/icons/symbol_arrow_up.tga"
local FLOW_ACTION_KEY = "pgrace_jam_session_flow"
-- Framing the arrow, as Commuter Compass: camera distance as a multiple of the arrow's length, clamped (focusPosition
-- caps it at the game's maximum zoom-out, about 4,055 m).
local CAMERA_DISTANCE_FACTOR = 1.6
local CAMERA_MIN_DISTANCE = 500
local CAMERA_MAX_DISTANCE = 4000
-- How far to move the view toward the camera, as a fraction of the camera distance, so the arrow sits in the map area
-- above our window (docked bottom-centre, about the lower 40% of the screen). Looked right in-game.
local CAMERA_WINDOW_SHIFT = 0.2
-- The cargo-flow arrow is drawn as an arc this high (as a share of its length); the label sits on its top
-- (Commuter Compass, measured by eye).
local ARROW_ARC_HEIGHT = 0.06
-- F2's class for numeric columns; window.css.lua aligns it inside our window.
local RIGHT_ALIGNED = "right-aligned"

local type ToolParam = ToolReactUtil.IToolParam
local type Row = PgraceJamSessionTally.Row
local type Result = PgraceJamSessionTally.Result

-- One list for the table: a count's cars, all or only those drawn (the eye). Both lists of a count share its
-- spot, generation and distances.
local record Snapshot
	error : boolean
	-- Which list this is; part of the table's key.
	onlyVisible : boolean
	result : Result
	-- rowKey (an id per origin and destination pair, see pairKey) -> row.
	rows : {integer : Row}
	keys : {integer}
	-- Differs per scan, so a refresh remounts the table (cells keep their first userParam).
	generation : integer
	-- Where the cars were counted (the camera's look-at point); the arrows start here.
	from : Vec3f
	-- Destination town -> straight-line metres from `from` (the counted spot) to its centre, and its text ("Here").
	distance : {integer : number}
	distanceText : {integer : string}
	-- rowKey -> straight-line metres from the origin town's centre to the destination's, and its text ("Trip").
	trip : {integer : number}
	tripText : {integer : string}
	-- The row key (trip) whose arrow is shown, or nil. Set by the window when it renders, so cells can read and change it.
	selectionState : ReactStateT<integer>
	-- Shrinks the window if it's expanded (set by the window when it renders, as selectionState).
	collapse : function()
end

-- One count (on open and on Refresh). The eye only picks a list, so toggling it never counts again or moves the
-- counted spot.
local record Count
	visible : Snapshot
	all : Snapshot
end

local nextGeneration = 0

-- react.enqueueJoin without a pcall around it (react.lua doExecute), and a join can run just after its recipe has
-- unmounted (the window closed mid-count): an error there would take down the whole UI. Logged once per scope.
local loggedJoinError : {string : boolean} = {}
local function safeJoin(fn : function(), scope : string)
	react.enqueueJoin(function()
		local ok, err = pcall(function() : boolean
			fn()
			return true
		end)
		if not ok and not loggedJoinError[scope] then
			loggedJoinError[scope] = true
			debugPrint(LOG_PREFIX .. scope .. " error: " .. tostring(err))
		end
	end, scope)
end

local function planarDistance(a : Vec3f, b : Vec3f) : number
	local dx, dy = b.x - a.x, b.y - a.y
	return math.sqrt(dx * dx + dy * dy)
end

-- Centre of the town's bounding volume, as the base town window computes it.
local function townPosition(town : Engine.Entity) : Vec3f
	local bv = api.engine.getComponent(town, api.type.ComponentType.BOUNDING_VOLUME) as Engine.Component.BoundingVolume
	if bv == nil then
		return nil
	end
	return api.type.Vec3f.new(0.5 * (bv.bbox.min.x + bv.bbox.max.x), 0.5 * (bv.bbox.min.y + bv.bbox.max.y), bv.bbox.max.z)
end

local function formatDistance(metres : number) : string
	local ok, text = pcall(api.util.formatLength, metres)
	if ok and text ~= nil then
		return text as string
	end
	return tostring(math.floor(metres + 0.5)) .. " m"
end

-- Row keys: one integer per origin and destination pair, the same for the whole session, so a selected row keeps its
-- key across counts and between the eye's lists.
local pairIds : {string : integer} = {}
local nextPairId = 0

local function pairKey(row : Row) : integer
	local name = tostring(row.town) .. ">" .. tostring(row.from or -1)
	local id = pairIds[name]
	if id == nil then
		nextPairId = nextPairId + 1
		id = nextPairId
		pairIds[name] = id
	end
	return id
end

local record Distances
	here : {integer : number}
	hereText : {integer : string}
	trip : {integer : number}
	tripText : {integer : string}
end

local function makeSnapshot(entries : {PgraceJamSessionTally.Entry}, onlyVisible : boolean, from : Vec3f,
		generation : integer, d : Distances) : Snapshot
	local kept : {PgraceJamSessionTally.Entry} = {}
	for __, entry in ipairs(entries) do
		if entry.drawn or not onlyVisible then
			kept[#kept + 1] = entry
		end
	end
	local snapshot : Snapshot = { error = false, onlyVisible = onlyVisible, result = tally.group(kept), rows = {},
		keys = {}, generation = generation, from = from, distance = d.here, distanceText = d.hereText, trip = d.trip,
		tripText = d.tripText }
	for __, row in ipairs(snapshot.result.rows) do
		local key = pairKey(row)
		snapshot.rows[key] = row
		snapshot.keys[#snapshot.keys + 1] = key
	end
	return snapshot
end

local function failedCount() : Count
	nextGeneration = nextGeneration + 1
	local failed : Snapshot = { error = true, rows = {}, keys = {}, generation = nextGeneration, distance = {},
		distanceText = {}, trip = {}, tripText = {} }
	return { visible = failed, all = failed }
end

-- The tables for a finished scan. Never throws. Main thread (see Destinations). `keepFrom`, if given, is kept as the
-- counted spot (the arrow's start) instead of the camera's look-at point when the scan started.
local function buildCount(found : PgraceJamSessionScan.Result, keepFrom : Vec3f) : Count
	nextGeneration = nextGeneration + 1
	local generation = nextGeneration
	local ok, countOrError = pcall(function() : Count
		local from = keepFrom or api.type.Vec3f.new(found.center.x, found.center.y, found.center.z)
		local d : Distances = { here = {}, hereText = {}, trip = {}, tripText = {} }
		local all = makeSnapshot(found.entries, false, from, generation, d)
		-- Every row of either list is in `all`. Formatted here, once per count, not in the cells.
		local positions : {integer : Vec3f} = {}
		local function positionOf(town : integer) : Vec3f
			if town == nil then
				return nil
			end
			if positions[town] == nil then
				local positionOk, position = pcall(townPosition, town)
				positions[town] = positionOk and position as Vec3f or nil
			end
			return positions[town]
		end
		for key, row in pairs(all.rows) do
			local to = positionOf(row.town)
			if to ~= nil then
				if d.here[row.town] == nil then
					d.here[row.town] = planarDistance(from, to)
					d.hereText[row.town] = formatDistance(d.here[row.town])
				end
				local origin = positionOf(row.from)
				if origin ~= nil then
					d.trip[key] = planarDistance(origin, to)
					d.tripText[key] = formatDistance(d.trip[key])
				end
			end
		end
		return { visible = makeSnapshot(found.entries, true, from, generation, d), all = all }
	end)
	if ok then
		return countOrError as Count
	end
	debugPrint(LOG_PREFIX .. "count error: " .. tostring(countOrError))
	return failedCount()
end

-- Microseconds of scanning per frame: a zoomed-out scan (250 ms to 1 s of work in one go) spreads over a second or
-- two instead of freezing the game.
local SCAN_BUDGET_US = 6000

-- A count in progress: the scan, and the arrow start to keep (see Destinations).
local record Counting
	job : PgraceJamSessionScan.Job
	keepFrom : Vec3f
end

local function textRow(text : string, class : string) : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.TextView{ meta = { class = class or "font-scale-body" }, text = text },
		},
	}
end

local function fill(template : string, values : {string : string}) : string
	return (template:gsub("{(%w+)}", function(key : string) : string
		return values[key] or ("{" .. key .. "}")
	end))
end

local function formatCount(count : integer) : string
	local ok, text = pcall(api.util.lang.formatInt, count)
	if ok and text ~= nil then
		return text as string
	end
	return tostring(count)
end

local function carsText(count : integer, onlyVisible : boolean) : string
	local ok, code = pcall(function() : string
		return app.getUserProfile():getLanguage().code
	end)
	local forms : {string : string}
	if onlyVisible then
		forms = {
			one = _("{count} cars in view|one"), few = _("{count} cars in view|few"),
			many = _("{count} cars in view|many"), other = _("{count} cars in view|other"),
		}
	else
		forms = {
			one = _("{count} cars nearby|one"), few = _("{count} cars nearby|few"),
			many = _("{count} cars nearby|many"), other = _("{count} cars nearby|other"),
		}
	end
	local category = tally.pluralCategory(ok and code as string or "en", count)
	return fill(forms[category] or forms.other, { count = formatCount(count) })
end

-- Our own pin, as the base LocateButton draws it: other mods may replace the base one (Supply Chain Manager adds a
-- planner button to it), which pushed the names out of line in Trim the Fat's table.
local function makeLocateButton(entity : Engine.Entity) : TreeNodeId
	return builtin.Button{
		meta = { tooltip = _("Locate") },
		content = builtin.ImageView{
			path = LOCATE_ICON,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		},
		onClick = function()
			if api.engine.entityExists(entity) then
				api.gui.camera.followEntity(entity, true)
			end
		end,
	}
end

-- Pin, arrow toggle and the name (opens the town's window), as Commuter Compass's name cell.
local TownCell = react.RegisterRecipe("PgraceJamSessionTownCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local snapshot = params.userParam as Snapshot
	local row = snapshot.rows[params.rowKey]
	-- Cells keep their first userParam, so the toggle polls the shared selection to follow other rows' clicks.
	local selectedState = engine_react_util.useStepState(function() : boolean
		return snapshot.selectionState ~= nil and snapshot.selectionState:old() == params.rowKey
	end)
	if row == nil then
		return textRow("", "font-scale-body")
	end
	-- A town can't be deleted, but check anyway: the base button reads the entity's components.
	local ok, exists = pcall(api.engine.entityExists, row.town)
	if not ok or not exists then
		return textRow(row.name, "font-scale-body")
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			makeLocateButton(row.town),
			builtin.ToggleButton{
				meta = { tooltip = _("Show on the map") },
				content = builtin.ImageView{
					path = ARROW_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				value = selectedState:old() and 1 or 0,
				onValueChange = function(value : integer)
					if snapshot.selectionState == nil then
						return
					end
					if value == 1 then
						snapshot.selectionState:set(params.rowKey)
						-- An expanded window covers most of the screen, so the framed arrow (and its label) would be
						-- behind it: shrink it first.
						if snapshot.collapse ~= nil then
							snapshot.collapse()
						end
					elseif snapshot.selectionState:old() == params.rowKey then
						snapshot.selectionState:set(nil)
					end
				end,
			},
			builtin.Component{
				layout = builtin.BoxLayout{
					children = {
						line_react_util.makeEntityWindowButton(row.name, row.town, nil, nil, true, nil, row.name),
					},
				},
			},
		},
	}
end)

-- The origin town's name (opens its window), or "Unknown".
local FromCell = react.RegisterRecipe("PgraceJamSessionFromCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local row = (params.userParam as Snapshot).rows[params.rowKey]
	if row == nil or row.from == nil then
		return textRow(_("Unknown"), "font-scale-body")
	end
	local ok, exists = pcall(api.engine.entityExists, row.from)
	if not ok or not exists then
		return textRow(row.fromName, "font-scale-body")
	end
	return builtin.BoxLayout{
		children = {
			line_react_util.makeEntityWindowButton(row.fromName, row.from, nil, nil, true, nil, row.fromName),
		},
	}
end)

-- The map arrow, after Commuter Compass (pgrace_commuter_compass.script.tl), whose notes in AGENTS.md ("Drawing on
-- the map") explain each piece.

-- The renderer API has this, but it is missing from the type definitions. The override takes precedence over the tool
-- stack's active owner without replacing it, so clearing it with `false` hands the map straight back.
local record ActiveOwnerApi
	setActiveOwnerOverride : function(ReactRefWrap | boolean)
end

-- Where the camera is: its eye and look-at point. Compared at Refresh to tell whether the player moved the view.
local record View
	eye : {number}
	center : {number}
	distance : number
end

-- Main thread only (camera reads).
local function currentView() : View
	local eye = api.gui.camera.getEye()
	local center = api.gui.camera.getCenter()
	local dx, dy, dz = eye.x - center.x, eye.y - center.y, eye.z - center.z
	return { eye = { eye.x, eye.y, eye.z }, center = { center.x, center.y, center.z },
		distance = math.sqrt(dx * dx + dy * dy + dz * dz) }
end

-- Panning moves both points, zooming and rotating move the eye. A small tolerance (2% of the distance, plus 5 m)
-- ignores drift from terrain following.
local VIEW_TOLERANCE_SHARE = 0.02
local VIEW_TOLERANCE_METRES = 5.0

local function viewMoved(a : View, b : View) : boolean
	local tolerance = VIEW_TOLERANCE_SHARE * a.distance + VIEW_TOLERANCE_METRES
	for __, pair in ipairs({ { a.eye, b.eye }, { a.center, b.center } }) do
		local p, q = pair[1], pair[2]
		local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
		if math.sqrt(dx * dx + dy * dy + dz * dz) > tolerance then
			return true
		end
	end
	return false
end

-- Steps to wait after framing before reading where the camera came to rest (focusPosition animates).
local SETTLE_STEPS = 90

local record FlowParams is IRecipeParamWithMeta
	gameCtx : GameContext
	-- Called with the camera's view once the arrow's framing has come to rest.
	onViewSettled : function(View)
	from : Vec3f
	town : Engine.Entity
	-- Part of the action key: a new count (a new starting point) needs a fresh mount.
	generation : integer
end

local record FlowCache
	key : string
	action : function() : TreeNodeId
end

-- Cargo Compass's style for actual flows: the base cargo-flow colours, animated, with the passenger icon.
local function makeFlowLayerConfig(from : Vec3f, to : Vec3f) : LayerConfig
	local flow = api.type.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
	flow.from = from
	flow.to = to
	flow.speed = 40.0
	flow.arrowColors = color_util.toArray4(layerColors.CargoFlow.Consumers3D.Actual)
	flow.cargoIconAlpha = 1.0
	flow.cargoTypes = { api.res.cargoTypeRep.getPassengerCargoTypeId() }
	local cargoFlow = api.type.LayerConfig.CargoFlowRenderableConfig.new()
	cargoFlow.flowData = { flow }
	local layerConfig = api.type.LayerConfig.new()
	layerConfig.cargoFlowRenderableConfig = cargoFlow
	return layerConfig
end

-- The window's place on screen: docked bottom-centre, WINDOW_BOTTOM_GAP pixels above the bottom edge (window.css.lua's
-- padding), its size from api.gui.byId.getSize (UI pixels, which matched screen pixels at 1920x1080). The margin
-- covers the label's own size around its anchor.
local WINDOW_BOTTOM_GAP = 64
local LABEL_MARGIN = 40

-- Main thread only.
local function underWindow(x : number, y : number, viewport : Vec2i) : boolean
	local ok, size = pcall(api.gui.byId.getSize, WINDOW_ID)
	if not ok or size == nil then
		return false
	end
	local window = size as Vec2f
	if window.x <= 0 or window.y <= 0 then
		return false
	end
	local left = 0.5 * (viewport.x - window.x) - LABEL_MARGIN
	local right = 0.5 * (viewport.x + window.x) + LABEL_MARGIN
	local bottom = viewport.y - WINDOW_BOTTOM_GAP + LABEL_MARGIN
	local top = bottom - LABEL_MARGIN - window.y - LABEL_MARGIN
	return x >= left and x <= right and y >= top and y <= bottom
end

local record ArrowLabelParams is IRecipeParamWithMeta
	text : string
end

local ArrowLabel = react.RegisterRecipe("PgraceJamSessionArrowLabel", function(params : ArrowLabelParams) : TreeNodeId
	return builtin.BoxLayout{
		children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = params.text } },
	}
end)

local record ArrowLabelLayerParams
	from : Vec3f
	to : Vec3f
	text : string
end

-- The arrow's distance at the top of its arc: a full-screen layer of the arrow's own map action, so it comes and goes
-- with the arrow. window.css.lua makes the floating layout fill the screen.
local ArrowLabelLayer = react.RegisterRecipe("PgraceJamSessionArrowLabelLayer", function(params : ArrowLabelLayerParams) : TreeNodeId
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local a, b = params.from, params.to
	local lift = ARROW_ARC_HEIGHT * planarDistance(a, b)
	local top = api.type.Vec3f.new(0.5 * (a.x + b.x), 0.5 * (a.y + b.y), 0.5 * (a.z + b.z) + lift)
	-- In fractions of the screen; nil while unknown.
	local positionState : ReactStateT<Vec2f> = react.useState(nil)
	react.onStep(function()
		-- world2Screen is restricted during the react step, so it runs in a join on the main thread.
		safeJoin(function()
			local ok, point = pcall(api.gui.camera.world2Screen, top)
			local sizeOk, size = pcall(api.gui.camera.getSize)
			if not ok or not sizeOk or point == nil or size == nil then
				return
			end
			local pixel, viewport = point as Vec2i, size as Vec2i
			if viewport.x <= 0 or viewport.y <= 0 then
				return
			end
			local h, v = pixel.x / viewport.x, pixel.y / viewport.y
			-- The label's layer is drawn above windows, so hide it where our window is (an expanded window covers
			-- most of the screen, and no framing keeps the arrow's middle clear of it). Off-screen hides it.
			if underWindow(pixel.x, pixel.y, viewport) then
				h, v = -1, -1
			end
			local old = positionState:old()
			if old == nil or old.x ~= h or old.y ~= v then
				positionState:set(api.type.Vec2f.new(h, v))
			end
		end, "PgraceJamSessionArrowLabelLayer")
	end)
	local position = positionState:old()
	if position == nil or position.x < 0 or position.x > 1 or position.y < 0 or position.y > 1 then
		return builtin.FloatingLayout{ children = {} }
	end
	return builtin.FloatingLayout{
		children = {
			builtin.FloatingLayoutChild{
				h = position.x,
				v = position.y,
				-- The tealdef types this field as boolean, but the game passes the enum.
				overflowMode = builtin.type.FloatingLayoutOverflowMode.KeepInside as any as boolean,
				item = callout_react_util.DefaultCalloutWrapper{
					meta = { styleSheet = styleutil.makeStyle{ anchorPoint = api.type.Vec2f.new(0.5, 0.5) } },
					recipe = ArrowLabel,
					recipeParam = { text = params.text } as ArrowLabelParams,
				},
			},
		},
	}
end)

-- Moves the look-at point toward the camera, so the arrow's midpoint lands above our window. The direction comes
-- from the eye and centre; world2Screen confirms the sign (main thread only).
local function shiftClearOfWindow(midpoint : Vec3f, distance : number) : Vec3f
	local camera = api.gui.camera
	local eye = camera.getEye()
	local center = camera.getCenter()
	local fx, fy = center.x - eye.x, center.y - eye.y
	local length = math.sqrt(fx * fx + fy * fy)
	if length < 1e-3 then
		return midpoint
	end
	fx, fy = fx / length, fy / length
	-- Ahead of the look-at point should be higher on screen (smaller y).
	local ahead = api.type.Vec3f.new(center.x + 100 * fx, center.y + 100 * fy, center.z)
	if camera.world2Screen(ahead).y > camera.world2Screen(center).y then
		fx, fy = -fx, -fy
	end
	local shift = CAMERA_WINDOW_SHIFT * math.min(distance, CAMERA_MAX_DISTANCE)
	return api.type.Vec3f.new(midpoint.x - shift * fx, midpoint.y - shift * fy, midpoint.z)
end

local function frameCamera(from : Vec3f, to : Vec3f)
	local distance = math.max(CAMERA_MIN_DISTANCE, planarDistance(from, to) * CAMERA_DISTANCE_FACTOR)
	local midpoint = api.type.Vec3f.new(0.5 * (from.x + to.x), 0.5 * (from.y + to.y), 0.5 * (from.z + to.z))
	local ok, target = pcall(shiftClearOfWindow, midpoint, distance)
	if not ok then
		debugPrint(LOG_PREFIX .. "camera shift failed: " .. tostring(target))
		target = midpoint
	end
	api.gui.camera.focusPosition(target as Vec3f, distance)
end

-- The map action's selector and HUD icons read these from the game context. The window gets none (the mod button
-- area passes no gameCtx), so build them. Not with hooks, as game.tl does: the renderer keeps calling into the action
-- for a moment after our recipe unmounts, and a ref of an unmounted recipe throws ("attempt to index a nil value" in
-- the base notification cache took down the whole UI when the window closed). Module-level state lives on.

-- The notification state, refreshed on the main thread each step while an arrow is shown (FlowAction), and only read
-- by the lookup below. The HUD icons call the lookup from worker threads, where reading the engine's notification
-- state crashed the game natively ("Main Pool 1", no Lua error); the base cache splits the work the same way.
local record NotificationCache
	native : NativeLuaTable
	persisting : {Engine.Entity : {integer}}
end
local notificationCache : NotificationCache = { native = nil, persisting = {} }

-- Main thread only.
local function refreshNotifications()
	local ok, native = pcall(notification_util.externalGetNotificationsStateNative)
	if not ok or native == nil then
		return
	end
	local persistingOk, persisting = pcall(notification_util.getPersistingEntity2NotificationFromNative, native as NativeLuaTable)
	if persistingOk and persisting ~= nil then
		-- Replaced whole, never edited in place, so a reader on another thread sees one state or the other.
		notificationCache = { native = native as NativeLuaTable, persisting = persisting as {Engine.Entity : {integer}} }
	end
end

-- The base cache's lookup (notification_react_util.createNotificationCacheAccessFn) without its hooks: it reads the
-- cached state only. Never throws: an error gives no notification icons.
local function accessNotifications(entity : Engine.Entity) : {Notification}
	local cache = notificationCache
	local ok, notificationsOrError = pcall(function() : {Notification}
		local result : {Notification} = {}
		if cache.native == nil then
			return result
		end
		for __, notificationId in ipairs(cache.persisting[entity] or {}) do
			local notification = notification_util.getNotificationFromNative(cache.native, notificationId)
			notification.notificationId = notificationId
			result[#result + 1] = notification
		end
		return result
	end)
	if ok then
		return notificationsOrError as {Notification}
	end
	return {}
end

-- Empty filters, as game.tl starts with, behind a ref-shaped object (the selector calls filters:get()).
local mapFilters : GameContext.Filters = {
	menuFilter = { enabledItems = {}, disabledItems = {}, disabledParams = {} },
	vehicleFilter = { enabledVehicles = {}, disabledVehicles = {} },
	protectedEntities = {},
	selectorEntityFilter = {},
}
local record FiltersRef
	get : function(FiltersRef) : GameContext.Filters
	set : function(FiltersRef, GameContext.Filters)
end
local mapFiltersRef : FiltersRef = {
	get = function(__ : FiltersRef) : GameContext.Filters return mapFilters end,
	set = function(__ : FiltersRef, filters : GameContext.Filters) mapFilters = filters end,
}

local function mapGameContext(base : GameContext) : GameContext
	return {
		rendererComponent = game_react_globals.getDefaultRendererComponent(),
		windowContainer = base.windowContainer,
		toolStack = base.toolStack,
		accessNotificationCacheFn = accessNotifications,
		filters = mapFiltersRef as any as ReactRefT<GameContext.Filters>,
	} as GameContext
end

local function makeNumberCell(name : string, valueOf : function(Row) : integer) : Recipe<Builtin.TableCellParam>
	return react.RegisterRecipe(name, function(params : Builtin.TableCellParam) : TreeNodeId
		react.setStyleClasses(RIGHT_ALIGNED)
		local row = (params.userParam as Snapshot).rows[params.rowKey]
		if row == nil then
			return textRow("", "font-scale-body")
		end
		return textRow(formatCount(valueOf(row)), "font-scale-body")
	end)
end

local function cars(row : Row) : integer return row.cars end
local function home(row : Row) : integer return row.home end
local function work(row : Row) : integer return row.work end
local function shop(row : Row) : integer return row.shop end

local CarsCell = makeNumberCell("PgraceJamSessionCarsCell", cars)
local HomeCell = makeNumberCell("PgraceJamSessionHomeCell", home)
local WorkCell = makeNumberCell("PgraceJamSessionWorkCell", work)
local ShopCell = makeNumberCell("PgraceJamSessionShopCell", shop)

local TripCell = react.RegisterRecipe("PgraceJamSessionTripCell", function(params : Builtin.TableCellParam) : TreeNodeId
	react.setStyleClasses(RIGHT_ALIGNED)
	return textRow((params.userParam as Snapshot).tripText[params.rowKey] or "–", "font-scale-body")
end)

local HereCell = react.RegisterRecipe("PgraceJamSessionHereCell", function(params : Builtin.TableCellParam) : TreeNodeId
	react.setStyleClasses(RIGHT_ALIGNED)
	local snapshot = params.userParam as Snapshot
	local row = snapshot.rows[params.rowKey]
	return textRow(row ~= nil and snapshot.distanceText[row.town] or "–", "font-scale-body")
end)

local record Sort
	column : integer
	ascending : boolean
end

local function makeTable(snapshot : Snapshot, sort : Sort, onSort : function(integer, boolean)) : TreeNodeId
	local function by(valueOf : function(Row) : integer) : function(integer) : any
		return function(rowKey : integer) : any
			local row = snapshot.rows[rowKey]
			return row ~= nil and valueOf(row) or 0
		end
	end
	local function number(name : string, tooltip : string, recipe : Recipe<Builtin.TableCellParam>,
			valueOf : function(Row) : integer) : TreeNodeId
		return builtin.ColumnDesc{ name = name, tooltip = tooltip, recipe = recipe, weight = 1,
			headerStyleClass = RIGHT_ALIGNED, getCompareValue = by(valueOf) }
	end
	return builtin.DataTable{
		-- The sort is part of the key: see onSort in Destinations.
		meta = { localKey = "towns_" .. tostring(snapshot.generation) .. (snapshot.onlyVisible and "v" or "") .. "_"
			.. tostring(sort.column)
			.. (sort.ascending and "a" or "d") },
		columns = {
			builtin.ColumnDesc{ name = _("From"), tooltip = _("Where the trip started"), recipe = FromCell, weight = 2.2,
				getCompareValue = function(rowKey : integer) : any
					local row = snapshot.rows[rowKey]
					return row ~= nil and row.fromName or ""
				end },
			builtin.ColumnDesc{ name = _("To"), tooltip = _("Where the cars are heading"), recipe = TownCell, weight = 3,
				getCompareValue = function(rowKey : integer) : any
					local row = snapshot.rows[rowKey]
					return row ~= nil and row.name or ""
				end },
			number(_("Cars"), _("Counted cars on this trip"), CarsCell, cars),
			number(_("Home"), _("Driving home"), HomeCell, home),
			number(_("Work"), _("Driving to work"), WorkCell, work),
			number(_("Shop"), _("Driving to the shops"), ShopCell, shop),
			-- Unknown distances sort last when nearest-first.
			builtin.ColumnDesc{ name = _("Trip"),
				tooltip = _("Straight-line distance from the centre of the town the trip started in to the destination's"),
				recipe = TripCell, weight = 1.2, headerStyleClass = RIGHT_ALIGNED,
				getCompareValue = function(rowKey : integer) : any
					return snapshot.trip[rowKey] or math.huge
				end },
			builtin.ColumnDesc{ name = _("Here"),
				tooltip = _("Straight-line distance from where the cars were counted to the destination town's centre"),
				recipe = HereCell, weight = 1.2, headerStyleClass = RIGHT_ALIGNED,
				getCompareValue = function(rowKey : integer) : any
					local row = snapshot.rows[rowKey]
					return row ~= nil and snapshot.distance[row.town] or math.huge
				end },
		},
		rowKeys = snapshot.keys,
		userParam = snapshot,
		initialSortColumn = { sort.column, sort.ascending },
		onSortColumnChange = onSort,
	}
end

-- Binds a map action that draws one arrow and makes it the renderer's active owner override. Unmounting (arrow off,
-- window closed) clears the override.
local FlowAction = react.RegisterRecipe("PgraceJamSessionFlowAction", function(params : FlowParams) : TreeNodeId
	local gameCtx = mapGameContext(params.gameCtx)
	-- The HUD icons' notification lookup reads this (see refreshNotifications).
	react.onStep(refreshNotifications)
	local key = tostring(params.generation) .. ">" .. tostring(params.town)
	local cacheRef : ReactRefT<FlowCache> = react.useRef(nil)
	local frameRef : ReactRefT<{Vec3f}> = react.useRef(nil)
	-- The camera frames the arrow when it's turned on or moved to another town, not when a refresh moves its start:
	-- the camera then sits where the arrow put it, and following a new start each time made the view creep.
	local framedTownRef : ReactRefT<Engine.Entity> = react.useRef(nil)
	local changed = cacheRef:get() == nil or cacheRef:get().key ~= key
	if changed then
		local from = params.from
		local okTo, to = pcall(townPosition, params.town)
		local action : function() : TreeNodeId = nil
		if okTo and to ~= nil then
			local text = formatDistance(planarDistance(from, to as Vec3f))
			action = selector_react_util.makeDefaultSelectorAction(gameCtx, makeFlowLayerConfig(from, to as Vec3f),
				nil, function() : TreeNodeId
					return builtin.FullScreenComponent{
						recipe = ArrowLabelLayer,
						param = { from = from, to = to as Vec3f, text = text } as ArrowLabelLayerParams,
					}
				end)
			if framedTownRef:get() ~= params.town then
				framedTownRef:set(params.town)
				frameRef:set({ from, to as Vec3f })
			end
		else
			debugPrint(LOG_PREFIX .. "flow: no position for town " .. tostring(params.town))
		end
		cacheRef:set({ key = key, action = action })
	end
	-- Steps left until the framed view is read (nil: not waiting).
	local settleRef : ReactRefT<integer> = react.useRef(nil)
	-- The camera moves on the main thread: the shift reads world2Screen, restricted during the react step.
	react.onStep(function()
		local ends = frameRef:get()
		if ends ~= nil then
			frameRef:set(nil)
			safeJoin(function()
				local ok, err = pcall(function() : boolean
					frameCamera(ends[1], ends[2])
					return true
				end)
				if not ok then
					debugPrint(LOG_PREFIX .. "camera move failed: " .. tostring(err))
				end
			end, "PgraceJamSessionFrameCamera")
			settleRef:set(SETTLE_STEPS)
		end
		local steps = settleRef:get()
		if steps ~= nil then
			if steps > 0 then
				settleRef:set(steps - 1)
			else
				settleRef:set(nil)
				-- The framed view becomes the one Refresh compares with, so a refresh without moving keeps the arrow.
				safeJoin(function()
					local ok, view = pcall(currentView)
					if ok and view ~= nil then
						params.onViewSettled(view as View)
					end
				end, "PgraceJamSessionViewSettled")
			end
		end
	end)

	-- One action key per arrow: switching arrows under a single key kept the old arrow on screen (Commuter Compass).
	local selfRef = react.useAction(gameCtx.rendererComponent, cacheRef:get().action, FLOW_ACTION_KEY .. ":" .. key)

	local function setOverride(owner : ReactRefWrap | boolean) : boolean
		local rendererComponent = gameCtx.rendererComponent
		if rendererComponent == nil or rendererComponent:hasExpired() then
			return false
		end
		local rc = rendererComponent:get()
		if rc == nil or not rc:getIdentity() then
			return false
		end
		-- Not part of the documented API: degrade to "no arrow" rather than erroring if a game update removes it.
		local rcApi = rc:getApi() as any as ActiveOwnerApi
		if rcApi.setActiveOwnerOverride == nil then
			return false
		end
		rcApi.setActiveOwnerOverride(owner)
		return true
	end

	-- Only with an action bound: without one (no town position), taking over the map would leave it ownerless.
	local function activate()
		if cacheRef:get().action ~= nil then
			setOverride(selfRef)
		end
	end

	react.onMount(activate)
	if changed and selfRef:get() ~= nil then
		activate()
	end
	react.onUnmount(function()
		setOverride(false)
	end)

	return builtin.BoxLayout{ children = {} }
end)

-- Settings kept between openings, until the game restarts (the window's state starts fresh each time it opens).
local record Remembered
	onlyVisible : boolean
	expanded : boolean
	sort : Sort
end
-- Sorted by Cars (column 3), most first.
local remembered : Remembered = { onlyVisible = true, expanded = false, sort = { column = 3, ascending = false } }

local record ContentParams
	gameCtx : GameContext
	expanded : boolean
	setExpanded : function(boolean)
end

local Destinations = react.RegisterRecipe("PgraceJamSessionContent", function(params : ContentParams) : TreeNodeId
	local countState : ReactStateT<Count> = react.useState(nil)
	-- The view at the last count, or where the arrow's framing came to rest since.
	local viewRef : ReactRefT<View> = react.useRef(nil)
	-- The row key (trip) whose arrow is on the map; one at a time. Refresh keeps it, with its start, if the view
	-- didn't move, and drops it if the view moved or the trip is no longer counted.
	local selectionState : ReactStateT<integer> = react.useState(nil)
	local sortState = react.useState(remembered.sort) as ReactStateT<Sort>
	local sort = sortState:old()
	-- A header click builds a new table, already in the new order, as Trim the Fat: re-sorting the existing table keeps
	-- its current row (the last row clicked, else the first) in view, which leaves the list scrolled partway down. A
	-- fresh table starts at the top. The counts stay; only the order changes.
	local function onSort(column : integer, ascending : boolean)
		if column ~= sort.column or ascending ~= sort.ascending then
			remembered.sort = { column = column, ascending = ascending }
			sortState:set(remembered.sort)
		end
	end
	local onlyVisibleState = react.useState(remembered.onlyVisible) as ReactStateT<boolean>
	local onlyVisible = onlyVisibleState:old()
	-- A count is due: on open and after Refresh, from wherever the camera is then. isVisible reads the camera, which may
	-- be restricted during the react step (world2Screen is: "API is currently restricted", an uncatchable crash), so
	-- the scan runs in joins on the main thread, as Commuter Compass's label position: one to start it, then one per
	-- frame for SCAN_BUDGET_US until done. The last count stays on screen meanwhile. Refresh during a count starts over.
	local pendingRef : ReactRefT<boolean> = react.useRef(true)
	local countingRef : ReactRefT<Counting> = react.useRef(nil)
	-- A join is queued and hasn't run yet; at most one at a time.
	local joinQueuedRef : ReactRefT<boolean> = react.useRef(false)
	-- Percent done while counting, nil otherwise.
	local progressState : ReactStateT<integer> = react.useState(nil)
	react.onStep(function()
		if joinQueuedRef:get() then
			return
		end
		if pendingRef:get() then
			pendingRef:set(false)
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				-- With an arrow shown, Refresh cancels it if the player moved the view since; otherwise it keeps the
				-- arrow and its start, and only the counts change.
				local viewOk, viewOrError = pcall(currentView)
				local view = viewOk and viewOrError as View or nil
				local keepFrom : Vec3f = nil
				local previous = countState:old()
				if selectionState:old() ~= nil and previous ~= nil then
					local before = viewRef:get()
					if view == nil or before == nil or viewMoved(before, view) then
						selectionState:set(nil)
					else
						keepFrom = previous.all.from
					end
				end
				viewRef:set(view)
				local ok, jobOrError = pcall(scan.start)
				if ok then
					countingRef:set({ job = jobOrError as PgraceJamSessionScan.Job, keepFrom = keepFrom })
					progressState:set(0)
				else
					debugPrint(LOG_PREFIX .. "scan error: " .. tostring(jobOrError))
					countingRef:set(nil)
					progressState:set(nil)
					countState:set(failedCount())
				end
			end, "PgraceJamSessionScan")
		elseif countingRef:get() ~= nil then
			joinQueuedRef:set(true)
			safeJoin(function()
				joinQueuedRef:set(false)
				local counting = countingRef:get()
				if counting == nil then
					return
				end
				local ok, doneOrError = pcall(scan.step, counting.job, SCAN_BUDGET_US)
				if not ok then
					debugPrint(LOG_PREFIX .. "scan error: " .. tostring(doneOrError))
					countingRef:set(nil)
					progressState:set(nil)
					countState:set(failedCount())
				elseif doneOrError == true then
					countingRef:set(nil)
					progressState:set(nil)
					local count = buildCount(scan.result(counting.job), counting.keepFrom)
					countState:set(count)
					-- A selected trip that's no longer counted is dropped, so it can't reappear (and move the camera) in
					-- a later count.
					local selected = selectionState:old()
					if selected ~= nil and count.all.rows[selected] == nil then
						selectionState:set(nil)
					end
				else
					local percent = math.floor(100 * scan.progress(counting.job))
					if percent ~= progressState:old() then
						progressState:set(percent)
					end
				end
			end, "PgraceJamSessionScan")
		end
	end)

	-- F2's toolbar (statistics_react_util): flat icon toggles with an 18 px icon, class "category", inside a box of
	-- class "filter"; the eye (createShowOnlyVisibleButton), then refresh, then the expand toggle in its own box.
	local filterButtons : {TreeNodeId} = {
		builtin.ToggleButton{
			meta = { class = "eye", tooltip = _("Count only the cars drawn on screen. Off: also cars on nearby streets too far away to be drawn.") },
			value = onlyVisible and 1 or 0,
			content = builtin.ImageView{
				meta = { class = "category" },
				path = EYE_ICON,
				scaling = builtin.type.ImageViewScaling.AutoFit,
			},
			onValueChange = function(value : integer)
				remembered.onlyVisible = value == 1
				onlyVisibleState:set(value == 1)
			end,
		},
		builtin.Button{
			meta = { class = "refresh", tooltip = _("Count the cars again") },
			content = builtin.ImageView{
				meta = { class = "category" },
				path = REFRESH_ICON,
				scaling = builtin.type.ImageViewScaling.AutoFit,
			},
			onClick = function()
				pendingRef:set(true)
			end,
		},
	}
	local expandButton = builtin.ToggleButton{
		meta = { class = "expand", tooltip = params.expanded and _("Shrink") or _("Expand") },
		value = params.expanded and 1 or 0,
		content = builtin.ImageView{
			path = params.expanded and "::/gui/builtin/window/icons/symbol_minimize_18.tga"
				or "::/gui/builtin/window/icons/symbol_maximize_18.tga",
		},
		onValueChange = function(value : integer)
			params.setExpanded(value == 1)
		end,
	}
	local toolbar = builtin.BoxLayout{
		meta = { class = "look-up" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.BoxLayout{
				meta = { class = "filter" },
				orientation = builtin.type.Orientation.Horizontal,
				children = filterButtons,
			},
			builtin.BoxLayout{
				meta = { class = "filter" },
				orientation = builtin.type.Orientation.Horizontal,
				children = { expandButton },
			},
		},
	}

	local count = countState:old()
	local snapshot : Snapshot = nil
	if count ~= nil then
		snapshot = onlyVisible and count.visible or count.all
		snapshot.selectionState = selectionState
		snapshot.collapse = function()
			if params.expanded then
				params.setExpanded(false)
			end
		end
	end
	local body : {TreeNodeId} = {}
	local progress = progressState:old()
	if progress ~= nil then
		body[#body + 1] = textRow(fill(_("Counting… {percent}%"), { percent = tostring(progress) }), "font-scale-annotation")
	end
	if snapshot == nil then
		-- Nothing yet: the progress line above says why.
	elseif snapshot.error then
		body[#body + 1] = textRow(_("Error (see log)"), "font-scale-body, negative")
	elseif snapshot.result.total == 0 then
		body[#body + 1] = textRow(onlyVisible and _("No cars in view. Move the camera to a road and count again.")
			or _("No cars nearby. Move the camera to a road and count again."), "font-scale-body")
	else
		local summary = carsText(snapshot.result.total, onlyVisible)
		local unknown = snapshot.result.unknown
		if unknown ~= nil then
			summary = summary .. " · " .. fill(_("Destination unknown: {count}"), { count = formatCount(unknown.cars) })
		end
		body[#body + 1] = textRow(summary, "font-scale-annotation")
		if #snapshot.keys > 0 then
			body[#body + 1] = makeTable(snapshot, sort, onSort)
		end
	end
	-- The selection is a row key; `all` holds every row of either list, so the eye doesn't take the arrow away. The
	-- arrow runs from the counted spot to the row's destination.
	local selected = selectionState:old()
	local selectedRow = selected ~= nil and count ~= nil and count.all.rows[selected] or nil
	if selectedRow ~= nil and snapshot ~= nil and snapshot.from ~= nil then
		-- A fixed key: the progress line comes and goes above it during a count, and a positional match would remount
		-- the arrow (and frame the camera again) on every refresh.
		body[#body + 1] = FlowAction{ meta = { localKey = "flow" }, gameCtx = params.gameCtx,
			onViewSettled = function(view : View) viewRef:set(view) end, from = snapshot.from, town = selectedRow.town,
			generation = snapshot.generation }
	end

	-- F2's layout (StatisticsContainer), as Trim the Fat: a tab widget filling the window, here with one tab, and the
	-- toolbar floated over the tab row's right end. The tab item must not be a layout ("TabWidgetChild item must not
	-- be a Layout" crashes the whole UI), so it's wrapped in a Component.
	return builtin.FloatingLayout{
		children = {
			builtin.FloatingLayoutChild{
				localKey = "tabs",
				h = -1,
				v = -1,
				item = builtin.TabWidget{
					orientation = builtin.type.TabOrientation.North,
					deselectAllowed = false,
					value = "destinations",
					onValueChange = function(__ : integer|number|string) end,
					tabs = {
						builtin.TabWidgetChild{
							localKey = "destinations",
							value = "destinations",
							indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = MOD_NAME },
							item = builtin.Component{
								layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = body },
							},
						},
					},
				},
			},
			builtin.FloatingLayoutChild{
				localKey = "toolbar",
				h = 1.0,
				v = 0.0,
				item = toolbar,
			},
		},
	}
end)

-- The tool machinery only reads gameCtx.windowContainer (and the button its tool stack); the mod-area plugin gets
-- no gameCtx, so build one from the game's defaults.
local function makeToolParam() : ToolParam
	local gameCtx = {
		windowContainer = game_react_globals.getDefaultWindowContainer(),
		toolStack = game_react_globals.getDefaultToolStack(),
	} as GameContext
	return { gameCtx = gameCtx }
end

local DestinationsWindow = react.RegisterWrapperRecipe("PgraceJamSessionWindow", builtin.Window, function(params : ToolReactUtil.IToolWindowParam<ToolParam>) : TreeNodeId
	local expandedState = react.useState(remembered.expanded) as ReactStateT<boolean>
	-- Size, position and animations come from window.css.lua, by this class: F2's rules for its window.
	return builtin.Window{
		meta = { class = "pgrace-jam-session" },
		id = WINDOW_ID,
		title = MOD_NAME,
		closable = true,
		-- As F2: no title bar (the close button overlaps the content's top-right corner), docked, not movable.
		compact = true,
		movable = false,
		onClose = params.onClose,
		expanded = expandedState:old(),
		content = Destinations{
			gameCtx = params.payload ~= nil and params.payload.toolParam ~= nil and params.payload.toolParam.gameCtx or makeToolParam().gameCtx,
			expanded = expandedState:old(),
			setExpanded = function(expanded : boolean)
				remembered.expanded = expanded
				expandedState:set(expanded)
			end,
		},
	}
end)

local DestinationsTool = tool_react_util.registerToolWithWindow("PgraceJamSession", WINDOW_ID, DestinationsWindow)

local DestinationsButton = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "PgraceJamSessionButton", function() : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.ToolButton{
				meta = { tooltip = _("Jam Session: where the cars on screen are heading") },
				toolDefinition = DestinationsTool,
				toolStack = game_react_globals.getDefaultToolStack(),
				content = builtin.ImageView{
					path = BUTTON_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				showFn = function()
					local ok, err = pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().push(DestinationsTool, nil, makeToolParam())
						return true
					end)
					if not ok then
						debugPrint(LOG_PREFIX .. "open failed: " .. tostring(err))
					end
				end,
				hideFn = function()
					pcall(function() : boolean
						game_react_globals.getDefaultToolStackApi().pop(DestinationsTool, nil)
						return true
					end)
				end,
			},
		},
	}
end)

return {
	DestinationsButton = DestinationsButton,
}
