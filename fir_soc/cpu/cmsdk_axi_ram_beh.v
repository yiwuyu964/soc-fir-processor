//------------------------------------------------------------------------------
// The confidential and proprietary information contained in this file may
// only be used by a person authorised under and to the extent permitted
// by a subsisting licensing agreement from ARM Limited.
//
//            (C) COPYRIGHT 2010-2015  ARM Limited or its affiliates.
//                ALL RIGHTS RESERVED
//
// This entire notice must be reproduced on all copies of this file
// and copies of this file may only be made by a person if such person is
// permitted to do so under the terms of a subsisting license agreement
// from ARM Limited.
//
//  Version and Release Control Information:
//
//  File Revision       : $Revision: $
//  File Date           : $Date: $
//
//  Release Information : Cortex-M0 DesignStart-r1p0-00rel0
//------------------------------------------------------------------------------
// Verilog-2001 (IEEE Std 1364-2001)
//------------------------------------------------------------------------------
//
//-----------------------------------------------------------------------------
// Abstract :AXI to RAM Interface
//-----------------------------------------------------------------------------
`include "ahb_axi_define.v"

module cmsdk_axi_ram_beh #(
    parameter AW       = 16,						// Address width
    parameter filename = "",                        // 程序存储的文件名
    parameter WS_N     = 0, 						// First access wait state
    parameter WS_S     = 0) 						// Subsequent access wait state
    (
    input wire                         	ACLK,       // Clock
    input wire                         	ARESETn,    // Reset

    //----------------- AXI - Write -----------------
	input wire 							AW_SEL,     // 写片选
    input wire                          AW_VALID,   // 写请求有效
    output wire                         AW_READY,   // 写请求就绪
    input wire [2:0]                    AW_SIZE,    // 写数据宽度
    input wire [1:0]                    AW_BURST,   // 写数据burst类型
    input wire [7:0]                    AW_LEN,     // 写数据burst长度
    input wire [AW-1:0]                 AW_ADDR,    // 写地址

    input wire                          W_VALID,    // 写数据有效
    output wire                         W_READY,    // 写数据就绪
    input wire                          W_LAST,     // 写数据最后一拍
    input wire [31:0]                   W_DATA,     // 写数据

    output wire                         B_VALID,    // 写响应有效
    input wire                          B_READY,    // 写响应就绪
    output wire [1:0]                   B_RESP,     // 写响应

    //----------------- AXI - Read ------------------
	input wire 							AR_SEL,     // 读片选
    input wire                          AR_VALID,   // 读请求有效
    output wire                         AR_READY,   // 读请求就绪
    input wire [2:0]                    AR_SIZE,    // 读数据宽度
    input wire [1:0]                    AR_BURST,   // 读突发类型
    input wire [7:0]                    AR_LEN,     // 读突发长度
    input wire [AW-1:0]                 AR_ADDR,    // 读地址

    output wire                         R_VALID,    // 读数据有效
    input wire                          R_READY,    // 读数据就绪
    output wire                         R_LAST,     // 读数据最后一拍
    output wire [31:0]                  R_DATA,     // 读数据
    output wire [1:0]                   R_RESP      // 读响应信息
    );

    // RF接口信号
    wire                    RF_WAREQ;           	// Address phase write valid
    reg                     RF_WREQ;            	// Data phase write enable
    wire                    RF_WACK;            	// Data phase write ack
    reg [3:0]               RF_WSTB;              	// 写字节选通
    wire                    RF_WSEQ;            	// 顺序写
    reg  [AW-1:0]	    	RF_WADDR;               // Address phase write address
    reg  [31:0]	    	    RF_WDATA;               // Data phase write data（改为寄存，修 bug）
    wire                    RF_RAREQ;           	// Address phase read valid
    wire                    RF_RREQ;            	// Data phase read enable
    wire                    RF_RACK;            	// Data phase read ack
    reg [3:0]               RF_RSTB;                // 读字节选通
    wire                    RF_RSEQ;            	// 顺序读
    reg [AW-1:0]	    	RF_RADDR;               // Address phase read address
    wire [31:0]	    	    RF_RDATA;               // Data phase read data

	//---------------------<状态机参数>-------------------------------------
	localparam STWA_IDLE	= 3'b001;				// 写请求空闲
	localparam STWA_REQ	    = 3'b010;				// 写请求
	localparam STWA_WAIT	= 3'b100;				// 写请求等待
	reg [2:0]               stwa_cur;
	reg [2:0]               stwa_next;

	localparam STW_IDLE		= 4'b0001;				// 写操作空闲
	localparam STW_DATA		= 4'b0010;				// 写操作数据
	localparam STW_BURST	= 4'b0100;				// BURST写等待
	localparam STW_RESP		= 4'b1000;				// 写操作响应
	reg [3:0]               stw_cur;
	reg [3:0]               stw_next;

	localparam STR_IDLE		= 4'b0001;				// 读操作空闲
	localparam STR_REQ		= 4'b0010;				// 读操作请求
	localparam STR_DATA		= 4'b0100;				// 读操作数据
	localparam STR_BURST	= 4'b1000;				// BURST读等待
	reg [3:0]               str_cur;
	reg [3:0]               str_next;

	//---------------------<局部变量定义>-------------------------------------
	reg [7:0]               w_beatCNT;				// BUSRT写操作拍数计数器
	reg [7:0]               r_beatCNT;				// BUSRT读操作拍数计数器


	//############################# 写操作 #################################
	reg						B_VALID_d1, B_READY_d1;

	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			B_VALID_d1 <= 1'b0;
			B_READY_d1 <= 1'b0;
		end
		else begin
			B_VALID_d1 <= B_VALID;                  // 延迟一拍
			B_READY_d1 <= B_READY;                  // 延迟一拍
		end
	end

	//----------------------------------------------------------------------
	//--   写请求状态机第1段（状态迁移）
	//----------------------------------------------------------------------
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			stwa_cur <= STWA_IDLE;
		end
		else begin
			stwa_cur <= stwa_next;
		end
	end

	//----------------------------------------------------------------------
	//--   写请求状态机第2段（输入对状态的影响）
	//----------------------------------------------------------------------
	always @(*) begin
		stwa_next = stwa_cur;		// 默认保持当前状态，避免LATCH
		case(stwa_cur)
			STWA_IDLE: begin						// 写请求空闲
				if(AW_SEL & AW_VALID)               // 写请求
					stwa_next = STWA_REQ;
			end
			STWA_REQ: begin						    // 写请求通道
				stwa_next = STWA_WAIT;
			end
			STWA_WAIT: begin						// 写请求同步
				if(B_VALID_d1 & B_READY_d1)begin
					if(AW_SEL & AW_VALID)			// 单拍流水
						stwa_next = STWA_REQ;
					else							// 单拍非流水
						stwa_next = STWA_IDLE;
				end
			end
			default: stwa_next = STWA_IDLE;			// 防御性编程：异常状态恢复
		endcase
	end

	//----------------------------------------------------------------------
	//--    写请求状态机第3段（状态对输出的影响）
	//----------------------------------------------------------------------
	// AXI信号产生
	assign AW_READY = (stwa_next == STWA_REQ) ? 1'b1 : 1'b0;	// 写请求准备好

	// RF地址信号产生
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			RF_WADDR <= 'h04;						// 复位入口地址
		end
		else if(stwa_next == STWA_REQ)begin
			RF_WADDR <= {AW_ADDR[AW-1:2], 2'b00};	// 要求字边界对齐！！！
		end
		else if(stwa_next == STWA_WAIT)begin
			if((W_VALID & W_READY))
				RF_WADDR <= get_next_addr(RF_WADDR, AW_SIZE, AW_BURST);	// 下一拍地址
		end
	end

    // 写字节选通 (address phase)
    always @(ARESETn or RF_WAREQ or AW_ADDR or AW_SIZE)
    begin
		if(!ARESETn)begin
			RF_WSTB = 4'b0000;          			// Not writing
		end
        else if(RF_WAREQ)
        begin
            case (AW_SIZE)
                0 : // Byte
                begin
                    case (AW_ADDR[1:0])
                        0: RF_WSTB = 4'b0001; 		// Byte 0
                        1: RF_WSTB = 4'b0010; 		// Byte 1
                        2: RF_WSTB = 4'b0100; 		// Byte 2
                        3: RF_WSTB = 4'b1000; 		// Byte 3
                        default:RF_WSTB = 4'b0000; 	// Address not valid
                    endcase
                end
                1 : // Halfword
                begin
                    if (AW_ADDR[1])
                        RF_WSTB = 4'b1100;  		// Upper halfword
                    else
                        RF_WSTB = 4'b0011;  		// Lower halfword
                end
                default: // Word
                    RF_WSTB = 4'b1111;      		// Whole word
            endcase
        end
    end

	//----------------------------------------------------------------------
	//--   写数据响应状态机第1段（状态迁移）
	//----------------------------------------------------------------------
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			stw_cur <= STW_IDLE;
		end
		else begin
			stw_cur <= stw_next;
		end
	end

	//----------------------------------------------------------------------
	//--   写数据响应状态机第2段（输入对状态的影响）
	//----------------------------------------------------------------------
	always @(*) begin
		stw_next = stw_cur;			// 默认保持当前状态，避免LATCH
		case(stw_cur)
			STW_IDLE: begin							// 写数据空闲
				if(AW_SEL & W_VALID)                // 写数据请求
					stw_next = STW_DATA;
			end
			STW_DATA: begin							// 写数据通道
                if(RF_WACK)begin
                    if(w_beatCNT >= AW_LEN)	    	// 单拍或者BUSRT最后一拍
                        stw_next = STW_RESP;
                    else					    	// BUSRT写
                        stw_next = STW_BURST;
                end
			end
			STW_BURST: begin						// BURST写
				if(W_VALID)
					stw_next = STW_DATA;
			end
			STW_RESP: begin							// 写响应通道
				if(B_READY_d1)begin
					if(AW_SEL & W_VALID)			// 单拍流水
						stw_next = STW_DATA;
					else	    					// 单拍非流水或者BUSRT最后一拍
						stw_next = STW_IDLE;
				end
			end
			default: stw_next = STW_IDLE;			// 防御性编程：异常状态恢复
		endcase
	end

	// BUSRT写操作拍数计数
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			w_beatCNT <= 'h0; 
		end
		else if((stw_cur == STW_DATA) ||(stw_cur == STW_BURST)) begin
			if((W_VALID & W_READY) && (w_beatCNT < AW_LEN))
				w_beatCNT <= w_beatCNT + 1;			// 完成一拍
		end
		else
			w_beatCNT <= 'h0;                       // 重置
	end

	//----------------------------------------------------------------------
	//--    写数据响应状态机第3段（状态对输出的影响）
	//----------------------------------------------------------------------
	// AXI信号产生
	assign W_READY = (stw_next == STW_DATA) ? 1'b1 : 1'b0;	// 写数据准备好

	assign B_VALID = (stw_next == STW_RESP) ? 1'b1 : 1'b0;	// 写响应有效
	assign B_RESP = 2'b00;							// 输出写响应信息：OKAY	

	// RF数据信号产生
    // Generate write control (address phase)
    assign RF_WAREQ = AW_SEL & AW_VALID & AW_READY & (~RF_RREQ);  // 读写数据时互斥操作

    // Generate write enable (data phase)
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			RF_WREQ <= 1'b0;
		end
		else begin
			RF_WREQ <= W_VALID & W_READY;           // RF写请求有效
		end
	end

	// 修 bug：原来 `assign RF_WDATA = W_DATA;` 是组合直通，但下面的 RAM 写入
	// 发生在 RF_WREQ（= W_VALID & W_READY 延迟一拍）之后，导致采样到的 W_DATA
	// 是"下一拍"已经变掉的旧数据（所以循环计数器 i++ 写回去的值不对）。
	// 改成在握手那一拍把 W_DATA 寄存下来，保证写进 RAM 的数据就是握手时的数据。
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn)
			RF_WDATA <= 32'h0;
		else if(W_VALID & W_READY)
			RF_WDATA <= W_DATA;
	end

    //  Wait state generate treat access as sequential if AW_LEN > 0, 
    //  or access address is in the same word, or if the access is in the next word
    assign RF_WSEQ = (AW_LEN > 0) | (AW_ADDR[AW-1:2] == RF_WADDR[AW-1:2]) |
                                    (AW_ADDR[AW-1:2] == (RF_WADDR[AW-1:2]+1));


	//############################# 读操作 #################################
	reg						RF_RACK_d1;

	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			RF_RACK_d1 <= 1'b0;
		end
		else begin
			RF_RACK_d1 <= RF_RACK;                  // 延迟一拍
		end
	end

	//----------------------------------------------------------------------
	//--   状态机第1段（状态迁移）
	//----------------------------------------------------------------------
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			str_cur <= STR_IDLE;
		end
		else begin
			str_cur <= str_next;
		end
	end

	//----------------------------------------------------------------------
	//--   状态机第2段（输入对状态的影响）
	//----------------------------------------------------------------------
	always @(*) begin
		str_next = str_cur;
		case(str_cur)
			STR_IDLE: begin							// 读空闲
				if(AR_SEL & AR_VALID)               // 读请求
					str_next = STR_REQ;
			end
			STR_REQ: begin							// 读请求通道
				str_next = STR_DATA;
			end
			STR_DATA: begin							// 读数据通道
                if(RF_RACK_d1)begin
                    if(r_beatCNT < AR_LEN)			// BURST读
                        str_next = STR_BURST;
					else if(AR_SEL & AR_VALID)		// 单拍流水
						str_next = STR_REQ;
					else		                	// 单拍或者BURST最后一拍
						str_next = STR_IDLE;
                end
			end
			STR_BURST: begin						// BURST读
				str_next = STR_DATA;
			end
			default: str_next = STR_IDLE;			// 防御性编程：异常状态恢复
		endcase
	end

	// BUSRT读操作拍数计数
	always @(posedge ACLK or negedge ARESETn) begin
		if(!ARESETn) begin
			r_beatCNT <= 'h0; 
		end
 		else if(str_next == STR_REQ) begin
			r_beatCNT <= 'h0;                       // 重置
		end
 		else if(str_next == STR_BURST) begin
			r_beatCNT <= r_beatCNT + 1;		    	// 完成一拍
		end
	end

	//----------------------------------------------------------------------
	//--   状态机第3段（状态对输出的影响）
	//----------------------------------------------------------------------
	// AXI信号产生
	assign AR_READY = (str_next == STR_REQ) ? 1'b1 : 1'b0; 	// 读请求准备好

	assign R_VALID = RF_RACK;                       // 读数据有效
	assign R_LAST = R_VALID & R_READY & (r_beatCNT == AR_LEN);	// 最后一拍数据
	assign R_DATA = RF_RDATA;                   	// 输出读数据
	assign R_RESP = 2'b00; 							// 输出读响应信息：OKAY

	// RF信号产生
    // BURST读操作计算下一拍地址
    always @(posedge ACLK or negedge ARESETn)
    begin
		if(!ARESETn) begin
			RF_RADDR <= 'h04;						// 复位入口地址
		end
		else if(str_next == STR_REQ)begin
			RF_RADDR <= {AR_ADDR[AW-1:2], 2'b00};	// 要求字边界对齐！！！
		end
		else if(str_next == STR_BURST)begin
			RF_RADDR <= get_next_addr(RF_RADDR, AR_SIZE, AR_BURST);	// 下一拍地址
		end
	end

    // Generate read control (address phase)
    assign RF_RAREQ = AR_SEL & AR_VALID & AR_READY & (~RF_WREQ);  // 读写数据时互斥操作
 
    // Generate read enable (data and respone phase)
    assign RF_RREQ  = R_READY;                      // RF读请求有效

    // 读字节选通 (address phase, Registering read strobe signals to data phase)
    always @(posedge ACLK or negedge ARESETn)
    begin
        if(~ARESETn)begin
            RF_RSTB <= 4'b0000;
        end
        else if(RF_RAREQ)
        begin
            case (AR_SIZE)
                0 : // Byte
                begin
                    case (AR_ADDR[1:0])
                        0: RF_RSTB = 4'b0001; 		// Byte 0
                        1: RF_RSTB = 4'b0010; 		// Byte 1
                        2: RF_RSTB = 4'b0100; 		// Byte 2
                        3: RF_RSTB = 4'b1000; 		// Byte 3
                        default:RF_RSTB = 4'b0000; 	// Address not valid
                    endcase
                end
                1 : // Halfword
                begin
                    if (AR_ADDR[1])
                        RF_RSTB = 4'b1100; 			// Upper halfword
                    else
                        RF_RSTB = 4'b0011; 			// Lower halfword
                end
                default : // Word
                    RF_RSTB = 4'b1111; 				// Whole word
            endcase
        end
    end

    //  Wait state generate treat access as sequential if AR_LEN > 0, 
    //  or access address is in the same word, or if the access is in the next word
    assign RF_RSEQ = (AR_LEN > 0) | (AR_ADDR[AW-1:2] == RF_RADDR[AW-1:2]) |
                                    (AR_ADDR[AW-1:2] == (RF_RADDR[AW-1:2]+1));

	//############################# 基本函数 #################################
    function [AW-1:0]   get_next_addr;
        input [AW-1:0]  addr ;
        input [ 2:0]    size ;
        input [ 1:0]    burst; // burst type
     begin
        case (burst)
        `FIXED_AXI: get_next_addr = addr;     		// 固定地址
        `INCR_AXI: get_next_addr = addr + (1<<size);// 递增地址
        `WRAP_AXI: begin        					// 回绕地址——不支持
               $display($time,,"%m ERROR BURST WRAP not supported");
               end
        `RESERVED_AXI: begin        				// 保留
               get_next_addr = addr;
               $display($time,,"%m ERROR un-defined BURST %01x", burst);
               end
        endcase
    end
    endfunction


    // #########################RAM模型##############################
    // Abstract : Simple AXI RAM behavioral model
    // 内部信号
    reg    [7:0]  ram_data[0:((1<<AW)-1)];          // 64k byte of RAM data

    reg    [7:0]  rdata_out_0;                      // Read Data Output byte#0
    reg    [7:0]  rdata_out_1;                      // Read Data Output byte#1
    reg    [7:0]  rdata_out_2;                      // Read Data Output byte#2
    reg    [7:0]  rdata_out_3;                      // Read Data Output byte#3

    // Wait state control
    reg   [31:0]  write_waitstate_cnt;
    wire  [31:0]  write_waitstate_cnt_next;

    reg   [31:0]  read_waitstate_cnt;
    wire  [31:0]  read_waitstate_cnt_next;


    // Start of main code
    // Initialize ROM
    integer       i;                                // Loop counter
    initial
    begin
        for(i=0; i<(1<<AW); i=i+1)
        begin
            ram_data[i] = 8'h00;                    //Initialize all data to 0
        end
        if(filename != "")
        begin
            $readmemh(filename, ram_data);          // Then read in program code
        end
    end

    // 写操作
    // Registered write
    always @(posedge ACLK)
    begin
        if(RF_WREQ &  RF_WSTB[0])
        begin
            ram_data[RF_WADDR  ] = RF_WDATA[ 7: 0];
        end
        if(RF_WREQ &  RF_WSTB[1])
        begin
            ram_data[RF_WADDR+1] = RF_WDATA[15: 8];
        end
        if(RF_WREQ &  RF_WSTB[2])
        begin
            ram_data[RF_WADDR+2] = RF_WDATA[23:16];
        end
        if(RF_WREQ &  RF_WSTB[3])
        begin
            ram_data[RF_WADDR+3] = RF_WDATA[31:24];
        end
    end

    assign RF_WACK = RF_WREQ;                       // Write acknowledge
    //assign RF_WACK = RF_WREQ & (write_waitstate_cnt == 0);

    // Write wait state control
    assign write_waitstate_cnt_next = (RF_WAREQ) ?
                             ((RF_WSEQ) ? WS_S : WS_N) :
                             ((write_waitstate_cnt != 0) ? (write_waitstate_cnt - 1) : 0);
    // Register wait state counter
    always @(posedge ACLK or negedge ARESETn)
    begin
        if(~ARESETn)
            write_waitstate_cnt <= 0;
        else
            write_waitstate_cnt <= write_waitstate_cnt_next;
    end


    // 读操作
    // Read operation
    always @(ARESETn or RF_RREQ or RF_RSTB or RF_RADDR)
        if(~ARESETn)
            rdata_out_0 = 8'h00;
        else if((RF_RREQ & RF_RSTB[0]))
            rdata_out_0 = ram_data[RF_RADDR  ];
		else
			rdata_out_0 = 8'h00;

    always @(ARESETn or RF_RREQ or RF_RSTB or RF_RADDR)
        if(~ARESETn)
            rdata_out_1 = 8'h00;
        else if((RF_RREQ & RF_RSTB[1]))
            rdata_out_1 = ram_data[RF_RADDR+1];
		else
			rdata_out_1 = 8'h00;

    always @(ARESETn or RF_RREQ or RF_RSTB or RF_RADDR)
        if(~ARESETn)
            rdata_out_2 = 8'h00;
        else if((RF_RREQ & RF_RSTB[2]))
            rdata_out_2 = ram_data[RF_RADDR+2];
		else
			rdata_out_2 = 8'h00;

    always @(ARESETn or RF_RREQ or RF_RSTB or RF_RADDR)
        if(~ARESETn)
            rdata_out_3 = 8'h00;
        else if((RF_RREQ & RF_RSTB[3]))
            rdata_out_3 = ram_data[RF_RADDR+3];
		else
			rdata_out_3 = 8'h00;

	assign RF_RDATA = {rdata_out_3, rdata_out_2, rdata_out_1,rdata_out_0};    // 读数据

    assign RF_RACK = RF_RREQ & (read_waitstate_cnt == 0);   // 读应答

    // Read wait state control
    assign read_waitstate_cnt_next = (RF_RAREQ) ?
                             ((RF_RSEQ) ? WS_S : WS_N) :
                             ((read_waitstate_cnt != 0) ? (read_waitstate_cnt - 1) : 0);
    // Register wait state counter
    always @(posedge ACLK or negedge ARESETn)
    begin
        if(~ARESETn)
            read_waitstate_cnt <= 0;
        else
            read_waitstate_cnt <= read_waitstate_cnt_next;
    end

endmodule
