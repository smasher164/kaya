' Run a C:\kaya command with a HIDDEN console, forwarding every argument.
'
' run-hidden.vbs cannot serve here: its second argument is consumed as
' KAYA_WIN_SLOT and never reaches the command, so a caller that needs to
' PASS arguments needs this one.
'
' Hidden matters more than tidiness for the flight recorder: a visible
' console takes the foreground, and the sampler this launches is measuring
' exactly that.
Dim cmd, i
cmd = "cmd /c C:\kaya\" & WScript.Arguments(0)
For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next
CreateObject("Wscript.Shell").Run cmd, 0, False
