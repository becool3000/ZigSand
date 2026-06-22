$root = Split-Path -Parent $PSScriptRoot
$zigBin = Join-Path $root '.tools\zig'
$dxcBin = Join-Path $root '.tools\dxc\bin\x64'

if (-not (Test-Path -LiteralPath (Join-Path $zigBin 'zig.exe'))) {
    throw 'Zig is not installed. Run .\tools\bootstrap.ps1 first.'
}
if (-not (Test-Path -LiteralPath (Join-Path $dxcBin 'dxc.exe'))) {
    throw 'DXC is not installed. Run .\tools\bootstrap.ps1 first.'
}

$env:Path = "$zigBin;$dxcBin;$env:Path"
$env:ZIGSAND_DXC = Join-Path $dxcBin 'dxc.exe'

