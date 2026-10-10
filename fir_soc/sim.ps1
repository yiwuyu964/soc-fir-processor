# ============================================================
# 一键仿真脚本
#
# 用法（在 fir_soc 目录下）：
#     .\sim.ps1 01_counter
#     .\sim.ps1 02_delayline
#     .\sim.ps1 03_mac
#     .\sim.ps1 04_fir9
#     .\sim.ps1 05_fir81
#
# 如果提示"无法加载文件，因为在此系统上禁止运行脚本"，用 sim.bat 代替：
#     .\sim.bat 01_counter
#
# 脚本会做三件事：
#   1. 编译并运行仿真
#   2. 在终端里把波形画成 ASCII 图（不想开 GTKWave 就看这个）
#   3. 打开 GTKWave 看真实波形
# ============================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$Lab,
    [switch]$NoWave           # 加 -NoWave 就只跑仿真，不开 GTKWave
)

# 让原生命令写到 stderr 的内容（比如 iverilog 的 warning）不要当成致命错误
$PSNativeCommandUseErrorActionPreference = $false

# ============================================================
# ↓↓↓ 你的 OSS CAD Suite 安装位置，换目录只改这一行 ↓↓↓
$OssCadSuite = "E:\FPGA\OSS-CAD-suite\oss-cad-suite"
# ============================================================

$root = $PSScriptRoot
$dir  = Join-Path $root $Lab

if (-not (Test-Path $dir)) {
    Write-Host "找不到实验目录: $dir" -ForegroundColor Red
    Write-Host "可用的实验: 01_counter 02_delayline 03_mac 04_fir9 05_fir81 06_axi_lite 07_fir_axi 08_soc 09_soc_cm0 10_dma 11_axi_apb 12_uart_echo" -ForegroundColor Yellow
    exit 1
}

# ---- 每个实验的顶层模块和源文件 ----
switch ($Lab) {
    "01_counter"   { $top = "tb_counter";    $src = @("01_counter\counter.v", "01_counter\tb_counter.v") }
    "02_delayline" { $top = "tb_delay_line"; $src = @("02_delayline\delay_line.v", "02_delayline\tb_delay_line.v") }
    "03_mac"       { $top = "tb_mac";        $src = @("03_mac\mac.v", "03_mac\tb_mac.v") }
    "04_fir9"      { $top = "tb_fir";        $src = @("04_fir9\fir.v", "04_fir9\tb_fir.v") }
    "05_fir81"     { $top = "tb_fir";        $src = @("05_fir81\fir.v", "05_fir81\tb_fir.v") }
    "06_axi_lite"  { $top = "tb_axi_sram";   $src = @("rtl\axi_lite_sram.v", "06_axi_lite\tb_axi_sram.v") }
    "07_fir_axi"   { $top = "tb_fir_axi";    $src = @("rtl\fir_axi.v", "rtl\fir_cfg.v", "rtl\sync_fifo.v", "07_fir_axi\tb_fir_axi.v") }
    "08_soc"       { $top = "tb_soc";        $src = @("rtl\soc_top.v", "rtl\axi_lite_xbar.v", "rtl\fir_axi.v", "rtl\fir_cfg.v", "rtl\sync_fifo.v", "rtl\uart_axi.v", "rtl\uart_tx.v", "rtl\axi_lite_sram.v", "08_soc\tb_soc.v") }
    "09_soc_cm0"   { $top = "tb_soc_cm0";
                     $src = @("cpu\cortexm0ds\cortexm0ds.v","cpu\cortexm0ds\cortexm0ds_logic.v","cpu\cortexm0ds\ahb2axi4_if.v","cpu\cortexm0ds\ahb2axi4_ahb.v","cpu\cortexm0ds\ahb2axi4_axi.v","cpu\cortexm0ds\ahb2axi4_burst.v","cpu\cortexm0ds\ahb2axi4_fifo.v","cpu\cortexm0ds\ahb_axi_define.v","cpu\cmsdk_axi_ram_beh.v","rtl\axi4_to_axilite.v","rtl\fir_axi.v","rtl\fir_cfg.v","rtl\sync_fifo.v","rtl\uart_axi.v","rtl\uart_tx.v","rtl\soc_cm0_top.v","09_soc_cm0\tb_soc_cm0.v")
                     $inc = @("cpu\cortexm0ds") }
    "10_dma"       { $top = "tb_dma";        $src = @("rtl\dma.v", "10_dma\tb_dma.v") }
    "11_axi_apb"   { $top = "tb_axi_to_apb"; $src = @("rtl\axi_to_apb.v", "11_axi_apb\tb_axi_to_apb.v") }
    "12_uart_echo" { $top = "tb_uart_echo";  $src = @("rtl\axi_to_apb.v", "rtl\uart_tx.v", "rtl\uart_rx.v", "rtl\uart_apb.v", "rtl\sync_fifo.v", "12_uart_echo\tb_uart_echo.v") }
    default        { Write-Host "未知实验: $Lab" -ForegroundColor Red; exit 1 }
}

