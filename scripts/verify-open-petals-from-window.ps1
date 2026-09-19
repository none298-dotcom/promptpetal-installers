# Reproduces Microsoft's 10.1.2.10 rejection of 09/17 exactly as their tester described
# it:
#   1. Launch the product
#   2. Open Notepad and type some text
#   3. Click "Open Petals" in the window and pick a petal
#   4. Notice nothing happened
#
# Pressing the global shortcut (press-ring-shortcut.ps1) never exercised this path: that
# summons the ring over whatever app was already focused, so the paste always had
# somewhere real to land. The button in Prompt Petal's own window is different, because
# clicking it makes PROMPT PETAL the frontmost window, and a synthesized Ctrl+V with
# nothing done about that lands back in Prompt Petal. That is the bug the certifier
# found, and this script is the one place in this workflow that clicks the button the
# way a person, and the certifier, actually would: by its position in the window, not by
# a shortcut key.
#
# A separate file rather than inline in the workflow, for the same reason
# press-ring-shortcut.ps1 is: the P/Invoke needs a here-string whose closing "@ has to
# sit at column zero, and a line at column zero ends a YAML block.
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [string]$OutDir = "artifacts",
  [string]$TypedText = "Testing certification steps. Cursor is right after this line.`r`n"
)
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class OpenPetalsClick {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowTitle);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int SendMessage(IntPtr hwnd, int msg, int wParam, StringBuilder lParam);
  [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

  const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;
  const int WM_GETTEXTLENGTH = 0x000E, WM_GETTEXT = 0x000D;

  // Every visible top level window owned by one of these process ids, with its rect.
  public static Dictionary<IntPtr, Rect> VisibleWindows(HashSet<uint> pids) {
    var found = new Dictionary<IntPtr, Rect>();
    EnumWindows((h, l) => {
      if (IsWindowVisible(h)) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (pids.Contains(pid)) { Rect r; if (GetWindowRect(h, out r)) found[h] = r; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string TitleOf(IntPtr hwnd) {
    var sb = new StringBuilder(256);
    GetWindowText(hwnd, sb, sb.Capacity);
    return sb.ToString();
  }

  public static void ClickAt(int x, int y) {
    SetCursorPos(x, y);
    mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
  }

  // The classic Win32 edit control Notepad has held since long before this app existed.
  // windows-2022 ships that Notepad, not the newer one, which is exactly why the
  // workflow is pinned to that image rather than windows-latest.
  public static string NotepadText(IntPtr notepadWindow) {
    IntPtr edit = FindWindowEx(notepadWindow, IntPtr.Zero, "Edit", null);
    if (edit == IntPtr.Zero) return null;
    int length = SendMessage(edit, WM_GETTEXTLENGTH, 0, null);
    var buffer = new StringBuilder(length + 1);
    SendMessage(edit, WM_GETTEXT, buffer.Capacity, buffer);
    return buffer.ToString();
  }
}
"@

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
function Save-Screen([string]$name) {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  [System.Drawing.Graphics]::FromImage($bitmap).CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bitmap.Save((Join-Path $OutDir $name))
}

$folder = Split-Path -Parent $ExePath
function App-Pids {
  [uint32[]](Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.Id })
}

# ── Step 1 and 2: open Notepad, type some text ──────────────────────────────
$notepad = Start-Process notepad.exe -PassThru
$deadline = (Get-Date).AddSeconds(15)
while ($notepad.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; $notepad.Refresh() }
if ($notepad.MainWindowHandle -eq 0) { throw "Notepad never showed a window" }
[void][OpenPetalsClick]::SetForegroundWindow($notepad.MainWindowHandle)
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait($TypedText.Replace("{", "{{}").Replace("}", "{}}"))
Start-Sleep -Milliseconds 300
Save-Screen "open-petals-before.png"

# ── Step 3a: bring Prompt Petal's own window back to the front ─────────────
# Exactly what a person did to trigger the rejection: Notepad was in front, and now
# Prompt Petal is asked for by name, the way Alt+Tab or clicking its taskbar icon would.
$appPids = [System.Collections.Generic.HashSet[uint32]]::new([uint32[]](App-Pids))
if ($appPids.Count -eq 0) { throw "No Prompt Petal process is running from $folder" }
$before = [OpenPetalsClick]::VisibleWindows($appPids)
$main = $before.GetEnumerator() | Where-Object { [OpenPetalsClick]::TitleOf($_.Key) -like "*$env:APP_NAME*" } | Select-Object -First 1
if (-not $main) { throw "No visible Prompt Petal window to click Open Petals in" }
[void][OpenPetalsClick]::SetForegroundWindow($main.Key)
Start-Sleep -Milliseconds 500

# ── Step 3b: click "Open Petals" by its position in that window ────────────
# Header.kt puts it at the right edge of a 28dp padded row, level with the title. There
# is no accessibility tree to ask for it by name: Compose Desktop draws the whole window
# as one Skia surface with nothing else for Windows to see, so this is a coordinate, the
# way a real click is.
$rect = $main.Value
$openPetalsX = $rect.Right - 100
$openPetalsY = $rect.Top + 50
Write-Host "clicking Open Petals at $openPetalsX, $openPetalsY (window $($rect.Left),$($rect.Top) - $($rect.Right),$($rect.Bottom))"
[OpenPetalsClick]::ClickAt($openPetalsX, $openPetalsY)

# ── Step 3c: wait for the ring, then click the first petal ─────────────────
# Slot 0 is fixed at the top of the flower (RadialGeometry.fullRingAngles), and the
# angular sector it owns reaches out from the hub's dead zone to past every petal's tip,
# so anywhere on the vertical line above the hub, short of the window's own edge, lands
# on it. No need to know the exact radius the five default petals were drawn at.
$deadline = (Get-Date).AddSeconds(6)
$ring = $null
while (-not $ring -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 300
  $after = [OpenPetalsClick]::VisibleWindows($appPids)
  $ring = $after.GetEnumerator() | Where-Object { -not $before.ContainsKey($_.Key) } | Select-Object -First 1
}
if (-not $ring) {
  Save-Screen "open-petals-no-ring.png"
  throw "Clicking Open Petals did not open a new window. See open-petals-no-ring.png."
}
$ringRect = $ring.Value
$centerX = [int](($ringRect.Left + $ringRect.Right) / 2)
$centerY = [int](($ringRect.Top + $ringRect.Bottom) / 2)
$petalX = $centerX
$petalY = $centerY - 70
Write-Host "clicking the first petal at $petalX, $petalY (ring window $($ringRect.Left),$($ringRect.Top) - $($ringRect.Right),$($ringRect.Bottom))"
[OpenPetalsClick]::ClickAt($petalX, $petalY)
Start-Sleep -Milliseconds 800
Save-Screen "open-petals-after.png"

# ── Step 4: read what actually landed in Notepad ────────────────────────────
$text = [OpenPetalsClick]::NotepadText($notepad.MainWindowHandle)
if ($null -eq $text) { throw "Could not read Notepad's own text (its Edit control was not found)" }
Write-Host "Notepad now reads:"
Write-Host $text
$expected = "Research the following thoroughly"
if ($text -notlike "*$expected*") {
  Write-Host "::error::10.1.2.10 FAILED. Clicking Open Petals in the window and picking a petal did not type the prompt into Notepad. Notepad's text has no '$expected'. This is exactly what Microsoft's certifier reported: 'Notice nothing happened.' See open-petals-before.png and open-petals-after.png."
  exit 1
}
Write-Host "10.1.2.10 ok: the petal's words reached Notepad, not Prompt Petal's own window."
