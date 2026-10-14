# Vehicle Destination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A game-bar button opens a window listing where the private cars currently on screen are heading, grouped
by destination town with Home/Work/Shop splits.

**Architecture:** `tally.tl` (pure, unit-tested) groups `{town, townName, purpose}` entries into sorted rows.
`scan.tl` reads the engine: moving sim people whose last move mode is DRIVE and which `api.gui.byEntity.isVisible`
reports on screen. `window.script.tl` is a copy of Trim the Fat's button/tool/window setup with a `DataTable`. The
scan runs in `react.enqueueJoin` on the main thread (camera reads can be restricted during the react step).

**Tech Stack:** Teal 0.24.8 type-checked against the TF3 tealdefs; plain-Lua tests (`tools/test.lua`); `just`.

**Spec:** `docs/superpowers/specs/2026-10-14-vehicle-destination-design.md`

**Paths:** all paths are relative to the worktree root
`/home/pgrace/repos/tf3_mods/tf3_vehicle_destination/.worktrees/tf3-vehicle-destination-vehicle_destination`.
`MOD = mod/pgrace_vehicle_destination`, `GUI = $MOD/content/gui/pgrace_vehicle_destination`,
`DEF = $MOD/tealdef/gui/pgrace_vehicle_destination`.

**Reference implementation:** `/home/pgrace/repos/tf3_mods/tf3_trim_the_fat/mod/pgrace_trim_the_fat/content/gui/pgrace_trim_the_fat/overview.script.tl`
(button, tool, window, `DataTable`) and its `overview.css.lua`. Read AGENTS.md in `/home/pgrace/repos/tf3_mods/`
before starting, especially "Teal gotchas" and "A game-bar button that opens a window".

---

### Task 1: `tally.tl`, the pure grouping (replaces the template's `util.tl`)

**Files:**
- Create: `$DEF/tally.d.tl`, `$GUI/tally.tl`, `tests/tally_test.lua`
- Delete: `$DEF/util.d.tl`, `$GUI/util.tl`, `$GUI/util.d.tl`, `tests/util_test.lua`
- Modify: `$MOD/tealdef/pgrace_vehicle_destination_def.d.tl`

The template's industry plugin script requires `util.tl`. Delete the plugin in this task too (Task 3 would delete
it anyway), so `just check` stays green:
- Delete: `$GUI/industry_plugin.res.lua`, `$GUI/pgrace_vehicle_destination.script.tl`

- [ ] **Step 1: Write the type definition** `$DEF/tally.d.tl`

```teal
-- Pure helpers (no api.* calls), so tests/tally_test.lua can run them in plain Lua.
global record PgraceVehicleDestinationTally
	-- Why the car is going to its target: SimPerson.destinations holds {residence, shopping, work}.
	enum Purpose
		"home"
		"shop"
		"work"
	end

	-- One visible car. town is nil when the destination town can't be resolved; purpose is nil when the target
	-- matches none of the person's destinations.
	record Entry
		town : integer
		townName : string
		purpose : Purpose
	end

	record Row
		-- nil for the unknown row.
		town : integer
		name : string
		cars : integer
		home : integer
		work : integer
		shop : integer
	end

	record Result
		-- One row per known town: most cars first, then by name.
		rows : {Row}
		-- Cars whose town is unknown; nil when there are none.
		unknown : Row
		-- Every entry, unknown included.
		total : integer
	end

	-- destinations[1] residence, [2] shopping, [3] work (engine.d.tl SimPerson). nil when nothing matches.
	purposeOf : function(target : integer, destinations : {integer}) : Purpose
	group : function(entries : {Entry}) : Result
	-- CLDR integer plural category ("one", "few", "many", "other") for a TF3 language code such as "pt_BR".
	pluralCategory : function(language : string, count : integer) : string
end
```

- [ ] **Step 2: Register it** — replace the whole of `$MOD/tealdef/pgrace_vehicle_destination_def.d.tl` with:

```teal
require "gui.pgrace_vehicle_destination.tally"
```

- [ ] **Step 3: Write the failing tests** `tests/tally_test.lua`

