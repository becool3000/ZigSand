[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$downloads = Join-Path $tools 'downloads'
$zigHome = Join-Path $tools 'zig'
$dxcHome = Join-Path $tools 'dxc'

$zigUrl = 'https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip'
$zigSha256 = '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e'
$dxcUrl = 'https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2602.24/dxc_2026_05_27.zip'
$dxcSha256 = 'cf658aacf070d3045e31b8f1f8a696c2945f37c1095019481ef7c513368db3b4'

function Install-Archive {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ReadyFile,
        [Parameter(Mandatory = $true)][bool]$FlattenSingleDirectory
    )

    if (Test-Path -LiteralPath (Join-Path $Destination $ReadyFile)) {
        Write-Host "$Name already installed."
        return
    }

    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    $archive = Join-Path $downloads "$Name.zip"
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Host "Downloading $Name..."
        Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        Remove-Item -LiteralPath $archive -Force
        throw "$Name checksum mismatch. Expected $Sha256, got $actual."
    }

    $staging = Join-Path $tools "$Name-staging"
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    # Windows PowerShell's Expand-Archive is extremely slow for Zig's many
    # small library files. The inbox bsdtar handles the same ZIP safely and
    # finishes in seconds.
    & tar.exe -xf $archive -C $staging
    if ($LASTEXITCODE -ne 0) {
        throw "$Name extraction failed with exit code $LASTEXITCODE."
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    if ($FlattenSingleDirectory) {
        $children = @(Get-ChildItem -LiteralPath $staging)
        if ($children.Count -ne 1 -or -not $children[0].PSIsContainer) {
            throw "$Name archive layout changed; expected one top-level directory."
        }
        Move-Item -LiteralPath $children[0].FullName -Destination $Destination
        Remove-Item -LiteralPath $staging -Recurse -Force
    } else {
        Move-Item -LiteralPath $staging -Destination $Destination
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Destination $ReadyFile))) {
        throw "$Name installation did not produce $ReadyFile."
    }
    Write-Host "$Name installed."
}

New-Item -ItemType Directory -Force -Path $tools | Out-Null
Install-Archive -Name 'zig-0.16.0' -Url $zigUrl -Sha256 $zigSha256 -Destination $zigHome -ReadyFile 'zig.exe' -FlattenSingleDirectory $true
Install-Archive -Name 'dxc-1.9.2602.24' -Url $dxcUrl -Sha256 $dxcSha256 -Destination $dxcHome -ReadyFile 'bin\x64\dxc.exe' -FlattenSingleDirectory $false

. (Join-Path $PSScriptRoot 'env.ps1')
Write-Host ''
Write-Host 'ZigSand toolchain is ready for this PowerShell session.'
Write-Host 'Run: zig build test'
Write-Host 'For a new shell, first run: . .\tools\env.ps1'
