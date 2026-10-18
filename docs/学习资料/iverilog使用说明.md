# iverilog 在哪里打开、怎么用

## 0. 先说最重要的一句话

> iverilog 没有界面，它不是"双击打开"的软件。
> 它是命令行编译器，性质和你 arm-none-eabi-gcc、和 VS Code 里编译 C 用的是同一类东西。

具体表现：
- 你双击 `E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\iverilog.exe`
  → 只会闪一下黑窗口就消失，什么都看不到。
  这不是装坏了，是因为它不知道你要编译哪个文件。
- 它的用法永远是这一种形式：

```
iverilog  [参数...]  你的源文件.v
```

- 你其实一直在用它 —— `sim.bat` 里面就是替你敲了这条命令。
  你不需要"打开"它，就像你不需要"打开"gcc 一样。

---

## 1. 它在整个流程里的位置

```
   你的代码                      iverilog 干的活        vvp 干的活
  counter.v      ┐
  tb_counter.v   ┴──▶ iverilog 编译 ──▶ sim.out ──▶ vvp 运行 ──┬──▶ 终端打印 PASS/FAIL
                                                                 └──▶ tb_counter.vcd ──▶ GTKWave / vcd_wave.py

   └────────────── 输入：源代码 ──────────────┘   └─ 中间产物 ─┘   └──────── 输出：结果 ────────┘
```

记住三个文件的分工：

| 文件 | 是什么 | 谁生成的 |
|---|---|---|
| `xxx.v` | 你写的源代码 | 你 |
| `sim.out` | 编译产物（相当于 exe），不能双击运行 | iverilog |
| `xxx.vcd` | 仿真波形数据 | vvp（运行 sim.out 时） |

---

## 2. 三个层次，挑一个用就行

### 层次 0 —— 日常就用这个（推荐）

```powershell
cd "E:\Deepseek Harness\fir_soc"
.\sim.bat 01_counter
```

一条命令内部做完：编译 → 运行 → 打印终端波形 → 打开 GTKWave。
你不需要知道 iverilog 在哪，`sim.bat` 会自动找到它。

### 层次 1 —— 手动两条命令（这两个必须看懂）

如果 `sim.bat` 出问题，或者你想理解底层发生了什么，就手动敲：

```powershell
cd "E:\Deepseek Harness\fir_soc\01_counter"

# 第 1 步：编译（把 .v 变成 sim.out）
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\iverilog.exe -g2012 -o sim.out -s tb_counter counter.v tb_counter.v

# 第 2 步：运行（产生波形 + 打印结果）
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\vvp.exe sim.out
```

实测第 1 步跑完，目录里多出 `sim.out`（6421 字节）；
第 2 步跑完，多出 `tb_counter.vcd`（1814 字节），并在终端打印：

```
VCD info: dumpfile tb_counter.vcd opened for output.
[ OK ] 复位后 cnt = 0
  第  1 拍: cnt =  1  tick = 0
  ...
```

### 层次 2 —— 把波形也手动打开

```powershell
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\gtkwave.exe tb_counter.vcd
```

> 注意：`sim.out` 不要双击，双击没反应也没意义，它是给 `vvp` 吃的。

---

## 3. 去掉那串长路径：让 `iverilog` 变成全局命令

现在你敲 `iverilog` 会报：

```
iverilog : 无法将"iverilog"项识别为 cmdlet、函数、脚本文件或可运行程序的名称
```

原因：OSS CAD Suite 的 `bin` 目录不在 PATH 里（我在这台机器上查过，确实不在）。

### 其实你不需要改

`sim.bat` / `wave.bat` 已经写死了自动查找逻辑，找不到就去
`E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin` 找。所以日常用完全不用管 PATH。

### 但如果你想改（改完能少打一长串路径）

方式一：图形界面（最稳，推荐新手）

1. `Win + R` → 输入 `sysdm.cpl` → 回车
2. 「高级」选项卡 → 「环境变量」
3. 上半部分「用户变量」里选中 `Path` → 「编辑」
4. 「新建」→ 粘贴 `E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin` → 一路确定
5. 关掉所有终端窗口重新打开（不重启终端不生效）