```lua
local t = ...
local tally = t.requireTl("gui/pgrace_vehicle_destination/tally.tl")

t.test("purposeOf: matches residence, shopping, work", function()
	local destinations = { 10, 20, 30 }
	t.eq(tally.purposeOf(10, destinations), "home")
	t.eq(tally.purposeOf(20, destinations), "shop")
	t.eq(tally.purposeOf(30, destinations), "work")
	t.eq(tally.purposeOf(40, destinations), nil, "no match")
	t.eq(tally.purposeOf(nil, destinations), nil, "no target")
	t.eq(tally.purposeOf(10, nil), nil, "no destinations")
end)

t.test("group: one row per town with purpose counts", function()
	local r = tally.group({
		{ town = 1, townName = "Alpha", purpose = "work" },
		{ town = 2, townName = "Beta", purpose = "home" },
		{ town = 1, townName = "Alpha", purpose = "work" },
		{ town = 1, townName = "Alpha", purpose = "shop" },
	})
	t.eq(#r.rows, 2)
	t.eq(r.rows[1].town, 1)
	t.eq(r.rows[1].name, "Alpha")
	t.eq(r.rows[1].cars, 3)
	t.eq(r.rows[1].work, 2)
	t.eq(r.rows[1].shop, 1)
	t.eq(r.rows[1].home, 0)
	t.eq(r.rows[2].cars, 1)
	t.eq(r.rows[2].home, 1)
	t.eq(r.unknown, nil)
	t.eq(r.total, 4)
end)

t.test("group: sorted by cars, then by name", function()
	local r = tally.group({
		{ town = 3, townName = "Gamma" },
		{ town = 2, townName = "Beta" },
		{ town = 1, townName = "Alpha" },
		{ town = 3, townName = "Gamma" },
	})
	t.eq(r.rows[1].name, "Gamma")
	t.eq(r.rows[2].name, "Alpha")
	t.eq(r.rows[3].name, "Beta")
end)

t.test("group: unknown towns go to their own row, outside rows", function()
	local r = tally.group({
		{ town = nil, purpose = "home" },
		{ town = nil },
		{ town = 1, townName = "Alpha" },
	})
	t.eq(#r.rows, 1)
	t.eq(r.unknown.cars, 2)
	t.eq(r.unknown.home, 1)
	t.eq(r.unknown.town, nil)
	t.eq(r.total, 3)
end)

t.test("group: an unknown purpose counts in cars only", function()
	local r = tally.group({ { town = 1, townName = "Alpha" } })
	t.eq(r.rows[1].cars, 1)
	t.eq(r.rows[1].home + r.rows[1].work + r.rows[1].shop, 0)
end)

t.test("group: a missing town name falls back to the entity id", function()
	local r = tally.group({ { town = 7 } })
	t.eq(r.rows[1].name, "7")
end)

t.test("group: empty input", function()
	local r = tally.group({})
	t.eq(#r.rows, 0)
	t.eq(r.unknown, nil)
	t.eq(r.total, 0)
end)

t.test("pluralCategory: CLDR integer rules", function()
	t.eq(tally.pluralCategory("en", 1), "one")
	t.eq(tally.pluralCategory("en", 2), "other")
	t.eq(tally.pluralCategory("en", 0), "other")
	t.eq(tally.pluralCategory("fr", 0), "one")
	t.eq(tally.pluralCategory("pt_BR", 1), "one")
	t.eq(tally.pluralCategory("pl", 1), "one")
	t.eq(tally.pluralCategory("pl", 2), "few")
	t.eq(tally.pluralCategory("pl", 5), "many")
	t.eq(tally.pluralCategory("pl", 12), "many")
	t.eq(tally.pluralCategory("pl", 22), "few")
	t.eq(tally.pluralCategory("pl", 21), "many")
	t.eq(tally.pluralCategory("ru", 21), "one")
	t.eq(tally.pluralCategory("ru", 11), "many")
	t.eq(tally.pluralCategory("ja", 1), "other")
	t.eq(tally.pluralCategory(nil, 1), "one", "missing language is English")
end)
```

Delete the template files:

