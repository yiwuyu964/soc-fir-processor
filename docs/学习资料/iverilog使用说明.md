# iverilog 使用说明

> 文档信息 ｜ 类别：参考与手册类 ｜ 所属：跨阶段 ｜ 状态：在用 ｜ 索引：`docs/README.md §1.5`

这份文档只讲 iverilog 这个工具本身：怎么调用、参数怎么给、报错怎么读。项目工作流（跑 26 个测试台、看覆盖率、开波形）在 `../怎么跑仿真.md`，两份不重复。

## 一、它不是那种"双击打开"的软件

iverilog 是命令行编译器，性质和你熟悉的 `arm-none-eabi-gcc` 一样：给源文件，出可执行产物。

双击 `iverilog.exe` 只会闪一下黑窗口就消失，这不是装坏了，而是它不知道要编译什么。它的调用形式永远只有一种：

```
iverilog [参数...] 源文件.v
```

整个流程里三个文件的分工：

| 文件 | 是什么 | 谁生成 |
|---|---|---|
| `xxx.v` | 源代码 | 你写 |
| `sim.out` | 编译产物，相当于 exe，**不能双击运行** | iverilog |
| `xxx.vcd` | 仿真波形 | vvp（运行 sim.out 时） |

所以是两步：`iverilog` 编译出 `sim.out`，`vvp` 运行 `sim.out` 产生波形和终端输出。

## 二、在本项目里怎么调

项目里跑测试台统一走 `sim\sim.cmd`，它会替你拼命令。但手敲一遍有助于理解底层发生了什么。

以 `tb_dma` 为例：

```powershell
cd "<仓库根目录>"

# 抓所有 RTL 文件
$rtl = Get-ChildItem RTL -Recurse -Filter *.v | ForEach-Object FullName

# 辅助文件：检查器、ID 契约检查、存储模型、阶段5 的公共件
$h = @("TB/axi_protocol_checker.v","TB/axi_id_contract_check.v","TB/axi_mem_model.v") +
     @(Get-ChildItem TB -Filter "phase5_*" -File | ForEach-Object FullName)

# 编译
iverilog -g2012 -Wall -s tb_dma -I RTL/cpu/cortexm0ds -o sim.out ($rtl + $h + "TB/tb_dma.v")

# 运行
vvp sim.out
```

两个参数必须注意：

`-s tb_dma` 指定顶层。一个工程里有几十个模块，iverilog 不知道从哪个开始展开，`-s` 就是告诉它"从 tb_dma 往下"。忘了写会报 `Unable to find the root module`。

`-I RTL/cpu/cortexm0ds` 指定 include 搜索目录。ARM 的 IP 里 `cmsdk_axi_ram_beh.v` 等文件 `\`include "ahb_axi_define.v"`，不指定这个目录就找不到头文件。这条在本项目里漏了必然编译失败。

## 三、常用参数

| 参数 | 作用 | 例子 |
|---|---|---|
| `-o 文件名` | 指定输出文件 | `-o sim.out` |
| `-s 模块名` | 指定顶层模块（testbench 名） | `-s tb_dma` |
| `-g2012` | 用 SystemVerilog-2012 语法 | 建议一直加 |
| `-I 目录` | include 搜索路径 | `-I RTL/cpu/cortexm0ds` |
| `-D 宏` | 定义宏，配合 `\`ifdef` | `-D SIM` |
| `-y 目录` | 自动搜索该目录下的模块 | `-y ./RTL` |
| `-Wall` | 打开更多警告 | 强烈建议 |
| `-Wno-timescale` | 关掉 timescale 告警 | ARM 的原厂文件没有 timescale，加它可减少噪音 |

最小可用模板，建议背下来：

```
iverilog -g2012 -Wall -o sim.out -s <testbench名> <所有源文件.v>
vvp sim.out
```

## 四、报错怎么读

报错格式是固定的：`文件名:行号: error: 说明`。去那个文件的对应行找问题就行。

但 PowerShell 会包一层很吓人的红字：

```
iverilog : e1.v:5: syntax error
At line:16 char:1
+ iverilog -g2012 -o e1.out -s demo1 e1.v 2>&1 | Select-Object -First 5
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (e1.v:5: syntax error:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError

e1.v:5: Syntax in assignment statement l-value.
```

除了 `e1.v:5: ...` 那几行，其它全是 PowerShell 的包装。红字只表示"命令往 stderr 写了东西"，不代表编译逻辑失败。

四种最常见的错误：

