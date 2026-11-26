-- Cursor Altitude, Distance & Incline Tooltip: swaps the plain map view's
-- cursor tooltip.
--
-- Why this way: the plain map view (no tool, layer or entity window) is the
-- action selector_react_util.makeDefaultSelectorCombinedFn builds; on every
-- render it adds its cursor tooltip by calling
-- selector_react_util.makeDefaultSelectorTooltips through the module table.
-- Layers, entity windows (station group, ...) call that same function, so
-- replacing it for good would put the altitude there too. Instead the
-- combined function is wrapped and the tooltip function is swapped only
-- while the plain map view renders (Station Coverage Filter wraps the same
-- combined function; both wraps chain whichever installs first).
--
-- The combined function is also the fallback action of entity windows that
-- bring none of their own (e.g. only pinned windows open), so the altitude
-- shows there too; layers, tools and windows with their own action (station,
-- vehicle, line, industry, town, ...) are not affected.
--
-- The replacement tooltip is the base TerrainTooltip "Height" idea (layer
-- terrain prints api.gui.mouse.getTerrainPosition().z), shown only while the
-- modifier is held, and falls back to the base entity tooltip otherwise.
--
-- While the key stays down the tooltip also measures from where it went
-- down (height difference, distance, incline) and a line joins the two
-- points. The line is a base cargo flow arrow: a LayerConfig child of the
-- plain map view's ActionDescriptor, as the industry and town windows add
-- theirs (industry.tl setActionFn, selector_react_util.tl
-- makeDefaultSelectorAction). The plain map view is the entity tool's action
-- on the tool stack (view_manager.tl setDefaultSelectorAction), and the
-- engine takes the layer config of the top entry only (builtin.lua
-- ToolStackEntryWrap), so the arrow goes with the view: a tool or a layer on
-- top hides it, and nothing of it is in the save. The ground band
-- (api.gui.mission.setZone) is the fallback, one line away (LINE_MODE).
local core = require "hummer_cursor_altitude_tooltip::/gui/cat_core.lua"

local map = {}

map.TEXT_CLASS = "font-scale-tooltip, default-tooltip-configuration"

-- How the line is drawn: "arrow" (cargo flow arrow, gone with the view),
-- "zone" (a band on the ground; it is drawn into the game's mission zones,
-- so it is removed on release, on unmount and at the first render after a
-- load, or a save made meanwhile would keep it) or "off".
map.LINE_MODE = "arrow"
-- end points move in steps of this many metres: each step rebuilds the map
-- view's action, so a finer grid costs more frames for no visible gain
map.LINE_GRID = 1.0
-- arrows at terrain height sink into slopes; the base examples lift theirs
-- to building tops, a few metres is enough for bare ground
map.ARROW_LIFT = 3.0
-- 40 is the base speed of a flow that carries cargo
map.ARROW_SPEED = 40.0
-- no cargo icon on our arrow (the field wants a cargo type; see makeArrowConfig)
map.ARROW_ICON_ALPHA = 0.0
-- used only when the base colour table can't be read
map.ARROW_FALLBACK_COLOR = { 0.54, 0.72, 0.95, 1.0 }
map.ZONE_KEY = "hummer_cat_measure_line"
map.ZONE_WIDTH = 4.0
map.ZONE_COLOR = { 0.54, 0.72, 0.95, 0.8 }
-- the test event (tf3ctl event): it can't hold a key or move the mouse
map.TEST_EVENT = "hummer_cat.test"

-- failures only, one line each the first time (a working tooltip logs
-- nothing; a failed install is logged by cat_install.script.lua)
local reported = {}
local function reportOnce(key, msg)
	if reported[key] then return end
	reported[key] = true
	pcall(debugPrint, "[CAT] " .. msg)
end

-- Looked up under pcall: touching api.* in a restricted context may throw,
-- and the tooltip then simply stays the usual one.
-- set by the test event only: { held = bool, pos = {x, y, z} | nil }
map.testInput = nil

local function isHeld()
	if map.testInput then return map.testInput.held == true end
	local ok, v = pcall(function()
		return api.gui.inputAction.modifierOnlyActionIsActive(core.INPUT_ACTION)
	end)
	if not ok then
		reportOnce("heldErr", "modifierOnlyActionIsActive failed: " .. tostring(v))
		return false
	end
	return v == true
end

local function terrainPos()
	local t = map.testInput
	if t and t.pos then return true, t.pos end
	local ok, has, pos = pcall(function()
		local mouse = api.gui.mouse
		if not mouse.hasTerrainPosition() then return false, nil end
		return true, mouse.getTerrainPosition()
	end)
	if not ok then
		reportOnce("posErr", "terrain position failed: " .. tostring(has))
		return false, nil
	end
	return has, pos
end