```bash
git rm -q tests/util_test.lua mod/pgrace_vehicle_destination/tealdef/gui/pgrace_vehicle_destination/util.d.tl \
  mod/pgrace_vehicle_destination/content/gui/pgrace_vehicle_destination/util.tl \
  mod/pgrace_vehicle_destination/content/gui/pgrace_vehicle_destination/util.d.tl \
  mod/pgrace_vehicle_destination/content/gui/pgrace_vehicle_destination/industry_plugin.res.lua \
  mod/pgrace_vehicle_destination/content/gui/pgrace_vehicle_destination/pgrace_vehicle_destination.script.tl
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `just test`
Expected: FAIL — `tally.tl` doesn't exist yet (`io.open` assertion in `requireTl`).

- [ ] **Step 5: Implement** `$GUI/tally.tl`

```teal
local tally : PgraceVehicleDestinationTally = {}

local type Purpose = PgraceVehicleDestinationTally.Purpose
local type Entry = PgraceVehicleDestinationTally.Entry
local type Row = PgraceVehicleDestinationTally.Row
local type Result = PgraceVehicleDestinationTally.Result

function tally.purposeOf(target : integer, destinations : {integer}) : Purpose
	if target == nil or destinations == nil then
		return nil
	end
	if destinations[1] == target then
		return "home"
	elseif destinations[2] == target then
		return "shop"
	elseif destinations[3] == target then
		return "work"
	end
	return nil
end

local function newRow(town : integer, name : string) : Row
	return { town = town, name = name, cars = 0, home = 0, work = 0, shop = 0 }
end

local function add(row : Row, purpose : Purpose)
	row.cars = row.cars + 1
	if purpose == "home" then
		row.home = row.home + 1
	elseif purpose == "work" then
		row.work = row.work + 1
	elseif purpose == "shop" then
		row.shop = row.shop + 1
	end
end

