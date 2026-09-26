# A tap on a petal in the Windows 11 widget, exactly as the Widgets board delivers it:
# the board calls the provider's OnActionInvoked, which runs the same code as
# `PromptPetal.WidgetProvider.exe --tap <petalId>` (Program.cs shares it), and that hands
# the petal to the running Prompt Petal app over its named pipe. The app then does what a
# click on the petal does: its words land where the person was typing.
#
# Setup mirrors verify-open-petals-from-window.ps1: Notepad in front with some text typed
# by a real click and real keys, so the app has a real "last window that was not Prompt
# Petal" to paste into. Then the tap, then Notepad's own text is read back.
param(
  [Parameter(Mandatory=$true)][string]$AppExe,
  [Parameter(Mandatory=$true)][string]$ProviderExe,
  [Parameter(Mandatory=$true)][string]$PetalId,
  [string]$OutDir = "artifacts"
)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WidgetTap {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowTitle);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int SendMessage(IntPtr hwnd, int msg, int wParam, StringBuilder lParam);
  [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public static void ClickAt(int x, int y) {
    SetCursorPos(x, y);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }
  public static string NotepadText(IntPtr notepadWindow) {
    IntPtr edit = FindWindowEx(notepadWindow, IntPtr.Zero, "Edit", null);
    if (edit == IntPtr.Zero) return null;
    int length = SendMessage(edit, 0x000E, 0, null);
    var buffer = new StringBuilder(length + 1);
    SendMessage(edit, 0x000D, buffer.Capacity, buffer);
    return buffer.ToString();
  }
}
"@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
function Save-Screen([string]$name) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $OutDir $name))
}

# Pro, so nothing on the app side can refuse the tap for being Free. The widget itself
# is Pro, and a Free person never has a petal on it to tap.
$data = "$env:APPDATA\PromptPetal"
New-Item -ItemType Directory -Force $data | Out-Null
Set-Content "$data\entitlement.json" '{"source":"lifetime","updatedAt":"2026-09-26T00:00:00Z"}' -Encoding utf8

# ── With no app running, the tap reports that nobody is listening ────────────
Get-Process | Where-Object { $_.Path -eq $AppExe } | Stop-Process -Force -EA SilentlyContinue
& $ProviderExe --tap $PetalId
$code = $LASTEXITCODE
Write-Host "tap with the app closed exited $code"
if ($code -ne 2) { throw "With Prompt Petal closed, --tap should exit 2 (nobody listening), not $code" }

# ── Start the app, then Notepad in front with text typed ─────────────────────
$app = Start-Process -FilePath $AppExe -PassThru
Start-Sleep -Seconds 25
if ($app.HasExited) { throw "Prompt Petal exited with $($app.ExitCode) before the tap" }

$notepad = Start-Process notepad.exe -PassThru
$deadline = (Get-Date).AddSeconds(15)
while ($notepad.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; $notepad.Refresh() }
if ($notepad.MainWindowHandle -eq 0) { throw "Notepad never showed a window" }
$r = New-Object WidgetTap+Rect
[void][WidgetTap]::GetWindowRect($notepad.MainWindowHandle, [ref]$r)
[WidgetTap]::ClickAt([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait("Typed before the widget tap.`r`n")
Start-Sleep -Milliseconds 1200
if ([WidgetTap]::NotepadText($notepad.MainWindowHandle) -notlike "*Typed before the widget tap*") {
  Save-Screen "widget-tap-setup-failed.png"
  throw "Test setup failed: the typing never reached Notepad."
}
Save-Screen "widget-tap-before.png"

# ── The tap ──────────────────────────────────────────────────────────────────
# Hidden, as the board runs the provider: no console window of its own to steal focus.
$tap = Start-Process -FilePath $ProviderExe -ArgumentList @("--tap", $PetalId) -WindowStyle Hidden -PassThru -Wait
Write-Host "tap exited $($tap.ExitCode)"
if ($tap.ExitCode -ne 0) { throw "--tap exited $($tap.ExitCode) with Prompt Petal running; the app did not take the tap" }
Start-Sleep -Seconds 3
Save-Screen "widget-tap-after.png"

$text = [WidgetTap]::NotepadText($notepad.MainWindowHandle)
Write-Host "Notepad now reads:"
Write-Host $text
if ($text -like "*Research the following thoroughly*") {
  Write-Host "The tapped petal's words landed in Notepad, where the person was typing."
  exit 0
}
$clip = Get-Clipboard -Raw -EA SilentlyContinue
Write-Host "clipboard: $clip"
Write-Host "::error::The tap reached the app but the petal's words did not land in Notepad. See widget-tap-before.png and widget-tap-after.png."
exit 1
