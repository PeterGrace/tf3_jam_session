local tally : PgraceVehicleDestinationTally = {}

local type Purpose = PgraceVehicleDestinationTally.Purpose
local type Entry = PgraceVehicleDestinationTally.Entry
local type Row = PgraceVehicleDestinationTally.Row
local type Result = PgraceVehicleDestinationTally.Result

function tally.purposeOf(target : integer, destinations : {integer}) : Purpose
	if target == nil or target < 0 or destinations == nil then
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
