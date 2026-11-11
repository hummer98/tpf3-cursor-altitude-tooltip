-- Cursor Altitude Tooltip: wraps the plain map view's action at UI bootstrap
-- so its cursor tooltip can show the altitude (cat_map.lua).
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "cursor_altitude_tooltip::/gui/cat_install.script",
			doReplaceFn = "CAT_Install",
		},
	}
end
