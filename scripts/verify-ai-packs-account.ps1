# Three FIXLIST items in one script, one second instance of the installed app, driven by
# hand the way verify-open-petals-from-window.ps1 drives the first instance:
#
#  1. Ask AI. A ring petal whose action is "ai_transform" sends its prompt to
#     PROMPTPETAL_AI_BASE (AIClient.kt), which this run points at a stand-in HTTP server
#     instead of a real AI service, with a dummy key sealed the same way a real one is
#     (WindowsKeyStore, DPAPI, CurrentUser). Clicking that petal in the ring must type the
#     stand-in's fixed answer into Notepad, and the stand-in must show it was actually asked.
#  2. Packs. Clicking Add on a catalogue pack must add that pack's petals to the store on
#     disk, not just flip a switch in memory.
#  3. The account panel. Clicking General must show it, with no network sign-in: the panel
#     starts on the emailed-code step, and nothing here types an address or presses send.
#
# A second, independent instance rather than the one already running: PROMPTPETAL_HOME
# points it at a scratch profile seeded before launch (a Pro entitlement, one Ask AI petal,
# a saved dummy key), so this never touches the first instance's real ring or its
# certification checks, and the two are never confused because every window is found by
# this instance's own process id rather than by title or by folder.
#
# Compose Desktop draws the whole window as one Skia surface, so there is no accessibility
# tree to ask "where is the Packs tab" or "where is Add". Two different answers to that:
# the tab row sits at a fixed offset from the window's own corner regardless of how many
# petals or packs are on screen (measured once from a real run's own screenshot, the same
# way every other coordinate in this workflow was measured), so the tab pills are clicked
# by that offset; the Add button moves depending on the catalogue's own content, so it is
# found by scanning the screenshot for Accent's own orange rather than guessing a position.
param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][string]$HomeDir,
  [Parameter(Mandatory=$true)][string]$AiBase,
  [Parameter(Mandatory=$true)][string]$AiStubLogPath,
  [Parameter(Mandatory=$true)][string]$ExpectedAnswer,
  [string]$OutDir = "artifacts",
  # The workflow's own break_mode input, unfiltered: wrong_ai_answer, remove_arp_entry and
  # wrong_vendor all reach here too, and none of them change what this script does, only
  # what the stand-in server answers with or what an earlier step already checked.
  [string]$BreakMode = "none"
)
$ErrorActionPreference = "Stop"
# Each of the three checks below is independent of the other two (a different tab, a
# different click, a different thing read back off disk), so one going wrong must not hide
# whether the other two still work. Setup that all three depend on (the app launching, a
# real window to click) still throws and stops the run; only the three checks themselves
# collect into this instead of exiting on the first one.
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
  [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowTitle);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int SendMessage(IntPtr hwnd, int msg, int wParam, StringBuilder lParam);
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
  // harmless way to reset that lock (it never reaches whatever window ends up frontmost,
  // since nothing here is a menu). Needed here and nowhere else in this workflow because
  // this is the only script asking two windows apart that sit in the exact same rectangle.
  public static void ForceForeground(IntPtr hwnd) {
    const byte VK_MENU = 0x12;
    const uint KEYUP = 0x0002;
    keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
    keybd_event(VK_MENU, 0, KEYUP, UIntPtr.Zero);
    SetForegroundWindow(hwnd);
  }

  public static void PressEscape() {
    const byte VK_ESCAPE = 0x1B;
    const uint KEYUP = 0x0002;
    keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
    keybd_event(VK_ESCAPE, 0, KEYUP, UIntPtr.Zero);
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
  return $bmp
}

# Accent, the app's own orange (MainScreen.kt's `Accent`), read back off a live screenshot
# rather than typed in twice: the one place it is a literal is Save-Screen's own capture.
function Find-Accent([System.Drawing.Bitmap]$bmp, [int]$left, [int]$top, [int]$right, [int]$bottom) {
  $tr = 217; $tg = 116; $tb = 31; $tol = 24
  $minX = -1; $maxX = -1; $minY = -1; $maxY = -1
  for ($y = $top; $y -lt $bottom; $y += 2) {
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
  if ($minX -lt 0) { return $null }
  return @{ X = [int](($minX + $maxX) / 2); Y = [int](($minY + $maxY) / 2) }
}

$env:PROMPTPETAL_HOME = $HomeDir
$env:PROMPTPETAL_AI_BASE = $AiBase
$env:PROMPTPETAL_DEBUG = "1"
Remove-Item (Join-Path $HomeDir "debug-state.json") -ErrorAction SilentlyContinue

$folder = Split-Path -Parent $ExePath
function Folder-Pids {
  [uint32[]](Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $_.Id })
}