# ---- 找 iverilog ----
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    $candidates = @(
        (Join-Path $OssCadSuite "bin"),
        "C:\oss-cad-suite\bin",
        "D:\oss-cad-suite\bin",
        "E:\oss-cad-suite\bin",
        "$env:USERPROFILE\oss-cad-suite\bin",
        "C:\iverilog\bin",
        "D:\iverilog\bin",
        "E:\iverilog\bin"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path (Join-Path $p "iverilog.exe"))) {
            # lib 目录放 OSS CAD Suite 依赖的 DLL，一起加进 PATH 更保险
            $lib = Join-Path (Split-Path $p -Parent) "lib"
            if (Test-Path $lib) { $env:Path = "$lib;" + $env:Path }
            $env:Path = "$p;" + $env:Path
            Write-Host "已自动加入 PATH: $p" -ForegroundColor DarkGray
            break
        }
    }
}

if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "找不到 iverilog。" -ForegroundColor Red
    Write-Host "请检查 sim.ps1 顶部 `$OssCadSuite 的路径是否正确。" -ForegroundColor Yellow
    Write-Host "当前设置: $OssCadSuite" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "实验目录 : $dir"
Write-Host "顶层模块 : $top"
Write-Host "编译中 ..." -ForegroundColor Cyan

Push-Location $dir
try {
    $files = $src | ForEach-Object { Join-Path $root $_ }
    $incPaths = @($dir)
    if ($inc) { $incPaths += $inc | ForEach-Object { Join-Path $root $_ } }
    $incArgs = $incPaths | ForEach-Object { "-I"; $_ }

    # -g2012      用 SystemVerilog-2012 语法（兼容性最好）
    # -I $dir     让 `include "coeffs.vh" 能找到文件
    # -s $top     指定顶层模块（testbench）
    & iverilog -g2012 @incArgs -o sim.out -s $top @files

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[编译失败] 把上面 iverilog 的报错贴出来即可定位。" -ForegroundColor Red
        exit 1
    }

    Write-Host "运行仿真 ..." -ForegroundColor Cyan
    Write-Host ("-" * 60)
    & vvp sim.out
    Write-Host ("-" * 60)

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[仿真异常退出]" -ForegroundColor Red
        exit 1
    }

    $vcd = Get-ChildItem -Path $dir -Filter *.vcd -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1

    # ---- 第二步：终端 ASCII 波形（看不懂 GTKWave 就先看这个）----
    if ($vcd) {
        $waveScript = Join-Path $root "vcd_wave.py"
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py -and (Test-Path $waveScript)) {
            Write-Host ""
            Write-Host "===== 终端波形（先看这个，比 GTKWave 好懂）=====" -ForegroundColor Cyan
            & python $waveScript $vcd.FullName
            Write-Host ""
            Write-Host "想换信号 / 换时间段：" -ForegroundColor DarkGray
            Write-Host "  python vcd_wave.py $Lab\$($vcd.Name) --list" -ForegroundColor DarkGray
            Write-Host "  python vcd_wave.py $Lab\$($vcd.Name) --radix dec --from 1500 --to 2300" -ForegroundColor DarkGray
        }
    }

    # ---- 第三步：打开 GTKWave ----
    if ($vcd -and -not $NoWave) {
        Write-Host ""
        Write-Host "波形文件: $($vcd.FullName)" -ForegroundColor Green
        if (Get-Command gtkwave -ErrorAction SilentlyContinue) {
            Write-Host "正在打开 GTKWave ...（操作说明见 GTKWave入门.md）" -ForegroundColor Green
            Start-Process gtkwave -ArgumentList "`"$($vcd.FullName)`""
        } else {
            Write-Host "没找到 gtkwave，可以手动用 GTKWave 打开上面的 .vcd 文件" -ForegroundColor Yellow
        }
    }
}
finally {
    Pop-Location
}
