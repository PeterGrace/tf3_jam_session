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
- **Out of scope for now:** origin towns (origin→destination pairs). The residence in `SimPerson.destinations` is
  only the origin on outbound trips, so this needs its own probe and is a possible follow-up.

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
│ 42 cars in view · 7 destination unknown     │
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
- **Eye:** on (default) counts only cars the game draws (`isVisible`); off also counts drivers on the streets in
  the search circle that aren't drawn (useful zoomed far out). Toggling it rescans.
- **Summary line** above the table: "{count} cars in view" (eye off: "{count} cars nearby"; one key per plural form,
  as in Commuter Compass), followed by " · {count} destination unknown" when there are any.
- **Table:** a `builtin.DataTable` with the columns Town, Cars, Home, Work and Shop. It starts sorted by Cars,
  descending, and every column sorts on a header click.
  - The Town column has a weight and a tooltip with the full name. Its cells are
    `line_react_util.makeEntityWindowButton(name, town)`, so a click opens the town window.
  - Numeric columns have short headers and weight 1 each: an unweighted column takes its widest content and can
    squeeze the weighted Town column (AGENTS.md "Tables").
    - **Pin and arrow** (as Commuter Compass): each Town cell starts with our own pin (`followEntity`; not the base
    `LocateButton`, which other mods replace) and an arrow toggle. One arrow at a time, from the **counted spot** (the
    camera's look-at point at the last count) to the town's centre (bounding-volume centre), styled as Cargo
    Compass's actual flows, with a distance label at the top of its arc. Turning it on frames both ends, with the
    view moved toward the camera so the arrow sits above the window. The arrow stays across refreshes (starting from
    the new spot) while its town is listed, and goes when the window closes.
  - The map action needs a fuller game context than the mod button area gives: the arrow builds one as `game.tl`
    does (default renderer, notification cache, empty filters).
- **Each Refresh rebuilds the table** (a new `localKey`), so it starts at the top. This is the approach Trim the
    Fat settled on.
- **Unknown destinations:** cars whose destination town can't be resolved are counted in the summary line, not as
  a table row: the `DataTable` sorts every row by the clicked column, so a row can't be pinned to the bottom. They're
  included in the total.
- **Empty view:** instead of the table, "No cars in view. Move the camera to a road and press Refresh."
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