local function altitudeFormatter()
	local ok, fn = pcall(function() return api.util.formatAltitude end)
	if ok and type(fn) == "function" then return fn end
	return nil
end

-- true when the player chose imperial units (feet), for the fallback text
-- (the same setting the base terrain layer reads, layer_terrain.tl:68)
local function isImperial()
	local ok, v = pcall(function()
		return api.util.getAppConfig().distanceSpeedUnit == api.type["enum"].DistanceSpeedUnit.Imperial
	end)
	return ok and v == true
end

local function utilFn(name)
	local ok, fn = pcall(function() return api.util[name] end)
	if ok and type(fn) == "function" then return fn end
	return nil
end

-- one tracker for the module: the tooltip recipe and the map view's action
-- both sample it each step, and it ignores the second sample (cat_core)
map.tracker = core.newTracker()

-- wall-clock seconds (os.clock is CPU time on Linux), nil when unreadable
local function appTime()
	local ok, v = pcall(function() return api.util.getApplicationTime() end)
	if ok and type(v) == "number" then return v end
	return nil
end

-- key, terrain position and origin for this step
function map.sample()
	local held = isHeld()
	local now = appTime()
	if not held then
		map.tracker.update(false, false, nil, now)
		return false, false, nil, nil
	end
	local has, pos = terrainPos()
	return true, has, pos, map.tracker.update(true, has, pos, now)
end

-- the text for this step, or nil (usual tooltip)
function map.stepText()
	local held, has, pos, origin = map.sample()
	if not held then return nil end
	-- the unit is read every time: the fallback is also taken when the game's
	-- formatter exists but throws or returns junk
	local imperial = isImperial()
	local extra = has and core.measureLines(origin, pos, {
		diff = core.label(_, "cat_height_difference", "Height difference"),
		distance = core.label(_, "cat_distance", "Distance"),
		incline = core.label(_, "cat_incline", "Incline"),
	}, {
		altitude = altitudeFormatter(),
		length = utilFn("formatLength"),
		percent = utilFn("toStringPercentPrecision"),
	}, imperial, core.SHOW_INCLINE) or nil
	return core.tooltipText(held, has, pos,
		core.label(_, "cat_altitude", "Altitude"), altitudeFormatter(), imperial, extra)
end

-- the line's snapped end points for this step, or nil (no line)
function map.stepLine()
	if map.LINE_MODE ~= "arrow" and map.LINE_MODE ~= "zone" then return nil end
	local held, has, pos, origin = map.sample()
	if not held or not has then return nil end
	return core.lineKey(origin, pos, map.LINE_GRID)
end

------------------------------------------------------------------------
-- the line: arrow
------------------------------------------------------------------------

local function vec4(c)
	return api.type.Vec4f.new(c[1], c[2], c[3], c[4] or 1.0)
end

