' guard.vbs -- run guard.ps1 without a console window.
Option Explicit
Dim fso, shell, here, repo, guard
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
repo = fso.GetParentFolderName(here)
guard = fso.BuildPath(repo, "guard.ps1")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & guard & """", 0, False
