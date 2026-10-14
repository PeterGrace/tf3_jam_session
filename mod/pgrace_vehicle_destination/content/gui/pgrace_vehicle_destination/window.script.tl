local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local tool_react_util = ug_require "::/gui/main/tool_react_util.tl" as ToolReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally
local scan = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/scan.tl" as PgraceVehicleDestinationScan

local LOG_PREFIX = "[vehicle_destination] "
local WINDOW_ID = "pgrace_vehicle_destination_window"
local BUTTON_ICON = "::/gui/entity_window/icons/vehicle_car.tga"
local REFRESH_ICON = "::/gui/builtin/window/icons/refresh.tga"
-- F2's class for numeric columns; window.css.lua aligns it inside our window.
local RIGHT_ALIGNED = "right-aligned"

local type ToolParam = ToolReactUtil.IToolParam
local type Row = PgraceVehicleDestinationTally.Row
local type Result = PgraceVehicleDestinationTally.Result

local record Snapshot
	error : boolean
	result : Result
	-- rowKey (the town entity) -> row.
	rows : {integer : Row}
	keys : {integer}
	-- Differs per scan, so a refresh remounts the table (cells keep their first userParam).
	generation : integer
end

local nextGeneration = 0

-- Never throws. Runs on the main thread (see Destinations).
local function takeSnapshot() : Snapshot
	nextGeneration = nextGeneration + 1
	local snapshot : Snapshot = { error = false, rows = {}, keys = {}, generation = nextGeneration }
	local ok, err = pcall(function() : boolean
		snapshot.result = tally.group(scan.visibleCars().entries)
		for __, row in ipairs(snapshot.result.rows) do
			snapshot.rows[row.town] = row
			snapshot.keys[#snapshot.keys + 1] = row.town
		end
		return true
	end)
	if not ok then
		debugPrint(LOG_PREFIX .. "scan error: " .. tostring(err))
		snapshot.error = true
	end
	return snapshot
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

local function carsInViewText(count : integer) : string
	local ok, code = pcall(function() : string
		return app.getUserProfile():getLanguage().code
	end)
	local forms : {string : string} = {
		one = _("{count} cars in view|one"), few = _("{count} cars in view|few"),
		many = _("{count} cars in view|many"), other = _("{count} cars in view|other"),
	}
	local category = tally.pluralCategory(ok and code as string or "en", count)
	return fill(forms[category] or forms.other, { count = formatCount(count) })
end

local TownCell = react.RegisterRecipe("PgraceVehicleDestinationTownCell", function(params : Builtin.TableCellParam) : TreeNodeId
	local row = (params.userParam as Snapshot).rows[params.rowKey]
	if row == nil then
		return textRow("", "font-scale-body")
	end
	-- A town can't be deleted, but check anyway: the base button reads the entity's components.
	local ok, exists = pcall(api.engine.entityExists, params.rowKey)
	if not ok or not exists then
		return textRow(row.name, "font-scale-body")
	end
	return builtin.BoxLayout{
		children = {
			line_react_util.makeEntityWindowButton(row.name, params.rowKey, nil, nil, true, nil, row.name),
		},
	}
end)

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

local CarsCell = makeNumberCell("PgraceVehicleDestinationCarsCell", cars)
local HomeCell = makeNumberCell("PgraceVehicleDestinationHomeCell", home)
local WorkCell = makeNumberCell("PgraceVehicleDestinationWorkCell", work)
local ShopCell = makeNumberCell("PgraceVehicleDestinationShopCell", shop)

local function makeTable(snapshot : Snapshot) : TreeNodeId
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
		meta = { localKey = "towns_" .. tostring(snapshot.generation) },
		columns = {
			builtin.ColumnDesc{ name = _("Town"), recipe = TownCell, weight = 3,
				getCompareValue = function(rowKey : integer) : any
					local row = snapshot.rows[rowKey]
					return row ~= nil and row.name or ""
				end },
			number(_("Cars"), _("Cars on screen heading to this town"), CarsCell, cars),
			number(_("Home"), _("Driving home"), HomeCell, home),
			number(_("Work"), _("Driving to work"), WorkCell, work),
			number(_("Shop"), _("Driving to the shops"), ShopCell, shop),
		},
		rowKeys = snapshot.keys,
		userParam = snapshot,
		initialSortColumn = { 2, false },
	}
