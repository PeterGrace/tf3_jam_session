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
