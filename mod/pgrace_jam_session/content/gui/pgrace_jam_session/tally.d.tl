-- Pure helpers (no api.* calls), so tests/tally_test.lua can run them in plain Lua.
global record PgraceJamSessionTally
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
		-- The town the trip started in (see originOf); nil if unknown.
		from : integer
		fromName : string
		purpose : Purpose
		drawn : boolean
	end

	-- One origin and destination pair.
	record Row
		-- nil for the unknown row.
		town : integer
		name : string
		-- The origin town; nil (and fromName nil) when unknown, and in the unknown row.
		from : integer
		fromName : string
		cars : integer
		home : integer
		work : integer
		shop : integer
	end

	record Result
		-- One row per known destination town and origin: most cars first, then by destination name, then origin name
		-- (an unknown origin first).
		rows : {Row}
		-- Cars whose town is unknown; nil when there are none.
		unknown : Row
		-- Every entry, unknown included.
		total : integer
	end

	-- destinations[1] residence, [2] shopping, [3] work (engine.d.tl SimPerson). nil when nothing matches, and nil for a negative target.
	purposeOf : function(target : integer, destinations : {integer}) : Purpose
	-- The building the trip started from: for a trip home, destinations[lastNonResType + 1] (1 shopping, 2 work);
	-- otherwise the residence, destinations[1]. nil when that can't be told.
	originOf : function(target : integer, destinations : {integer}, lastNonResType : integer) : integer
	group : function(entries : {Entry}) : Result
	-- CLDR integer plural category ("one", "few", "many", "other") for a TF3 language code such as "pt_BR".
	pluralCategory : function(language : string, count : integer) : string
end
