-- Cursor Altitude Tooltip: the replacement-config hook (cat_install.res.lua).
-- A failure leaves the plain map view as it was and logs one line.
local map = require "hummer_cursor_altitude_tooltip::/gui/cat_map.lua"

local function CAT_Install(_replacementApi)
	local ok, err = pcall(map.install, ug_require)
	if not ok then debugPrint("[CAT] install: " .. tostring(err)) end
end

-- The engine loads *.script.lua resources by calling data().
function data()
	return { CAT_Install = CAT_Install }
end
