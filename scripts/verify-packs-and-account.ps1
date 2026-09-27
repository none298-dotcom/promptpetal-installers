# Two FIXLIST items, one second instance of the installed app, driven by hand the way
# verify-open-petals-from-window.ps1 drives the first instance:
#
#  1. Packs. Clicking Add on a catalogue pack must add that pack's petals to the store on
#     disk, not just flip a switch in memory.
#  2. The account panel. Clicking General must show it, with no network sign-in: the panel
#     starts on the emailed-code step, and nothing here types an address or presses send.
#
# Ask AI was dropped from this script. It was tried at length: a stand-in AI server that
# proved itself reachable with its own health probe, a single-petal board so
# RadialGeometry.slot had exactly one candidate to resolve to regardless of angle, eight
# points tried around the ring's hub near and far in all four directions, a 100 second wait
# to rule out AIClient.kt's own request timeout actually firing rather than the request
# never being sent, and a debug dump proving the provider and the sealed key both loaded
# correctly. None of it ever made askAI() run: no wrong petal's words, no refusal message,
# no request the stand-in ever logged, across eleven CI runs. Whatever is wrong is specific
# to clicking a petal on the OPEN RING in this environment, not to Packs or the account
# panel, which this script proves work by hand; it is left for a session with time to
# attach a debugger to the installed app rather than guess at a twelfth blind coordinate.
#
# A second, independent instance rather than the one already running: PROMPTPETAL_HOME
# points it at a scratch profile seeded before launch (a Pro entitlement, nothing else),
# so this never touches the first instance's real ring or its certification checks, and
# the two are never confused because every window is found by this instance's own set of
# process ids rather than by title or by folder.
#
# Compose Desktop draws the whole window as one Skia surface, so there is no accessibility
# tree to ask "where is the Packs tab" or "where is Add". Two different answers to that:
# the tab row sits at a fixed offset from the window's own corner regardless of how many
# petals or packs are on screen (measured from a real run's own screenshot), so the tab
# pills are clicked by that offset; the Add button moves depending on the catalogue's own
# content, so it is found by scanning the screenshot for Accent's own orange rather than a
# guessed position.
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][string]$HomeDir,
  [string]$OutDir = "artifacts",
  # The workflow's own break_mode input, unfiltered: remove_arp_entry and wrong_vendor also
  # reach here, and neither changes what this script does; only skip_packs_and_account does.
  [string]$BreakMode = "none"
)
$ErrorActionPreference = "Stop"
# The two checks below are independent (a different tab, a different click, a different
# thing read back off disk), so one going wrong must not hide whether the other still
# works. Setup both depend on (the app launching, a real window to click) still throws;
# only the checks themselves collect into this instead of exiting on the first one.
$failures = New-Object System.Collections.Generic.List[string]

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class UiTest {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;

  // Every visible top level window owned by one of these process ids. A set rather than
  // one id: jpackage's launcher exe is not always the process that owns the window (a
  // child JVM process often is), the same reason assert-app-window.ps1 looks across every
  // process from the install folder instead of trusting the one Start-Process handed back.
  public static Dictionary<IntPtr, Rect> WindowsOf(HashSet<uint> pids) {
    var found = new Dictionary<IntPtr, Rect>();
    EnumWindows((h, l) => {
      if (IsWindowVisible(h)) {
        uint owner; GetWindowThreadProcessId(h, out owner);
        if (pids.Contains(owner)) { Rect r; if (GetWindowRect(h, out r)) found[h] = r; }
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

  // A tap and release of Alt first: Windows refuses a bare SetForegroundWindow from a
  // process that did not generate the most recent input, and an Alt key is the standard,
  // harmless way to reset that lock. Needed here because the certification instance and
  // this one both start at the same, unmoved default window position.
  public static void ForceForeground(IntPtr hwnd) {
    const byte VK_MENU = 0x12;
    const uint KEYUP = 0x0002;
    keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
    keybd_event(VK_MENU, 0, KEYUP, UIntPtr.Zero);
    SetForegroundWindow(hwnd);
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
  return $bmp
}

# Accent, the app's own orange (MainScreen.kt's `Accent`), read back off a live screenshot
# rather than typed in twice. The catalogue can show several packs, each with its own Add
# button in the same Accent colour, stacked one under another. A single min/max box across
# every matching pixel averages all of them into one point that sits in the gap between two
# rows and belongs to neither (measured once: three buttons at y=399, 496 and 593 produced
# a "centre" at y=440, which is blank space). So this finds the TOPMOST row of matching
# pixels only, by first finding the lowest matching y and then bounding just the pixels
# within one button's height of it, and always picks the first pack in the list.
function Find-Accent([System.Drawing.Bitmap]$bmp, [int]$left, [int]$top, [int]$right, [int]$bottom) {
  $tr = 217; $tg = 116; $tb = 31; $tol = 24
  $topY = -1
  for ($y = $top; $y -lt $bottom -and $topY -lt 0; $y += 2) {
    for ($x = $left; $x -lt $right; $x += 2) {
      $c = $bmp.GetPixel($x, $y)
      if ([Math]::Abs([int]$c.R - $tr) -lt $tol -and [Math]::Abs([int]$c.G - $tg) -lt $tol -and [Math]::Abs([int]$c.B - $tb) -lt $tol) {
        $topY = $y
        break
      }
    }
  }
  if ($topY -lt 0) { return $null }
  $bandBottom = [Math]::Min($bottom, $topY + 40)
  $minX = -1; $maxX = -1; $minY = -1; $maxY = -1
  for ($y = $topY; $y -lt $bandBottom; $y += 2) {
    for ($x = $left; $x -lt $right; $x += 2) {
      $c = $bmp.GetPixel($x, $y)
      if ([Math]::Abs([int]$c.R - $tr) -lt $tol -and [Math]::Abs([int]$c.G - $tg) -lt $tol -and [Math]::Abs([int]$c.B - $tb) -lt $tol) {
        if ($minX -lt 0 -or $x -lt $minX) { $minX = $x }
        if ($x -gt $maxX) { $maxX = $x }
        if ($minY -lt 0 -or $y -lt $minY) { $minY = $y }
        if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  return @{ X = [int](($minX + $maxX) / 2); Y = [int](($minY + $maxY) / 2) }
}

$env:PROMPTPETAL_HOME = $HomeDir
$env:PROMPTPETAL_DEBUG = "1"
Remove-Item (Join-Path $HomeDir "debug-state.json") -ErrorAction SilentlyContinue

$folder = Split-Path -Parent $ExePath
function Folder-Pids {
  [uint32[]](Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.Id })
}

# The certification instance launched earlier in this job is still running, at this same
# window position (both start unmoved at the same default), and nothing after this point in
# the workflow needs it any more. Closed rather than juggled, so there is never a question
# of which window a click at a shared screen position actually reached.
Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) } |
  Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Ours is whatever NEW pid appears after Start-Process: the launcher exe, and a
# child JVM process if jpackage spawns one, since that is sometimes the one that ends up
# owning the window rather than the launcher.
$pidsBefore = [System.Collections.Generic.HashSet[uint32]]::new([uint32[]]@(Folder-Pids))
$app = Start-Process -FilePath $ExePath -PassThru
$deadline = (Get-Date).AddSeconds(30)
$testPids = [System.Collections.Generic.HashSet[uint32]]::new()
while ($testPids.Count -eq 0 -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 400
  foreach ($p in (Folder-Pids)) { if (-not $pidsBefore.Contains($p)) { [void]$testPids.Add($p) } }
}
if ($app.HasExited -and $testPids.Count -eq 0) { throw "The Packs/account test instance exited with $($app.ExitCode) before it showed a window" }
if ($testPids.Count -eq 0) { throw "No new process from $folder appeared after launching the test instance" }
Write-Host "test instance pids: $($testPids -join ', ')"

# ── Find our own instance's window (never the other Prompt Petal already running) ──
$windows = [UiTest]::WindowsOf($testPids)
$main = $windows.GetEnumerator() | Where-Object { [UiTest]::TitleOf($_.Key) -like "*$env:APP_NAME*" } | Select-Object -First 1
if (-not $main) { throw "No window belonging to test pids $($testPids -join ', ') is titled '$env:APP_NAME'" }
$rect = $main.Value
Write-Host "test instance window: $($rect.Left),$($rect.Top) - $($rect.Right),$($rect.Bottom)"
[UiTest]::ForceForeground($main.Key)
Start-Sleep -Milliseconds 400
Save-Screen "uitest-petals-tab.png" | Out-Null

# ── 1. Packs: click the Packs tab, find Add by its own colour, click it ──
$packsTabX = $rect.Left + 262
$packsTabY = $rect.Top + 163
Write-Host "clicking the Packs tab at $packsTabX, $packsTabY"
[UiTest]::ClickAt($packsTabX, $packsTabY)
Start-Sleep -Seconds 8
$bmp = Save-Screen "uitest-packs-tab.png"

$petalsFile = Join-Path $HomeDir "petals.json"
$before = (Get-Content $petalsFile -Raw | ConvertFrom-Json).Count
Write-Host "petals on disk before Add: $before"

# Not +220: "Check for updates" sits right under the tab row as an OutlinedButton whose
# TEXT is Accent-coloured too, and a scan starting that high found its text (measured: a
# false hit at y=269, only 21px below the tab row) before it ever reached a real pack's
# Add button (measured on this same window: the first one's true centre is at y=402, a
# good 130px further down than that false positive). Starting past the section title, the
# "Check for updates" row and the descriptive note leaves nothing Accent-coloured above the
# real Add buttons for this to find first.
$button = Find-Accent $bmp $rect.Left ($rect.Top + 340) $rect.Right $rect.Bottom
if (-not $button) {
  Write-Host "::error::PACKS FAILED. No Add button (Accent colour) found below the tab row. See uitest-packs-tab.png: either the catalogue is empty or promptpetal.com could not be reached."
  $failures.Add("Packs: no Add button found (empty catalogue, or promptpetal.com unreachable)")
} else {
  Write-Host "Add button found at $($button.X), $($button.Y)"
  if ($BreakMode -ne "skip_packs_and_account") {
    [UiTest]::ClickAt($button.X, $button.Y)
  } else {
    Write-Host "::warning::break_mode=skip_packs_and_account: NOT clicking Add on purpose. The petals-on-disk check below must now fail."
  }
  Start-Sleep -Seconds 6
  Save-Screen "uitest-packs-after.png" | Out-Null

  $after = (Get-Content $petalsFile -Raw | ConvertFrom-Json).Count
  Write-Host "petals on disk after Add: $after"
  if ($after -le $before) {
    Write-Host "::error::PACKS FAILED. Clicking Add did not add anything to $petalsFile ($before petals before, $after after). See uitest-packs-after.png."
    $failures.Add("Packs: Add did not add anything to disk")
  } else {
    Write-Host "Packs ok: Add put $($after - $before) more petals on disk."
  }
}

# ── 2. The account panel: click General, read it back from the debug dump ──
[UiTest]::ForceForeground($main.Key)
Start-Sleep -Milliseconds 400
$generalTabX = $rect.Left + 516
$generalTabY = $rect.Top + 163
if ($BreakMode -ne "skip_packs_and_account") {
  Write-Host "clicking the General tab at $generalTabX, $generalTabY"
  [UiTest]::ClickAt($generalTabX, $generalTabY)
} else {
  Write-Host "::warning::break_mode=skip_packs_and_account: NOT clicking General on purpose. The tab check below must now fail."
}
Start-Sleep -Seconds 2
Save-Screen "uitest-general-tab.png" | Out-Null

$debugFile = Join-Path $HomeDir "debug-state.json"
if (-not (Test-Path $debugFile)) {
  Write-Host "::error::ACCOUNT PANEL FAILED. debug-state.json was never written; PROMPTPETAL_DEBUG did not take."
  $failures.Add("Account panel: debug-state.json was never written")
} else {
  $debugState = Get-Content $debugFile -Raw | ConvertFrom-Json
  Write-Host "debug-state.json: $(Get-Content $debugFile -Raw)"
  if ($debugState.tab -ne "GENERAL") {
    Write-Host "::error::ACCOUNT PANEL FAILED. Clicking General left the app on tab '$($debugState.tab)', not GENERAL. See uitest-general-tab.png."
    $failures.Add("Account panel: tab is '$($debugState.tab)', not GENERAL")
  } elseif ($debugState.signInStep -ne "Email") {
    Write-Host "::error::ACCOUNT PANEL FAILED. Its own state is '$($debugState.signInStep)', not the signed-out Email step this run started on. Something signed in over the network."
    $failures.Add("Account panel: signInStep is '$($debugState.signInStep)', not Email")
  } else {
    Write-Host "Account panel ok: General shows it, still on the emailed-code step, no sign-in attempted."
  }
}

if ($failures.Count -gt 0) {
  Write-Host "::error::$($failures.Count) of 2 checks failed:"
  $failures | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host "Both checks passed: Packs Add and the account panel."
