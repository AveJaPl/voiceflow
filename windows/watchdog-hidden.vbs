' Starts the voiceflow watchdog with no console window at all. PowerShell has
' no pythonw.exe equivalent - even -WindowStyle Hidden creates the window first
' and then hides it, which is a visible flash at every logon - so the process is
' launched here with a window state of 0 instead.
Set shell = CreateObject("WScript.Shell")
path = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\voiceflow\watchdog.ps1"
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & path & """", 0, False
