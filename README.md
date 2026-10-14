# Jam Session (Transport Fever 3 mod)

Counts the private cars on screen and lists where they're heading and where they came from, one row per
origin → destination trip, so you can see which trips a new line, a bypass or a ring road would take off the road.
A car button next to the map layers button opens the window; a refresh counts again, an eye toggle includes cars too
far away to be drawn, and each row can show an arrow on the map.

- Mod ID: `pgrace_jam_session`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.

Agent and modding notes for all mods live in `../AGENTS.md`. The design and its in-game findings are in
`docs/superpowers/specs/2026-10-14-vehicle-destination-design.md`.

## Layout

```
mod/pgrace_jam_session/                        # the mod folder TF3 loads
├── mod.json, _metadata/              # modinfo.json, description.html, screenshots
├── tealdef/                          # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_jam_session/
    ├── button.res.lua                # registers the game-bar button (::MainModButtonAreaExtension)
    ├── window.script.tl              # button, window, table, map arrow
    ├── window.css.lua                # F2-style window, toolbar, arrow label
    ├── scan.tl                       # engine reads: cars on the streets around the camera, spread over frames
    └── tally.tl                      # pure grouping, trip origin, plurals (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[jam_session]`.

## Releasing

1. Screenshots in `mod/pgrace_jam_session/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
