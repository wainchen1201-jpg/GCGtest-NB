' Runs run-heartbeats.ps1 with no console window at all.
'
' powershell.exe -WindowStyle Hidden still creates the console first and hides it
' afterwards, which shows up as a flash on screen every time the task fires.
' wscript.exe has no console of its own, so nothing is ever created.
'
' Comments are ASCII on purpose: wscript reads this file using the system ANSI
' codepage, and this repo forbids a BOM on anything that is not a .ps1 file.
Option Explicit

Dim shell, scriptDir, command

scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass" & _
          " -File """ & scriptDir & "run-heartbeats.ps1"""

Set shell = CreateObject("WScript.Shell")
' 0 = hidden window, True = wait so the task's result reflects the run.
WScript.Quit shell.Run(command, 0, True)
