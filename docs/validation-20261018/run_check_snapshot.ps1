param(
    [string] $Part = "xc7z020clg400-1",
    [double] $Period = 20.0,
    [string] $Label = "current",
    [string] $SourceRef = "",
    [switch] $SynthesisOnly
)
$ErrorActionPreference = "Stop"
function Get-Sha256([string] $Path) {
    $Hash = [Security.Cryptography.SHA256]::Create()
    $Stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($Hash.ComputeHash($Stream))).Replace("-", "") }
    finally { $Stream.Dispose(); $Hash.Dispose() }
}
$Repo = Split-Path -Parent $PSScriptRoot
$Vivado = (Get-Command vivado.bat -ErrorAction SilentlyContinue).Source
if (!$Vivado) { $Vivado = "D:\apps\vivado\Vivado\2026.1\Vivado\bin\vivado.bat" }
if (!(Test-Path -LiteralPath $Vivado)) { throw "Vivado not found. Add vivado.bat to PATH." }
if ($Label -notmatch '^[A-Za-z0-9_-]+$') { throw "Use an ASCII label." }
if ($Part -notmatch '^[A-Za-z0-9_-]+$' -or $Period -le 0) { throw "Invalid part or clock period." }
# Unique ASCII staging directory avoids Vivado's Unicode path limitation.
$Stage = Join-Path ([IO.Path]::GetTempPath()) ("soc_check_" + [guid]::NewGuid().ToString("N"))
if ($Stage -match '[^\x00-\x7F]') { $Stage = Join-Path $env:SystemRoot ("Temp\soc_check_" + [guid]::NewGuid().ToString("N")) }
New-Item -ItemType Directory -Path $Stage | Out-Null
if ($SourceRef) {
    & git -C $Repo archive --format=zip -o (Join-Path $Stage "sources.zip") $SourceRef RTL
    if ($LASTEXITCODE -ne 0) { throw "Cannot archive RTL from $SourceRef" }
    Expand-Archive -LiteralPath (Join-Path $Stage "sources.zip") -DestinationPath $Stage
} else {
    Copy-Item -LiteralPath (Join-Path $Repo "RTL") -Destination $Stage -Recurse
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "check.tcl") -Destination $Stage
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "soc_top.xdc") -Destination $Stage
$Report = Join-Path $Repo ("build\audit\" + $Label)
New-Item -ItemType Directory -Path $Report -Force | Out-Null
Get-ChildItem (Join-Path $Stage "RTL") -Recurse -File | Where-Object { $_.Extension -in '.v','.sv','.vh' } | ForEach-Object {
    "{0}  {1}" -f (Get-Sha256 $_.FullName), $_.FullName.Substring($Stage.Length+1)
} | Set-Content -LiteralPath (Join-Path $Report "source-sha256.txt") -Encoding ASCII
@((Join-Path $Stage "check.tcl"),(Join-Path $Stage "soc_top.xdc"),$PSCommandPath) | ForEach-Object {
    "{0}  {1}" -f (Get-Sha256 $_), [IO.Path]::GetFileName($_)
} | Set-Content (Join-Path $Report "flow-sha256.txt") -Encoding ASCII
$Mode = if ($SynthesisOnly) { "synth" } else { "route" }
$RunCode = 1
$SavedTemp = $env:TEMP
$SavedTmp = $env:TMP
$SavedLocalData = $env:XILINX_LOCAL_USER_DATA
# Vendor helper processes also need ASCII temporary paths.
$env:TEMP = $Stage
$env:TMP = $Stage
# Disable user Tcl catalog caching; vendor helper processes otherwise try
# to open an incorrectly parsed Unicode profile path (Common 17-354/1257).
$env:XILINX_LOCAL_USER_DATA = "NO"
Push-Location $Stage
try {
    $ErrorActionPreference = "Continue"
    & $Vivado -mode batch -nojournal -notrace -source check.tcl -log vivado.log -tclargs $Part ($Period.ToString([Globalization.CultureInfo]::InvariantCulture)) $Mode *> console.log
    $RunCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if (!(Select-String -LiteralPath "vivado.log" -Pattern '^AUDIT_DONE$' -Quiet)) { $RunCode = 1 }
    if (Select-String -LiteralPath "vivado.log" -Pattern '^ERROR:' -Quiet) { $RunCode = 1 }
    if (Select-String -LiteralPath "console.log" -Pattern 'ERROR:' -Quiet) { $RunCode = 1 }
} finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
    $env:TEMP = $SavedTemp
    $env:TMP = $SavedTmp
    $env:XILINX_LOCAL_USER_DATA = $SavedLocalData
    Get-ChildItem -LiteralPath $Stage -File | Where-Object { $_.Extension -in '.log','.rpt','.txt','.dcp' } | Copy-Item -Destination $Report
    Copy-Item -LiteralPath (Join-Path $Stage "check.tcl"),(Join-Path $Stage "soc_top.xdc") -Destination $Report
    "Part=$Part`nPeriod_ns=$Period`nMode=$Mode`nSourceRef=$SourceRef`nStage=$Stage`nExitCode=$RunCode" | Set-Content (Join-Path $Report "run.txt") -Encoding ASCII
}
Get-Content (Join-Path $Report "console.log") -Tail 30
Write-Host "Reports: $Report"
exit $RunCode
