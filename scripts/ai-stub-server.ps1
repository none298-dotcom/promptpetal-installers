# A stand-in for the real AI service, so Ask AI can be driven end to end on CI without a
# real key or a real network call to Anthropic, Gemini or OpenAI.
#
# AIClient.kt already honors PROMPTPETAL_AI_BASE: it sends the request to that base URL
# instead of the provider's own host, keeping the provider's own path
# (AIRequest.build's "/v1/messages" for Anthropic). So this only has to answer that one
# path the shape AIRequest.answer expects back, and remember that it was asked.
#
# A separate process rather than a background job in the calling shell: HttpListener needs
# an event loop of its own, and a here-string with a C# type at column zero would end the
# YAML block if this were inline in the workflow, the same reason every other P/Invoke
# script here is its own file.
param(
  [int]$Port = 8791,
  [string]$AnswerText = "The stand-in server answered.",
  [Parameter(Mandatory=$true)][string]$LogPath,
  [Parameter(Mandatory=$true)][string]$StopFile,
  [int]$IdleTimeoutSeconds = 180
)
$ErrorActionPreference = "Stop"

Remove-Item $LogPath -ErrorAction SilentlyContinue
Remove-Item $StopFile -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Split-Path $LogPath) | Out-Null

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "AI stub listening on http://127.0.0.1:$Port/, answering with '$AnswerText'"

# Anthropic's own shape: content is a list of parts, the text ones concatenated.
# AIRequest.answer(ANTHROPIC, ...) reads exactly this back.
function Escape-Json([string]$s) {
  $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}
$body = '{"content":[{"type":"text","text":"' + (Escape-Json $AnswerText) + '"}]}'
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)

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
  $request = $context.Request
  $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
  $requestBody = $reader.ReadToEnd()
  $reader.Close()
  $apiKey = $request.Headers["x-api-key"]
  $line = "$(Get-Date -Format o)  $($request.HttpMethod) $($request.Url.AbsolutePath)  x-api-key=$($apiKey)  body=$requestBody"
  Add-Content -Path $LogPath -Value $line
  Write-Host "AI stub got: $line"

  $response = $context.Response
  $response.StatusCode = 200
  $response.ContentType = "application/json"
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.OutputStream.Close()
}
$listener.Stop()
Write-Host "AI stub stopped"
