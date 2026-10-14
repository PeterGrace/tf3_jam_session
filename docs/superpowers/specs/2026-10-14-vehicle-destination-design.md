# Vehicle Destination: where are the cars in view heading?

## Problem

When a road jams, the player wants to know where the people sitting in that traffic are going, to judge whether a
transit line could take them off the road. The base game shows a single car's destination only by clicking it, one
at a time.

## Scope

- **Private cars only**: people travelling with move mode `DRIVE`. Buses, trams and trucks are the player's own
  vehicles and are out of scope.
- **Every car in view** counts, moving or stopped. There's no speed filter: the player frames the jam and counts
  what's on screen.
- **Snapshot**, not live: counted when the window opens and on Refresh.
- **Origin towns** (added after the first in-game rounds): one row per origin → destination pair. The origin is
  worked out as the base game does (arrival tracker, person window): a trip home started at
  `destinations[lastNonResType + 1]` (the last shop or workplace); any other trip started at home, `destinations[1]`.

## §1 Button and window

Copied from Trim the Fat's overview (see AGENTS.md, "A game-bar button that opens a window"):

- **Button:** a plugin on `::MainModButtonAreaExtension`, a `builtin.ToolButton` (car icon) with the tooltip
  "Car destinations: where the cars on screen are heading".
- **Window:** `tool_react_util.registerToolWithWindow`, with a `builtin.Window` wrapper recipe. It's sized and
  docked like F2 through a mod stylesheet keyed on a window class, with `compact = true` and a single-tab
  `TabWidget` for the title. The button shows pressed while the window is open; clicking it again, ✕ and Esc
  close it.