local function arrowColors()
	local ok, colors = pcall(function()
		local rep = api.gui.genericRep
		local lc = rep.get(rep.find("::/gui/layers/layer_colors.gres")).data
		local out = {}
		for __, c in ipairs(lc.CargoFlow.Consumers3D.Actual) do out[#out + 1] = vec4(c) end
		return out
	end)
	if ok and type(colors) == "table" and #colors > 0 then return colors end
	return { vec4(map.ARROW_FALLBACK_COLOR) }
end

-- The LayerConfig for one line key. Built only when the key changes (the
-- action renders for other reasons too) and kept for the next render.
local lastArrow = { key = nil, config = nil }

local function sameKey(a, b)
	if a == nil or b == nil then return a == b end
	for i = 1, 6 do if a[i] ~= b[i] then return false end end
	return true
end

function map.makeArrowConfig(key)
	if sameKey(key, lastArrow.key) then return lastArrow.config end
	local ok, cfg = pcall(function()
		local T = api.type
		local flow = T.LayerConfig.CargoFlowRenderableConfig.FlowData.new()
		flow.from = T.Vec3f.new(key[1], key[2], key[3] + map.ARROW_LIFT)
		flow.to = T.Vec3f.new(key[4], key[5], key[6] + map.ARROW_LIFT)
		flow.speed = map.ARROW_SPEED
		flow.arrowColors = arrowColors()
		flow.cargoIconAlpha = map.ARROW_ICON_ALPHA
		-- every base flow names a cargo; an empty list is untried, so the
		-- passenger type (always there) with its icon made invisible
		local okP, pax = pcall(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end)
		flow.cargoTypes = (okP and type(pax) == "number") and { pax } or {}
		local flows = T.LayerConfig.CargoFlowRenderableConfig.new()
		flows.flowData = { flow }
		local layer = T.LayerConfig.new()
		layer.cargoFlowRenderableConfig = flows
		return layer
	end)
	if not ok then
		reportOnce("arrowErr", "arrow layer config failed: " .. tostring(cfg))
		cfg = nil
	end
	lastArrow.key, lastArrow.config = key, cfg
	return cfg
end

------------------------------------------------------------------------
-- the line: ground band (LINE_MODE = "zone")
------------------------------------------------------------------------

-- what is drawn under ZONE_KEY: a key, false (nothing) or "unknown" (after a
-- load: a band saved with the game may be there, so the first render clears)
local zoneDrawn = "unknown"

-- the band as a thin rectangle around the segment, on the ground
function map.ribbon(key, width)
	local ax, ay, bx, by = key[1], key[2], key[4], key[5]
	local dx, dy = bx - ax, by - ay
	local len = math.sqrt(dx * dx + dy * dy)
	if len <= 0 then return nil end
	local nx, ny = -dy / len * width / 2, dx / len * width / 2
	return {
		{ ax + nx, ay + ny }, { bx + nx, by + ny },
		{ bx - nx, by - ny }, { ax - nx, ay - ny },
	}
end

function map.drawZone(key)
	if key == nil then
		if zoneDrawn == false then return end
		local ok, err = pcall(function() api.gui.mission.removeZone(map.ZONE_KEY) end)
		if not ok then reportOnce("zoneRmErr", "removeZone failed: " .. tostring(err)) end
		zoneDrawn = false
		return
	end
	if zoneDrawn ~= "unknown" and zoneDrawn ~= false and sameKey(key, zoneDrawn) then return end
	local poly = map.ribbon(key, map.ZONE_WIDTH)
	if not poly then return map.drawZone(nil) end
	local ok, err = pcall(function()
		local pts = {}
		for i, p in ipairs(poly) do pts[i] = api.type.Vec2f.new(p[1], p[2]) end
		-- no building ban, no zone animation (it would replay on each move)
		api.gui.mission.setZone(map.ZONE_KEY, pts, true, vec4(map.ZONE_COLOR), false, false)
	end)
	if not ok then reportOnce("zoneErr", "setZone failed: " .. tostring(err)) end
	zoneDrawn = key
end

------------------------------------------------------------------------
-- test input (tf3ctl event hummer_cat.test --param ...)
------------------------------------------------------------------------

-- { hold = true, cursor = {x, y, z} }: as if the key were down and the
-- cursor on that terrain point (cursor left out: the real mouse);
-- { hold = false } or {}: back to the real key and mouse;
-- { report = true } (with or without the above): one log line of the state.
function map.onTestEvent(param)
	if type(param) ~= "table" then param = {} end
	if param.hold == true then
		local c = param.cursor
		local pos = type(c) == "table" and core.copyPos({ x = tonumber(c.x or c[1]), y = tonumber(c.y or c[2]), z = tonumber(c.z or c[3]) }) or nil
		map.testInput = { held = true, pos = pos }
	elseif param.hold == false or param.report ~= true then
		map.testInput = nil
	end
	if param.report == true then
		local o = map.tracker.origin
		local key = map.stepLine()
		pcall(debugPrint, string.format("[CAT] test: mode=%s held=%s origin=%s line=%s arrow=%s text=%s",
			tostring(map.LINE_MODE), tostring(map.tracker.held),
			o and string.format("%.1f,%.1f,%.1f", o.x, o.y, o.z) or "nil",
			key and table.concat(key, ",") or "nil",
			tostring(lastArrow.config ~= nil and sameKey(key, lastArrow.key)),
			string.format("%q", tostring(map.stepText()))))
	end
end

-- Builds the tooltip recipe for one set of GUI modules. A recipe belongs to
-- the react instance it was registered with, so it is made again when the
-- modules are loaded afresh (next game load) and reused otherwise.
local recipeCache = setmetatable({}, { __mode = "k" })

function map.makeRecipe(mods)
	local react, builtin = mods.react, mods.builtin
	local cached = recipeCache[react]
	if cached then return cached end
	local recipe = react.RegisterRecipe("CursorAltitudeTooltip", function(param)
		react.setMouseTransparent(true)
		local state = mods.engine_react_util.useStepState(map.stepText)
		local text = state:old()
		local child
		if text then
			-- the tooltip box (background, padding, text colour) is styled by
			-- selectors naming the base recipes (game.css.lua); under our recipe
			-- only this class brings it, as the LVM selector tooltip does
			child = builtin.TextView{
				meta = { class = map.TEXT_CLASS, mouseTransparent = true },
				text = text,
			}
		else
			child = mods.tooltips.DefaultEntityToolTip(param)
		end
		-- same shape as the base TerrainTooltip in both cases
		return builtin.BoxLayout{ children = { child } }
	end)
	recipeCache[react] = recipe
	return recipe
end

-- Our makeDefaultSelectorTooltips: same parameters as the base one.
function map.makeTooltips(mods)
	local recipe = map.makeRecipe(mods)
	return function(selectedEntityRef)
		return mods.builtin.ActionTooltip{
			recipe = recipe,
			param = { entityRef = selectedEntityRef },
		}
	end
end

-- Wraps the combined function: each render of the plain map view runs with
-- our tooltip function in the module table, and the base one put back after
-- (also when the render throws).
-- The hooks our action adds, the same ones on every render (react keeps
-- hooks by call order). Returns the line key, or nil.
local function useLine(mods)
	local react = mods.react
	local ok, key = pcall(function()
		react.onEvent(map.TEST_EVENT, function(_name, param) map.onTestEvent(param) end)
		if map.LINE_MODE == "zone" then
			-- a tool or window taking over while the key is down
			react.onUnmount(function() map.drawZone(nil) end)
		end
		return mods.engine_react_util.useStepState(map.stepLine):old()
	end)
	if not ok then
		reportOnce("lineErr", "line state failed: " .. tostring(key))
		return nil
	end
	return key
end

-- Wraps the combined function: each render of the plain map view runs with
-- our tooltip function in the module table, and the base one put back after
-- (also when the render throws). While a line is shown, the view's
-- ActionDescriptor gets our LayerConfig as one more child the same way:
-- builtin.ActionDescriptor is swapped for the render, as the base builds the
-- descriptor inside the function and hands back only the finished node.
function map.wrapCombinedFn(original, sru, mods)
	local ours = map.makeTooltips(mods)
	local builtin = mods.builtin
	return function(params, ...)
		local inner = original(params, ...)
		return function(...)
			local key = useLine(mods)
			local layer
			if map.LINE_MODE == "arrow" and key then
				layer = map.makeArrowConfig(key)
			elseif map.LINE_MODE == "zone" then
				map.drawZone(key)
			end
			local baseAD = builtin.ActionDescriptor
			if layer then
				local added = false
				builtin.ActionDescriptor = function(p, ...)
					-- once: only the view's own descriptor, not one a chained
					-- wrap might build; and only when called as (params), the
					-- builtin also takes (ref, params), passed through untouched
					-- (as Station Coverage Filter's same swap does)
					if added or select("#", ...) > 0 or type(p) ~= "table" then
						return baseAD(p, ...)
					end
					do
						added = true
						local okL, node = pcall(builtin.LayerConfig, { config = layer })
						if okL then
							local q = {}
							for k, v in pairs(p) do q[k] = v end
							local children = {}
							for i, c in ipairs(p.children or {}) do children[i] = c end
							children[#children + 1] = node
							q.children = children
							p = q
						else
							reportOnce("layerNodeErr", "LayerConfig node failed: " .. tostring(node))
						end
					end
					return baseAD(p)
				end
			end
			local base = sru.makeDefaultSelectorTooltips
			sru.makeDefaultSelectorTooltips = ours
			-- the action function returns one node; one value keeps this free of
			-- table.pack, which plain LuaJIT lacks
			local ok, node = pcall(inner, ...)
			sru.makeDefaultSelectorTooltips = base
			builtin.ActionDescriptor = baseAD
			if not ok then error(node, 0) end
			return node
		end
	end
end

-- the wrap last installed: install runs again on every game load, and this
-- module may outlive a load while selector_react_util is loaded afresh, so
-- "already done" is told by the function in place, not by a flag
local wrapped

--- Wraps the plain map view's action. Called at UI bootstrap.
function map.install(ug)
	-- the same require paths the base files use, so the same module
	-- instances (and their recipes) are shared
	local sru = ug "::/gui/main/selector_react_util.tl"
	local current = sru.makeDefaultSelectorCombinedFn
	if type(current) ~= "function" then error("makeDefaultSelectorCombinedFn not found") end
	if type(sru.makeDefaultSelectorTooltips) ~= "function" then error("makeDefaultSelectorTooltips not found") end
	if current == wrapped then return end
	local mods = {
		react = ug "::/gui/main/react.lua",
		builtin = ug "::/gui/main/builtin.lua",
		tooltips = ug "/gui/main/game_tooltips.tl",
		engine_react_util = ug "/gui/main/engine_react_util.tl",
	}
	-- a fresh load: a band may have been saved with the game (LINE_MODE
	-- "zone"); the first render clears it. The arrow's cache holds a userdata
	-- of the old load, so it goes too.
	zoneDrawn = "unknown"
	lastArrow.key, lastArrow.config = nil, nil
	map.testInput = nil
	-- no origin carried over from the last game
	map.tracker = core.newTracker()
	wrapped = map.wrapCombinedFn(current, sru, mods)
	sru.makeDefaultSelectorCombinedFn = wrapped
end

return map
