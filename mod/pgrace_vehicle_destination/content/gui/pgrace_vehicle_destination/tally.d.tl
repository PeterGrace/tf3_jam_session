-- Pure helpers (no api.* calls), so tests/tally_test.lua can run them in plain Lua.
global record PgraceVehicleDestinationTally
	-- Why the car is going to its target: SimPerson.destinations holds {residence, shopping, work}.
	enum Purpose
		"home"
		"shop"
		"work"
	end

	-- One car. town is nil when the destination town can't be resolved; purpose is nil when the target matches none
	-- of the person's destinations. drawn: whether the game draws it on screen (set by scan; group ignores it).
	record Entry
		town : integer
		townName : string
		purpose : Purpose
		drawn : boolean
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

	-- destinations[1] residence, [2] shopping, [3] work (engine.d.tl SimPerson). nil when nothing matches, and nil for a negative target.
	purposeOf : function(target : integer, destinations : {integer}) : Purpose
	group : function(entries : {Entry}) : Result
	-- CLDR integer plural category ("one", "few", "many", "other") for a TF3 language code such as "pt_BR".
	pluralCategory : function(language : string, count : integer) : string
end
