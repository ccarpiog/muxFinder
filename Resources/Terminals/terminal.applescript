-- muxFinder's built-in script for Terminal (terminal.json; PLAN.md D38).
-- muxFinder compiles this file exactly as it is and calls its three handlers, passing every
-- value as an argument of one Apple event; it never builds or changes script source.
-- It opens a new window running muxFinder's helper, brings that window forward, and closes
-- that window by its id once nothing runs in it. It never types into a window or tab.

-- Opens a new window running commandText (D3's shell command text) in the user's shell.
-- Returns {window id as text, the new tab's tty}.
on muxfinder_open(commandText, helperPath, modeWord, token)
	tell application id "com.apple.Terminal"
		set newTab to do script commandText
		set ttyName to tty of newTab
		set windowID to ""
		repeat with candidateWindow in windows
			repeat with candidateTab in tabs of candidateWindow
				if windowID is "" and (tty of candidateTab) is ttyName then
					set windowID to (id of candidateWindow) as text
				end if
			end repeat
		end repeat
	end tell
	return {windowID, ttyName}
end muxfinder_open

-- Brings forward the window whose tab has ttyName. Error -1728 when there is none.
on muxfinder_focus(windowID, ttyName)
	if ttyName is "" then error "muxFinder has no terminal device for this window." number -1728
	tell application id "com.apple.Terminal"
		repeat with candidateWindow in windows
			repeat with candidateTab in tabs of candidateWindow
				if (tty of candidateTab) is ttyName then
					if miniaturized of candidateWindow then set miniaturized of candidateWindow to false
					set selected of candidateTab to true
					set index of candidateWindow to 1
					activate
					return
				end if
			end repeat
		end repeat
	end tell
	error "The window is gone." number -1728
end muxfinder_focus

-- Closes the window with windowID, only when none of its tabs is busy (a busy window would
-- ask the user first). Error 1001 when one is busy, -1728 when the window is gone.
on muxfinder_close(windowID)
	tell application id "com.apple.Terminal"
		set targetWindow to window id (windowID as integer)
		repeat with candidateTab in tabs of targetWindow
			if busy of candidateTab then error "The window still runs a process." number 1001
		end repeat
		close targetWindow
	end tell
	return
end muxfinder_close
