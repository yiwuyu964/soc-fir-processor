# 契约 C：AXI ID 编码（已冻结 v1）

> 文档信息 ｜ 类别：契约类 ｜ 所属：跨阶段 ｜ 状态：冻结 ｜ 索引：`docs/README.md §1.1`
>
> 冻结日期：2026-10-11
> 关联：`../任务4-模块接口信号清单.md` 1.3 / 1.6 节、`../任务3-地址映射与中断分配.md`、`../阶段划分/阶段3-三人分工.md` §2

## 一、契约内容

DMA 的 AXI4 主口（数据口）事务 ID 编码：

```verilog
m_axi_awid = { CH[2:0], 1'b1 }     // 例：通道 3 → 4'b0111
m_axi_arid = { CH[2:0], 1'b1 }
m_axi_bid  = 原样返回对应的 AWID
m_axi_rid  = 原样返回对应的 ARID
```

| 位 | 含义 |
|---|---|
| `ID[0]` | 恒为 1，标记"这条事务来自 DMA" |
| `ID[3:1]` | 通道号 CH，取值 0 到 5 |

之所以这么编码，是因为 `../任务4-模块接口信号清单.md` 1.3 节规定"DMA 数据口，主设备 ID=1"。六个通道共用一个 AXI 主口，如果直接用通道号当 ID，就分不清这条事务来自 CPU 还是 DMA。固定最低位为 1 保留"这是 DMA"这个信息，高三位用来区分通道。

## 二、谁依赖这份契约

| 依赖方 | 依赖什么 | 出错的后果 |
|---|---|---|
| B（`dma_engine`） | 用 `CH` 参数生成 ID，不能硬编码 | 通道号错位 |
| A（`dma.v` 顶层） | 6→1 仲裁时 ID 原样透传，不能改写 | 响应回选到错误的通道 |
| 阶段 2 的 AXI 互连 | 靠 `ID[0]` 区分"事务来自 CPU 还是 DMA" | **路由到错误的从设备** |
| C（验证） | 按这个编码写期望值 | 测不出真问题 |

这条契约比别的更危险，原因是它**跨阶段**。阶段 2 的 AXI 互连写在另一个分支上、由另一个人维护。如果哪天有人改了编码——比如把通道号挪到低位——互连不会报任何错，只会把 DMA 的数据悄悄路由到错误的从设备上去。

不报错的错误是最难查的错误。所以这条契约要三件事一起做：写进文档（本文）、变成仿真里能自动检查的东西（第三节）、改动走流程（第五节）。

## 三、编码型契约要用代码钉住

接口型契约（端口名、位宽）可以写个 `.v` 空壳来冻结。编码型契约不行——端口的名字和位宽都没变，变的是**含义**，空壳冻不住它。所以要用检查器。

### 3.1 自动检查器

`TB/axi_id_contract_check.v` 是个纯被动监视器，只读不写，挂在 DMA 的 AXI4 主口上：

```verilog
axi_id_contract_check #(.NAME("dma_m")) u_id_chk (
    .clk(clk), .rst_n(rst_n),
    .awid(m_axi_awid), .awvalid(m_axi_awvalid), .awready(m_axi_awready),
    .bid (m_axi_bid),  .bvalid (m_axi_bvalid),  .bready (m_axi_bready),
    .arid(m_axi_arid), .arvalid(m_axi_arvalid), .arready(m_axi_arready),
    .rid (m_axi_rid),  .rvalid (m_axi_rvalid),  .rready (m_axi_rready),
    .error_count(id_contract_errors)
);
```

检查四条规则：

| 规则 | 内容 |
|---|---|
| C1 | `AWID[0]` 必须是 1 |
| C2 | `ARID[0]` 必须是 1 |
| C3 | `AWID` 的通道号必须在 0 到 5 范围内 |
| C4 | `ARID` 的通道号必须在 0 到 5 范围内 |

`BID`/`RID` 与 `AWID`/`ARID` 的顺序和取值匹配不归这里管，由 `TB/axi_protocol_checker.v` 的规则 R10 负责，本检查器不重复。

跑完看 `error_count`，为 0 说明契约守住了。

### 3.2 自测台

`TB/tb_axi_id_check.v` 负责证明检查器不误报也不漏报：

| 用例 | 内容 | 期望 |
|---|---|---|
| T0 | 6 个通道各发一次合法的 AW + AR | 0 个错误（防误报） |
| T1 | `AWID[0] = 0` | 抓到 C1 |
| T2 | `ARID[0] = 0` | 抓到 C2 |
| T3 | `AWID` 通道号 = 7 | 抓到 C3 |
| T4 | `ARID` 通道号 = 6 | 抓到 C4 |

为什么非得做自测？因为一个"永远不报错"的检查器会让所有人误以为代码是对的。只有证明它对每条违规都会报错，它的"0 错误"才有意义。这五项目前全部通过。

### 3.3 备选方案：RTL 里的断言

如果不想接检查器，至少在 `RTL/dma.v` 顶层加这几行：

```verilog
// 契约C：AXI ID = { CH[2:0], 1'b1 }，最低位恒为 1
// 依据 docs/契约/契约C-AXI ID编码.md，改动必须三人同意
always @(posedge clk) begin
    if (rst_n && m_axi_awvalid && (m_axi_awid[0] !== 1'b1))
        $display("  [契约C违规] t=%0t AWID=%b 最低位不是 1", $time, m_axi_awid);
    if (rst_n && m_axi_arvalid && (m_axi_arid[0] !== 1'b1))
        $display("  [契约C违规] t=%0t ARID=%b 最低位不是 1", $time, m_axi_arid);
end
```

两样都做最好：断言让 RTL 随时自检，检查器让测试台能独立验收。

## 四、实现方各自要做什么

| 谁 | 做什么 |
|---|---|
| B | `dma_engine` 里用 `parameter CH` 生成 ID：`assign m_awid = {CH[2:0], 1'b1};`，不要硬编码 |
| A | `dma.v` 顶层做 6→1 仲裁时 ID 原样透传，不做任何改写，并加上 3.3 节的断言 |
| C | 在 `tb_dma.v` 里挂 `axi_id_contract_check`，把 `error_count` 纳入最终 PASS/FAIL 判定 |

## 五、改这份契约的流程

不许私自改。要改就走这五步：

1. 在群里发起，说明为什么要改
2. 三人同意，**尤其要通知阶段 2 的 AXI 互连实现者**——他直接依赖这条
3. 本文版本号升到 v2，写明改了什么、为什么
4. 同步更新 `TB/axi_id_contract_check.v` 的参数和 `TB/tb_axi_id_check.v` 的期望值
5. 通知全队

## 六、验证状态

| 项 | 状态 |
|---|---|
| `TB/axi_id_contract_check.v` 编译（`-Wall`） | 零告警 |
| `TB/tb_axi_id_check.v` 自测 | 5/5 通过，不误报不漏报 |
| 挂到真实 DMA 主口验证 | 通过。`tb_dma` 的 69 项检查里包含契约 C 专项，`tb_dma_ic` 和 `tb_dma_self` 也各挂了一份 |
