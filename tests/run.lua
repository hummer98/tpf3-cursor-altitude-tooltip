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
-- one description, so like other multilingual mods the name is
-- "English / 日本語" and the description carries every language in turn.
test("_metadata/modinfo.json: readable name, summary, author, tag", function()
	local info = readJson("_metadata/modinfo.json")
	-- the same keys as the game's own modinfo files, no more, no less
	local keys = {}
	for k in pairs(info) do keys[#keys + 1] = k end
	table.sort(keys)
	eq(table.concat(keys, ","), "authors,description,name,summary,tags,url")
	eq(info.name, "Cursor Altitude Tooltip / カーソル位置の標高表示")
	-- mod.io limits: name 50 characters, summary 250 (counted in characters)
	-- characters, not bytes: count the bytes that start a UTF-8 sequence
	local function chars(str) return select(2, str:gsub("[^\128-\191]", "")) end
	eq(chars("標高 m"), 4, "UTF-8 character count")
	assert(chars(info.name) <= 50, "name too long for mod.io")
	assert(chars(info.summary) <= 250, "summary too long for mod.io")
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
	assert(info.summary:find("Surface Snapping", 1, true) and info.summary:find("地表スナップ", 1, true), "summary names the key")
end)

-- strings.json: only the tooltip label, in every game language
-- (base/strings/<lang>); the game reads no other key from it
test("strings.json: the label in every game language, nothing else", function()
	local langs = readJson("strings.json")
	local known = {}
	for _, lang in ipairs(GAME_LANGS) do
		known[lang] = true
		local t = assert(langs[lang], "missing language " .. lang)
		assert(type(t.cat_altitude) == "string" and t.cat_altitude ~= "", lang .. " lacks cat_altitude")
		for k in pairs(t) do eq(k, "cat_altitude", lang .. " unused key") end
	end
	for lang in pairs(langs) do assert(known[lang], "unknown language " .. lang) end
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
	local n = 0
	for line in src:gmatch("[^\n]+") do
		if line:find("mod.io", 1, true) and line:find(url, 1, true) then n = n + 1 end
	end
	eq(n, 2, "mod.io lines with the link")
	assert(not src:find("link to be added", 1, true), "English placeholder left")
	assert(not src:find("公開後に追記", 1, true), "Japanese placeholder left")
end)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
