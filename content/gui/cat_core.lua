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

M.FEET_PER_METRE = 1 / 0.3048

-- The game's formatter when it works (it follows the metric/imperial
-- setting); else our own text, in feet when `imperial` says the player chose
-- imperial units, so the fallback never disagrees with the rest of the UI.
function M.formatAltitude(label, z, formatFn, imperial)
	if math.abs(z) < 0.05 then z = 0 end -- avoid "-0.0 m"
	if type(formatFn) == "function" then
		local ok, s = pcall(formatFn, z, 1)
		if ok and type(s) == "string" and s ~= "" then
			return string.format("%s: %s", label, s)
		end
	end
	if imperial == true then
		-- z is already 0 or at least 0.05 m (0.16 ft), so no "-0.0 ft" either
		return string.format("%s: %.1f ft", label, z * M.FEET_PER_METRE)
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
--   extra  : more lines under the altitude (measureLines) or nil
function M.tooltipText(held, hasPos, pos, label, formatFn, imperial, extra)
	if not held or not hasPos then return nil end
	if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
	local z = pos.z
	if not isNumber(z) then return nil end
	local text = M.formatAltitude(label, z, formatFn, imperial)
	if type(extra) == "table" and #extra > 0 then
		-- one TextView, one line each (the base help texts are multi-line
		-- TextViews too), so the tooltip keeps a single box
		text = text .. "\n" .. table.concat(extra, "\n")
	end
	return text
end

------------------------------------------------------------------------
-- Measuring between two points (key pressed -> key released)
------------------------------------------------------------------------

-- Show the incline line (height difference / horizontal distance). One line
-- to turn it off: the player asked for it, but its unit is our choice.
M.SHOW_INCLINE = true

-- The base road and track "Incline" slider prints whole percent
-- (construction_react_util.tl makeNumberSliderSlopeFormatValueFn:
-- api.util.toStringPercentPrecision(value, 0)); this follows it.
M.INCLINE_DECIMALS = 0

-- Below this horizontal distance (metres) only the altitude shows: right
-- after the press origin and cursor are the same point, and an incline over
-- a few centimetres is noise (dz / ~0 blows up).
M.MIN_DISTANCE = 1.0

M.METRES_PER_KM = 1000
M.FEET_PER_MILE = 5280

-- a plain copy of a terrain position: the engine may hand out the same
-- Vec3f again, and the origin must not move with the cursor
function M.copyPos(pos)
	if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
	local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
	if not ok or not isNumber(x) or not isNumber(y) or not isNumber(z) then return nil end
	return { x = x, y = y, z = z }
end

-- Remembers where the key went down. update() is called (maybe more than
-- once) every step with the key state and the cursor's terrain position and
-- returns the origin, or nil:
--   * the step the key goes down, the cursor's position;
--   * if the cursor was off the terrain then (sky, a window), the first
--     terrain position after it;
--   * the key up drops it.
-- Calling it twice in the same step with the same input changes nothing, so
-- the tooltip and the line may both drive it.
-- `now` (seconds, optional): the key going up is only seen while the map
-- view steps; after a gap longer than STALE_SECONDS (a tool or window was on
-- top meanwhile) the key may have been released and pressed again unseen, so
-- the old origin is dropped and this counts as a new press.
M.STALE_SECONDS = 2.0

function M.newTracker()
	local t = { held = false, origin = nil, last = nil }
	function t.update(held, hasPos, pos, now)
		if isNumber(now) then
			if t.last and now - t.last > M.STALE_SECONDS then t.held, t.origin = false, nil end
			t.last = now
		end
		if held ~= true then
			t.held, t.origin = false, nil
			return nil
		end
		t.held = true
		if t.origin == nil and hasPos then t.origin = M.copyPos(pos) end
		return t.origin
	end
	return t
end

