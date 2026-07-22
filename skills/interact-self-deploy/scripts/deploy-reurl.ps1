[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^[a-z0-9]{20}$')]
  [string] $ProjectRef
)

. (Join-Path $PSScriptRoot 'common.ps1')

try { $Host.UI.RawUI.WindowTitle = 'InterAct - Paste Reurl.cc API key' } catch {}

$root = Get-InterActRoot
$apiKey = $null
while ([string]::IsNullOrWhiteSpace($apiKey)) {
  $candidate = Read-SecretText 'Paste only the Reurl.cc API key'
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    Write-Warning 'Reurl API key is required. Please try again.'
    continue
  }
  if ($candidate.Contains('...') -or $candidate.IndexOf([char]0x2026) -ge 0 -or $candidate -match '\*{3,}') {
    Write-Warning 'The pasted key is masked or truncated. Use the Reurl copy control, then paste again.'
    $candidate = $null
    continue
  }
  if ($candidate -notmatch '^[\x21-\x7E]{20,512}$') {
    Write-Warning 'The pasted value contains whitespace, non-ASCII characters, or is incomplete. Copy only the complete key value.'
    $candidate = $null
    continue
  }
  $apiKey = $candidate
  $candidate = $null
}

$secretFile = [IO.Path]::GetTempFileName()
$cliModeArgs = @('--agent', 'no', '--output-format', 'text')

Push-Location $root
try {
  Write-Utf8NoBom $secretFile "REURL_API_KEY=$apiKey`n"
  Invoke-Checked 'pnpm.cmd' (@('dlx', 'supabase', 'secrets', 'set', '--project-ref', $ProjectRef, '--env-file', $secretFile) + $cliModeArgs)
  $apiKey = $null
  if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
  Invoke-Checked 'pnpm.cmd' (@('dlx', 'supabase', 'functions', 'deploy', 'shorten-url', '--project-ref', $ProjectRef, '--no-verify-jwt', '--use-api') + $cliModeArgs)
  Write-Host 'Reurl deployment completed.' -ForegroundColor Green
} finally {
  $apiKey = $null
  if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
  Pop-Location
}
