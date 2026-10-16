@ ============================================================
@ sw/startup.s —— Cortex-M0 启动代码（阶段4 分工 C）
@
@ 干什么：
@   1. 向量表（从 0x0 开始，共 48 个表项 = 初始 SP + 15 个系统异常 + 32 个 IRQ）
@   2. Reset_Handler：清零 .bss → 调 main → main 返回就死循环
@   3. 各中断的默认处理函数（弱符号，C 里可以覆盖）
@
@ 中断号依据：docs/阶段4-契约S-soc顶层端口.md §S.5（与 docs/任务三 §5.2 一致）
@   IRQ0      FIR 滤波完成        fir.irq_done
@   IRQ1      FIR 错误            fir.irq_err
@   IRQ2~7    DMA 通道 0~5 完成   dma.irq_done[5:0]
@   IRQ8      DMA 全局错误        dma.irq_err
@   IRQ9~31   预留，恒 0（向量表里填 Default_Handler 即可）
@ ============================================================

    .syntax unified
    .cpu cortex-m0
    .thumb

@ ------------------------------------------------------------
@ 向量表：必须放在最前面（链接脚本 .vectors 段，地址 0x0）
@ ------------------------------------------------------------
    .section .vectors, "a", %progbits
    .align 2
    .global  __isr_vector
__isr_vector:
    .word   _estack                 @ 0x00  初始栈指针
    .word   Reset_Handler           @ 0x04  复位入口
    .word   Default_Handler         @ 0x08  NMI
    .word   Default_Handler         @ 0x0C  HardFault
    .word   Default_Handler         @ 0x10  保留
    .word   Default_Handler         @ 0x14  保留
    .word   Default_Handler         @ 0x18  保留
    .word   Default_Handler         @ 0x1C  保留
    .word   Default_Handler         @ 0x20  保留
    .word   Default_Handler         @ 0x24  保留
    .word   Default_Handler         @ 0x28  保留
    .word   Default_Handler         @ 0x2C  SVCall
    .word   Default_Handler         @ 0x30  保留
    .word   Default_Handler         @ 0x34  保留
    .word   Default_Handler         @ 0x38  PendSV
    .word   Default_Handler         @ 0x3C  SysTick
    @ ---- 以下是外部中断 IRQ0 ~ IRQ31（异常号 16~47）----
    .word   FIR_DONE_Handler         @ IRQ0  FIR done
    .word   FIR_ERR_Handler          @ IRQ1  FIR err
    .word   DMA_DONE_Handler         @ IRQ2  DMA ch0
    .word   DMA_DONE_Handler         @ IRQ3  DMA ch1
    .word   DMA_DONE_Handler         @ IRQ4  DMA ch2
    .word   DMA_DONE_Handler         @ IRQ5  DMA ch3
    .word   DMA_DONE_Handler         @ IRQ6  DMA ch4
    .word   DMA_DONE_Handler         @ IRQ7  DMA ch5
    .word   DMA_ERR_Handler          @ IRQ8  DMA err
    .word   Default_Handler         @ IRQ9  预留
    .word   Default_Handler         @ IRQ10 预留
    .word   Default_Handler         @ IRQ11 预留（UART RX 无中断输出）
    .word   Default_Handler         @ IRQ12 预留（UART TX 无中断输出）
    .word   Default_Handler         @ IRQ13
    .word   Default_Handler         @ IRQ14
    .word   Default_Handler         @ IRQ15
    .word   Default_Handler         @ IRQ16
    .word   Default_Handler         @ IRQ17
    .word   Default_Handler         @ IRQ18
    .word   Default_Handler         @ IRQ19
    .word   Default_Handler         @ IRQ20
    .word   Default_Handler         @ IRQ21
    .word   Default_Handler         @ IRQ22
    .word   Default_Handler         @ IRQ23
    .word   Default_Handler         @ IRQ24
    .word   Default_Handler         @ IRQ25
    .word   Default_Handler         @ IRQ26
    .word   Default_Handler         @ IRQ27
    .word   Default_Handler         @ IRQ28
    .word   Default_Handler         @ IRQ29
    .word   Default_Handler         @ IRQ30
    .word   Default_Handler         @ IRQ31

@ ------------------------------------------------------------
@ Reset_Handler
@   方案 B 下 .data 和 .text 同在 SRAM，不需要"从 Flash 拷贝"，
@   所以启动代码只做一件事：把 .bss 清零，然后进 main。
@ ------------------------------------------------------------
    .section .text.Reset_Handler, "ax", %progbits
    .align 2
    .global  Reset_Handler
    .type    Reset_Handler, %function
Reset_Handler:
    @ 关总中断（M0 的 PRIMASK 在 r0 里，cpsid i 等价）
    cpsid   i

    @ 清零 .bss
    ldr     r0, =_sbss
    ldr     r1, =_ebss
    movs    r2, #0
1:  cmp     r0, r1
    bhs     2f
    stmia   r0!, {r2}
    b       1b
2:

    @ 进 main
    bl      main

    @ main 不该返回；万一返回了就死在这里
3:  b       3b

    .size Reset_Handler, . - Reset_Handler

@ ------------------------------------------------------------
@ 默认中断处理：死循环
@   用 .weak 让 C 里定义同名函数即可覆盖
@ ------------------------------------------------------------
    .section .text.Default_Handler, "ax", %progbits
    .align 2
    .weak    Default_Handler
    .type    Default_Handler, %function
Default_Handler:
4:  b       4b
    .size Default_Handler, . - Default_Handler

@ ------------------------------------------------------------
@ 给 C 用的弱别名（可选覆盖）
@ ------------------------------------------------------------
    .weak    FIR_DONE_Handler
    .thumb_set FIR_DONE_Handler, Default_Handler
    .weak    FIR_ERR_Handler
    .thumb_set FIR_ERR_Handler, Default_Handler
    .weak    DMA_DONE_Handler
    .thumb_set DMA_DONE_Handler, Default_Handler
    .weak    DMA_ERR_Handler
    .thumb_set DMA_ERR_Handler, Default_Handler

    .end
