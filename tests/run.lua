-- Offline tests for Cursor Altitude Tooltip. Run from anywhere:
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
-- cat_map with stubbed GUI modules
------------------------------------------------------------------------
local logs = {}
debugPrint = function(s) logs[#logs + 1] = s end
_ = function(k) if k == "cat_altitude" then return "標高" end return k end

local held, hasPos, pos = false, true, { x = 0, y = 0, z = 50 }
local heldIA
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
	}
end
resetApi()

-- builtin/react stubs: nodes are plain tables, a recipe is the registered
-- function (render it by calling it), useStepState evaluates getter now
local function newMods()
	local registered = {}
	local react = {
		registered = registered,
		RegisterRecipe = function(name, fn)
			registered[#registered + 1] = name
			return fn
		end,
		setMouseTransparent = function() end,
	}
	local builtin = {
		ActionTooltip = function(p) return { kind = "ActionTooltip", recipe = p.recipe, param = p.param } end,
		TextView = function(p) return { kind = "TextView", text = p.text, class = p.meta and p.meta.class } end,
		BoxLayout = function(p) return { kind = "BoxLayout", children = p.children } end,
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
			return { kind = "ActionDescriptor", tooltip = sru.makeDefaultSelectorTooltips("REF") }
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
	return { ug = ug, sru = sru, react = react, baseTooltips = baseTooltips }
end

local function freshMap()
	package.loaded["hummer_cursor_altitude_tooltip::/gui/cat_map.lua"] = nil
	return require "hummer_cursor_altitude_tooltip::/gui/cat_map.lua"
end

-- render the plain map view and then its tooltip recipe
local function renderTooltip(m, params)
	local node = m.sru.makeDefaultSelectorCombinedFn(params or {})()
	local tip = node.tooltip
	eq(tip.kind, "ActionTooltip", "plain map view tooltip")
	return tip.recipe(tip.param), tip
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

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