方式二：命令行（管理员无关，只改当前用户）

```powershell
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", $old.TrimEnd(';') + ";E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin", "User")
```

改完重开终端，然后验证：

```powershell
iverilog -V
```

能打印版本号就成了。

> 说明：`sim.ps1` 已经自动找到 `E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin` 并加入 PATH，
> 所以通常你根本不用改系统 PATH。上面这一节只在"换电脑/换安装位置"时才需要。

---

## 4. iverilog 常用参数（够你用到比赛结束）

| 参数 | 作用 | 例子 |
|---|---|---|
| `-o 文件名` | 指定输出文件名 | `-o sim.out` |
| `-s 模块名` | 指定顶层模块（必须写 testbench 的名字） | `-s tb_counter` |
| `-g2012` | 用 SystemVerilog-2012 语法（兼容性最好，建议一直加） | |
| `-I 目录` | 指定 `\`include` 的搜索目录 | `-I .` |
| `-D 宏` | 定义宏，配合 `\`ifdef` 用 | `-D SIM` |
| `-y 目录` | 自动搜索该目录下的模块文件 | `-y ./rtl` |
| `-Wall` | 打开更多警告（强烈建议加，能提前发现一堆 bug） | |
| `-t vvp` | 指定后端目标（默认就是 vvp，一般不用写） | |

最小可用命令模板（建议背下来）：

```
iverilog -g2012 -Wall -o sim.out -s <testbench名> <所有源文件.v>
vvp sim.out
```

### 一个常见问题：为什么必须写 `-s`？

因为一个工程里有很多模块，iverilog 不知道从哪个开始。
`-s tb_counter` 就是告诉它"从 tb_counter 这个模块往下展开"。
如果忘了写，它会报 `Unable to find the root module`。

---

## 5. 编译报错怎么读（这一节最实用）

### 报错的格式是固定的

```
文件名:行号: error: 说明
```

你只要去那个文件的第那个行找问题就行。

### 但 PowerShell 会包一堆废话

你在 PowerShell 里跑 iverilog，看到的是这样：

```
iverilog : e1.v:5: syntax error
At line:16 char:1
+ iverilog -g2012 -o e1.out -s demo1 e1.v 2>&1 | Select-Object -First 5
+ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : NotSpecified: (e1.v:5: syntax error:String) [], RemoteException
    + FullyQualifiedErrorId : NativeCommandError

e1.v:5: Syntax in assignment statement l-value.
```

除了 `e1.v:5: ...` 那几行，其它全是 PowerShell 自己的包装，不用看。
（红字很吓人，但大多只是"命令往 stderr 写了东西"而已，不代表编译逻辑失败。）

### 四个最常见的错误（下面都是实测的真实输出）

错误 A：拼写错误

```
e1.v:5: syntax error
e1.v:5: Syntax in assignment statement l-value.
e1.v:6: syntax error
I give up.
```
→ 原因是把 `begin` 写成了 `begn`。
`syntax error` 就是"这行语法不对"，99% 是拼写、少了分号、或者少了一个 `end`。

错误 B：用了没声明的信号

```
e2.v:3: error: Unable to bind wire/reg/memory `a' in `demo2'
e2.v:3: error: Unable to bind wire/reg/memory `b' in `demo2'
e2.v:3: error: Unable to elaborate r-value: (a)&(b)
```
→ `assign y = a & b;` 里 `a`、`b` 根本没声明。
看到 `Unable to bind` 就是"这个名字找不到"，去检查拼写或补上 `wire`/`reg` 声明。

错误 C：模块没加进编译列表

```
e3.v:3: error: Unknown module type: counter
*** These modules were missing:
        counter referenced 1 times.