**语法错误**，输出 `syntax error` 加 `I give up.`。原因通常是拼写（`begin` 写成 `begn`）、少了分号、或者少了一个 `end`。

**名字没声明**，输出 `Unable to bind wire/reg/memory 'a' in 'demo2'`。`assign y = a & b;` 里 `a`、`b` 根本没声明。看到 `Unable to bind` 就去检查拼写或补声明。

**模块没加进编译列表**，输出 `Unknown module type: counter` 加一段 `These modules were missing`。你用了 `counter` 但命令行里没把 `counter.v` 写进去。

**端口名写错**，输出 `port 'cntt' is not a port of dut`。实例化时写了 `.cntt(cnt)`，但模块里没这个端口。

排查顺序：只看第一个 `xxx.v:N:`（后面的多半是连锁反应），跳到那一行，检查分号、`begin`/`end` 配对、信号名拼写、模块与端口名，改完重新编译。

## 五、warning 不是 error，但要看一眼

加 `-Wall` 之后实际会看到的主要是这个：

```
RTL/cpu/cortexm0ds/cortexm0ds.v:28: warning: timescale for cortexm0ds inherited from another file.
RTL/cpu/cortexm0ds/ahb2axi4_ahb.v:3: warning: timescale for ahb2axi4_ahb inherited from another file.
```

同一类告警会在 ARM 的 8 个文件上各出一条。它不是错误，退出码仍然是 0，仿真照样 PASS。意思是从这些文件开始 timescale 是继承来的，不是自己声明的——ARM 的原厂代码没写 `\`timescale`，而我们自己的 RTL 都写了。

嫌吵闹就加 `-Wno-timescale`，`sim/sim.ps1` 里就是这么处理的。

判断标准很简单：`error` 必须改，`warning` 看懂就行。

## 六、一个必须记住的坑：`.v` 文件不能带 BOM

用 PowerShell 的 `-Encoding UTF8` 写出来的文件，开头会多三个字节 `EF BB BF`。iverilog 读到它之后认不出 `module` 关键字，报的错还特别误导人：

```
error: Unable to find the root module "demo1" in the Verilog source.
```

你会以为是顶层模块名写错，实际是文件头多了三个看不见的字节。

规则正好相反，容易记混：

- `.v` 源文件 → **UTF-8 无 BOM**
- `.ps1` 脚本 → **UTF-8 带 BOM**（PowerShell 5.1 要靠 BOM 才认得中文）

在 VS Code 里看右下角状态栏的编码提示，点它选 `Save with Encoding` → `UTF-8`（不要选 `UTF-8 with BOM`）。

这个坑在本项目里踩过不止一次：`sim/sim.ps1` 是 GBK 编码的，用 UTF-8 编辑器改会把中文注释变成乱码，PowerShell 直接解析失败。改这个文件只能用字节级编辑，或者整份重写。

## 七、找不到命令怎么办

敲 `iverilog -V` 如果报「无法将"iverilog"项识别为 cmdlet」，说明安装目录的 `bin` 不在 PATH 里。

本项目不需要改 PATH——`sim/sim.ps1` 会自己找 iverilog 并把它加进去。只有换电脑或换安装位置时才需要手动处理：

方式一是图形界面，`Win + R` 输 `sysdm.cpl`，高级 → 环境变量 → 用户变量里选 `Path` → 编辑 → 新建 → 粘贴 bin 目录 → 一路确定，然后**关掉所有终端窗口重开**（不重开不生效）。

方式二是命令行，只改当前用户：

```powershell
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", $old.TrimEnd(';') + ";<iverilog 安装目录>\bin", "User")
```

改完重开终端，`iverilog -V` 能打印版本号就成了。

## 八、速查

```powershell
# 本项目日常用这个，不要手敲 iverilog
sim\sim.cmd
sim\sim.cmd -Only dma
sim\sim.cmd -Only dma -KeepVcd

# 手动两步（理解底层 / 单独调试某个台）
$rtl = Get-ChildItem RTL -Recurse -Filter *.v | ForEach-Object FullName
iverilog -g2012 -Wall -s tb_dma -I RTL/cpu/cortexm0ds -o sim.out ($rtl + "TB/axi_protocol_checker.v" + "TB/axi_id_contract_check.v" + "TB/axi_mem_model.v" + "TB/tb_dma.v")
vvp sim.out
```

一句话：iverilog 不用"打开"，它是被命令行调用的，而 `sim.cmd` 已经替你调好了。