```
┌[Car destinations]──────────── [👁 ⟳] [⤢] ✕┐
│ 42 cars in view · Destination unknown: 7    │
├──────────────┬──────┬──────┬──────┬────────┤
│ Town         │ Cars │ Home │ Work │ Shop   │
├──────────────┼──────┼──────┼──────┼────────┤
│ Springfield  │   23 │    4 │   15 │      4 │
│ Shelbyville  │   12 │    9 │    2 │      1 │
└──────────────┴──────┴──────┴──────┴────────┘
```
- **Layout as Trim the Fat** (user's choice after the first in-game look): F2's toolbar floats over the tab row's
  right end: a filter box with the eye and Refresh (⟳), and the expand toggle in its own box. The eye and the
  expanded state are remembered between openings (until restart).
- **Eye:** on (default) lists only cars the game draws (`isVisible`); off also lists drivers on the streets in the
  search circle that aren't drawn (useful zoomed far out). Each count keeps every driver with a `drawn` flag, so the
  eye only switches lists: it never counts again, and never moves the counted spot. (Recounting on each toggle, from
  wherever an arrow had moved the camera, made the view creep.)
- **Counted spot:** set on open and on Refresh only, from the camera's look-at point then.
- **Refresh with an arrow shown:** if the player moved the view (eye or look-at point off by more than 2% of the
  distance + 5 m) since the last count, or since the arrow's framing came to rest (read 90 steps after it started),
  the arrow is cancelled and the count starts from the new spot. If not, the arrow and its start stay, and only the
  counts change (counted from what's on screen, which after framing is the arrow's whole route).
- **Summary line** above the table: "{count} cars in view" (eye off: "{count} cars nearby"; one key per plural form,
  as in Commuter Compass), followed by " · Destination unknown: {count}" when there are any.
- **Table:** a `builtin.DataTable` with the columns listed below. It starts sorted by Cars,
  descending, and every column sorts on a header click.
  - The Town column has a weight and a tooltip with the full name. Its cells are
    `line_react_util.makeEntityWindowButton(name, town)`, so a click opens the town window.
  - Numeric columns have short headers and weight 1 each: an unweighted column takes its widest content and can
    squeeze the weighted Town column (AGENTS.md "Tables").
    - **Pin and arrow** (as Commuter Compass): each Town cell starts with our own pin (`followEntity`; not the base
    `LocateButton`, which other mods replace) and an arrow toggle. One arrow at a time, from the **counted spot** (the
    camera's look-at point at the last count) to the town's centre (bounding-volume centre), styled as Cargo
    Compass's actual flows, with a distance label at the top of its arc. Turning it on (or switching town) frames both ends; a refresh moves its start but not the camera, with the
    view moved toward the camera so the arrow sits above the window. The arrow stays across refreshes (starting from
    the new spot) while its town is listed, and goes when the window closes.
  - The map action needs a fuller game context than the mod button area gives: the arrow builds one as `game.tl`
    does (default renderer, notification cache, empty filters).
- **Columns:** From | To | Cars | Home | Work | Shop | Trip | Here (user's choice: both distances, arrow unchanged).
  - **From:** the origin town's name (opens its window), or "Unknown". **To:** pin, arrow toggle and name, as before.
  - **Trip:** straight-line distance between the two towns' centres. **Here:** from the counted spot to To's centre,
    as the arrow's label. Both formatted once per count with `api.util.formatLength`; "–" if unknown, sorted last
    when nearest-first.
  - Row keys are one integer per pair for the session, so a selected row keeps its key across counts. Rows sharing a
    destination share the arrow (counted spot → To); only the clicked row's toggle lights up.
- **A header click rebuilds the table** in the new order (new `localKey`, `initialSortColumn` = the new sort), so the
  list starts at the top, as Trim the Fat. The sort is remembered between openings, like the eye.
- **Each Refresh rebuilds the table** (a new `localKey`), so it starts at the top. This is the approach Trim the
    Fat settled on.
- **Unknown destinations:** cars whose destination town can't be resolved are counted in the summary line, not as
  a table row: the `DataTable` sorts every row by the clicked column, so a row can't be pinned to the bottom. They're
  included in the total.
- **Empty view:** instead of the table, "No cars in view. Move the camera to a road and count again."
- **Error:** "Error (see log)", with the error logged under a `[vehicle_destination]` prefix.

## §2 Data

### Finding visible cars (`scan.tl`, engine reads)

1. `SIM_ENTITY_MOVING` **can't be looped over** ("Cannot loop over this component type", in-game). Instead,
   `octree.findEntitiesInCircle(lookAt, r, BASE_EDGE_STREET)` collects the street edges around the camera's look-at
   point (`r` = 2.5 × the eye's distance, clamped to 300–8000 m), and
   `simPersonSystem.getSimPersonsMovingForTransportNetwork(edge)` gives the people moving on each (deduplicated).
2. Keep a person if `SIM_PERSON.lastMoveMode == MoveMode.DRIVE`.
3. With the eye on, keep it if `api.gui.byEntity.isVisible(person)` is true.
4. For each car, produce an entry `{ town, townName, purpose }`:
   - `target = SimPerson.targetOrAtEntity`, then `TOWN_BUILDING.town` gives the town, and
     `api.engine.util.getEntityName(town)` its name.
   - **Purpose:** compare `target` with `SimPerson.destinations`, which the tealdef documents as {residence,
     shopping, work}. A match on residence is `home`, on shopping `shop`, on work `work`, and no match is `nil`.
   - A missing target, a target that isn't a town building, or an entity that no longer exists gives
     `town = nil` (the Unknown row).
   - Each car is read in its own `pcall`, so one bad entity becomes Unknown without failing the scan.
5. Log `[vehicle_destination] scan: E street edges in R m, N moving, M drivers, D drawn, C counted, T ms`.

**Spread over frames** (the freeze fix): a zoomed-out scan was 250 ms to 1 s of work in one frame, almost all of it
the engine's own lookups (finding street edges: 60 ms in one call; the people on each edge: 113 ms; destinations 23
ms; isVisible on 2,500 cars only 4 ms). `scan.start` reads the camera and splits the search circle into ~1 km tiles;
`scan.step(job, 6000 µs)` then looks up tiles and reads edges until the budget is spent, once per frame, timed with
`api.type.Clock` (wall clock, µs; `os.clock` is process CPU time and runs several times too fast in a busy game). The
last count stays on screen with "Counting… N%" above it; Refresh during a count starts over. Skipping edges that
aren't `isVisible` was measured and rejected: 2,919 of 3,225 edges counted as visible, and 8 edges with drawn cars
didn't.

The scan runs on the main thread: on open and on Refresh, the window sets a "scan due" ref, and `react.onStep`
hands the scan to `react.enqueueJoin`. `isVisible` is a camera read, and camera reads can be restricted during the
react step (`world2Screen` throws "API is currently restricted", an uncatchable crash) or crash from a step timer
(`isLineEmptyOrVisible`, see AGENTS.md). The join is the path proven safe in Commuter Compass.

### Grouping (`tally.tl`, pure, unit-tested)

`tally.group(entries) : { rows : {Row}, unknown : Row|nil, total : integer }`, where
`Row = { town : integer|nil, name : string, cars, home, work, shop : integer }`:

- one row per town; `nil` towns are collected in the separate `unknown` row;
- `rows` sorted by `cars` descending, then by name;
- `total` is the sum of `cars`, which equals the number of entries;
- an entry with an unknown purpose adds to `cars` only, so `home + work + shop ≤ cars`.

## §3 Files

```
content/gui/pgrace_vehicle_destination/
├── tally.tl                 # pure grouping (replaces the template's util.tl)
├── scan.tl                  # engine reads
├── window.script.tl         # button plugin, tool, window, table
├── button.res.lua           # react-plugin ::MainModButtonAreaExtension
└── window.css.lua           # window size/position, F2 look
```

The template's industry plugin (`industry_plugin.res.lua` and its script) and `util.tl` are removed. `mod.json`
stays `cosmetic: true` with severities `"None"`: the mod only reads.

## §4 Probe round 1

Temporary `debugPrint`s marked `-- PROBE (remove before release)`. The user restarts, opens the window over a busy
road and presses Refresh a few times, at a few zoom levels:

- the components of the first few `SIM_ENTITY_MOVING` entities that have `SIM_PERSON`, and the numeric value of
  `lastMoveMode` for driving and walking people;
- whether `isVisible` returns true for cars on screen and false off screen, and whether `isVehicleVisible` agrees;
- for a few cars: `targetOrAtEntity`, the `destinations` list, and whether the target has `TOWN_BUILDING`;
- the scan timing on the user's save.

If the purpose match is rare, fall back to the target building's land use: the Home, Work and Shop columns become
Residential, Industrial and Commercial.

### Findings (round 1, 2026-10-14, user's 697k-population save)

- `forEachEntityWithComponent(…, SIM_ENTITY_MOVING)` throws "Cannot loop over this component type"; the street-edge
  route above replaced it.
- `MoveMode.DRIVE` = 1 (0 and 2 also seen among people on streets; 2 = walking, with `MODEL_PERSON`). 95–99% of the
  people moving on street edges were driving.
- **A driving person is the car:** it has `LAND_VEHICLE` and `MOVE_PATH`, no `MODEL_PERSON`, no
  `SIM_ENTITY_AT_VEHICLE`. `isVisible` works on it (true on screen, false off); `isVehicleVisible` throws on it.
- `targetOrAtEntity` was a town building for every sampled car, and it matched one of `destinations` each time
  (residence, shopping or work; a missing slot is -1). The purpose columns stay; no land-use fallback.
- **Cost:** 1–90 ms close up; 200–320 ms fully zoomed out (2,500–3,400 edges, 8 km circle), of which about a fifth of
  the drivers were drawn. Round 2 probes how far the drawn cars reach (as a multiple of the eye distance) to tighten
  the circle.
## §5 Testing

- `tests/tally_test.lua`:
  - grouping and counts;
  - sorting by count, then name;
  - unknown towns kept out of `rows`;
  - an unknown purpose counts in `cars` only;
  - an empty input gives no rows and a total of 0.
- `just verify` must pass.
- **In-game checklist:**
  1. The button appears; the window opens and closes with the button, ✕ and Esc.
  2. Over a jam, the counts look plausible against clicking a few cars by hand.
  3. Refresh after panning changes the counts.
  4. With the camera on empty land, the empty hint shows.
  5. A town name opens that town's window.
  6. Sorting by each column works.

## §6 Translations

All text goes through `_()`. Plural keys use the Commuter Compass `pluralCategory` pattern (copy `rank.pluralCategory`
into `tally.tl` with its tests). English ships first; the other 11 languages follow before the first upload, using
base-game terms (`base.mo`) for Town, Home, Work and Shop where they exist.
