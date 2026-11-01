' notify.vbs -- start the resident notifier without a console window.
Option Explicit
Dim fso, shell, here, command
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
command = fso.BuildPath(here, "notify.cmd")
shell.Run "cmd.exe /c """ & command & """", 0, False
