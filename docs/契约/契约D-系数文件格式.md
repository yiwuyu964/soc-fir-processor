# 契约 D：系数文件格式（C 生成，A/B 消费）

> 文档信息 ｜ 类别：契约类 ｜ 所属：跨阶段 ｜ 状态：冻结 ｜ 索引：`docs/README.md §1.1`
> 本契约定义 FIR 81 阶系数的文件格式。C 生成、A/B 消费，冻结后谁都不许私改。
> 依据：[契约1-接口契约（冻结版）.md](契约1-接口契约（冻结版）.md) 契约 A（`CW=16`、`NTAP=82`）、契约 C（`COEF[k]`，k=0..81）。
> 版本：v2，按评委问答更正为 81 阶 / 82 抽头，端口和 5 拍流水延迟不变。

---

## D.0 范围

- 本契约只定义两个系数文件：`fir/coeffs.vh`、`fir/coeffs.hex`。
- 两者内容完全相同（同一组 82 个系数），仅编码方式不同。
- 测试向量 `stim.hex` / `exp.hex` 见 [契约E-测试向量格式.md](契约E-测试向量格式.md)。

## D.1 量化约定（Q1.15，依据契约 A 的 CW=16）

- 定点格式 Q1.15：`浮点值 = 整数 / 32768`。
- 每个系数整数 ∈ [-32768, 32767]（int16 二进制补码）。
- 直流增益归一化：浮点 Σh = 1.0，量化后 Σ(整数) ≈ 32768（脚本打印供验收）。

## D.2 抽头顺序约定（本契约冻结，A/B 必须遵守）

这是全契约最关键的一条，直接决定 A 的 TB 逐位比对是否成立：

- H0 = h[0] = 当前样本 x[n] 的系数（延迟链第 0 级）。
- Hk = h[k] = x[n−k] 的系数（延迟链第 k 级）。
- H81 = h[81] = 最老样本 x[n−81] 的系数（延迟链第 81 级）。
- 卷积定义：`y[n] = Σ_{k=0}^{81} h[k] · x[n−k]`（scipy.signal.firwin 的天然顺序）。
- 索引对应：`coef_idx=k` ↔ `Hk` ↔ `h[k]` ↔ 契约 C 的 `COEF[k]`（地址 `0x100 + 4·k`）。

## D.3 `coeffs.vh`（Verilog 头文件）

- 82 行，每行一个 `localparam`，命名 `H0`…`H81`（下标从 0 开始，不补零：是 `H0` 不是 `H00`）。
- 语法：`localparam signed [15:0] Hk = 16'sd<十进制有符号>;`
- 值 = `round(浮点系数 × 32768)`，clamp 到 int16 范围。
- 示例（首尾，数值与 PDF 示意一致）：

```verilog
// fir/coeffs.vh —— 81 阶 FIR 系数，Q1.15，抽头顺序 H0=h[0]（当前样本）
localparam signed [15:0] H0  = 16'sd20;
localparam signed [15:0] H1  = -16'sd20;
// ... 中间省略 ...
localparam signed [15:0] H81 = 16'sd20;
```

## D.4 `coeffs.hex`（十六进制补码文本，供 `$readmemh`）

- 82 行，每行恰好 4 个十六进制字符（16-bit 二进制补码），无前缀、无注释、无分隔符。
- 顺序与 `coeffs.vh` 完全一致：第 1 行 = H0，第 82 行 = H81。
- 末尾允许且仅允许一个换行符。
- 示例（对应 D.3）：

```
0014
FFEC
...
0014
```

- 消费方式：

```verilog
reg [15:0] coeff_mem [0:81];
$readmemh("fir/coeffs.hex", coeff_mem);
// 读取后 coeff_mem[k] == Hk（k=0..81）
```

>  `.gitignore` 已排除 `*.hex`，所以 `coeffs.hex` 不进 git，需要时由脚本重新生成；
> `coeffs.vh` 不在忽略列表里，会被提交。

## D.5 两文件一致性（脚本强制校验）

- `coeffs.vh` 第 k 个 localparam 的十进制值 → 转 4 位十六进制补码 → 必须等于 `coeffs.hex` 第 k 行。
- `fir_coeff.py` 生成时自动校验，不一致直接报错退出（防止手改出错）。

## D.6 A/B 消费约定（写清接口，避免踩踏）

| 谁 | 文件 | 怎么用 |
|---|---|---|
| A（`tb_fir_core.v`） | `coeffs.hex` | `$readmemh` 读入 → 经 `coef_we/coef_idx/coef_din` 逐拍写入 fir_core → 输出与 golden model 比对 |
| B（`tb_fir.v`） | `coeffs.hex`/`coeffs.vh` | 经 AXI 写 `COEF[k]`（基址 `0x4000_0000 + 0x100 + 4k`）下发系数，期望值取自本文件 |

- 系数文件只由 C 的脚本生成；任何人要改系数 → 重跑生成命令，不手改文件。

## D.7 生成命令

```
python fir/fir_coeff.py --taps 82 --cutoff 0.12 --nsamp 256
```

## D.8 `fir_data.h`（C 头文件，供 C 驱动，阶段 6 用；阶段 1 可选）

- 用途：真核 C 驱动要把系数编进固件（软硬协同验证时下发 `COEF[k]`）。
- 文件名：`sw/fir_data.h`（由 C 驱动目录定）。
- 内容：`static const int16_t fir_coeffs[NTAP] = { ... };`，顺序与 D.2 一致（下标 0 = h[0]）。

```c
/* 由 fir/fir_coeff.py 自动生成，勿手改 */
static const int16_t fir_coeffs[82] = { 20, 20, -9, /* ... */ };
```

- 状态：⬜ 待确认是否本阶段生成（冻结版建议生成，可留到阶段 6）。

---

## 遗留事项（不阻塞本契约）

- 无。STATUS 的 done/err 位已在任务三 4.1 确认（`[2]=done`、`[3]=err`），系数文件不受影响。
