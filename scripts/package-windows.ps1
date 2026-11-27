[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z.-]*$')]
    [string]$Version,
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectDirectory = Join-Path $repoRoot 'Windows' 'Toki.Windows'
$projectFiles = @(Get-ChildItem -LiteralPath $projectDirectory -Filter '*.csproj' -File)
if ($projectFiles.Count -ne 1) {
    throw "Expected exactly one project file in $projectDirectory, found $($projectFiles.Count)."
}
$projectPath = $projectFiles[0].FullName

if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot $OutputDirectory
}
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($outputPath -eq $repoRoot -or $outputPath -eq [System.IO.Path]::GetPathRoot($outputPath)) {
    throw "Output directory must not be the repository root or a drive root: $outputPath"
}

$stagingPath = Join-Path $outputPath ".staging-$Runtime"
$appPath = Join-Path $stagingPath 'Toki'
$zipName = "Toki-windows-preview-$Version-$Runtime.zip"
$zipPath = Join-Path $outputPath $zipName
$hashPath = "$zipPath.sha256"

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
if (Test-Path -LiteralPath $stagingPath) {
    $resolvedStaging = [System.IO.Path]::GetFullPath($stagingPath)
    $outputPrefix = $outputPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStaging.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a staging directory outside the output directory: $resolvedStaging"
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}

Write-Host "==> Restoring $projectPath for $Runtime"
& dotnet restore $projectPath -r $Runtime
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE."
}

Write-Host "==> Publishing $Runtime"
& dotnet publish $projectPath `
    -c Release `
    -r $Runtime `
    --self-contained true `
    --no-restore `
    -p:Version=$Version `
    -p:EnableWindowsTargeting=true `
    -p:PublishTrimmed=false `
    -p:PublishReadyToRun=false `
    -o $appPath
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$exePath = Join-Path $appPath 'Toki.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Publish did not produce Toki.exe at $exePath."
}

Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $appPath
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs/windows.md') -Destination (Join-Path $appPath 'WINDOWS-README.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $appPath

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
if (Test-Path -LiteralPath $hashPath) {
    Remove-Item -LiteralPath $hashPath -Force
}

Write-Host "==> Creating $zipName"
Compress-Archive -Path (Join-Path $appPath '*') -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $zipName" | Set-Content -LiteralPath $hashPath -Encoding ascii

Write-Host "==> Package: $zipPath"
Write-Host "==> SHA256:  $hashPath"
