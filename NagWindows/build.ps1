param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [string]$Dotnet = 'dotnet'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot 'Nag.Windows/Nag.Windows.csproj'
$output = Join-Path $repoRoot "build/Nag-$Runtime"
& $Dotnet publish $project -c Release -r $Runtime --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o $output
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $output 'README.md')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'VERIFICATION.md') -Destination (Join-Path $output 'VERIFICATION.md')
$archive = Join-Path $repoRoot "build/Nag-$Runtime.zip"
Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive -Force
Write-Output "Portable Windows app: $output/Nag.exe"
Write-Output "Archive: $archive"