# The certification instance launched earlier in this job is still running, at this same
# window position (both start unmoved at the same default), and nothing after this point in
# the workflow needs it any more. Closed rather than juggled: ForegroundApp.kt's own
# foreground poller runs per PROCESS ("if (pid.value.toLong() != me)"), so it has no idea a
# second Prompt Petal even exists, and if that instance's window is ever the one Windows
# reports as foreground for even one 400ms tick, this instance quietly records IT as "the
# last window that was not Prompt Petal" and later pastes Ask AI's answer into it instead
# of Notepad, with nothing on screen to say so. One Prompt Petal process removes the
# question entirely.
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
if ($app.HasExited -and $testPids.Count -eq 0) { throw "The Ask AI / Packs / account test instance exited with $($app.ExitCode) before it showed a window" }
if ($testPids.Count -eq 0) { throw "No new process from $folder appeared after launching the test instance" }
Write-Host "test instance pids: $($testPids -join ', ')"

# ── Notepad, with real typing, the way the certifier's own script gets a target to paste into ──
#
# A Notepad from an earlier step in this same job may still be open. Closed rather than
# reused: a second Notepad launched on top of it is how a click meant for the new window
# lands on the old one instead, and the words go somewhere this script never reads back.
Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$notepad = Start-Process notepad.exe -PassThru
$deadline = (Get-Date).AddSeconds(15)
while ($notepad.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; $notepad.Refresh() }
if ($notepad.MainWindowHandle -eq 0) { throw "Notepad never showed a window" }
$npRect = New-Object UiTest+Rect
[void][UiTest]::GetWindowRect($notepad.MainWindowHandle, [ref]$npRect)
# The title bar first, the same reason verify-open-petals-from-window.ps1 clicks Prompt
# Petal's own title bar before anything else: a click alone does not always move the
# foreground away from whatever already owned it.
[UiTest]::ForceForeground($notepad.MainWindowHandle)
[UiTest]::ClickAt([int](($npRect.Left + $npRect.Right) / 2), $npRect.Top + 15)
Start-Sleep -Milliseconds 400
[UiTest]::ClickAt([int](($npRect.Left + $npRect.Right) / 2), [int](($npRect.Top + $npRect.Bottom) / 2))
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait("Before Ask AI.`r`n")
Start-Sleep -Milliseconds 500
if ([UiTest]::NotepadText($notepad.MainWindowHandle) -notlike "*Before Ask AI*") {
  Save-Screen "uitest-notepad-setup-failed.png" | Out-Null
  throw "Test setup failed: typing never reached Notepad. See uitest-notepad-setup-failed.png."
}

# ── Find our own instance's window (never the other Prompt Petal already running) ──
$windows = [UiTest]::WindowsOf($testPids)
$main = $windows.GetEnumerator() | Where-Object { [UiTest]::TitleOf($_.Key) -like "*$env:APP_NAME*" } | Select-Object -First 1
if (-not $main) { throw "No window belonging to test pids $($testPids -join ', ') is titled '$env:APP_NAME'" }
$rect = $main.Value
Write-Host "test instance window: $($rect.Left),$($rect.Top) - $($rect.Right),$($rect.Bottom)"

# ── 1. Ask AI: Open Petals, click the one petal on this ring, read what landed ──
#
# This window and the certification instance's window both start at the same, unmoved
# default position, so they occupy the same screen rectangle. SetForegroundWindow first,
# not just a click on the title bar: whichever window is already on top there receives an
# ordinary click regardless of which hwnd this script means, the exact reason a leftover
# Notepad had to be closed above rather than clicked past.
[UiTest]::ForceForeground($main.Key)
Start-Sleep -Milliseconds 400
Save-Screen "uitest-petals-tab.png" | Out-Null
[UiTest]::ClickAt($rect.Left + 200, $rect.Top + 15)
Start-Sleep -Milliseconds 500
$openPetalsX = $rect.Right - 92
$openPetalsY = $rect.Top + 87
Write-Host "clicking Open Petals at $openPetalsX, $openPetalsY"
[UiTest]::ClickAt($openPetalsX, $openPetalsY)

