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
-- F2's "Show Only Visible" toggle (statistics_react_util.createShowOnlyVisibleButton).
local EYE_ICON = "::/gui/statistics/icons/symbol_eye_18.tga"
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
local function takeSnapshot(onlyVisible : boolean) : Snapshot
	nextGeneration = nextGeneration + 1
	local snapshot : Snapshot = { error = false, rows = {}, keys = {}, generation = nextGeneration }
	local ok, err = pcall(function() : boolean
		snapshot.result = tally.group(scan.cars(onlyVisible).entries)
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
			number(_("Cars"), _("Counted cars heading to this town"), CarsCell, cars),
			number(_("Home"), _("Driving home"), HomeCell, home),
			number(_("Work"), _("Driving to work"), WorkCell, work),
			number(_("Shop"), _("Driving to the shops"), ShopCell, shop),
		},
		rowKeys = snapshot.keys,
		userParam = snapshot,
		initialSortColumn = { 2, false },
	}
end

-- Settings kept between openings, until the game restarts (the window's state starts fresh each time it opens).
local record Remembered
	onlyVisible : boolean
	expanded : boolean
end
local remembered : Remembered = { onlyVisible = true, expanded = false }

local record ContentParams
	expanded : boolean
	setExpanded : function(boolean)
end

local Destinations = react.RegisterRecipe("PgraceVehicleDestinationContent", function(params : ContentParams) : TreeNodeId
	local snapshotState : ReactStateT<Snapshot> = react.useState(nil)
	local onlyVisibleState = react.useState(remembered.onlyVisible) as ReactStateT<boolean>
	local onlyVisible = onlyVisibleState:old()
	-- A scan is due: on open, after Refresh and when the eye changes. isVisible reads the camera, which may be
	-- restricted during the react step (world2Screen is: "API is currently restricted", an uncatchable crash), so the
	-- scan runs in a join on the main thread, as Commuter Compass's label position. It reads remembered, which the
	-- eye's setter writes, so it never sees a stale value.
	local pendingRef : ReactRefT<boolean> = react.useRef(true)
	react.onStep(function()
		if pendingRef:get() then
			pendingRef:set(false)
			react.enqueueJoin(function()
				snapshotState:set(takeSnapshot(remembered.onlyVisible))
			end, "PgraceVehicleDestinationScan")
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
				pendingRef:set(true)
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

	local snapshot = snapshotState:old()
	local body : {TreeNodeId} = {}
	if snapshot == nil then
		body[#body + 1] = textRow(_("Counting…"), "font-scale-annotation")
	elseif snapshot.error then
		body[#body + 1] = textRow(_("Error (see log)"), "font-scale-body, negative")
	elseif snapshot.result.total == 0 then
		body[#body + 1] = textRow(onlyVisible and _("No cars in view. Move the camera to a road and press Refresh.")
			or _("No cars nearby. Move the camera to a road and press Refresh."), "font-scale-body")
	else
		local summary = carsText(snapshot.result.total, onlyVisible)
		local unknown = snapshot.result.unknown
		if unknown ~= nil then
			summary = summary .. " · " .. fill(_("{count} destination unknown"), { count = formatCount(unknown.cars) })
		end
		body[#body + 1] = textRow(summary, "font-scale-annotation")
		if #snapshot.keys > 0 then
			body[#body + 1] = makeTable(snapshot)
		end
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
							indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = _("Car destinations") },
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

local DestinationsWindow = react.RegisterWrapperRecipe("PgraceVehicleDestinationWindow", builtin.Window, function(params : ToolReactUtil.IToolWindowParam<ToolParam>) : TreeNodeId
	local expandedState = react.useState(remembered.expanded) as ReactStateT<boolean>
	-- Size, position and animations come from window.css.lua, by this class: F2's rules for its window.
	return builtin.Window{
		meta = { class = "pgrace-vehicle-destination" },
		id = WINDOW_ID,
		title = _("Car destinations"),
		closable = true,
		-- As F2: no title bar (the close button overlaps the content's top-right corner), docked, not movable.
		compact = true,
		movable = false,
		onClose = params.onClose,
		expanded = expandedState:old(),
		content = Destinations{
			expanded = expandedState:old(),
			setExpanded = function(expanded : boolean)
				remembered.expanded = expanded
				expandedState:set(expanded)
			end,
		},
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
