# Asserts that a running process is showing the APP, not an error dialog.
#
# "Still running" is not "works". A build that installed and then put up a modal box
# reading "Failed to launch JVM" passed a liveness check, because the process had not
# exited: it was sitting on that dialog.
#
# The title and the SIZE are both checked, and the size is the one that bites. A JVM
# launch failure shows a small dialog whose title is the executable's own file name, so a
# title check on its own can be satisfied by the error message.
#
# A separate file rather than inline in the workflow because the P/Invoke needs a
# PowerShell here-string, whose closing "@ must sit at column zero, and a line at column
# zero ends a YAML block. Inlining it silently removed the workflow's own
# `workflow_dispatch` trigger, which then could not be dispatched at all.
param(
  [Parameter(Mandatory=$true)][int]$ProcessId,
  [int]$MinWidth = 400,
  [int]$MinHeight = 400
)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WindowGeometry {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr handle, out Rect rect);
}
"@

$proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if (-not $proc) { throw "Process $ProcessId is gone" }

$handle = $proc.MainWindowHandle
if ($handle -eq 0) {
  Write-Host "::error::The app is running but has no main window. That is what a silent failure to open one looks like, and what a crash dialog owned by another thread looks like."
  exit 1
}

$rect = New-Object WindowGeometry+Rect
[void][WindowGeometry]::GetWindowRect($handle, [ref]$rect)
$width  = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
$title  = $proc.MainWindowTitle
Write-Host "main window: '$title'  ${width}x${height}"

$failures = 0
if ($width -lt $MinWidth -or $height -lt $MinHeight) {
  Write-Host "::error::The main window is ${width}x${height}, far smaller than the app's own window. That is the shape of an error dialog. Look at the screenshot in the artifacts."
  $failures++
}
if ($title -like "*.exe*") {
  Write-Host "::error::The window is titled '$title'. A window titled after the executable is the jpackage launcher's error box, not the app."
  $failures++
}
if ($failures -gt 0) { exit 1 }
Write-Host "window ok, it is the app and not a dialog"