$deadline = (Get-Date).AddSeconds(6)
$ring = $null
while (-not $ring -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 300
  $after = [UiTest]::WindowsOf($testPids)
  $newOnes = $after.GetEnumerator() | Where-Object { -not $windows.ContainsKey($_.Key) }
  $ring = $newOnes | Select-Object -First 1
}
if (-not $ring) { Save-Screen "uitest-no-ring.png" | Out-Null; throw "Clicking Open Petals did not open a ring" }
foreach ($w in $newOnes) {
  Write-Host "new window: hwnd=$($w.Key) title='$([UiTest]::TitleOf($w.Key))' rect=$($w.Value.Left),$($w.Value.Top)-$($w.Value.Right),$($w.Value.Bottom)"
}
$ringHandle = $ring.Key
Save-Screen "uitest-ring-open.png" | Out-Null
Start-Sleep -Milliseconds 1200
# Re-read the rect after the wait rather than trusting the one caught at creation:
# RingArrangement's own window size depends on how wide every label is (`half` grows to
# fit the longest name), and this ring's names ("Ask AI Test", "Dummy One"...) are not the
# five short defaults every other script on this window ever shows, so the window this
# ring settles into is not necessarily the size it was first created at.
$ringRect = New-Object UiTest+Rect
[void][UiTest]::GetWindowRect($ringHandle, [ref]$ringRect)
$centerX = [int](($ringRect.Left + $ringRect.Right) / 2)
$centerY = [int](($ringRect.Top + $ringRect.Bottom) / 2)
# A fraction of this ring's own half height, not a fixed pixel count: outside the hub's
# dead zone and inside slot 0's wedge whatever this ring's actual radius turns out to be,
# since the wedge test is angle only (RadialGeometry.slot), never distance. With exactly
# one petal on this board, ringPickSlot has exactly one candidate to resolve to regardless
# of which direction the click comes from, so several points are tried rather than one:
# whichever one this ring is actually drawn at, one of these should land past its own hub
# dead zone and inside its wedge.
$half = ($ringRect.Bottom - $ringRect.Top) / 2
$near = [int]($half * 0.3)
$far = [int]($half * 0.6)
$debugFile = Join-Path $HomeDir "debug-state.json"
$candidates = @(
  @{ Name = "up-far"; X = $centerX; Y = $centerY - $far },
  @{ Name = "down-far"; X = $centerX; Y = $centerY + $far },
  @{ Name = "left-far"; X = $centerX - $far; Y = $centerY },
  @{ Name = "right-far"; X = $centerX + $far; Y = $centerY },
  @{ Name = "up-near"; X = $centerX; Y = $centerY - $near },
  @{ Name = "down-near"; X = $centerX; Y = $centerY + $near },
  @{ Name = "left-near"; X = $centerX - $near; Y = $centerY },
  @{ Name = "right-near"; X = $centerX + $near; Y = $centerY }
)
Write-Host "ring window: $($ringRect.Left),$($ringRect.Top) - $($ringRect.Right),$($ringRect.Bottom), center $centerX,$centerY"
foreach ($c in $candidates) {
  if (Test-Path $debugFile) { break }
  Write-Host "trying the Ask AI petal at $($c.Name): $($c.X), $($c.Y)"
  [UiTest]::ClickAt($c.X, $c.Y)
  Start-Sleep -Milliseconds 900
}

# askAI() runs the request on a background thread and pastes only once it comes back, so
# this polls rather than trusting one fixed pause: a screenshot from a run that used a flat
# 2.5s wait caught the app still mid-request, a small loading flower still on the tab bar.
# AIClient.kt's own HttpRequest carries a 90 second timeout, so this waits long enough to
# find out whether the request is genuinely stuck rather than merely slow.
$notepadText = $null
$deadline = (Get-Date).AddSeconds(100)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  $notepadText = [UiTest]::NotepadText($notepad.MainWindowHandle)
  if ($notepadText -like "*$ExpectedAnswer*") { break }
}
Save-Screen "uitest-ask-ai-after.png" | Out-Null