end

local Destinations = react.RegisterRecipe("PgraceVehicleDestinationContent", function() : TreeNodeId
	local snapshotState : ReactStateT<Snapshot> = react.useState(nil)
	-- A scan is due: on open and after Refresh. isVisible reads the camera, which may be restricted during the react
	-- step (world2Screen is: "API is currently restricted", an uncatchable crash), so the scan runs in a join on the
	-- main thread, as Commuter Compass's label position.
	local pendingRef : ReactRefT<boolean> = react.useRef(true)
	react.onStep(function()
		if pendingRef:get() then
			pendingRef:set(false)
			react.enqueueJoin(function()
				snapshotState:set(takeSnapshot())
			end, "PgraceVehicleDestinationScan")
		end
	end)

	local snapshot = snapshotState:old()
	local body : {TreeNodeId} = {}
	local header : string
	if snapshot == nil then
		header = _("Counting…")
	elseif snapshot.error then
		header = _("Error (see log)")
	else
		header = carsInViewText(snapshot.result.total)
	end
	body[#body + 1] = builtin.BoxLayout{
		meta = { class = "toolbar" },
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			builtin.TextView{ meta = { class = "font-scale-body" }, text = header },
			builtin.Button{
				meta = { class = "refresh", tooltip = _("Count the cars on screen again") },
				content = builtin.ImageView{
					path = REFRESH_ICON,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
				onClick = function()
					pendingRef:set(true)
				end,
			},
		},
	}
	if snapshot ~= nil and not snapshot.error then
		if snapshot.result.total == 0 then
			body[#body + 1] = textRow(_("No cars in view. Move the camera to a road and press Refresh."), "font-scale-body")
		else
			if #snapshot.keys > 0 then
				body[#body + 1] = makeTable(snapshot)
			end
			local unknown = snapshot.result.unknown
			if unknown ~= nil then
				body[#body + 1] = textRow(fill(_("Destination unknown: {count}"), { count = formatCount(unknown.cars) }),
					"font-scale-annotation")
			end
		end
	end

	-- F2's look: one tab carrying the title. The item must not be a layout ("TabWidgetChild item must not be a
	-- Layout" crashes the whole UI), so it's wrapped in a Component.
	return builtin.BoxLayout{
		children = {
			builtin.TabWidget{
				orientation = builtin.type.TabOrientation.North,
				deselectAllowed = false,
				value = "destinations",
				onValueChange = function(__ : integer|number|string) end,
				tabs = {
					builtin.TabWidgetChild{
						localKey = "destinations",
						value = "destinations",
						indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = _("Car destinations") },
						item = builtin.Component{
							layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = body },
						},
					},
				},
			},
		},
	}
end)

local DestinationsWindow = react.RegisterWrapperRecipe("PgraceVehicleDestinationWindow", builtin.Window, function(params : ToolReactUtil.IToolWindowParam<ToolParam>) : TreeNodeId
	-- Size and position come from window.css.lua, by this class.
	return builtin.Window{
		meta = { class = "pgrace-vehicle-destination" },
		id = WINDOW_ID,
		title = _("Car destinations"),
		closable = true,
		compact = true,
		movable = false,
		onClose = params.onClose,
		content = Destinations{},
	}
end)

local DestinationsTool = tool_react_util.registerToolWithWindow("PgraceVehicleDestination", WINDOW_ID, DestinationsWindow)

-- The tool machinery only reads gameCtx.windowContainer (and the button its tool stack); the mod-area plugin gets
-- no gameCtx, so build one from the game's defaults.
local function makeToolParam() : ToolParam
	local gameCtx = {
		windowContainer = game_react_globals.getDefaultWindowContainer(),
		toolStack = game_react_globals.getDefaultToolStack(),
	} as GameContext
	return { gameCtx = gameCtx }
end

local DestinationsButton = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "PgraceVehicleDestinationButton", function() : TreeNodeId
	return builtin.BoxLayout{
		children = {
			builtin.ToolButton{
				meta = { tooltip = _("Car destinations: where the cars on screen are heading") },
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
