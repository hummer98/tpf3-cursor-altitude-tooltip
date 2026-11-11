-- Pure helpers for the cursor altitude tooltip (no engine access, testable
-- offline). The engine-facing glue lives in cat_map.lua.
local M = {}

-- The game has no "is this key down" query for Lua; the only way to read a
-- held modifier is a modifier-only input action. IA_ENHANCED_SNAP
-- ("Surface Snapping") is the one bound to Alt by default, so the tooltip
-- follows whatever key the player binds to it.
M.INPUT_ACTION = "IA_ENHANCED_SNAP"

local function isNumber(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Same rules as the build-cursor altitude mod (construction_height_tooltip)
-- so both read alike: the game's formatter when it works, else plain metres.
function M.formatAltitude(label, z, formatFn)
	if math.abs(z) < 0.05 then z = 0 end -- avoid "-0.0 m"
	if type(formatFn) == "function" then
		local ok, s = pcall(formatFn, z, 1)
		if ok and type(s) == "string" and s ~= "" then
			return string.format("%s: %s", label, s)
		end
	end
	return string.format("%s: %.1f m", label, z)
end

-- Resolve a strings.json key with the game's _(), falling back when the
-- key is missing (then _() echoes the key back) or _ is unavailable.
function M.label(translate, key, fallback)
	if type(translate) ~= "function" then return fallback end
	local ok, v = pcall(translate, key)
	if not ok or type(v) ~= "string" or v == "" or v == key then return fallback end
	return v
end

-- The tooltip text for one step, or nil for "show the usual tooltip".
--   held   : modifier key held (boolean)
--   hasPos : the mouse points at terrain
--   pos    : terrain position (x, y, z) or nil
-- Returning a string (not the number) keeps the step state from changing
-- while the cursor moves within the same 0.1 m, so the tooltip does not
-- re-render on every tiny move.
function M.tooltipText(held, hasPos, pos, label, formatFn)
	if not held or not hasPos then return nil end
	if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
	local z = pos.z
	if not isNumber(z) then return nil end
	return M.formatAltitude(label, z, formatFn)
end

return M