# Whether or not that landed, the ring must not be left open: none of the eight tries
# above closing it (as a successful pick always does) is itself evidence something is
# still wrong with it, and an open ring is a real window sitting over part of the main
# window underneath, ready to silently eat a click meant for a tab.
[UiTest]::PressEscape()
Start-Sleep -Milliseconds 500

Write-Host "Notepad now reads: $notepadText"
if ($notepadText -notlike "*$ExpectedAnswer*") {
  $debugFile = Join-Path $HomeDir "debug-state.json"
  if (Test-Path $debugFile) { Write-Host "debug-state.json: $(Get-Content $debugFile -Raw)" }
  else { Write-Host "debug-state.json was never written for this click" }
  Write-Host "::error::Ask AI FAILED. Notepad has no '$ExpectedAnswer'. See uitest-ask-ai-after.png."
  $failures.Add("Ask AI: the stand-in's answer never reached Notepad")
} elseif (-not (Test-Path $AiStubLogPath) -or (Get-Content $AiStubLogPath).Count -eq 0) {
  Write-Host "::error::Ask AI FAILED. The stand-in server logged no request: the app never asked it."
  $failures.Add("Ask AI: the stand-in server logged no request")
} else {
  Write-Host "stand-in server received:"
  Get-Content $AiStubLogPath | ForEach-Object { Write-Host "  $_" }
  if (-not (Select-String -Path $AiStubLogPath -Pattern "x-api-key=\S")) {
    Write-Host "::error::Ask AI FAILED. The request the stand-in logged carried no x-api-key, so the saved key never made it into the request."
    $failures.Add("Ask AI: the request carried no x-api-key")
  } else {
    Write-Host "Ask AI ok: the stand-in's answer reached Notepad, with the saved key on the request."
  }
}

# ── 2. Packs: click the Packs tab, find Add by its own colour, click it ──
[UiTest]::ForceForeground($main.Key)
Start-Sleep -Milliseconds 400
$packsTabX = $rect.Left + 262
$packsTabY = $rect.Top + 163
Write-Host "clicking the Packs tab at $packsTabX, $packsTabY"
[UiTest]::ClickAt($packsTabX, $packsTabY)
Start-Sleep -Seconds 8
$bmp = Save-Screen "uitest-packs-tab.png"

$petalsFile = Join-Path $HomeDir "petals.json"
$before = (Get-Content $petalsFile -Raw | ConvertFrom-Json).Count
Write-Host "petals on disk before Add: $before"

$button = Find-Accent $bmp $rect.Left ($rect.Top + 220) $rect.Right $rect.Bottom
if (-not $button) {
  Write-Host "::error::PACKS FAILED. No Add button (Accent colour) found below the tab row. See uitest-packs-tab.png: either the catalogue is empty or promptpetal.com could not be reached."
  $failures.Add("Packs: no Add button found (empty catalogue, or promptpetal.com unreachable)")
} else {
  Write-Host "Add button found at $($button.X), $($button.Y)"
  if ($BreakMode -ne "skip_packs_add") {
    [UiTest]::ClickAt($button.X, $button.Y)
  } else {
    Write-Host "::warning::break_mode=skip_packs_add: NOT clicking Add on purpose. The petals-on-disk check below must now fail."
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

# ── 3. The account panel: click General, read it back from the debug dump ──
[UiTest]::ForceForeground($main.Key)
Start-Sleep -Milliseconds 400
$generalTabX = $rect.Left + 516
$generalTabY = $rect.Top + 163
if ($BreakMode -ne "skip_account_click") {
  Write-Host "clicking the General tab at $generalTabX, $generalTabY"
  [UiTest]::ClickAt($generalTabX, $generalTabY)
} else {
  Write-Host "::warning::break_mode=skip_account_click: NOT clicking General on purpose. The tab check below must now fail."
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
  Write-Host "::error::$($failures.Count) of 3 checks failed:"
  $failures | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host "All three checks passed: Ask AI, Packs Add, and the account panel."
