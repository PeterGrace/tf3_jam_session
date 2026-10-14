local ssu = require "::/gui/main/stylesheetutil.lua"

-- Copies the F2 Statistics window's rules (base gui/statistics/statistics.css.lua), as Trim the Fat's overview,
-- keyed on our window's class (an id selector didn't apply in Trim the Fat) and our content recipe, so other windows
-- are unaffected. Docked bottom-centre.
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
	a(window .. "!window-expanded", {
		animationName = "expand-statistics",
		animationIterationCount = 1,
		animationDuration = 0.25,
		animationTimingFunction = "EaseOutSine",
	})
	a(window .. "!window-collapsed", {
		animationName = "collapse-statistics",
		animationIterationCount = 1,
		animationDuration = 0.25,
		animationTimingFunction = "EaseOutSine",
	})
	a(window .. " Window::Content", {
		padding = { 8, 8, 12, 8 },
	})

	-- Narrower than F2: five columns. Expanded takes most of the screen height, as F2.
	local sizes = {
		["!font-small"] = { collapsed = { 560, 380 }, expanded = { 560, "80vh" } },
		["!font-medium"] = { collapsed = { 640, 380 }, expanded = { 640, "85vh" } },
		["!font-large"] = { collapsed = { 760, 380 }, expanded = { 760, "90vh" } },
	}
	for font, size in pairs(sizes) do
		a(font .. " " .. window, {
			size = size.collapsed,
		})
		a(font .. " " .. window .. "!window-expanded", {
			size = size.expanded,
		})
	end

	-- The content (F2: R::StatisticsContainer).
	local root = "R::PgraceVehicleDestinationContent"

	-- Let the table fill the window.
	a(root .. " Table", {
		gravity = { -1, -1 },
		margin = { 0, 0, 0, 0 },
	})
	a("!font-medium " .. root .. " Table", {
		margin = { 0, 0, 8, 0 },
	})
	a("!font-large " .. root .. " Table", {
		margin = { 0, 0, 12, 0 },
	})
	a(root .. " Table::Layout", {
		gravity = { -1, -1 },
	})

	-- The toolbar: eye, refresh, expand.
	a(root .. " !look-up", {
		innerSpacing = { 16, 16 },
	})
	a(root .. " !look-up BoxLayout", {
		innerSpacing = { 2, 2 },
	})
	a(root .. " !filter ToggleButton", {
		padding = { 0, 0, 0, 0 },
	})
	a(root .. " !filter Button", {
		padding = { 0, 0, 0, 0 },
	})
	a(root .. " !filter ImageView!category", {
		padding = { 6, 6, 6, 6 },
	})
	a(root .. " !filter !refresh", {
		margin = { 0, 0, 0, 12 },
	})
	a(root .. " !expand", {
		padding = { 6, 6, 6, 6 },
		margin = { 0, 32, 0, 0 }, -- leave space for the close button (which overlaps due to compact mode)
	})
	a("!input-controller " .. root .. " !expand", {
		margin = { 0, 12, 0, 0 },
	})
	a(root .. " ToggleButton!expand ImageView", {
		padding = { 6, 6, 6, 6 },
	})

	-- Right-aligned numeric columns: cells with react.setStyleClasses("right-aligned") and headers with
	-- headerStyleClass = "right-aligned".
	a(root .. " !table-item!right-aligned TextView, "
		.. root .. " DataTable::HeaderItem !right-aligned, "
		.. root .. " DataTable::HeaderItem !right-aligned TextView", {
		gravity = { -1, -1 },
		textAlignment = { 1, 0.5 },
	})

	return result
end
