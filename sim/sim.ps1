# ============================================================
# sim/sim.ps1 —— SoC-FIR 一键仿真脚本
#
# 【为什么有这一步】
#   2026-10 审计发现：axi_slave_model 被两个测试台各定义了一份，
#   单独编译各自的 TB 都过，但【一起编译就报 already declared】。
#   这类"重名模块"问题很隐蔽 —— 平时看不出来，等到评委一次编译
#   全部 TB 时才炸。所以本脚本【第一步就做全量编译检查】，永远堵住它。
#
# 【用法】在仓库根目录运行 —— 推荐用 .cmd 包装（免去执行策略的麻烦）：
#   sim\sim.cmd                 跑全部测试台（含全量编译检查）
#   sim\sim.cmd -List           只列出有哪些测试台
#   sim\sim.cmd -Only dma       只跑名字含 "dma" 的测试台
#   sim\sim.cmd -NoLint         跳过全量编译检查（不建议）
#
#   也可以直接调 PowerShell（Windows 默认禁止跑 .ps1，所以要 Bypass）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\sim.ps1
#
# ⚠️ 本文件必须存成【UTF-8 带 BOM】—— Windows PowerShell 5.1 没有 BOM 时会
#    按 GBK 读，下面的中文会全乱、脚本直接语法报错。改这个文件时注意别丢 BOM。
#
# 【退出码】全部通过 = 0，任何一项失败 = 1（可当 CI 门禁用）
# ============================================================
param(
    [string] $Only  = "",
    [switch] $List,
    [switch] $NoLint,
    [switch] $KeepVcd          # 保留波形文件（默认跑完删掉，免得仓库变脏）
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# ---- 控制台用 UTF-8，免得中文乱码 ----
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$NL = [char]10   # 换行符（避免在脚本里写 PowerShell 的反引号转义）

# ============================================================
# 1. 找 iverilog
# ============================================================
function Find-Iverilog {
    $cand = @()
    $c = Get-Command iverilog -ErrorAction SilentlyContinue
    if ($c) { $cand += $c.Source }
    $cand += @(
        "E:\apps\iverilog\iverilog\bin\iverilog.exe",
        "C:\iverilog\bin\iverilog.exe",
        "D:\iverilog\bin\iverilog.exe",
        "C:\Program Files\iverilog\bin\iverilog.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($cand.Count -eq 0) {
        Write-Host "找不到 iverilog。请安装后加入 PATH，或改本脚本的 Find-Iverilog。" -ForegroundColor Red
        exit 1
    }
    return $cand[0]
}
$IV = Find-Iverilog
$VV = Join-Path (Split-Path $IV -Parent) "vvp.exe"
if (-not (Test-Path $VV)) { $VV = "vvp" }

Write-Host ""
Write-Host "iverilog  : $IV" -ForegroundColor DarkGray
Write-Host "仓库根目录: $RepoRoot" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# 2. 收集文件
# ============================================================
$IncDir  = Join-Path $RepoRoot "RTL\cpu\cortexm0ds"
$Rtl     = @(Get-ChildItem (Join-Path $RepoRoot "RTL") -Recurse -Filter *.v | ForEach-Object { $_.FullName })
# 验证公共件：所有测试台都可能用到
$Helpers = @("axi_protocol_checker.v", "axi_id_contract_check.v", "axi_mem_model.v") |
           ForEach-Object { Join-Path $RepoRoot ("TB\" + $_) } | Where-Object { Test-Path $_ }
$AllTb   = @(Get-ChildItem (Join-Path $RepoRoot "TB") -Filter "tb_*.v" | Sort-Object Name)

if ($AllTb.Count -eq 0) { Write-Host "TB/ 下没有找到 tb_*.v" -ForegroundColor Red; exit 1 }

if ($List) {
    Write-Host "共 $($AllTb.Count) 个测试台：" -ForegroundColor Cyan
    $AllTb | ForEach-Object { Write-Host ("  " + $_.BaseName) }
    exit 0
}

$OutDir = Join-Path $env:TEMP ("socsim_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ============================================================
# 3. 第一步：全量编译检查（专门堵"重名模块"这类坑）
# ============================================================
if (-not $NoLint) {
    Write-Host "[0/$($AllTb.Count)] 全量编译检查（RTL + 全部 TB 一起编译）..." -ForegroundColor Yellow
    $lintOut = Join-Path $OutDir "lintall.out"
    $lintLog = & $IV -g2012 -Wall -I $IncDir -o $lintOut ($Rtl + $Helpers + ($AllTb | ForEach-Object { $_.FullName })) 2>&1
    $lintErr = @($lintLog | Select-String -Pattern "error:")
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "全量编译失败 —— 这类问题单跑各自的 TB 是发现不了的：" -ForegroundColor Red
        $lintLog | ForEach-Object { Write-Host ("   " + $_.ToString().Trim()) -ForegroundColor Red }
        Write-Host ""
        Write-Host "   最常见的两种原因：" -ForegroundColor Yellow
        Write-Host "   1. 两个 TB 里定义了同名的模块（如 axi_slave_model / axi_mem_model）" -ForegroundColor Yellow
        Write-Host "      → 提取成 TB/ 下的公共件，两边都例化它" -ForegroundColor Yellow
        Write-Host "   2. 某个模块被写了两次（复制粘贴忘删）" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "      OK 全量编译通过，无重名模块" -ForegroundColor Green
}
else {
    Write-Host "[0/$($AllTb.Count)] 已跳过全量编译检查（-NoLint）" -ForegroundColor DarkYellow
}
Write-Host ""

# ============================================================
# 4. 逐个测试台：编译 + 运行
# ============================================================
# Build only the diagnostic image; never overwrite sw/firmware.hex.
if ((!$Only -or "tb_soc_probe" -match $Only)) {
    & python (Join-Path $RepoRoot "sim/tinyfw.py")
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
if ((!$Only -or "tb_fir_core" -match $Only -or "tb_fir" -match $Only)) {
    $VectorDir = Join-Path $OutDir "fir"
    & python (Join-Path $RepoRoot "fir/fir_coeff.py") --outdir $VectorDir | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
$Results = @()
$Idx = 0
foreach ($tb in $AllTb) {
    $Idx++
    $name = $tb.BaseName
    if ($Only -and ($name -notmatch $Only)) { continue }

    Write-Host ("[{0}/{1}] {2}" -f $Idx, $AllTb.Count, $name) -ForegroundColor Cyan -NoNewline

    $out = Join-Path $OutDir ($name + ".out")
    $cLog = & $IV -g2012 -Wall -s $name -I $IncDir -o $out ($Rtl + $Helpers + $tb.FullName) 2>&1
    if ($LASTEXITCODE -ne 0) {
        $firstErr = ($cLog | Select-String -Pattern "error:" | Select-Object -First 1)
        Write-Host "  编译失败" -ForegroundColor Red
        if ($firstErr) { Write-Host ("       " + $firstErr.Line.Trim()) -ForegroundColor Red }
        $Results += [pscustomobject]@{ 测试台=$name; 编译="X"; 运行="-"; 结论="编译失败" }
        continue
    }

    # Run in an isolated directory so VCDs never overwrite users' waveforms.
    $RunSw = Join-Path $OutDir "sw"
    New-Item -ItemType Directory -Force $RunSw | Out-Null
    Get-ChildItem (Join-Path $RepoRoot "sw") -Filter *.hex | Copy-Item -Destination $RunSw
    Push-Location $OutDir
    try { $rLog = (& $VV $out 2>&1) -join $NL } finally { Pop-Location }
    $runExit = $LASTEXITCODE
    $verdict = ($rLog -split $NL | Select-String -Pattern "PASS|FAIL|TIMEOUT" | Select-Object -Last 1)
    $txt = if ($verdict) { $verdict.Line.Trim() } else { "(无结论输出)" }

    if ($runExit -ne 0 -or $rLog -match "(?im)^.*(FAIL|TIMEOUT|FATAL|ERROR:).*$") { $txt = ($rLog -split $NL | Select-String -Pattern "FAIL|TIMEOUT|FATAL|ERROR:" | Select-Object -Last 1).Line; $mark = "失败"; $color = "Red" }
    elseif ($verdict -and $txt -match "PASS")    { $mark = "通过"; $color = "Green" }
    elseif ($txt -match "TIMEOUT") { $mark = "超时"; $color = "Yellow" }
    elseif ($txt -match "FAIL")    { $mark = "失败"; $color = "Red" }
    else                           { $mark = "无结论"; $color = "Yellow" }

    Write-Host ("  " + $mark) -ForegroundColor $color
    $Results += [pscustomobject]@{ 测试台=$name; 编译="OK"; 运行=$mark; 结论=$txt }
}

if ($KeepVcd) { Write-Host ("波形目录: " + $OutDir) }
else { Get-ChildItem -LiteralPath $OutDir -Filter *.vcd -File | Remove-Item -Force }
# ============================================================
# 5. 汇总
# ============================================================
Write-Host ""
Write-Host ("=" * 78) -ForegroundColor White
$Results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$bad = @($Results | Where-Object { $_.运行 -ne "通过" })
if ($Results.Count -eq 0) { Write-Host "没有匹配的测试台" -ForegroundColor Red; exit 1 }
if ($Results.Count -gt 0 -and $bad.Count -eq 0) {
    Write-Host ("===== 全部通过：{0} 个测试台 =====" -f $Results.Count) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("===== 有 {0} 个测试台未通过 =====" -f $bad.Count) -ForegroundColor Red
    $bad | ForEach-Object { Write-Host ("   " + $_.测试台 + " : " + $_.结论) -ForegroundColor Red }
    exit 1
}
