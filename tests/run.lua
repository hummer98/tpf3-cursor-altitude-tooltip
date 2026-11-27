-- Offline tests for Cursor Altitude, Distance & Incline Tooltip. Run from
-- anywhere:
--   luajit tests/run.lua
-- The game globals the scripts use (api, ug_require, _, debugPrint) and the
-- GUI modules (react, builtin, ...) are stubbed with just enough behaviour.

local root = (arg and arg[0] or "tests/run.lua"):match("^(.*)/tests/[^/]*$") or "."

local loaders = package.loaders or package.searchers
table.insert(loaders, 2, function(name)
	local rel = name:match("^hummer_cursor_altitude_tooltip::/(.*)$")
	if rel then return assert(loadfile(root .. "/content/" .. rel)) end
end)

local failures, passes = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passes = passes + 1
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end
local function eq(a, b, msg)
	if a ~= b then error((msg or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2) end
end

------------------------------------------------------------------------
-- cat_core (pure)
------------------------------------------------------------------------
local core = require "hummer_cursor_altitude_tooltip::/gui/cat_core.lua"

local function fmt(z, d) return string.format("%." .. d .. "f m", z) end

test("formatAltitude uses the game formatter with one decimal", function()
	eq(core.formatAltitude("標高", 123.456, fmt), "標高: 123.5 m")
end)

test("formatAltitude falls back when the formatter throws or returns junk", function()
	eq(core.formatAltitude("A", 5, function() error("restricted") end), "A: 5.0 m")
	eq(core.formatAltitude("A", 5, function() return "" end), "A: 5.0 m")
	eq(core.formatAltitude("A", 5, nil), "A: 5.0 m")
end)

test("formatAltitude fallback in feet when imperial", function()
	eq(core.formatAltitude("A", 100, nil, true), "A: 328.1 ft")
	eq(core.formatAltitude("A", -10, nil, true), "A: -32.8 ft")
	eq(core.formatAltitude("A", -0.01, nil, true), "A: 0.0 ft")
	eq(core.formatAltitude("A", 100, nil, false), "A: 100.0 m")
	eq(core.formatAltitude("A", 100, nil, nil), "A: 100.0 m")
	-- the game's formatter wins over our own unit choice
	eq(core.formatAltitude("A", 100, fmt, true), "A: 100.0 m")
	eq(core.tooltipText(true, true, { z = 100 }, "A", nil, true), "A: 328.1 ft")
end)

test("formatAltitude prints tiny negatives as 0, keeps real negatives", function()
	eq(core.formatAltitude("A", -0.01, nil), "A: 0.0 m")
	eq(core.formatAltitude("A", -12.34, nil), "A: -12.3 m")
end)

test("label: translation, missing key echo, no _", function()
	eq(core.label(function() return "標高" end, "cat_altitude", "Altitude"), "標高")
	eq(core.label(function(k) return k end, "cat_altitude", "Altitude"), "Altitude")
	eq(core.label(function() error("x") end, "cat_altitude", "Altitude"), "Altitude")
	eq(core.label(nil, "cat_altitude", "Altitude"), "Altitude")
end)

test("tooltipText: nil unless held and on terrain", function()
	local pos = { x = 1, y = 2, z = 30 }
	eq(core.tooltipText(false, true, pos, "A", nil), nil)
	eq(core.tooltipText(true, false, pos, "A", nil), nil)
	eq(core.tooltipText(true, true, nil, "A", nil), nil)
	eq(core.tooltipText(true, true, pos, "A", nil), "A: 30.0 m")
end)

test("tooltipText: non-finite or missing z gives nil", function()
	eq(core.tooltipText(true, true, { z = 0 / 0 }, "A", nil), nil)
	eq(core.tooltipText(true, true, { z = math.huge }, "A", nil), nil)
	eq(core.tooltipText(true, true, {}, "A", nil), nil)
	eq(core.tooltipText(true, true, 42, "A", nil), nil)
end)

test("tooltipText reads z from a userdata Vec3f", function()
	local ud = newproxy and newproxy(true)
	if not ud then return end -- plain Lua 5.2+: no newproxy, covered by tables
	getmetatable(ud).__index = function(_, k) if k == "z" then return 7.25 end end
	eq(core.tooltipText(true, true, ud, "A", nil), "A: 7.2 m")
end)

------------------------------------------------------------------------
-- cat_core: measuring between two points
------------------------------------------------------------------------

test("tracker: press, move, release, press again", function()
	local t = core.newTracker()
	local o = t.update(true, true, { x = 10, y = 20, z = 5 })
	eq(o.x, 10); eq(o.y, 20); eq(o.z, 5)
	-- moving keeps the origin where the key went down
	o = t.update(true, true, { x = 100, y = 20, z = 9 })
	eq(o.x, 10); eq(o.z, 5)
	-- a second sample in the same step changes nothing
	o = t.update(true, true, { x = 100, y = 20, z = 9 })
	eq(o.x, 10)
	eq(t.update(false), nil, "release drops it")
	eq(t.origin, nil)
	o = t.update(true, true, { x = -3, y = 4, z = 1 })
	eq(o.x, -3, "next press starts afresh")
end)

test("tracker: pressed off the terrain, origin is the first terrain point", function()
	local t = core.newTracker()
	eq(t.update(true, false, nil), nil)
	eq(t.update(true, true, nil), nil, "has but nil pos")
	eq(t.update(true, true, { x = 1, y = 2, z = 0 / 0 }), nil, "NaN is not a point")
	local o = t.update(true, true, { x = 7, y = 8, z = 9 })
	eq(o.x, 7)
	-- leaving the terrain again keeps it
	o = t.update(true, false, nil)
	eq(o.x, 7)
	o = t.update(true, true, { x = 50, y = 8, z = 9 })
	eq(o.x, 7)
end)

test("tracker: the origin is a copy, not the engine's (reused) vector", function()
	local t = core.newTracker()
	local v = { x = 1, y = 1, z = 1 }
	t.update(true, true, v)
	v.x = 99
	eq(t.update(true, true, v).x, 1)
end)

test("tracker: a gap in the samples counts as a new press", function()
	local t = core.newTracker()
	t.update(true, true, { x = 1, y = 0, z = 0 }, 10.0)
	eq(t.update(true, true, { x = 5, y = 0, z = 0 }, 10.5).x, 1)
	-- the view stopped stepping (a tool on top); key up and down unseen
	eq(t.update(true, true, { x = 9, y = 0, z = 0 }, 10.5 + core.STALE_SECONDS + 0.1).x, 9)
	-- without a clock it behaves as before
	local u = core.newTracker()
	u.update(true, true, { x = 1, y = 0, z = 0 })
	eq(u.update(true, true, { x = 2, y = 0, z = 0 }, nil).x, 1)
end)

test("tracker: nil and junk input", function()
	local t = core.newTracker()
	eq(t.update(nil, nil, nil), nil)
	eq(t.update("yes", true, { x = 1, y = 1, z = 1 }), nil, "only true is held")
	eq(t.update(true, true, 42), nil)
	eq(t.update(true, true, "pos"), nil)
	eq(t.update(true, true, { x = 1, y = "2", z = 3 }), nil)
	eq(t.update(true, true, { x = 1, y = 2, z = 3 }).y, 2)
end)

test("tracker: reads a userdata Vec3f", function()
	local ud = newproxy and newproxy(true)
	if not ud then return end
	getmetatable(ud).__index = function(_, k) return ({ x = 1, y = 2, z = 3 })[k] end
	eq(core.newTracker().update(true, true, ud).z, 3)
	-- a userdata that throws on index is no point
	local bad = newproxy(true)
	getmetatable(bad).__index = function() error("expired") end
	eq(core.copyPos(bad), nil)
end)

test("measure: signed height, horizontal distance, incline", function()
	local m = core.measure({ x = 0, y = 0, z = 10 }, { x = 30, y = 40, z = 15 })
	eq(m.dz, 5); eq(m.dist, 50); eq(m.incline, 0.1)
	m = core.measure({ x = 0, y = 0, z = 15 }, { x = 30, y = 40, z = 10 })
	eq(m.dz, -5); eq(m.incline, -0.1)
end)

test("measure: nothing below MIN_DISTANCE or without both points", function()
	eq(core.measure({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }), nil, "same point")
	eq(core.measure({ x = 0, y = 0, z = 0 }, { x = 0.6, y = 0.6, z = 50 }), nil, "0.85 m apart")
	assert(core.measure({ x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }), "1 m is enough")
	eq(core.measure(nil, { x = 1, y = 0, z = 0 }), nil)
	eq(core.measure({ x = 1, y = 0, z = 0 }, nil), nil)
	eq(core.measureLines(nil, { x = 1, y = 0, z = 0 }), nil)
	eq(core.lineKey({ x = 0, y = 0, z = 0 }, { x = 0.5, y = 0, z = 0 }, 1), nil)
end)

test("formatHeightDiff: sign, zero, game formatter, feet fallback", function()
	eq(core.formatHeightDiff("D", 12.34, fmt), "D: +12.3 m")
	eq(core.formatHeightDiff("D", -12.34, fmt), "D: -12.3 m")
	eq(core.formatHeightDiff("D", 0.04, fmt), "D: 0.0 m", "no sign for zero")
	eq(core.formatHeightDiff("D", -0.04, nil), "D: 0.0 m")
	-- a formatter that prints its own minus would double it: it gets the magnitude
	local seen
	eq(core.formatHeightDiff("D", -3, function(v, d) seen = v; return string.format("%.1f m", v) end), "D: -3.0 m")
	eq(seen, 3)
	eq(core.formatHeightDiff("D", 10, nil, true), "D: +32.8 ft")
	eq(core.formatHeightDiff("D", -10, function() error("x") end, true), "D: -32.8 ft")
end)

test("formatDistance: game formatter, metric and imperial fallback", function()
	eq(core.formatDistance("L", 340.2, function(v) return string.format("%.0f m (game)", v) end), "L: 340 m (game)")
	eq(core.formatDistance("L", 5.25, nil), "L: 5.2 m")
	eq(core.formatDistance("L", 340.4, nil), "L: 340 m")
	eq(core.formatDistance("L", 1500, nil), "L: 1.50 km")
	eq(core.formatDistance("L", 2, nil, true), "L: 6.6 ft")
	eq(core.formatDistance("L", 100, nil, true), "L: 328 ft")
	eq(core.formatDistance("L", 1609.344, nil, true), "L: 1.00 mi")
	eq(core.formatDistance("L", 100, function() return "" end, true), "L: 328 ft", "junk from the game: fallback")
end)

test("formatIncline: whole percent like the base slider, signed", function()
	eq(core.INCLINE_DECIMALS, 0)
	eq(core.formatIncline("I", 0.1, nil), "I: +10%")
	eq(core.formatIncline("I", -0.034, nil), "I: -3%")
	eq(core.formatIncline("I", 0.004, nil), "I: 0%", "rounds to 0: no sign")
	eq(core.formatIncline("I", -0.004, nil), "I: 0%")
	local args
	eq(core.formatIncline("I", -0.25, function(v, d) args = { v, d }; return string.format("%.0f %%", v * 100) end), "I: -25 %")
	eq(args[1], 0.25); eq(args[2], 0)
	-- more decimals: one line
	core.INCLINE_DECIMALS = 1
	local ok, s = pcall(core.formatIncline, "I", 0.0123, nil)
	core.INCLINE_DECIMALS = 0
	assert(ok, s)
	eq(s, "I: +1.2%")
end)

test("measureLines: height difference, distance and incline (switchable)", function()
	local o, p = { x = 0, y = 0, z = 10 }, { x = 30, y = 40, z = 15 }
	local labels = { diff = "高度差", distance = "距離", incline = "勾配" }
	local lines = core.measureLines(o, p, labels, { altitude = fmt }, false, true)
	eq(#lines, 3)
	eq(lines[1], "高度差: +5.0 m")
	eq(lines[2], "距離: 50 m")
	eq(lines[3], "勾配: +10%")
	lines = core.measureLines(o, p, labels, { altitude = fmt }, false, false)
	eq(#lines, 2, "incline off")
	-- no labels or formatters given: English fallbacks
	lines = core.measureLines(o, p, nil, nil, true, true)
	eq(lines[1], "Height difference: +16.4 ft")
	eq(lines[2], "Distance: 164 ft")
	eq(lines[3], "Incline: +10%")
end)

test("tooltipText: extra lines under the altitude, one per line", function()
	eq(core.tooltipText(true, true, { z = 1 }, "A", nil, false, { "B", "C" }), "A: 1.0 m\nB\nC")
	eq(core.tooltipText(true, true, { z = 1 }, "A", nil, false, {}), "A: 1.0 m")
	eq(core.tooltipText(true, true, { z = 1 }, "A", nil, false, nil), "A: 1.0 m")
	eq(core.tooltipText(false, true, { z = 1 }, "A", nil, false, { "B" }), nil)
end)

test("lineKey: snapped end points", function()
	local k = core.lineKey({ x = 0.4, y = 10.6, z = 3.2 }, { x = 20.49, y = -5.5, z = 7.7 }, 1)
	eq(table.concat(k, ","), "0,11,3,20,-5,8")
	k = core.lineKey({ x = 0, y = 0, z = 0 }, { x = 7, y = 0, z = 0 }, 5)
	eq(table.concat(k, ","), "0,0,0,5,0,0")
	-- a bad grid falls back to 1 m
	k = core.lineKey({ x = 0, y = 0, z = 0 }, { x = 7.2, y = 0, z = 0 }, 0)
	eq(k[4], 7)
end)

test("lineKey: no zero-length line after snapping; far cursor snaps coarser", function()
	-- 1.4 m apart, both snap to (1, 1)
	eq(core.lineKey({ x = 0.5, y = 0.5, z = 0 }, { x = 1.49, y = 1.49, z = 0 }, 1), nil)
	-- 2 km away: the cursor end moves in 20 m steps, the origin stays on 1 m
	local k = core.lineKey({ x = 0.4, y = 0, z = 0 }, { x = 2009, y = 0, z = 3.4 }, 1)
	eq(table.concat(k, ","), "0,0,0,2000,0,3")
	eq(table.concat(core.lineKey({ x = 0.4, y = 0, z = 0 }, { x = 2001, y = 0, z = 3.4 }, 1), ","), "0,0,0,2000,0,3")
end)

------------------------------------------------------------------------
-- cat_map with stubbed GUI modules
------------------------------------------------------------------------
local logs = {}
debugPrint = function(s) logs[#logs + 1] = s end
_ = function(k) if k == "cat_altitude" then return "標高" end return k end

local held, hasPos, pos = false, true, { x = 0, y = 0, z = 50 }
local heldIA, zoneCalls
local function resetApi()
	held, hasPos, pos, heldIA = false, true, { x = 0, y = 0, z = 50 }, nil
	api = {
		gui = {
			inputAction = {
				modifierOnlyActionIsActive = function(ia) heldIA = ia; return held end,
			},
			mouse = {
				hasTerrainPosition = function() return hasPos end,
				getTerrainPosition = function() return pos end,
			},
		},
		util = { formatAltitude = fmt },
		type = {
			Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
			Vec4f = { new = function(r, g, b, a) return { r, g, b, a } end },
			Vec2f = { new = function(x, y) return { x = x, y = y } end },
			LayerConfig = {
				new = function() return { kind = "LayerConfig" } end,
				CargoFlowRenderableConfig = {
					new = function() return { kind = "CargoFlow" } end,
					FlowData = { new = function() return { kind = "FlowData" } end },
				},
			},
		},
		res = { cargoTypeRep = { getPassengerCargoTypeId = function() return 0 end } },
	}
	-- the zone calls (LINE_MODE "zone"), recorded
	zoneCalls = {}
	api.gui.mission = {
		setZone = function(key, pts, draw, color, prohibit, anim)
			zoneCalls[#zoneCalls + 1] = { "set", key, pts, draw, prohibit, anim }
		end,
		removeZone = function(key) zoneCalls[#zoneCalls + 1] = { "remove", key } end,
	}
end
resetApi()

-- builtin/react stubs: nodes are plain tables, a recipe is the registered
-- function (render it by calling it), useStepState evaluates getter now
local function newMods()
	local registered = {}
	local events, unmounts = {}, {}
	local react = {
		registered = registered,
		events = events,
		unmounts = unmounts,
		RegisterRecipe = function(name, fn)
			registered[#registered + 1] = name
			return fn
		end,
		setMouseTransparent = function() end,
		-- the last handler per name, as a re-render replaces it
		onEvent = function(name, fn) events[name] = fn end,
		onUnmount = function(fn) unmounts[#unmounts + 1] = fn end,
	}
	local builtin = {
		ActionTooltip = function(p) return { kind = "ActionTooltip", recipe = p.recipe, param = p.param } end,
		TextView = function(p) return { kind = "TextView", text = p.text, class = p.meta and p.meta.class } end,
		BoxLayout = function(p) return { kind = "BoxLayout", children = p.children } end,
		ActionDescriptor = function(p) return { kind = "ActionDescriptor", children = p.children, params = p } end,
		LayerConfig = function(p) return { kind = "LayerConfigNode", config = p.config } end,
	}
	local tooltips = {
		DefaultEntityToolTip = function(param) return { kind = "Default", param = param } end,
	}
	local engine_react_util = {
		useStepState = function(getter)
			local v = getter()
			return { old = function() return v end }
		end,
	}
	local baseTooltips = function(ref) return { kind = "BaseTooltip", ref = ref } end
	local sru = {
		makeDefaultSelectorTooltips = baseTooltips,
	}
	-- like the base: the combined fn's action calls the tooltip function
	-- through the module table on each render
	sru.makeDefaultSelectorCombinedFn = function(params)
		return function()
			if params and params.throw then error("render failed") end
			return builtin.ActionDescriptor{
				children = { { kind = "HudIcons" }, sru.makeDefaultSelectorTooltips("REF") },
				terrainCirclePolicy = "Never",
			}
		end
	end
	local files = {
		["::/gui/main/selector_react_util.tl"] = sru,
		["::/gui/main/react.lua"] = react,
		["::/gui/main/builtin.lua"] = builtin,
		["/gui/main/game_tooltips.tl"] = tooltips,
		["/gui/main/engine_react_util.tl"] = engine_react_util,
	}
	local function ug(path) return assert(files[path], "unexpected require " .. path) end
	return { ug = ug, sru = sru, react = react, builtin = builtin, baseTooltips = baseTooltips }
end

local function freshMap()
	package.loaded["hummer_cursor_altitude_tooltip::/gui/cat_map.lua"] = nil
	return require "hummer_cursor_altitude_tooltip::/gui/cat_map.lua"
end

-- render the plain map view and then its tooltip recipe
local function findChild(node, kind)
	for _, c in ipairs(node.children or {}) do
		if c.kind == kind then return c end
	end
	return nil
end

local function renderTooltip(m, params)
	local node = m.sru.makeDefaultSelectorCombinedFn(params or {})()
	local tip = findChild(node, "ActionTooltip")
	eq(tip and tip.kind, "ActionTooltip", "plain map view tooltip")
	return tip.recipe(tip.param), tip, node
end

test("install wraps the plain map view, tooltip function is restored after render", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	renderTooltip(m)
	eq(m.sru.makeDefaultSelectorTooltips, m.baseTooltips, "base tooltip fn put back")
end)

test("other callers of makeDefaultSelectorTooltips keep the base tooltip", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	-- e.g. a station group window calls it outside the plain map view
	eq(m.sru.makeDefaultSelectorTooltips("R").kind, "BaseTooltip")
end)

test("tooltip function is restored when the render throws", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local ok, err = pcall(function() m.sru.makeDefaultSelectorCombinedFn({ throw = true })() end)
	eq(ok, false)
	assert(tostring(err):find("render failed"), tostring(err))
	eq(m.sru.makeDefaultSelectorTooltips, m.baseTooltips)
end)

test("held + on terrain: altitude text instead of the entity tooltip", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held, pos = true, { x = 1, y = 2, z = 87.66 }
	local out = renderTooltip(m)
	eq(out.kind, "BoxLayout")
	eq(out.children[1].kind, "TextView")
	eq(out.children[1].text, "標高: 87.7 m")
	eq(heldIA, "IA_ENHANCED_SNAP")
end)

test("altitude text carries the base tooltip box class (background, colour)", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	local cls = renderTooltip(m).children[1].class
	local set = {}
	for c in cls:gmatch("[^,%s]+") do set[c] = true end
	eq(set["default-tooltip-configuration"], true)
	eq(set["font-scale-tooltip"], true)
end)

test("not held: the base entity tooltip with the same entity ref", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local out, tip = renderTooltip(m)
	eq(out.children[1].kind, "Default")
	eq(out.children[1].param.entityRef, "REF")
	eq(tip.param.entityRef, "REF")
end)

test("held but cursor off terrain (sky): base entity tooltip", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held, hasPos = true, false
	eq(renderTooltip(m).children[1].kind, "Default")
end)

test("modifierOnlyActionIsActive throwing: base tooltip and one log line", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	api.gui.inputAction.modifierOnlyActionIsActive = function() error("API is currently restricted") end
	local before = #logs
	eq(renderTooltip(m).children[1].kind, "Default")
	eq(renderTooltip(m).children[1].kind, "Default")
	local n = 0
	for i = before + 1, #logs do if logs[i]:find("modifierOnlyActionIsActive failed") then n = n + 1 end end
	eq(n, 1, "logged once")
end)

test("terrain position throwing: base tooltip", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	api.gui.mouse.hasTerrainPosition = function() error("boom") end
	eq(renderTooltip(m).children[1].kind, "Default")
end)

test("formatAltitude missing from api.util: plain metres", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held, api.util = true, nil
	eq(renderTooltip(m).children[1].text, "標高: 50.0 m")
end)

-- the fallback must follow the metric/imperial setting like the rest of the UI
local function imperialApi(unit)
	api.util = { getAppConfig = function() return { distanceSpeedUnit = unit } end }
	api.type = { enum = { DistanceSpeedUnit = { Metric = "M", Imperial = "I" } } }
end

test("formatAltitude missing, imperial chosen: feet", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	imperialApi("I")
	eq(renderTooltip(m).children[1].text, "標高: 164.0 ft")
end)

test("formatAltitude missing, metric chosen: metres", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	imperialApi("M")
	eq(renderTooltip(m).children[1].text, "標高: 50.0 m")
end)

test("formatAltitude missing, unit setting unreadable: metres", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	api.util = { getAppConfig = function() error("restricted") end }
	eq(renderTooltip(m).children[1].text, "標高: 50.0 m")
end)

test("game formatter present but throwing, imperial chosen: feet", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	imperialApi("I")
	api.util.formatAltitude = function() error("restricted") end
	eq(renderTooltip(m).children[1].text, "標高: 164.0 ft")
	api.util.formatAltitude = function() return 42 end
	eq(renderTooltip(m).children[1].text, "標高: 164.0 ft")
end)

test("game formatter present: used as is, unit setting not needed", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held = true
	imperialApi("I")
	api.util.formatAltitude = function(z) return string.format("%.0f ft (game)", z * 3.28084) end
	eq(renderTooltip(m).children[1].text, "標高: 164 ft (game)")
end)

test("a working install, render and held key log nothing", function()
	resetApi()
	local map, m = freshMap(), newMods()
	local before = #logs
	map.install(m.ug)
	held = true
	renderTooltip(m)
	held = false
	renderTooltip(m)
	eq(#logs, before, "no log lines")
end)

test("install twice on the same modules wraps once", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local first = m.sru.makeDefaultSelectorCombinedFn
	map.install(m.ug)
	eq(m.sru.makeDefaultSelectorCombinedFn, first)
	eq(#m.react.registered, 1, "recipe registered once")
end)

test("next game load (fresh GUI modules): wraps again and registers a new recipe", function()
	resetApi()
	local map = freshMap()
	local m1, m2 = newMods(), newMods()
	local orig2 = m2.sru.makeDefaultSelectorCombinedFn
	map.install(m1.ug)
	map.install(m2.ug)
	assert(m2.sru.makeDefaultSelectorCombinedFn ~= orig2, "second load wrapped")
	eq(#m2.react.registered, 1)
	held = true
	eq(renderTooltip(m2).children[1].kind, "TextView")
end)

test("chains with another wrap of the combined fn (e.g. Station Coverage Filter)", function()
	resetApi()
	local map, m = freshMap(), newMods()
	local seen
	local base = m.sru.makeDefaultSelectorCombinedFn
	m.sru.makeDefaultSelectorCombinedFn = function(p)
		local inner = base(p)
		return function() local n = inner(); seen = true; return n end
	end
	map.install(m.ug)
	held = true
	eq(renderTooltip(m).children[1].kind, "TextView")
	eq(seen, true, "other wrap still runs")
end)

test("install errors when the base functions are missing", function()
	resetApi()
	local map, m = freshMap(), newMods()
	m.sru.makeDefaultSelectorTooltips = nil
	local ok = pcall(map.install, m.ug)
	eq(ok, false)
	local map2, m2 = freshMap(), newMods()
	m2.sru.makeDefaultSelectorCombinedFn = nil
	eq((pcall(map2.install, m2.ug)), false)
end)

test("install script: a failing install logs instead of throwing", function()
	resetApi()
	package.loaded["hummer_cursor_altitude_tooltip::/gui/cat_map.lua"] = nil
	local m = newMods()
	m.sru.makeDefaultSelectorTooltips = nil
	ug_require = m.ug
	dofile(root .. "/content/gui/cat_install.script.lua")
	local before = #logs
	data().CAT_Install({})
	assert(logs[#logs]:find("%[CAT%] install:"), logs[#logs])
	assert(#logs > before)
end)

test("res file points at the install script", function()
	dofile(root .. "/content/gui/cat_install.res.lua")
	local d = data()
	eq(d.type, "react-replacement-config")
	eq(d.data.filePath, "hummer_cursor_altitude_tooltip::/gui/cat_install.script")
	eq(d.data.doReplaceFn, "CAT_Install")
end)

------------------------------------------------------------------------
-- cat_map: measuring and the line
------------------------------------------------------------------------

_ = function(k)
	return ({ cat_altitude = "標高", cat_height_difference = "高度差", cat_distance = "距離", cat_incline = "勾配" })[k] or k
end

-- one press-move cycle through the plain map view: each render samples
-- the key and the cursor, as the engine's steps would
local function renderAt(m, isHeld, p)
	held, pos = isHeld, p
	local out, _, node = renderTooltip(m)
	return out, node
end

test("held and moved: altitude, height difference, distance, incline", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local out = renderAt(m, true, { x = 0, y = 0, z = 10 })
	eq(out.children[1].text, "標高: 10.0 m", "right after the press: altitude only")
	out = renderAt(m, true, { x = 30, y = 40, z = 15 })
	eq(out.children[1].text, "標高: 15.0 m\n高度差: +5.0 m\n距離: 50 m\n勾配: +10%")
	out = renderAt(m, true, { x = 0.3, y = 0.3, z = 12 })
	eq(out.children[1].text, "標高: 12.0 m", "back within 1 m: altitude only")
end)

test("released: usual tooltip, no line; next press measures from the new point", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	renderAt(m, true, { x = 0, y = 0, z = 10 })
	local _, node = renderAt(m, true, { x = 100, y = 0, z = 0 })
	assert(findChild(node, "LayerConfigNode"), "line while held")
	local out
	out, node = renderAt(m, false, { x = 100, y = 0, z = 0 })
	eq(out.children[1].kind, "Default")
	eq(findChild(node, "LayerConfigNode"), nil, "no line after release")
	renderAt(m, true, { x = 100, y = 0, z = 0 })
	out = renderAt(m, true, { x = 100, y = 10, z = -5 })
	eq(out.children[1].text, "標高: -5.0 m\n高度差: -5.0 m\n距離: 10 m\n勾配: -50%")
end)

test("pressed over the sky: origin is where the cursor first meets terrain", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	hasPos = false
	eq(renderAt(m, true, { x = 999, y = 999, z = 999 }).children[1].kind, "Default")
	hasPos = true
	eq(renderAt(m, true, { x = 0, y = 0, z = 20 }).children[1].text, "標高: 20.0 m")
	eq(renderAt(m, true, { x = 0, y = 100, z = 30 }).children[1].text,
		"標高: 30.0 m\n高度差: +10.0 m\n距離: 100 m\n勾配: +10%")
end)

test("measuring in feet when the game formatters are missing and imperial is set", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	api.util = { getAppConfig = function() return { distanceSpeedUnit = "I" } end }
	api.type.enum = { DistanceSpeedUnit = { Metric = "M", Imperial = "I" } }
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	eq(renderAt(m, true, { x = 100, y = 0, z = 10 }).children[1].text,
		"標高: 32.8 ft\n高度差: +32.8 ft\n距離: 328 ft\n勾配: +10%")
end)

test("the game's length and percent formatters are used", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	api.util.formatLength = function(v) return string.format("%.0f m*", v) end
	api.util.toStringPercentPrecision = function(v, d) return string.format("%." .. d .. "f %%*", v * 100) end
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	eq(renderAt(m, true, { x = 0, y = 200, z = 4 }).children[1].text,
		"標高: 4.0 m\n高度差: +4.0 m\n距離: 200 m*\n勾配: +2 %*")
end)

test("SHOW_INCLINE off: no incline line", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	core.SHOW_INCLINE = false
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local ok, out = pcall(renderAt, m, true, { x = 0, y = 200, z = 4 })
	core.SHOW_INCLINE = true
	assert(ok, out)
	eq(out.children[1].text, "標高: 4.0 m\n高度差: +4.0 m\n距離: 200 m")
end)

test("arrow: a LayerConfig child with one flow from origin to cursor, lifted", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local _, node = renderAt(m, true, { x = 0.2, y = 0, z = 10 })
	eq(findChild(node, "LayerConfigNode"), nil, "no line right after the press")
	_, node = renderAt(m, true, { x = 50.4, y = -20, z = 14.6 })
	local lc = assert(findChild(node, "LayerConfigNode"), "layer config child")
	local flows = lc.config.cargoFlowRenderableConfig.flowData
	eq(#flows, 1)
	local f = flows[1]
	eq(f.from.x, 0); eq(f.from.y, 0); eq(f.from.z, 10 + map.ARROW_LIFT)
	eq(f.to.x, 50); eq(f.to.y, -20); eq(f.to.z, 15 + map.ARROW_LIFT)
	eq(f.speed, map.ARROW_SPEED)
	eq(f.cargoIconAlpha, 0)
	eq(#f.cargoTypes, 0, "no cargo type: the engine's icon pass never runs")
	assert(#f.arrowColors >= 1, "colours")
	-- the base children stay, in order, and the descriptor keeps its fields
	eq(node.children[1].kind, "HudIcons")
	eq(node.children[2].kind, "ActionTooltip")
	eq(node.params.terrainCirclePolicy, "Never")
	eq(m.builtin.ActionDescriptor ~= nil, true)
end)

test("arrow: the layer config is rebuilt only when an end moves a grid step", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local built = 0
	local orig = api.type.LayerConfig.new
	api.type.LayerConfig.new = function() built = built + 1; return orig() end
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local _, n1 = renderAt(m, true, { x = 40, y = 0, z = 0 })
	local _, n2 = renderAt(m, true, { x = 40.3, y = 0.2, z = 0.1 })
	eq(built, 1, "same snapped key")
	eq(findChild(n1, "LayerConfigNode").config, findChild(n2, "LayerConfigNode").config)
	renderAt(m, true, { x = 42, y = 0, z = 0 })
	eq(built, 2)
end)

test("builtin.ActionDescriptor and the tooltip function are put back after each render", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local baseAD = m.builtin.ActionDescriptor
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	renderAt(m, true, { x = 40, y = 0, z = 0 })
	eq(m.builtin.ActionDescriptor, baseAD)
	eq(m.sru.makeDefaultSelectorTooltips, m.baseTooltips)
	-- also when the render throws while a line is shown
	held, pos = true, { x = 80, y = 0, z = 0 }
	local ok = pcall(function() m.sru.makeDefaultSelectorCombinedFn({ throw = true })() end)
	eq(ok, false)
	eq(m.builtin.ActionDescriptor, baseAD)
	eq(m.sru.makeDefaultSelectorTooltips, m.baseTooltips)
end)

test("arrow: layer config API throwing keeps the altitude text, logs once", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	api.type.LayerConfig.new = function() error("restricted") end
	local before = #logs
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local out, node = renderAt(m, true, { x = 40, y = 0, z = 1.2 })
	eq(out.children[1].text, "標高: 1.2 m\n高度差: +1.2 m\n距離: 40 m\n勾配: +3%")
	eq(findChild(node, "LayerConfigNode"), nil)
	renderAt(m, true, { x = 60, y = 0, z = 1 })
	local n = 0
	for i = before + 1, #logs do if logs[i]:find("arrow layer config failed", 1, true) then n = n + 1 end end
	eq(n, 1)
end)

test("arrow: colour table unreadable, still one arrow", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	api.res = nil
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local _, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
	local f = findChild(node, "LayerConfigNode").config.cargoFlowRenderableConfig.flowData[1]
	eq(#f.cargoTypes, 0)
	eq(f.arrowColors[1][1], map.ARROW_FALLBACK_COLOR[1])
end)

-- 1.1.0 exited the game with render_util.cpp AddEveryNthPoint
-- "(num)>=(2) Actual: 1 < 2" in the first metres of a measurement: the engine
-- samples a flow every 8 m and its cargo icon pass asserts on one point
test("arrow: none shorter than ARROW_MIN_LENGTH, the tooltip still measures", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local built = 0
	local orig = api.type.LayerConfig.new
	api.type.LayerConfig.new = function() built = built + 1; return orig() end
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	for _, x in ipairs({ 1.2, 2, 5, 8, 9, 12, 15, 16, 20, 23 }) do
		local out, node = renderAt(m, true, { x = x, y = 0, z = 0 })
		eq(findChild(node, "LayerConfigNode"), nil, "no arrow at " .. x .. " m")
		assert(out.children[1].text:find("\n", 1, true), "distance shown at " .. x .. " m")
	end
	eq(built, 0, "no layer config built for a short line")
	local _, node = renderAt(m, true, { x = 24, y = 0, z = 0 })
	assert(findChild(node, "LayerConfigNode"), "arrow from 24 m")
	-- short horizontally, long in 3D (a cliff): the engine measures in 3D
	_, node = renderAt(m, true, { x = 0, y = 7, z = 30 })
	assert(findChild(node, "LayerConfigNode"), "7 m across, 30 m up")
	-- back to short: the arrow goes again
	_, node = renderAt(m, true, { x = 10, y = 0, z = 0 })
	eq(findChild(node, "LayerConfigNode"), nil, "back under the minimum")
	eq(m.builtin.ActionDescriptor ~= nil, true)
end)

test("arrow: makeArrowConfig refuses short, junk and NaN keys", function()
	resetApi()
	local map = freshMap()
	eq(map.makeArrowConfig({ 0, 0, 0, 15.9, 0, 0 }), nil)
	eq(map.makeArrowConfig({ 0, 0, 0, 23.9, 0, 0 }), nil)
	eq(map.makeArrowConfig(nil), nil)
	eq(map.makeArrowConfig({ 0, 0, 0, 0 / 0, 0, 0 }), nil)
	local cfg = assert(map.makeArrowConfig({ 0, 0, 0, 24, 0, 0 }))
	eq(#cfg.cargoFlowRenderableConfig.flowData[1].cargoTypes, 0)
	assert(map.makeArrowConfig({ 0, 0, 0, 0, 0, 24 }), "vertical 24 m")
end)

-- 1.1.0's first crash came right after leaving construction mode: the key is
-- also the game's Surface Snapping key, so it can still be down when the
-- plain map view comes back
test("key down when a tool on top closes: no stale arrow, short lines none", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local t = 100
	api.util.getApplicationTime = function() return t end
	local baseAD = m.builtin.ActionDescriptor
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local _, node = renderAt(m, true, { x = 200, y = 0, z = 0 })
	assert(findChild(node, "LayerConfigNode"), "arrow before the tool")
	-- the tool (construction) is on top: the view does not render for a while
	t = t + 30
	local out
	out, node = renderAt(m, true, { x = 203, y = 0, z = 0 })
	eq(findChild(node, "LayerConfigNode"), nil, "new press point, no old arrow")
	eq(out.children[1].text, "標高: 0.0 m", "measures from the new point")
	t = t + 0.1
	_, node = renderAt(m, true, { x = 210, y = 0, z = 0 })
	eq(findChild(node, "LayerConfigNode"), nil, "7 m from the new point: no arrow")
	eq(m.builtin.ActionDescriptor, baseAD, "descriptor put back")
	-- key up: nothing, however often the view renders
	for i = 1, 3 do
		t = t + 0.1
		_, node = renderAt(m, false, { x = 300, y = 0, z = 0 })
		eq(findChild(node, "LayerConfigNode"), nil, "no arrow without the key " .. i)
	end
	eq(m.builtin.ActionDescriptor, baseAD)
end)

test("line state hook failing: altitude still shows, one log line", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	m.react.onEvent = function() error("no ctx") end
	local before = #logs
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local out, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
	eq(out.children[1].text:sub(1, 13), "標高: 0.0 m")
	eq(findChild(node, "LayerConfigNode"), nil)
	local n = 0
	for i = before + 1, #logs do if logs[i]:find("line state failed", 1, true) then n = n + 1 end end
	eq(n, 1)
end)

test("LINE_MODE off: no line, text unchanged", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.LINE_MODE = "off"
	map.install(m.ug)
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local out, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
	eq(findChild(node, "LayerConfigNode"), nil)
	eq(out.children[1].text, "標高: 0.0 m\n高度差: 0.0 m\n距離: 40 m\n勾配: 0%")
	eq(#zoneCalls, 0)
end)

test("LINE_MODE zone: band drawn, moved, removed on release, cleared after a load", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.LINE_MODE = "zone"
	map.install(m.ug)
	renderAt(m, false, { x = 0, y = 0, z = 0 })
	eq(zoneCalls[1][1], "remove", "first render after a load clears a saved band")
	eq(zoneCalls[1][2], map.ZONE_KEY)
	local n = #zoneCalls
	renderAt(m, false, { x = 0, y = 0, z = 0 })
	eq(#zoneCalls, n, "nothing drawn, nothing to remove again")
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local _, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
	eq(findChild(node, "LayerConfigNode"), nil, "no arrow in zone mode")
	local c = zoneCalls[#zoneCalls]
	eq(c[1], "set"); eq(c[2], map.ZONE_KEY); eq(c[4], true); eq(c[5], false, "no building ban"); eq(c[6], false)
	eq(#c[3], 4)
	-- a rectangle ZONE_WIDTH wide around the segment
	eq(c[3][1].x, 0); eq(c[3][1].y, map.ZONE_WIDTH / 2)
	eq(c[3][3].x, 40); eq(c[3][3].y, -map.ZONE_WIDTH / 2)
	n = #zoneCalls
	renderAt(m, true, { x = 40.2, y = 0, z = 0 })
	eq(#zoneCalls, n, "same snapped key: not drawn again")
	renderAt(m, false, { x = 40, y = 0, z = 0 })
	eq(zoneCalls[#zoneCalls][1], "remove", "release removes it")
	-- the view going away while the key is down
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	renderAt(m, true, { x = 0, y = 30, z = 0 })
	eq(zoneCalls[#zoneCalls][1], "set")
	for _, fn in ipairs(m.react.unmounts) do fn() end
	eq(zoneCalls[#zoneCalls][1], "remove", "unmount removes it")
end)

test("LINE_MODE zone: setZone throwing keeps the tooltip, logs once", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.LINE_MODE = "zone"
	map.install(m.ug)
	api.gui.mission.setZone = function() error("restricted") end
	local before = #logs
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	eq(renderAt(m, true, { x = 40, y = 0, z = 0 }).children[1].kind, "TextView")
	renderAt(m, true, { x = 80, y = 0, z = 0 })
	local n = 0
	for i = before + 1, #logs do if logs[i]:find("setZone failed", 1, true) then n = n + 1 end end
	eq(n, 1)
end)

test("test event: holds the key at given points without a key or mouse", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	held, hasPos = false, false
	renderTooltip(m)
	local ev = assert(m.react.events[map.TEST_EVENT], "event registered on the map view")
	ev(map.TEST_EVENT, { hold = true, cursor = { x = 0, y = 0, z = 10 } })
	eq(renderTooltip(m).children[1].text, "標高: 10.0 m")
	ev(map.TEST_EVENT, { hold = true, cursor = { 30, 40, 15 } })
	local out, _, node = renderTooltip(m)
	eq(out.children[1].text, "標高: 15.0 m\n高度差: +5.0 m\n距離: 50 m\n勾配: +10%")
	assert(findChild(node, "LayerConfigNode"), "arrow")
	local before = #logs
	ev(map.TEST_EVENT, { report = true })
	eq(#logs, before + 1)
	assert(logs[#logs]:find("held=true origin=0.0,0.0,10.0 line=0,0,10,30,40,15 arrow=true", 1, true), logs[#logs])
	assert(logs[#logs]:find("勾配: +10%", 1, true), "text in the report")
	ev(map.TEST_EVENT, { hold = false })
	eq(map.testInput, nil)
	out, _, node = renderTooltip(m)
	eq(out.children[1].kind, "Default", "real key (not held) again")
	eq(findChild(node, "LayerConfigNode"), nil)
	-- junk params clear the test input rather than throw
	ev(map.TEST_EVENT, { hold = true })
	ev(map.TEST_EVENT, "junk")
	eq(map.testInput, nil)
end)

test("test event: hold without cursor uses the real mouse", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	renderTooltip(m)
	m.react.events[map.TEST_EVENT](map.TEST_EVENT, { hold = true })
	pos = { x = 1, y = 1, z = 33 }
	eq(renderTooltip(m).children[1].text, "標高: 33.0 m")
end)

test("swapped ActionDescriptor passes a (ref, params) call through untouched", function()
	resetApi()
	local map, m = freshMap(), newMods()
	local seen
	local base = m.sru.makeDefaultSelectorCombinedFn
	-- an inner wrap that builds a descriptor the other way first
	m.sru.makeDefaultSelectorCombinedFn = function(p)
		local inner = base(p)
		return function()
			seen = { m.builtin.ActionDescriptor("REF", { children = { "x" } }) }
			return inner()
		end
	end
	local realAD = m.builtin.ActionDescriptor
	local calls = {}
	m.builtin.ActionDescriptor = function(a, b)
		calls[#calls + 1] = { a, b }
		if b ~= nil then return { kind = "AD2", ref = a, params = b } end
		return realAD(a)
	end
	map.install(m.ug)
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	local _, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
	eq(seen[1].kind, "AD2")
	eq(seen[1].ref, "REF")
	eq(#seen[1].params.children, 1, "no layer added to the two-argument call")
	assert(findChild(node, "LayerConfigNode"), "the view's own descriptor got it")
end)

-- a Station Coverage Filter style wrap: swaps ActionDescriptor itself to add
-- its own LayerConfig (scf_map.lua withFill)
local function scfWrap(m)
	local base = m.sru.makeDefaultSelectorCombinedFn
	m.sru.makeDefaultSelectorCombinedFn = function(p)
		local inner = base(p)
		return function()
			local b = m.builtin.ActionDescriptor
			m.builtin.ActionDescriptor = function(q, ...)
				if select("#", ...) == 0 and type(q) == "table" then
					local c = {}
					for k, v in pairs(q) do c[k] = v end
					local ch = {}
					for i, x in ipairs(q.children or {}) do ch[i] = x end
					ch[#ch + 1] = { kind = "LayerConfigNode", config = "SCF" }
					c.children = ch
					return b(c)
				end
				return b(q, ...)
			end
			local ok, n = pcall(inner)
			m.builtin.ActionDescriptor = b
			if not ok then error(n, 0) end
			return n
		end
	end
end

local function layerConfigs(node)
	local out = {}
	for _, c in ipairs(node.children) do
		if c.kind == "LayerConfigNode" then out[#out + 1] = c.config == "SCF" and "SCF" or "CAT" end
	end
	table.sort(out)
	return table.concat(out, ",")
end

test("chains with a wrap that adds its own LayerConfig, either order", function()
	for _, scfFirst in ipairs({ true, false }) do
		resetApi()
		local map, m = freshMap(), newMods()
		local realAD = m.builtin.ActionDescriptor
		if scfFirst then scfWrap(m); map.install(m.ug) else map.install(m.ug); scfWrap(m) end
		renderAt(m, true, { x = 0, y = 0, z = 0 })
		local _, node = renderAt(m, true, { x = 40, y = 0, z = 0 })
		eq(layerConfigs(node), "CAT,SCF", "both kept (scfFirst " .. tostring(scfFirst) .. ")")
		eq(m.builtin.ActionDescriptor, realAD, "put back")
		_, node = renderAt(m, false, { x = 40, y = 0, z = 0 })
		eq(layerConfigs(node), "SCF", "only theirs after release")
	end
end)

test("cat_map: a gap in the steps (view not stepping) drops the origin", function()
	resetApi()
	local map, m = freshMap(), newMods()
	map.install(m.ug)
	local now = 100
	api.util.getApplicationTime = function() return now end
	renderAt(m, true, { x = 0, y = 0, z = 0 })
	now = 101
	eq(renderAt(m, true, { x = 40, y = 0, z = 0 }).children[1].text:find("距離", 1, true) ~= nil, true)
	now = 101 + core.STALE_SECONDS + 1
	eq(renderAt(m, true, { x = 40, y = 0, z = 0 }).children[1].text, "標高: 0.0 m", "new origin here")
end)

test("next game load drops a held origin", function()
	resetApi()
	local map = freshMap()
	local m1, m2 = newMods(), newMods()
	map.install(m1.ug)
	renderAt(m1, true, { x = 0, y = 0, z = 0 })
	map.install(m2.ug)
	eq(map.tracker.origin, nil)
	eq(renderAt(m2, true, { x = 40, y = 0, z = 0 }).children[1].text, "標高: 0.0 m")
end)

-- a small JSON decoder (objects, arrays, strings with escapes, numbers,
-- true/false/null): enough for strings.json and _metadata/modinfo.json,
-- whose keys contain spaces and escaped quotes
local function decodeJson(src)
	local pos = 1
	local function ws() pos = src:find("[^ \t\r\n]", pos) or #src + 1 end
	local value
	local function str()
		local out, i = {}, pos + 1
		while true do
			local c = src:sub(i, i)
			assert(c ~= "", "unterminated string")
			if c == '"' then pos = i + 1; return table.concat(out) end
			assert(c:byte() >= 0x20, "control character in string")
		if c == "\\" then
				local e = src:sub(i + 1, i + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				if e == "u" then
					local cp = tonumber(src:sub(i + 2, i + 5), 16)
					assert(cp and cp < 0x80, "only ASCII \\u escapes are expected")
					out[#out + 1] = string.char(cp); i = i + 6
				else
					out[#out + 1] = assert(map[e], "bad escape"); i = i + 2
				end
			else
				out[#out + 1] = c; i = i + 1
			end
		end
	end
	function value()
		ws()
		local c = src:sub(pos, pos)
		if c == "{" then
			local t = {}
			pos = pos + 1; ws()
			if src:sub(pos, pos) == "}" then pos = pos + 1; return t end
			while true do
				ws(); assert(src:sub(pos, pos) == '"', "key expected at " .. pos)
				local k = str(); ws()
				assert(src:sub(pos, pos) == ":", ": expected at " .. pos); pos = pos + 1
				assert(t[k] == nil, "duplicate key " .. k)
				t[k] = value(); ws()
				local d = src:sub(pos, pos); pos = pos + 1
				if d == "}" then return t end
				assert(d == ",", ", or } expected at " .. pos)
			end
		elseif c == "[" then
			local t = {}
			pos = pos + 1; ws()
			if src:sub(pos, pos) == "]" then pos = pos + 1; return t end
			while true do
				t[#t + 1] = value(); ws()
				local d = src:sub(pos, pos); pos = pos + 1
				if d == "]" then return t end
				assert(d == ",", ", or ] expected at " .. pos)
			end
		elseif c == '"' then
			return str()
		end
		for lit, v in pairs({ ["true"] = true, ["false"] = false, ["null"] = false }) do
			if src:sub(pos, pos + #lit - 1) == lit then pos = pos + #lit; return v end
		end
		local num = src:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		local n = num and tonumber(num)
		assert(n, "bad value at " .. pos)
		pos = pos + #num
		return n
	end
	local v = value(); ws()
	assert(pos > #src, "trailing data at " .. pos)
	return v
end

local function readJson(rel)
	local f = assert(io.open(root .. "/" .. rel))
	local src = f:read("*a")
	f:close()
	return decodeJson(src)
end

local GAME_LANGS = { "en", "ja", "de", "es", "fr", "it", "ko", "nl", "pl", "pt_BR", "ru", "zh_CN", "zh_TW" }

test("decodeJson: escapes, nesting, rejects broken input", function()
	local v = decodeJson('{"a \\"b\\"": ["x", 1, true], "c": {"d": "\\u0041\\n"}}')
	eq(v['a "b"'][1], "x"); eq(v['a "b"'][2], 1); eq(v['a "b"'][3], true)
	eq(v.c.d, "A\n")
	eq((pcall(decodeJson, '{"a": "b"')), false)
	eq((pcall(decodeJson, '{"a": "b",}')), false)
	eq((pcall(decodeJson, '{"a": 1, "a": 2}')), false)
	eq((pcall(decodeJson, '[1-]')), false)
	eq((pcall(decodeJson, '["a\\nb"]')), true) -- an escaped newline is fine
	eq((pcall(decodeJson, '["a' .. "\n" .. 'b"]')), false) -- a raw one is not
end)

-- The game lists a local mod by _metadata/modinfo.json (as its own mods in
-- mods/release/*/_metadata do); without it the list shows the folder name
-- in snake_case. The game doesn't translate these texts through the mod's
-- strings.json (checked in game, 2026-11-12) and mod.io keeps one name and
-- one description, so the description carries every language in turn.
-- The name is English only: published mod names carry no Japanese
-- (decided 2026-11-22), the summary and description keep it.
test("_metadata/modinfo.json: readable name, summary, author, tag", function()
	local info = readJson("_metadata/modinfo.json")
	-- the same keys as the game's own modinfo files, no more, no less
	local keys = {}
	for k in pairs(info) do keys[#keys + 1] = k end
	table.sort(keys)
	eq(table.concat(keys, ","), "authors,description,name,summary,tags,url")
	eq(info.name, "Cursor Altitude, Distance & Incline Tooltip")
	assert(not info.name:find("[\128-\255]"), "name is English (ASCII) only")
	-- mod.io limits: name 50 characters, summary 250 (counted in characters)
	-- characters, not bytes: count the bytes that start a UTF-8 sequence
	local function chars(str) return select(2, str:gsub("[^\128-\191]", "")) end
	eq(chars("標高 m"), 4, "UTF-8 character count")
	assert(chars(info.name) <= 50, "name too long for mod.io")
	assert(chars(info.summary) <= 250, "summary too long for mod.io")
	-- and 250 in bytes too: whether mod.io counts characters or UTF-8 bytes
	-- is untested, and the Japanese half takes 3 bytes a character
	assert(#info.summary <= 250, "summary over 250 bytes: " .. #info.summary)
	assert(chars(info.description) <= 50000, "description too long for mod.io")
	eq(info.authors[1].name, "hummer")
	eq(info.authors[1].role, "CREATOR")
	-- a tag the game knows (its mod-tags list), so filters and translation work
	eq(info.tags[1], "Script Mod")
end)

-- every game language has a section in the description, and each names the
-- key to hold as that language's key bindings name it (base.mo "Surface
-- Snapping"), or players can't find it
test("modinfo description: every language, each naming the official key", function()
	local info = readJson("_metadata/modinfo.json")
	local official = {
		en = { "English", "Surface Snapping" }, ja = { "日本語", "地表スナップ" },
		de = { "Deutsch", "Oberflächen-Snapping" }, es = { "Español", "Ajuste a la superficie" },
		fr = { "Français", "Accrochage aux surfaces" }, it = { "Italiano", "Agganciamento alla superficie" },
		ko = { "한국어", "표면 스내핑" }, nl = { "Nederlands", "Vastklikken op oppervlak" },
		pl = { "Polski", "Przyciąganie do powierzchni" }, pt_BR = { "Português (Brasil)", "Fixação na Superfície" },
		ru = { "Русский", "Привязка к поверхности" }, zh_CN = { "简体中文", "表面吸附" },
		zh_TW = { "繁體中文", "貼齊表面" },
	}
	-- sections are paragraphs starting with "[<language>] "; read them in
	-- order from line starts only, so a "[" inside a text can't fake one
	local found = {}
	-- split on blank lines (plain find: Lua 5.1 patterns can't hold "\0")
	local paras, from = {}, 1
	while true do
		local at = info.description:find("\n\n", from, true)
		paras[#paras + 1] = info.description:sub(from, (at or 0) - 1)
		if not at then break end
		from = at + 2
	end
	for _, para in ipairs(paras) do
		local head = para:match("^%[([^%]\n]+)%] ")
		assert(head, "paragraph without a language heading: " .. para:sub(1, 30))
		found[#found + 1] = { head = head, text = para }
	end
	eq(#found, #GAME_LANGS, "one section per game language")
	for i, lang in ipairs(GAME_LANGS) do
		local head, key = official[lang][1], official[lang][2]
		eq(found[i].head, head, "section " .. i .. " (English first, then the game's order)")
		assert(found[i].text:find(key, 1, true), lang .. " doesn't name " .. key)
	end
	-- LICENSE can't ship in the mod (validation rejects extensionless files),
	-- so the description states the licence and where the code is
	assert(found[1].text:find("License: MIT", 1, true) and found[1].text:find("github.com/hummer98/tpf3-cursor-altitude-tooltip", 1, true), "licence and source link")
	-- the English and Japanese sections open with the mod's name in that
	-- language (the game shows one name, English; Japanese players find it
	-- here and in the summary)
	eq(found[1].text:match("^%[[^%]]+%] ([^\n]+)"), info.name, "English heading")
	eq(found[2].text:match("^%[[^%]]+%] ([^\n]+)"), "カーソル位置の標高・距離・勾配の表示", "Japanese heading")
	-- the summary is short, so it names the default key (Alt) in both halves
	local en, ja = info.summary:match("^(.-) / (.+)$")
	assert(en and ja, "summary is \"<English> / <Japanese>\"")
	assert(en:find("Alt", 1, true) and ja:find("Alt", 1, true), "summary names the key")
	assert(ja:find("[\128-\255]"), "summary's second half is Japanese")
end)

-- strings.json: only the tooltip labels, in every game language
-- (base/strings/<lang>); the game reads no other key from it
local LABEL_KEYS = { "cat_altitude", "cat_height_difference", "cat_distance", "cat_incline" }
test("strings.json: the labels in every game language, nothing else", function()
	local langs = readJson("strings.json")
	local known, wanted = {}, {}
	for _, k in ipairs(LABEL_KEYS) do wanted[k] = true end
	for _, lang in ipairs(GAME_LANGS) do
		known[lang] = true
		local t = assert(langs[lang], "missing language " .. lang)
		for _, k in ipairs(LABEL_KEYS) do
			assert(type(t[k]) == "string" and t[k] ~= "", lang .. " lacks " .. k)
		end
		for k in pairs(t) do assert(wanted[k], lang .. " unused key " .. k) end
	end
	for lang in pairs(langs) do assert(known[lang], "unknown language " .. lang) end
end)

-- every label key the code asks _() for is in strings.json (a typo would
-- show the English fallback in every language)
test("cat_map asks only for keys strings.json has", function()
	local f = assert(io.open(root .. "/content/gui/cat_map.lua"))
	local src = f:read("*a")
	f:close()
	local en = readJson("strings.json").en
	local n = 0
	for k in src:gmatch('core%.label%(_, "([%w_]+)"') do
		n = n + 1
		assert(en[k], "missing key " .. k)
	end
	eq(n, #LABEL_KEYS, "label lookups")
end)

-- the game resolves "<modId>::/..." paths by mod.json's modId and loads the
-- mod from the folder "<modId>_<major>", so a rename must change all three
test("modId, folder name and every require prefix agree", function()
	local f = assert(io.open(root .. "/mod.json"))
	local modId = f:read("*a"):match('"modId"%s*:%s*"([^"]+)"')
	f:close()
	eq(modId, "hummer_cursor_altitude_tooltip")
	local folder = (root == "." and io.popen("pwd"):read("*l") or root):match("([^/]+)/?$")
	if folder:match("_%d+$") then eq(folder:gsub("_%d+$", ""), modId, "folder name") end
	for _, name in ipairs({ "cat_map.lua", "cat_install.res.lua", "cat_install.script.lua" }) do
		local h = assert(io.open(root .. "/content/gui/" .. name))
		local src = h:read("*a")
		h:close()
		for prefix in src:gmatch('"([%w_]+)::/') do eq(prefix, modId, name) end
	end
end)

-- the README is the GitHub landing page; both languages must point at the
-- published mod.io page, not the pre-release placeholder
test("README links the mod.io page in both languages", function()
	local f = assert(io.open(root .. "/README.md"))
	local src = f:read("*a")
	f:close()
	local url = "https://mod.io/g/transportfever3/m/cursor-altitude-tooltip"
	-- each language section needs its own link; extra links (badges) are fine
	local split = assert(src:find("\n## 日本語", 1, true), "Japanese section")
	assert(src:sub(1, split):find(url, 1, true), "English section link")
	assert(src:sub(split):find(url, 1, true), "Japanese section link")
	assert(not src:find("link to be added", 1, true), "English placeholder left")
	assert(not src:find("公開後に追記", 1, true), "Japanese placeholder left")
end)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