-- { dz, dist, incline } from origin to pos, or nil when either is missing or
-- the two are closer than MIN_DISTANCE horizontally
function M.measure(origin, pos)
	local a, b = M.copyPos(origin), M.copyPos(pos)
	if not a or not b then return nil end
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local dist = math.sqrt(dx * dx + dy * dy)
	if not isNumber(dist) or dist < M.MIN_DISTANCE then return nil end
	return { dz = dz, dist = dist, incline = dz / dist }
end

-- "+" for up, "-" for down, nothing for (rounded) zero; the number itself is
-- formatted as a magnitude so a formatter's own minus can't double it
local function signOf(v, zero)
	if math.abs(v) < zero then return "", 0 end
	return v > 0 and "+" or "-", math.abs(v)
end

local function callFormatter(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, s = pcall(fn, ...)
	if ok and type(s) == "string" and s ~= "" then return s end
	return nil
end

-- signed height difference, one decimal like the altitude
function M.formatHeightDiff(label, dz, formatFn, imperial)
	local sign, mag = signOf(dz, 0.05)
	local s = callFormatter(formatFn, mag, 1)
	if not s then
		if imperial == true then
			s = string.format("%.1f ft", mag * M.FEET_PER_METRE)
		else
			s = string.format("%.1f m", mag)
		end
	end
	return string.format("%s: %s%s", label, sign, s)
end

-- horizontal distance with the game's length formatter (its own decimals
-- and its switch to km / mi); the fallback copies that shape
function M.formatDistance(label, dist, formatFn, imperial)
	local s = callFormatter(formatFn, dist)
	if not s then
		if imperial == true then
			local ft = dist * M.FEET_PER_METRE
			if ft >= M.FEET_PER_MILE then
				s = string.format("%.2f mi", ft / M.FEET_PER_MILE)
			else
				s = string.format(ft < 10 and "%.1f ft" or "%.0f ft", ft)
			end
		elseif dist >= M.METRES_PER_KM then
			s = string.format("%.2f km", dist / M.METRES_PER_KM)
		else
			s = string.format(dist < 10 and "%.1f m" or "%.0f m", dist)
		end
	end
	return string.format("%s: %s", label, s)
end

-- signed incline in percent (a ratio in, as the base percent formatter
-- takes); a ratio that rounds to 0 at INCLINE_DECIMALS gets no sign
function M.formatIncline(label, incline, formatFn)
	local dec = M.INCLINE_DECIMALS
	local sign, mag = signOf(incline, 0.5 * 10 ^ -dec / 100)
	local s = callFormatter(formatFn, mag, dec)
	if not s then s = string.format("%." .. dec .. "f%%", mag * 100) end
	return string.format("%s: %s%s", label, sign, s)
end

-- The lines under the altitude, or nil (no origin yet, or too close).
--   labels : { diff, distance, incline }
--   fmts   : { altitude, length, percent } (the game's formatters or nil)
function M.measureLines(origin, pos, labels, fmts, imperial, showIncline)
	local m = M.measure(origin, pos)
	if not m then return nil end
	labels, fmts = labels or {}, fmts or {}
	local lines = {
		M.formatHeightDiff(labels.diff or "Height difference", m.dz, fmts.altitude, imperial),
		M.formatDistance(labels.distance or "Distance", m.dist, fmts.length, imperial),
	}
	if showIncline then
		lines[#lines + 1] = M.formatIncline(labels.incline or "Incline", m.incline, fmts.percent)
	end
	return lines
end

-- The line's end points snapped to `grid` metres, or nil when nothing is to
-- be drawn. The snapped table is what the map view's step state compares, so
-- the action (and its layer config) is rebuilt only when an end moves by a
-- grid step, not on every frame.
function M.lineKey(origin, pos, grid)
	if not M.measure(origin, pos) then return nil end
	grid = (isNumber(grid) and grid > 0) and grid or 1
	local function snap(v) return math.floor(v / grid + 0.5) * grid end
	local a, b = M.copyPos(origin), M.copyPos(pos)
	return { snap(a.x), snap(a.y), snap(a.z), snap(b.x), snap(b.y), snap(b.z) }
end

return M
