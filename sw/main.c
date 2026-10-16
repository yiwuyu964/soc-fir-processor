/* ============================================================
 * sw/main.c —— 阶段4 分工 C 的 C 驱动
 *
 * 干两件事：
 *   [1] 冒烟测试 —— CPU 能否正确读写各外设寄存器（SRAM / FIR / DMA / UART）
 *   [2] UART 回显 demo —— 从 UART 收一个字节，原样发回去（本阶段核心交付）
 *
 * 地址与寄存器依据：
 *   docs/阶段4-契约S-soc顶层端口.md §S.4 / §S.5
 *   docs/任务三_地址映射与中断分配.md §4.1 / §4.2 / §4.3
 *
 * 【测试台怎么读结果】
 *   固件把结果写进 SRAM 里的一个"信箱"（地址 0x0000_0F00），
 *   TB/tb_soc.v 直接读那块内存来判定，不依赖串口输出。
 *   这样冒烟测试的结果是可机读的、不靠人眼看日志。
 * ============================================================ */

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;

/* ---------------- 地址映射（契约S §S.4）---------------- */
#define SRAM_BASE   0x00000000u
#define FIR_BASE    0x40000000u
#define DMA_BASE    0x40001000u
#define UART_BASE   0x40002000u
#define APB_BASE    0x40002000u

#define REG32(a)    (*(volatile u32 *)(a))

/* ---- FIR（基址 0x4000_0000，任务三 §4.1）---- */
#define FIR_CTRL    REG32(FIR_BASE + 0x000)
#define FIR_DIN     REG32(FIR_BASE + 0x004)
#define FIR_DOUT    REG32(FIR_BASE + 0x008)
#define FIR_STATUS  REG32(FIR_BASE + 0x00C)
/* STATUS: [0]=fifo_empty [1]=fifo_full [2]=done [3]=err [31:16]=fifo_count */

/* ---- DMA（基址 0x4000_1000，任务三 §4.2）---- */
#define DMA_SRC(n)  REG32(DMA_BASE + 0x10u*(n) + 0x00)
#define DMA_DST(n)  REG32(DMA_BASE + 0x10u*(n) + 0x04)
#define DMA_LEN(n)  REG32(DMA_BASE + 0x10u*(n) + 0x08)
#define DMA_CTRL(n) REG32(DMA_BASE + 0x10u*(n) + 0x0C)
/* CTRL 写: bit0=START(自清) bit1=SRC_INC bit2=DST_INC
 * CTRL 读: bit31=DONE bit30=BUSY bit29=ERR */

/* ---- UART（基址 0x4000_2000，任务三 §4.3）---- */
#define UART_DATA   REG32(UART_BASE + 0x000)
#define UART_STATUS REG32(UART_BASE + 0x004)
#define UART_RXDATA REG32(UART_BASE + 0x008)
/* STATUS: [0]=tx_busy [1]=rx_valid [2]=rx_full [3]=rx_frame_err */
#define UART_ST_TX_BUSY   0x1u
#define UART_ST_RX_VALID  0x2u
#define UART_ST_RX_FULL   0x4u

/* ---------------- 测试信箱（TB 读这里判定）---------------- */
#define MB_BASE     0x00000F00u
#define MB_MAGIC    0x534F4321u     /* 'SOC!' —— TB 看到它就认为固件跑起来了 */
#define MB          ((volatile u32 *)MB_BASE)
#define MB_MAGIC_IDX   0
#define MB_PASS_IDX    1
#define MB_FAIL_IDX    2
#define MB_ECHO_IDX    3
#define MB_DMA_IDX     4
#define MB_FIR_IDX     5
#define MB_STATUS_IDX  6
/* MB[MB_STATUS_IDX] 的取值 */
#define MB_STATUS_SMOKE_OK  0x1000u   /* 冒烟跑完，进入回显循环 */

/* ---------------- 冒烟测试框架 ---------------- */
static u32 g_pass = 0;
static u32 g_fail = 0;

