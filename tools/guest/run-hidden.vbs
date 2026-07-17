' Launch a C:\kaya\ script with NO console window. Scheduled-task
' payloads run interactively (/it) so their cmd consoles open ON the
' desktop — directly on top of the guest windows the recording mode
' films. Window style 0 keeps the desktop showing only what the
' guests draw.
CreateObject("Wscript.Shell").Run "cmd /c C:\kaya\" & WScript.Arguments(0), 0, False
