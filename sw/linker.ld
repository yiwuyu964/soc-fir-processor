/* ============================================================
 * sw/linker.ld —— Cortex-M0 链接脚本（阶段4 方案 B：SRAM @0x0）
 *
 * 地址依据：docs/阶段4-契约S-soc顶层端口.md §S.4 / §S.6
 *   · 方案 B：不做 ROM，片内 SRAM 放在 0x0000_0000，64KB
 *   · 程序 / 数据 / 栈 全部挤在这 64KB 里
 *   · M0 复位后从 0x0 取初始栈指针、0x4 取复位入口
 *
 * 布局：
 *   0x0000_0000  .vectors  向量表（必须是头 8 字节：初始 SP + Reset_Handler）
 *   0x0000_00xx  .text     代码 + 只读数据
 *   ...          .data     已初始化变量（启动时从 Flash 拷来；这里同在 SRAM，
 *                          所以启动代码里只需要清零 .bss 即可）
 *   ...          .bss      未初始化变量
 *   0x0000_FFFF  栈顶（向下生长）
 * ============================================================ */

ENTRY(Reset_Handler)

MEMORY
{
    SRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

/* 栈顶 = SRAM 末端 */
_estack = ORIGIN(SRAM) + LENGTH(SRAM);

SECTIONS
{
    /* ---- 向量表：必须放在最前面 ---- */
    .vectors : ALIGN(4)
    {
        KEEP(*(.vectors))
    } > SRAM

    /* ---- 代码 ---- */
    .text : ALIGN(4)
    {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
        _etext = .;
    } > SRAM

    ASSERT(. <= 0xE00, "Code overlaps reserved smoke-test memory")
    .test_sram 0xE00 (NOLOAD) :
    {
        _test_sram_start = .;
        . = . + 0x100;
    } > SRAM
    .mailbox 0xF00 (NOLOAD) : { . = . + 0x100; } > SRAM

    /* ---- 已初始化数据 ---- */
    .data : ALIGN(4)
    {
        _sdata = .;
        *(.data)
        *(.data.*)
        . = ALIGN(4);
        _edata = .;
    } > SRAM

    /* ---- 未初始化数据 ---- */
    .bss : ALIGN(4)
    {
        _sbss = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > SRAM

    /* ---- 给栈留个符号性的位置（实际不占用输出段）---- */
    ASSERT(. <= _estack - 0x4000, "Data overlaps stack")
    .stack (_estack - 0x4000) (NOLOAD) :
    {
        . = . + 0x4000;          /* 16KB 栈 */
        . = ALIGN(8);
    } > SRAM

    /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
