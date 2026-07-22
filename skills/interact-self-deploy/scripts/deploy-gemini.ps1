[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^[a-z0-9]{20}$')]
  [string] $ProjectRef,

  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
  [string] $Model = 'gemini-3.6-flash'
)

. (Join-Path $PSScriptRoot 'common.ps1')

try { $Host.UI.RawUI.WindowTitle = 'InterAct - Paste NEW Gemini API key' } catch {}

$root = Get-InterActRoot
$apiKey = $null
$originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
  [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  while ([string]::IsNullOrWhiteSpace($apiKey)) {
    $candidate = Read-SecretText 'Paste only the Google AI Studio Gemini API key'
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      Write-Warning 'Gemini API key is required. Please try again.'
      continue
    }
    if ($candidate.Contains('...') -or $candidate.IndexOf([char]0x2026) -ge 0 -or $candidate -match '\*{3,}') {
      Write-Warning 'The pasted key is masked or truncated. Use the copy icon beside the key in Google AI Studio, then paste again.'
      $candidate = $null
      continue
    }
    if ($candidate -notmatch '^[A-Za-z0-9._~-]{20,512}$') {
      Write-Warning 'The pasted value contains unsupported characters, whitespace, or is too short. Copy only the complete key value, then paste again.'
      $candidate = $null
      continue
    }

    try {
      $modelUri = "https://generativelanguage.googleapis.com/v1beta/models/$([Uri]::EscapeDataString($Model))"
      $modelInfo = Invoke-RestMethod -Method Get -Uri $modelUri -Headers @{ 'x-goog-api-key' = $candidate } -TimeoutSec 30
    } catch {
      $statusCode = $null
      if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
        $statusCode = [int] $_.Exception.Response.StatusCode
      }
      $candidate = $null
      if ($statusCode -in @(400, 401, 403)) {
        Write-Warning 'Google rejected this key or its API restrictions. Copy the current AI Studio key and try again.'
        continue
      }
      if ($statusCode -eq 404) { throw "Gemini model $Model is not available in this project." }
      if ($statusCode -eq 429) { throw 'Google rejected validation because the project is rate-limited or out of quota.' }
      throw 'Could not validate Gemini because of a network, TLS, or Google service error.'
    }

    if ($modelInfo.name -cne "models/$Model") {
      $candidate = $null
      throw "Google returned unexpected metadata for Gemini model $Model."
    }
    if (-not (@($modelInfo.supportedGenerationMethods) -contains 'generateContent')) {
      $candidate = $null
      throw "Gemini model $Model does not support generateContent."
    }

    $apiKey = $candidate
    $candidate = $null
    $modelInfo = $null
    Write-Host "Gemini key and model $Model validated by Google." -ForegroundColor Green
  }
} finally {
  [Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
}

$secretFile = [IO.Path]::GetTempFileName()
$cliModeArgs = @('--agent', 'no', '--output-format', 'text')
$aiFunctions = @(
  'ai-exit-ticket-summary',
  'ai-screen-preview',
  'ai-short-answer-summary',
  'analyze-question',
  'analyze-session',
  'generate-exit-ticket'
)

Push-Location $root
try {
  Write-Utf8NoBom $secretFile "GEMINI_API_KEY=$apiKey`nGEMINI_MODEL=$Model`n"
  Invoke-Checked 'pnpm.cmd' (@('dlx', 'supabase', 'secrets', 'set', '--project-ref', $ProjectRef, '--env-file', $secretFile) + $cliModeArgs)
  $apiKey = $null
  if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
  Invoke-Checked 'pnpm.cmd' (@('dlx', 'supabase', 'functions', 'deploy') + $aiFunctions + @('--project-ref', $ProjectRef, '--no-verify-jwt', '--use-api') + $cliModeArgs)
  Write-Host "Gemini deployment completed with model $Model." -ForegroundColor Green
} finally {
  $apiKey = $null
  if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
  Pop-Location
}
