-- Engine reads: the private cars around the camera and where they're going, spread over frames. Call from the main
-- thread (react.enqueueJoin): isVisible reads the camera.
global record PgraceVehicleDestinationScan
	record Result
		-- Every driver found, each flagged with whether it's drawn on screen.
		entries : {PgraceVehicleDestinationTally.Entry}
		-- The camera's look-at point when counted: where the cars were counted.
		center : Vec3f
		-- Street edges in the search circle around the camera, and its radius in metres.
		edges : integer
		radius : integer
		-- People moving on those edges.
		moving : integer
		-- Of those, people whose last move mode is DRIVE, and how many of them the game draws on screen.
		drivers : integer
		drawn : integer
		-- Milliseconds of work (wall clock, summed over the frames the scan ran in).
		ms : integer
	end

	-- A scan in progress (opaque).
	record Job
	end

	-- Reads the camera and sets up a scan of the cars around what's on screen. Throws if MoveMode.DRIVE is missing.
	start : function() : Job
	-- Advances the scan for about `budgetUs` microseconds (at least one unit of work); true when done. Each tile, edge
	-- and person is read in its own pcall: a car whose destination can't be read becomes an unknown entry, and a
	-- person that can't be read at all (or whose isVisible throws) is skipped.
	step : function(job : Job, budgetUs : integer) : boolean
	-- Share of the work done, 0 to 1.
	progress : function(job : Job) : number
	-- The result; complete once step has returned true.
	result : function(job : Job) : Result
end
