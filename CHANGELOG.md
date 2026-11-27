# Changelog

All notable changes to Cursor Altitude, Distance & Incline Tooltip are
recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the mod uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The mod's
`revision` in `mod.json` is MAJOR * 10000 + MINOR * 100 + PATCH.

## [Unreleased]

### Fixed
- The game could exit with an error right after you pressed the key and
  started to move the mouse (also when the key was still held as you left
  a construction tool). The line now appears only from 24 m; the tooltip
  measures from 1 m as before.

## [1.1.0] - 2026-11-27

### Added
- Keep holding the key and move the mouse: the tooltip adds the signed
  height difference, the horizontal distance and the incline (%) between
  the point where the key went down and the cursor, and a line joins the
  two points. Within 1 m of that point only the altitude shows. Release the
  key and everything disappears; nothing is saved in the savegame.
- Distances follow the game's unit setting, like the altitude.

### Changed
- The mod is renamed "Cursor Altitude, Distance & Incline Tooltip"
  (Japanese: 「カーソル位置の標高・距離・勾配の表示」), and the summary and
  the description in every language describe the new measuring.

## [1.0.1] - 2026-11-22

### Changed
- The mod's name in the game's mod list and on mod.io is now English only,
  "Cursor Altitude Tooltip". The summary and the description still carry
  Japanese, and the description has a section for every game language.

## [1.0.0] - 2026-11-12

### Added
- First public release, uploaded to mod.io as `revision` 1 before the mod
  had version numbers. While no tool or layer is active, holding the
  **Surface Snapping** key (Alt by default) shows the altitude of the
  terrain under the mouse cursor in the cursor tooltip, instead of the
  usual name tooltip.
- The altitude follows the game's unit setting (metres / feet); over
  buildings and water the ground below is measured.
- Not shown while a station, vehicle, line, industry or town window is
  open: they bring their own cursor and tooltip.
- The tooltip label in the game's 13 languages, and a description section
  per language.
- GUI only: safe to add to and remove from a running save.