function tally.group(entries : {Entry}) : Result
	local result : Result = { rows = {}, unknown = nil, total = 0 }
	local byTown : {integer : Row} = {}
	for __, entry in ipairs(entries) do
		local row : Row
		if entry.town == nil then
			if result.unknown == nil then
				result.unknown = newRow(nil, "")
			end
			row = result.unknown
		else
			row = byTown[entry.town]
			if row == nil then
				row = newRow(entry.town, entry.townName or tostring(entry.town))
				byTown[entry.town] = row
				result.rows[#result.rows + 1] = row
			end
		end
		add(row, entry.purpose)
		result.total = result.total + 1
	end
	table.sort(result.rows, function(a : Row, b : Row) : boolean
		if a.cars ~= b.cars then
			return a.cars > b.cars
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.town < b.town
	end)
	return result
end

-- Integer plural rules from CLDR, for the languages TF3 ships (same as Commuter Compass rank.pluralCategory).
local function slavicCategory(count : integer, oneNeedsTensCheck : boolean) : string
	local lastDigit, lastTwo = count % 10, count % 100
	if count == 1 or (oneNeedsTensCheck and lastDigit == 1 and lastTwo ~= 11) then
		return "one"
	end
	if lastDigit >= 2 and lastDigit <= 4 and not (lastTwo >= 12 and lastTwo <= 14) then
		return "few"
	end
	return "many"
end

function tally.pluralCategory(language : string, count : integer) : string
	local lang = (language or "en"):sub(1, 2)
	if lang == "ja" or lang == "ko" or lang == "zh" then
		return "other"
	end
	if lang == "ru" then
		return slavicCategory(count, true)
	end
	if lang == "pl" then
		return slavicCategory(count, false)
	end
	if lang == "fr" or lang == "pt" then
		return (count == 0 or count == 1) and "one" or "other"
	end
	return count == 1 and "one" or "other"
end

return tally
```

- [ ] **Step 6: Run the tests and the type-check**

Run: `just test && just check`
Expected: `8 passed, 0 failed`, and the check reports no errors. `just check` rewrites `_content.json` to list
`tally.tl` and `tally.d.tl` only.

- [ ] **Step 7: Commit**

```bash
git add -A tests mod
git commit -m "feat: tally visible cars by destination town and purpose"
```

---

### Task 2: `scan.tl`, the engine reads (with probe round 1)

**Files:**
- Create: `$DEF/scan.d.tl`, `$GUI/scan.tl`
- Modify: `$MOD/tealdef/pgrace_vehicle_destination_def.d.tl`

No unit test: everything here calls `api.*`. It's verified in-game in Task 4.

- [ ] **Step 1: Type definition** `$DEF/scan.d.tl`

```teal
-- Engine reads: the private cars on screen and where they're going. Call from the main thread
-- (react.enqueueJoin): isVisible reads the camera.
global record PgraceVehicleDestinationScan
	record Result
		entries : {PgraceVehicleDestinationTally.Entry}
		-- Entities with SIM_ENTITY_MOVING.
		moving : integer
		-- Of those, people whose last move mode is DRIVE (on screen or not).
		drivers : integer
		ms : integer
	end

	-- Throws if the engine can't be read at all; a car that fails on its own becomes an unknown entry.
	visibleCars : function() : Result
end
```

- [ ] **Step 2: Register it** — `$MOD/tealdef/pgrace_vehicle_destination_def.d.tl` becomes:

```teal
require "gui.pgrace_vehicle_destination.tally"
require "gui.pgrace_vehicle_destination.scan"
```

- [ ] **Step 3: Implement** `$GUI/scan.tl`, with the probes from spec §4

```teal
local tally = ug_require "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/tally.tl" as PgraceVehicleDestinationTally

local scan : PgraceVehicleDestinationScan = {}

local type Entry = PgraceVehicleDestinationTally.Entry

local LOG_PREFIX = "[vehicle_destination] "

-- Logged once per session, so a broken car doesn't flood the log on every refresh.
local loggedCarError = false

local probeDetailsLeft = 8 -- PROBE (remove before release)

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

function scan.visibleCars() : PgraceVehicleDestinationScan.Result
	local start = os.clock()
	local drive = api.type["enum"].MoveMode.DRIVE
	local moving : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(e : Engine.Entity)
		moving[#moving + 1] = e
	end, api.type.ComponentType.SIM_ENTITY_MOVING)

	local result : PgraceVehicleDestinationScan.Result = { entries = {}, moving = #moving, drivers = 0, ms = 0 }
	local modeCounts : {string : integer} = {} -- PROBE (remove before release)
	local visibleNonDrivers = 0 -- PROBE (remove before release)
	for __, person in ipairs(moving) do
		local simPerson = api.engine.getComponent(person, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
		if simPerson ~= nil then
			local modeKey = tostring(simPerson.lastMoveMode) -- PROBE (remove before release)
			modeCounts[modeKey] = (modeCounts[modeKey] or 0) + 1 -- PROBE (remove before release)
			if simPerson.lastMoveMode == drive then
				result.drivers = result.drivers + 1
				if api.gui.byEntity.isVisible(person) then
					if probeDetailsLeft > 0 then -- PROBE (remove before release)
						probeDetailsLeft = probeDetailsLeft - 1
						pcall(probeDetails, person, simPerson)
					end
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
			elseif api.gui.byEntity.isVisible(person) then -- PROBE (remove before release)
				visibleNonDrivers = visibleNonDrivers + 1
			end
		end
	end
	result.ms = math.floor((os.clock() - start) * 1000 + 0.5)

	-- PROBE (remove before release): move modes seen, and how many people on screen aren't drivers.
	local modes : {string} = {}
	for mode, count in pairs(modeCounts) do
		modes[#modes + 1] = mode .. "=" .. tostring(count)
	end
	debugPrint(LOG_PREFIX .. "probe modes " .. table.concat(modes, " ") .. " DRIVE=" .. tostring(drive)
		.. " visibleNonDrivers=" .. tostring(visibleNonDrivers))

	debugPrint(LOG_PREFIX .. "scan: " .. tostring(result.moving) .. " moving, " .. tostring(result.drivers)
		.. " drivers, " .. tostring(#result.entries) .. " visible, " .. tostring(result.ms) .. " ms")
	return result
end

return scan
```

- [ ] **Step 4: Type-check**

Run: `just check`
Expected: no errors. If `api.type["enum"].MoveMode` or `api.gui.byEntity.isVehicleVisible` isn't accepted, look
up the exact path in `api/tealdef/api/type.d.tl` (around line 2120) and `api/tealdef/api/gui.d.tl` (around line 630)
of the game install and fix the expression. Don't fix it with `as any`.

- [ ] **Step 5: Commit**

```bash
git add -A mod
git commit -m "feat: scan visible private cars (with probe round 1)"
```

---

### Task 3: Button, window and table

**Files:**
- Create: `$GUI/window.script.tl`, `$GUI/button.res.lua`, `$GUI/window.css.lua`, `$MOD/strings.json`

- [ ] **Step 1: The button registration** `$GUI/button.res.lua`

```lua
function data()
	return {
		type = "react-plugin ::MainModButtonAreaExtension",
		data = {
			filePath = "pgrace_vehicle_destination::/gui/pgrace_vehicle_destination/window.script@DestinationsButton",
		}
	}
end
```

- [ ] **Step 2: The window script** `$GUI/window.script.tl`

```teal
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
			valueOf : function(Row) : integer) : Builtin.ColumnDesc
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
```

Notes for the implementer:
- `makeEntityWindowButton(text, entity, tabIndex, content, stack, onClickOverride, tooltip, styleClass)` is the
  base signature (`gui/line_vehicle_mgmt/line_react_util.tl`); the call passes the name as the tooltip.
- If `react.useState(nil)` with an explicit `ReactStateT<Snapshot>` type doesn't type-check, use
  `react.useState(nil) as ReactStateT<Snapshot>` (Trim the Fat does the same for `expandedState`).

- [ ] **Step 3: The stylesheet** `$GUI/window.css.lua`

```lua
local ssu = require "::/gui/main/stylesheetutil.lua"

-- F2's window rules (base gui/statistics/statistics.css.lua), keyed on our window's class (an id selector didn't
-- apply in Trim the Fat) and our content recipe, so other windows are unaffected. Docked bottom-centre.
function data()
	local result = {}
	local a = ssu.makeAdder(result)

	local window = "Window!pgrace-vehicle-destination"
	a(window, {
		gravity = { 0.5, 1.0 },
		anchorPoint = { 0.5, 1.0 },
		padding = { 0, 0, 64, 0 },
		animationName = "open-statistics",
		animationIterationCount = 1,
		animationDuration = 0.2,
		animationTimingFunction = "EaseOutSine",
	})
	a(window .. " Window::Content", {
		padding = { 8, 8, 12, 8 },
	})
	local sizes = {
		["!font-small"] = { 560, 380 },
		["!font-medium"] = { 640, 420 },
		["!font-large"] = { 760, 480 },
	}
	for font, size in pairs(sizes) do
		a(font .. " " .. window, { size = size })
	end

	local root = "R::PgraceVehicleDestinationContent"
	a(root .. " Table", {
		gravity = { -1, -1 },
	})
	a(root .. " Table::Layout", {
		gravity = { -1, -1 },
	})
	a(root .. " !toolbar", {
		innerSpacing = { 12, 12 },
		margin = { 4, 32, 4, 0 }, -- leave space for the close button (compact mode overlaps it)
	})
	a(root .. " !refresh", {
		padding = { 2, 2, 2, 2 },
	})
	a(root .. " !table-item!right-aligned TextView, "
		.. root .. " DataTable::HeaderItem !right-aligned, "
		.. root .. " DataTable::HeaderItem !right-aligned TextView", {
		gravity = { -1, -1 },
		textAlignment = { 1, 0.5 },
	})

	return result
end
```

- [ ] **Step 4: English plural strings** `$MOD/strings.json`

```json
{
    "en": {
        "{count} cars in view|one": "{count} car in view",
        "{count} cars in view|other": "{count} cars in view"
    }
}
```

The other 11 languages come in Task 5. Until then `just release-check` reports them as warnings (missing
languages), not errors. Check this; if it errors, note it and carry on, since Task 5 fixes it.

- [ ] **Step 5: Build and check**

Run: `just check && just test`
Expected: no type errors. `_content.json` lists `button.res.lua`, `scan.d.tl`, `scan.tl`, `tally.d.tl`, `tally.tl`,
`window.css.lua` and `window.script.tl`.

- [ ] **Step 6: Commit**

```bash
git add -A mod
git commit -m "feat: game-bar button and car destinations window"
```

---

### Task 4: In-game probe round 1 (the user)

- [ ] **Step 1: Install from this worktree.** The staging-area symlink must point at this worktree's mod folder
(AGENTS.md "Worktrees"):

```bash
ln -sfn "$PWD/mod/pgrace_vehicle_destination" \
  ~/.local/share/Steam/userdata/12818001/3493540/local/staging_area/pgrace_vehicle_destination
ls -l ~/.local/share/Steam/userdata/12818001/3493540/local/staging_area/pgrace_vehicle_destination
```

- [ ] **Step 2: Ask the user to test,** with this checklist:
  1. Restart TF3, enable "Vehicle Destination", and load a save with town traffic.
  2. A car button appears at the top left, next to the map-layers button. Click it: the window opens at the bottom
     centre. Clicking the button again, ✕ and Esc each close it.
  3. Move the camera over a busy road and press ⟳ about three times. Then zoom out to a whole town and press ⟳
     again.
  4. Move the camera over empty land and press ⟳: the "No cars in view" hint shows.
  5. Click a town name: the town window opens. Click the column headers: the table sorts.
  6. Click two or three cars on the road and note the destination the game shows, to compare with the table.
  7. Say when you're done.

- [ ] **Step 3: Read the log**

```bash
grep -h "\[vehicle_destination\]" ~/.local/share/Steam/userdata/12818001/3493540/local/crash_dump/stdout.txt | tail -60
```

Decide from what it shows:
- **`probe modes`:** which value is DRIVE, and whether drivers show up at all. If `drivers` is 0 while cars are
  clearly driving, cars aren't `SIM_ENTITY_MOVING` + DRIVE. Then look at the `probe car` component flags and pick
  the component that marks a car (for example `MOVE_PATH` on a `SIM_PERSON`), and change the scan.
- **`isVisible` vs `isVehicleVisible`:** use whichever is true on screen and false off it. If `visibleNonDrivers` is
  large while zoomed in on a road, they're pedestrians, which is expected.
- **`targetIsTownBuilding` and destinations:** if most targets match a destination, keep the purpose columns. If
  few do, follow spec §4's fallback (land use) and tell the user before changing the UI.
- **`scan: ... ms`:** if it's over about 50 ms, report it to the user, along with the moving count.
- **Errors or a whole-UI crash:** if the UI died ("Script component root failed"), find the cause in the log and fix
  it before anything else.

- [ ] **Step 4: Record the findings** in the spec (a "Findings" section under §4) and commit:

```bash
git add docs && git commit -m "docs: probe round 1 findings"
```

---

### Task 5: Remove probes, translate, release-ready

**Files:**
- Modify: `$GUI/scan.tl`, `$MOD/strings.json`, `$MOD/_metadata/modinfo.json`, `$MOD/_metadata/description.html`,
  `README.md`
- Modify (kit repo): `/home/pgrace/repos/tf3_mods/AGENTS.md`

- [ ] **Step 1: Remove every probe**: the lines marked `-- PROBE (remove before release)`, `probeDetails`,
  `probeDetailsLeft`, `modeCounts` and `visibleNonDrivers`. Apply the fixes the findings called for. Then:

Run: `grep -rn PROBE mod/ ; just check && just test`
Expected: no `PROBE` hits; check and tests pass.

- [ ] **Step 2: Translations.** Add all 12 languages to `strings.json`. That's every `_()` key in
`window.script.tl`; plural keys need only the forms each language uses (see `PLURAL_FORMS` in
`tools/release_check.py`). Use base-game terms where they exist: look up "Town", "Error (see log)" and so on in
`base/strings/<lang>/LC_MESSAGES/base.mo` with a small `.mo` parser (AGENTS.md "Translations"). Use Trim the Fat's
and Commuter Compass's `strings.json` as references for shared phrases.

Run: `just release-check`
Expected: no translation errors.

- [ ] **Step 3: Metadata.** In `modinfo.json`, fill in the summary (100 chars at most), for example "See where the
cars on screen are heading, grouped by town and trip purpose." Write a plain-text description, add
`localization` for the 12 languages (name, summary, description), and write a matching `description.html`. Replace
`README.md`'s template text with a short description and the dev loop.

- [ ] **Step 4: Kit lessons.** Add a short "Private cars" bullet group to AGENTS.md "Game data facts". It records
what the probe established: how a driving car is identified, which visibility call works, the purpose match rate
and the scan cost. Commit it in the **kit** repo (`/home/pgrace/repos/tf3_mods`), not this one.

- [ ] **Step 5: Verify and commit**

Run: `just verify`
Expected: check, tests and release-check all pass. Release-check may warn only about screenshots, which the user
takes.

```bash
git add -A mod README.md && git commit -m "chore: remove probes, translations, metadata"
```

- [ ] **Step 6: Final in-game check by the user:** the Task 4 checklist again, plus switching the game language to
German to see the translated window and the "1 car / 2 cars" plural.
