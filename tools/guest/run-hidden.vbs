' Launch a C:\kaya\ script with NO console window. Scheduled-task
' payloads run interactively (/it) so their cmd consoles open ON the
' desktop — directly on top of the guest windows the recording mode
' films. Window style 0 keeps the desktop showing only what the
' guests draw.
'
' Optional second argument: a tile slot, exported as KAYA_WIN_SLOT so
' parallel legs place their windows side by side (and carry the slot
' in their titles for the recorder).
Dim cmd
cmd = "cmd /c "
If WScript.Arguments.Count > 1 Then
    cmd = cmd & "set KAYA_WIN_SLOT=" & WScript.Arguments(1) & "&& "
End If
CreateObject("Wscript.Shell").Run cmd & "C:\kaya\" & WScript.Arguments(0), 0, False