static void check(const char *name, u32 got, u32 exp)
{
    (void)name;
    if (got == exp) g_pass++;
    else            g_fail++;
}

/* 简单延时（给 UART / DMA 留时间） */
static void delay(volatile u32 n)
{
    while (n--) { __asm volatile ("nop"); }
}

/* ---------------- UART ---------------- */
static void uart_putc(u8 b)
{
    /* 等发送器空 */
    while (UART_STATUS & UART_ST_TX_BUSY) { }
    UART_DATA = (u32)b;
}

static int uart_getc_nonblock(u8 *out)
{
    if (UART_STATUS & UART_ST_RX_VALID) {
        *out = (u8)(UART_RXDATA & 0xFFu);
        return 1;
    }
    return 0;
}

/* ---------------- 冒烟测试 ---------------- */
static void smoke_sram(void)
{
    extern u32 _test_sram_start;
    volatile u32 *p = &_test_sram_start;  /* Linker-reserved scratch memory. */
    u32 i;
    for (i = 0; i < 8; i++) p[i] = 0xA5A50000u + i;
    for (i = 0; i < 8; i++) check("sram", p[i], 0xA5A50000u + i);
}

static void smoke_fir(void)
{
    u32 st;
    /* 先 flush，把延迟线清空 */
    FIR_CTRL = 1;
    delay(20);

    st = FIR_STATUS;
    /* 刚 flush 完，FIFO 应该是空的（bit0=1）、没有 done（bit2=0） */
    check("fir_empty", st & 0x1u, 0x1u);
    check("fir_done0", st & 0x4u, 0x0u);

    /* 灌一个冲击（x[0]=0x7FFF，其余 0），推 81 拍应该能出一个非零结果 */
    FIR_DIN = 0x7FFFu;
    {
        int i;
        for (i = 0; i < 81; i++) FIR_DIN = 0x0000u;
    }
    delay(200);

    st = FIR_STATUS;
    MB[MB_FIR_IDX] = st;
    /* 推了 81 个样本进去，FIFO 里应该攒了结果（fifo_count > 0）。
       具体数值对不对由 TB/黄金模型判定，这里只确认"通路活着"。 */
    if (((st >> 16) & 0xFFFFu) > 0u) g_pass++;
    else                             g_fail++;
    /* 读一个结果，确认读操作不挂死 */
    (void)FIR_DOUT;
}

static void smoke_dma(void)
{
    u32 c;
    /* 只做寄存器读写，不真启动搬运（搬运需要内存里有数据，交给 TB 场景） */
    DMA_SRC(0) = 0x00000400u;
    DMA_DST(0) = 0x00000480u;
    DMA_LEN(0) = 4u;

    c = DMA_CTRL(0);
    /* 还没启动：DONE/BUSY/ERR 都应该是 0 */
    check("dma_idle", c & 0xE0000000u, 0u);

    /* 读回验证（SRC/DST/LEN 是只写的，能读回的是 CTRL）——这里只确认不挂死 */
    MB[MB_DMA_IDX] = c;
}

/* ---------------- 主程序 ---------------- */
int main(void)
{
    u32 echo_count = 0;
    u8  b;

    /* 先把信箱清零并打上魔数，TB 看到魔数就知道固件起来了 */
    {
        int i;
        for (i = 0; i < 16; i++) MB[i] = 0u;
    }
    MB[MB_MAGIC_IDX] = MB_MAGIC;

    /* ---- 冒烟测试 ---- */
    smoke_sram();
    smoke_fir();
    smoke_dma();

    MB[MB_PASS_IDX] = g_pass;
    MB[MB_FAIL_IDX] = g_fail;
    MB[MB_STATUS_IDX] = MB_STATUS_SMOKE_OK;   /* 告诉 TB：冒烟做完了，开始等回显 */

    /* ---- UART 回显：收到什么就发回什么 ---- */
    for (;;) {
        if (uart_getc_nonblock(&b)) {
            uart_putc(b);
            echo_count++;
            MB[MB_ECHO_IDX] = echo_count;
        }
    }

    /* 不会到这里 */
}
