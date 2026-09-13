# Asserts that the installed app is showing its own window, not an error dialog.
#
# "Still running" is not "works". A build that installed and then put up a modal box
# reading "Failed to launch JVM" passed a liveness check, because the process had not
# exited: it was sitting on that dialog.
#
# The title and the SIZE are both checked, and the size is the one that bites. A JVM
# launch failure shows a small dialog whose title is the executable's own file name, so a
# title check on its own can be satisfied by the error message.
#
# The window is found BY TITLE across every process, not through the process that was
# started. jpackage's launcher .exe is not always the process that owns the window, so
# asking it for MainWindowHandle returned zero on a run whose screenshot plainly showed the
# app, and this step failed a build that worked. Keep the Diff's verify-ui.ps1 looks across
# processes for the same reason.
#
# A separate file rather than inline in the workflow because the P/Invoke needs a
# PowerShell here-string, whose closing "@ must sit at column zero, and a line at column
# zero ends a YAML block. Inlining it silently removed the workflow's own
# `workflow_dispatch` trigger, which then could not be dispatched at all.
param(
  [Parameter(Mandatory=$true)][int]$ProcessId,
  [string]$Title = $env:APP_NAME,
  [int]$MinWidth = 400,
  [int]$MinHeight = 400,
  [int]$WaitSeconds = 30
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

if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { throw "Process $ProcessId is gone" }

# Every visible top level window, from any process, whose title names the app or the
# executable. The second kind is how a launcher error box is caught rather than missed.
function Find-Windows {
  Get-Process | Where-Object {
    $_.MainWindowHandle -ne 0 -and (
      $_.MainWindowTitle -like "*$Title*" -or $_.MainWindowTitle -like "*.exe*")
  }
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$found = @(Find-Windows)
while ($found.Count -eq 0 -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $found = @(Find-Windows)
}
if ($found.Count -eq 0) {
  Write-Host "::error::No window titled '$Title' appeared within ${WaitSeconds}s. That is what a silent failure to open one looks like."
  Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } |
    ForEach-Object { Write-Host "  visible: '$($_.MainWindowTitle)' ($($_.ProcessName) $($_.Id))" }
  exit 1
}

$failures = 0
foreach ($p in $found) {
  $rect = New-Object WindowGeometry+Rect
  [void][WindowGeometry]::GetWindowRect($p.MainWindowHandle, [ref]$rect)
  $width  = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  Write-Host "window: '$($p.MainWindowTitle)'  ${width}x${height}  from $($p.ProcessName) $($p.Id)"
  if ($p.MainWindowTitle -like "*.exe*") {
    Write-Host "::error::A window is titled '$($p.MainWindowTitle)'. A window titled after the executable is the jpackage launcher's error box, not the app."
    $failures++
  } elseif ($width -lt $MinWidth -or $height -lt $MinHeight) {
    Write-Host "::error::The window is ${width}x${height}, far smaller than the app's own window. That is the shape of an error dialog. Look at the screenshot in the artifacts."
    $failures++
  }
}
if ($failures -gt 0) { exit 1 }
Write-Host "window ok, it is the app and not a dialog"
