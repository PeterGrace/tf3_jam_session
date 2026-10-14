-- Engine reads: the private cars on screen and where they're going. Call from the main thread
-- (react.enqueueJoin): isVisible reads the camera.
global record PgraceVehicleDestinationScan
	record Result
		entries : {PgraceVehicleDestinationTally.Entry}
		-- Street edges in the search circle around the camera, and its radius in metres.
		edges : integer
		radius : integer
		-- People moving on those edges.
		moving : integer
		-- Of those, people whose last move mode is DRIVE (on screen or not).
		drivers : integer
		-- CPU ms for the scan, excluding probe-only work.
		ms : integer
	end

	-- Throws if the engine can't be read at all (or MoveMode.DRIVE is missing); each entity is read in its own pcall; a car whose destination can't be read becomes an unknown entry, and an entity that can't be read at all is skipped.
	visibleCars : function() : Result
end
