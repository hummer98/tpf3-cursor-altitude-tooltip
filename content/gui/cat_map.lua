-- Cursor Altitude Tooltip: swaps the plain map view's cursor tooltip.
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
local core = require "hummer_cursor_altitude_tooltip::/gui/cat_core.lua"

local map = {}

map.TEXT_CLASS = "font-scale-tooltip, default-tooltip-configuration"

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
local function isHeld()
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

-- the text for this step, or nil (usual tooltip)
function map.stepText()
	local held = isHeld()
	if not held then return nil end
	local has, pos = terrainPos()
	-- the unit is read every time: the fallback is also taken when the game's
	-- formatter exists but throws or returns junk
	return core.tooltipText(held, has, pos,
		core.label(_, "cat_altitude", "Altitude"), altitudeFormatter(), isImperial())
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
function map.wrapCombinedFn(original, sru, mods)
	local ours = map.makeTooltips(mods)
	return function(params, ...)
		local inner = original(params, ...)
		return function(...)
			local base = sru.makeDefaultSelectorTooltips
			sru.makeDefaultSelectorTooltips = ours
			-- the action function returns one node; one value keeps this free of
			-- table.pack, which plain LuaJIT lacks
			local ok, node = pcall(inner, ...)
			sru.makeDefaultSelectorTooltips = base
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
	wrapped = map.wrapCombinedFn(current, sru, mods)
	sru.makeDefaultSelectorCombinedFn = wrapped
end

return map
