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
