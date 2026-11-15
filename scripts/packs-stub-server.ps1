# A stand-in for promptpetal.com's packs list, so Packs Add can be driven on CI without the
# live site. GitHub's runners are refused by the site (403), which left the Packs page empty
# with no Add button to click.
#
# The app honors PROMPTPETAL_PACKS_BASE (Packs.kt) the way it honors PROMPTPETAL_AI_BASE for
# Ask AI. This answers the two paths it asks: the list and one pack.
param(
  [int]$Port = 8793,
  [Parameter(Mandatory=$true)][string]$StopFile,
  [int]$IdleTimeoutSeconds = 240
)
$ErrorActionPreference = "Stop"
Remove-Item $StopFile -ErrorAction SilentlyContinue

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Packs stub listening on http://127.0.0.1:$Port/"

$catalog = '{"packs":[{"id":"stub","name":"Test pack","summary":"A pack served by the test.","iconSystemName":"star","version":1,"count":2,"updatedAt":"2026-09-10T00:00:00Z"}]}'
$pack = '{"id":"stub","name":"Test pack","summary":"A pack served by the test.","iconSystemName":"star","version":1,"entries":[{"id":"stub-one","name":"Stub one","iconSystemName":"star","template":"Stub one: {{selection}}"},{"id":"stub-two","name":"Stub two","iconSystemName":"star","template":"Stub two: {{selection}}"}]}'

$deadline = (Get-Date).AddSeconds($IdleTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $StopFile) { break }
  $async = $listener.BeginGetContext($null, $null)
  while (-not $async.IsCompleted) {
    Start-Sleep -Milliseconds 150
    if (Test-Path $StopFile) { break }
    if ((Get-Date) -ge $deadline) { break }
  }
  if (-not $async.IsCompleted) { continue }
  $context = $listener.EndGetContext($async)
  $path = $context.Request.Url.AbsolutePath.TrimEnd('/')
  Write-Host "Packs stub got: $($context.Request.HttpMethod) $path"
  $body = if ($path -eq "/api/packs/stub") { $pack } elseif ($path -eq "/api/packs") { $catalog } else { $null }
  $response = $context.Response
  if ($null -eq $body) {
    $response.StatusCode = 404
    $response.OutputStream.Close()
  } else {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.StatusCode = 200
    $response.ContentType = "application/json"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
  }
}
$listener.Stop()
Write-Host "Packs stub stopped"
