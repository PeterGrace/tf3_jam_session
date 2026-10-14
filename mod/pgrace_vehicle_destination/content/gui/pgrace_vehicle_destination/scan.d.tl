-- Engine reads: the private cars around the camera and where they're going. Call from the main thread
-- (react.enqueueJoin): isVisible reads the camera.
global record PgraceVehicleDestinationScan
	record Result
		-- The counted cars: drawn ones only, or every driver found when onlyVisible is false.
		entries : {PgraceVehicleDestinationTally.Entry}
		-- Street edges in the search circle around the camera, and its radius in metres.
		edges : integer
		radius : integer
		-- People moving on those edges.
		moving : integer
		-- Of those, people whose last move mode is DRIVE, and how many of them the game draws on screen.
		drivers : integer
		drawn : integer
		-- CPU ms for the scan.
		ms : integer
	end

	-- Throws if the engine can't be read at all (or MoveMode.DRIVE is missing). Each person is read in its own pcall:
	-- a car whose destination can't be read becomes an unknown entry, and a person that can't be read at all (or
	-- whose isVisible throws) is skipped.
	cars : function(onlyVisible : boolean) : Result
end
