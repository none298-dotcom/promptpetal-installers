# Presses the keys that open the ring (Ctrl + Alt + Space, the default) and asserts a new
# window of the installed app appeared, then presses them again and asserts it went.
#
# Counted across every visible top level window whose process runs from the install folder,
# for the same reason assert-app-window.ps1 looks across processes: the launcher .exe is not
# always the process that owns the window.
#
# A separate file rather than inline in the workflow, because the P/Invoke needs a
# here-string whose closing "@ sits at column zero, which ends a YAML block.
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [string]$OutDir = "artifacts"
)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class RingKeys {
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
  // Whether some process already holds Ctrl + Alt + Space: trying to take it fails with 1409
  // (ERROR_HOTKEY_ALREADY_REGISTERED) when the app registered it.
  public static string WhoHoldsCtrlAltSpace() {
    if (RegisterHotKey(IntPtr.Zero, 0x7A7A, 2 | 1, 0x20)) { UnregisterHotKey(IntPtr.Zero, 0x7A7A); return "nobody: the app did not register the keys"; }
    int error = Marshal.GetLastWin32Error();
    return error == 1409 ? "already registered, as the app should have" : "refused with error " + error;
  }
  public static List<uint> VisibleWindowOwners() {
    var owners = new List<uint>();
    EnumWindows((h, l) => { if (IsWindowVisible(h)) { uint p; GetWindowThreadProcessId(h, out p); owners.Add(p); } return true; }, IntPtr.Zero);
    return owners;
  }
  public static void CtrlAltSpace() {
    const uint up = 2;
    keybd_event(0x11, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event(0x20, 0, 0, UIntPtr.Zero); keybd_event(0x20, 0, up, UIntPtr.Zero);
    keybd_event(0x12, 0, up, UIntPtr.Zero); keybd_event(0x11, 0, up, UIntPtr.Zero);
  }
}
"@

$folder = Split-Path -Parent $ExePath
function Count-AppWindows {
  $pids = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [uint32]$_.Id })
  if ($pids.Count -eq 0) { throw "No process is running from $folder" }
  @([RingKeys]::VisibleWindowOwners() | Where-Object { $pids -contains $_ }).Count
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
Write-Host "Ctrl + Alt + Space: $([RingKeys]::WhoHoldsCtrlAltSpace())"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Save-Screen([string]$name) {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  [System.Drawing.Graphics]::FromImage($bitmap).CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bitmap.Save((Join-Path $OutDir $name))
}
# The app writes what went wrong here, so a failure says why rather than only that it failed.
function Show-AppError {
  $log = Join-Path $env:APPDATA "PromptPetal\last-error.txt"
  if (Test-Path $log) { Write-Host "--- $log"; Get-Content $log | Select-Object -First 40 | ForEach-Object { Write-Host $_ } }
  Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { Write-Host "window: $($_.ProcessName) '$($_.MainWindowTitle)'" }
}
Save-Screen "before-ring-keys.png"
$before = Count-AppWindows
[RingKeys]::CtrlAltSpace()
Start-Sleep -Seconds 4
$open = Count-AppWindows
Save-Screen "ring-from-keyboard.png"
Write-Host "app windows: $before before the keys, $open after"
if ($open -le $before) {
  Show-AppError
  Write-Host "::error::Ctrl + Alt + Space did not open the ring: the app has $open visible windows, as many as before ($before)."
  exit 1
}
[RingKeys]::CtrlAltSpace()
Start-Sleep -Seconds 3
$closed = Count-AppWindows
Write-Host "app windows after pressing again: $closed"
if ($closed -ge $open) {
  Show-AppError
  Write-Host "::error::Pressing Ctrl + Alt + Space again did not close the ring."
  exit 1
}
Write-Host "Ctrl + Alt + Space opened the ring and closed it again."
