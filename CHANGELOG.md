# Changelog

All notable changes to Cursor Altitude Tooltip are recorded here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the mod uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The
mod's `revision` in `mod.json` is MAJOR * 10000 + MINOR * 100 + PATCH.

## [Unreleased]

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
