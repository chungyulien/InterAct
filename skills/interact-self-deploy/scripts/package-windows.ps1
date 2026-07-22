[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^https://[a-z0-9]+\.supabase\.co/?$')]
  [string] $SupabaseUrl,

  [Parameter(Mandatory)]
  [string] $PublishableKey,

  [Parameter(Mandatory)]
  [ValidatePattern('^https://')]
  [string] $PublicAppUrl
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($PublishableKey -notmatch '^sb_publishable_[A-Za-z0-9_-]{20,}$') {
  throw 'PublishableKey must be a modern Supabase sb_publishable_ key. Secret, service-role, Gemini, and Reurl keys are not allowed.'
}

$publicUri = $null
if (-not [Uri]::TryCreate($PublicAppUrl, [UriKind]::Absolute, [ref] $publicUri) -or
    $publicUri.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($publicUri.Query) -or
    -not [string]::IsNullOrEmpty($publicUri.Fragment) -or
    $publicUri.AbsolutePath -match '/index\.html/?$') {
  throw 'PublicAppUrl must be a plain HTTPS GitHub Pages base URL without query, fragment, or index.html.'
}

$root = Get-InterActRoot
$envPath = Join-Path $root '.env'
$output = Join-Path $env:TEMP ("InterAct-package-{0}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$outputFullPath = [IO.Path]::GetFullPath($output)
if (-not $outputFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($outputFullPath) -notlike 'InterAct-package-*') {
  throw 'Refusing to use a package output directory outside the Windows temp directory.'
}
$frontendVariableNames = @('VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY', 'VITE_PUBLIC_APP_URL')
$previousFrontendVariables = @{}
foreach ($name in $frontendVariableNames) {
  $previousFrontendVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$envContent = @"
VITE_SUPABASE_URL=$($SupabaseUrl.TrimEnd('/'))
VITE_SUPABASE_ANON_KEY=$PublishableKey
VITE_PUBLIC_APP_URL=$($PublicAppUrl.TrimEnd('/'))
"@

Push-Location $root
try {
  Write-Utf8NoBom $envPath ($envContent.Trim() + "`n")
  [Environment]::SetEnvironmentVariable('VITE_SUPABASE_URL', $SupabaseUrl.TrimEnd('/'), 'Process')
  [Environment]::SetEnvironmentVariable('VITE_SUPABASE_ANON_KEY', $PublishableKey, 'Process')
  [Environment]::SetEnvironmentVariable('VITE_PUBLIC_APP_URL', $PublicAppUrl.TrimEnd('/'), 'Process')
  Invoke-Checked 'pnpm.cmd' @('install', '--frozen-lockfile')
  Invoke-Checked 'pnpm.cmd' @('build')
  Invoke-Checked 'pnpm.cmd' @('exec', 'electron-builder', '--win', 'portable', '--x64', "--config.directories.output=$output")

  $source = Join-Path $output 'interact.exe'
  if (-not (Test-Path -LiteralPath $source)) { throw 'electron-builder did not produce interact.exe.' }
  Copy-Item -LiteralPath $source -Destination (Join-Path $root 'interact.exe') -Force
  Get-Item -LiteralPath (Join-Path $root 'interact.exe') | Select-Object FullName, Length, LastWriteTime
} finally {
  Pop-Location
  foreach ($name in $frontendVariableNames) {
    [Environment]::SetEnvironmentVariable($name, $previousFrontendVariables[$name], 'Process')
  }
  if (Test-Path -LiteralPath $outputFullPath) { Remove-Item -LiteralPath $outputFullPath -Recurse -Force }
}