```
→ 你用了 `counter` 这个模块，但命令行里没把 `counter.v` 写进去。
看到 `Unknown module type` 就去命令行补文件名（这就是 `sim.ps1` 里 `$src` 数组的作用）。

错误 D：端口名写错

```
e4.v:3: error: port ``cntt'' is not a port of dut.
```
→ 实例化时写了 `.cntt(cnt)`，但模块里根本没有 `cntt` 这个端口。
去对照模块定义改名字。

### 排查顺序（照着做）

1. 看报错的第一个 `xxx.v:N:`，后面的往往是连锁反应
2. 打开那个文件跳到那一行
3. 检查：分号、begin/end 配对、信号名拼写、模块/端口名
4. 改完重新编译

### warning 不是 error，但要看一眼

加 `-Wall` 之后，编译 `05_fir81` 会多出这么一条：

```
fir.v:72: warning: @* is sensitive to all 81 words in array 'p'.
```

这不是错误，编译退出码仍然是 0，仿真照样 PASS。
它是在告诉你：第 72 行那个 `always @(*)` 对 `p` 数组的 81 个元素全都敏感。
这正是我们想要的行为（任何一个乘积变了都要重算 `sum`），所以可以放心忽略。

判断标准很简单：`error` 必须改；`warning` 看懂就行。

---

## 6.  一个必须记住的坑：`.v` 文件不能带 BOM

我实测踩到的：

用 PowerShell 的 `-Encoding UTF8` 写出来的 `.v` 文件，开头会多 3 个字节 `EF BB BF`（BOM），
iverilog 读到它之后认不出 `module` 关键字，报的错还特别误导人：

```
error: Unable to find the root module "demo1" in the Verilog source.
```

你以为是顶层模块写错了，其实是文件头多了三个看不见的字节。

规则：
- `.v` 源文件 → UTF-8 无 BOM（`fir_soc` 里的文件都是无 BOM，所以能正常编译）
- `.ps1` 脚本 → UTF-8 with BOM（正好相反！因为 PowerShell 5.1 要用 BOM 才认得中文）

在 VS Code 里怎么确认/切换：右下角状态栏会显示编码（如 `UTF-8` 或 `UTF-8 with BOM`），
点它 → 选 `Save with Encoding` → 选 `UTF-8`（不要选 `UTF-8 with BOM`）。

---

## 7. 在哪里敲这些命令（怎么打开终端）

三种方式，任选：

方式 1：VS Code 内置终端（最方便，推荐）
1. 用 VS Code 打开文件夹 `E:\Deepseek Harness\fir_soc`
2. 菜单 `终端 → 新建终端`（快捷键 `` Ctrl+` ``）
3. 终端默认就在这个文件夹，直接敲 `.\sim.bat 01_counter`

方式 2：从资源管理器打开
1. 打开文件夹 `E:\Deepseek Harness\fir_soc`
2. 在地址栏里直接输入 `powershell` 回车
3. 终端会在这个目录打开

方式 3：开始菜单
`Win` → 搜 `PowerShell` → 打开 → `cd "E:\Deepseek Harness\fir_soc"`

> 不管哪种方式，`cd` 到 `fir_soc` 目录这一步很重要，
> 因为 `sim.bat` 是用相对路径找实验目录的。

---

## 8. 一页速查

```powershell
# 日常（推荐）
cd "E:\Deepseek Harness\fir_soc"
.\sim.bat 05_fir81                 # 编译 + 仿真 + 终端波形 + GTKWave
.\sim.bat 05_fir81 -NoWave         # 不开 GTKWave
.\wave.bat 05_fir81 --list         # 只看波形，列出信号
.\wave.bat 05_fir81 --radix dec    # 只看波形，十进制有符号

# 手动（理解底层）
cd "E:\Deepseek Harness\fir_soc\05_fir81"
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\iverilog.exe -g2012 -Wall -o sim.out -s tb_fir fir.v tb_fir.v
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\vvp.exe sim.out
E:\FPGA\OSS-CAD-suite\oss-cad-suite\bin\gtkwave.exe tb_fir.vcd
```

记住一句话：iverilog 不用"打开"，它是被命令行调用的；
而 `sim.bat` 已经替你调好了。
