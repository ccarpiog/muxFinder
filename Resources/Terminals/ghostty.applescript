-- muxFinder's built-in script for Ghostty 1.3 or later (ghostty.json; PLAN.md D38).
-- muxFinder compiles this file exactly as it is and calls its three handlers, passing every
-- value as an argument of one Apple event; it never builds or changes script source.
-- It opens a new window running muxFinder's helper, brings that window forward, and closes
-- that window by its id. It never types into a terminal or sends it keys or pointer events.

-- Opens a new window whose command is the helper path, the mode word and the token. They
-- hold only letters, digits and / . _ + - (muxFinder checks), so the command means the same
-- however Ghostty parses it. Returns {window id, ""}: Ghostty shows no tty.
on muxfinder_open(commandText, helperPath, modeWord, token)
	tell application id "com.mitchellh.ghostty"
		set launchConfiguration to new surface configuration
		set command of launchConfiguration to helperPath & " " & modeWord & " " & token
		set wait after command of launchConfiguration to false
		set newWindow to new window with configuration launchConfiguration
		set windowID to (id of newWindow) as text
	end tell
	return {windowID, ""}
end muxfinder_open

-- Brings forward the window with windowID. Error -1728 when it is gone.
on muxfinder_focus(windowID, ttyName)
	tell application id "com.mitchellh.ghostty"
		activate window (window id windowID)
		activate
	end tell
	return
end muxfinder_focus

-- Closes the window with windowID. muxFinder calls it only once its helper has ended, since
-- Ghostty asks before closing a window that still runs a process. Error -1728 when it is gone.
on muxfinder_close(windowID)
	tell application id "com.mitchellh.ghostty"
		close window (window id windowID)
	end tell
	return
end muxfinder_close
