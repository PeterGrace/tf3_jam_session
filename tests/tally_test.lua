local t = ...
local tally = t.requireTl("gui/pgrace_jam_session/tally.tl")

t.test("purposeOf: matches residence, shopping, work", function()
	local destinations = { 10, 20, 30 }
	t.eq(tally.purposeOf(10, destinations), "home")
	t.eq(tally.purposeOf(20, destinations), "shop")
	t.eq(tally.purposeOf(30, destinations), "work")
	t.eq(tally.purposeOf(40, destinations), nil, "no match")
	t.eq(tally.purposeOf(nil, destinations), nil, "no target")
	t.eq(tally.purposeOf(10, nil), nil, "no destinations")
	t.eq(tally.purposeOf(-1, { 10, -1, 30 }), nil, "invalid target")
end)

t.test("originOf: home trips come from the last shop or work, others from home", function()
	-- destinations: residence 10, shopping 20, work 30; lastNonResType 1 = shopping, 2 = work (index - 1).
	local destinations = { 10, 20, 30 }
	t.eq(tally.originOf(10, destinations, 1), 20, "home from shopping")
	t.eq(tally.originOf(10, destinations, 2), 30, "home from work")
	t.eq(tally.originOf(30, destinations, 1), 10, "to work from home")
	t.eq(tally.originOf(20, destinations, 2), 10, "to shopping from home")
	t.eq(tally.originOf(99, destinations, 2), 10, "unmatched target: from home, as the base game")
	t.eq(tally.originOf(10, { 10, -1, 30 }, 1), nil, "invalid origin building")
	t.eq(tally.originOf(10, destinations, nil), nil, "no last non-residential type")
	t.eq(tally.originOf(nil, destinations, 1), nil, "no target")
	t.eq(tally.originOf(10, nil, 1), nil, "no destinations")
end)

t.test("group: one row per origin and destination pair", function()
	local r = tally.group({
		{ town = 1, townName = "Tuscaloosa", from = 2, fromName = "Pasadena", purpose = "work" },
		{ town = 1, townName = "Tuscaloosa", from = 3, fromName = "Elk Lodge", purpose = "work" },
		{ town = 1, townName = "Tuscaloosa", from = 3, fromName = "Elk Lodge", purpose = "shop" },
		{ town = 1, townName = "Tuscaloosa", from = 2, fromName = "Pasadena", purpose = "work" },
		{ town = 1, townName = "Tuscaloosa", from = 3, fromName = "Elk Lodge", purpose = "work" },
	})
	t.eq(#r.rows, 2)
	t.eq(r.rows[1].fromName, "Elk Lodge")
	t.eq(r.rows[1].from, 3)
	t.eq(r.rows[1].cars, 3)
	t.eq(r.rows[1].work, 2)
	t.eq(r.rows[2].fromName, "Pasadena")
	t.eq(r.rows[2].cars, 2)
	t.eq(r.total, 5)
end)

t.test("group: equal counts sort by destination, then origin; unknown origins get their own row", function()
	local r = tally.group({
		{ town = 1, townName = "Alpha", from = 5, fromName = "Zed" },
		{ town = 1, townName = "Alpha" },
		{ town = 1, townName = "Alpha", from = 4, fromName = "Bee" },
	})
	t.eq(#r.rows, 3)
	t.eq(r.rows[1].fromName, nil, "unknown origin first (empty name)")
	t.eq(r.rows[1].from, nil)
	t.eq(r.rows[2].fromName, "Bee")
	t.eq(r.rows[3].fromName, "Zed")
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
