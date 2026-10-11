/*  riscvmulti module only:
 *  Modified from https://github.com/YosysHQ/picorv32/blob/main/picorv32.v
 *  PicoRV32 -- A Small RISC-V (RV32I) Processor Core
 *
 *  Copyright (C) 2015  Claire Xenia Wolf <claire@yosyshq.com>
 *  Modified by Jonghyeok Kim <rhdtn1244@gmail.com>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

 /* rest of the modules:
 *  Modified from https://github.com/YosysHQ/picorv32/blob/main/picorv32.v
 *  PicoRV32 -- A Small RISC-V (RV32I) Processor Core
 *
 *  Copyright (C) 2026  Jonghyeok (Burt) Kim <rhdtn1244@gmail.com>
 *
 *  Permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 *  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 *  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 *  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 *  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 *  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 *  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 */

`timescale 1 ns / 1 ps

module riscvmulti (
	input clk, resetn,
	// Trap Output
	output reg trap,
	output reg do_wfi,
	
	// Memory Interface Signals
	// Instruction/Data Memory
	output reg        mem_valid, // high when the CPU wants to initiate a memory operation
	output reg        mem_instr, // Indicates whether the current memory access is a code fetch (instruction) or a data access
								 // instruction fetch, 0:data load/store
	input             mem_ready, // Response signal from memory saying, “I’ve completed your read/write.”
								 // The CPU waits until this becomes high before proceeding.
	output reg [31:0] mem_addr,  // Address to access in memory - can point to an instruction (PC value) and a data load/store location
	output reg [31:0] mem_wdata, // The data to write during a store instruction. (Ignored during a load or fetch)
	output reg [ 3:0] mem_wstrb, // Tells which byte(s) in mem_wdata are valid.
								 // 4'b0001 → write only byte 0, 4'b1111 → write full 32-bit word
	input      [31:0] mem_rdata, // data read from the memory
	
	// IRQ Interface
	input      [31:0] irq,
	output reg [31:0] eoi, // End Of Interrupt

	// Debugging Registers
    output [31:0] dbg_pc
);
	// Program Counter - Definition and Increment
	// Temporary Registers (A, B, ALUOut, Data)
	reg [31:0] reg_pc, reg_next_pc;

	// ALU (Arithmetic Logic Unit)
	// Temporary Registers (A, B, ALUOut, Data)
	reg [31:0] reg_op1, reg_op2;

	// Result Mux (ResultSrc)
	reg [31:0] reg_out;
	
	// SrcB Mux (ALUSrcB)
	wire [31:0] pc_inc = 32'd4;
	reg [31:0] decoded_pc;
	wire [31:0] next_pc_raw = reg_pc + pc_inc;
	wire stale_decode = (decoded_pc != reg_pc);
	reg [4:0] reg_sh; // shift amount for shift instructions

	reg irq_delay; // used internally to sync IRQ response
	reg irq_active; // used internally to sync IRQ response
	reg [31:0] irq_mask; // enables/disables specific interrupts
	reg [31:0] irq_pending; // tracks interrupts waiting to be handled
	
    `ifndef PICORV32_REGS
		// Register File - Register File + Initialize to Zero
		reg [31:0] cpuregs [0:15];
	`endif
    assign dbg_pc     = reg_pc;

	reg [1:0] mem_state;
	reg [1:0] mem_wordsize;
	reg [31:0] mem_rdata_word;
	reg instr_sb, instr_sh, instr_sw; 
	reg [3:0] mem_wstrb_next;
	reg clear_instr_wfi;
	// Instruction/Data Memory
	// Temporary Registers (A, B, ALUOut, Data)
	reg [31:0] mem_rdata_q;

	reg mem_do_prefetch;
	reg mem_do_rinst;
	reg mem_do_rdata;

	// Instruction Decoder / Control Unit - MemWrite
	reg mem_do_wdata;
	
	// Instruction/Data Memory - Memory Transfer Detection
	wire mem_xfer = mem_valid && mem_ready;

	wire [31:0] mem_rdata_latched = mem_xfer ? mem_rdata : mem_rdata_q;

	// Immediate Extend Unit
	reg [31:0] decoded_imm, decoded_imm_j;

	reg [3:0] decoded_rd, decoded_rs1;
	reg [7:0] cpu_state;
	reg [1:0] irq_state;

	reg decoder_trigger;
	reg decoder_trigger_q;
	
	wire [31:0] mem_rdata_shifted = mem_rdata >> (reg_op1[1:0] * 8);

	always @* begin
		case (mem_wordsize)
			2'd0: mem_rdata_word = mem_rdata;
			2'd1: mem_rdata_word = {16'b0, mem_rdata_shifted[15:0]};
			2'd2: mem_rdata_word = {24'b0, mem_rdata_shifted[7:0]};
			default: mem_rdata_word = mem_rdata;
		endcase
	end

	// Instruction/Data Memory - Store Instruction for Decode
	always @(posedge clk) begin
		if (mem_xfer && (mem_do_prefetch || mem_do_rinst)) begin
			mem_rdata_q <= mem_rdata;
		end
	end

	reg instr_mret, instr_wfi;
	// reg instr_maskirq;
	always @(posedge clk or negedge resetn) begin
		if (!resetn) begin
				mem_state <= 0;
				mem_valid <= 0;
		end else if (trap && !do_wfi) begin
				// Allow state 3 to exit even during trap
				if (mem_state == 3) begin
					mem_state <= 0;
				end
		end else begin
				(* parallel_case, full_case *)
				case (mem_state)
					0: begin
						(* parallel_case *)
						case (1'b1)
							mem_do_prefetch || mem_do_rinst || mem_do_rdata: begin
								mem_instr <= mem_do_prefetch || mem_do_rinst;
								mem_wstrb <= 0;
								// Instruction/Data Memory - Address Source Selection (AdrSrc Mux)
								mem_addr <= (mem_do_prefetch || mem_do_rinst)
									? (decoder_trigger ? { reg_next_pc[31:2], 2'b00 } : { reg_pc[31:2], 2'b00 })
									: {reg_op1[31:2], 2'b00};
								mem_valid <= 1'b1;
								mem_state <= 1;
							end
							
							mem_do_wdata: begin
								mem_valid <= 1'b1;
								mem_instr <= 1'b0;
								mem_addr  <= {reg_op1[31:2], 2'b00};
								mem_wdata <= reg_op2;
								mem_wstrb <= mem_wstrb_next;
								mem_state <= 2;
							end
							
							default: begin
								// Stay in state 0
							end
						endcase
					end
					
					1: begin
						if (mem_xfer) begin
							mem_valid <= 0;
							if (mem_do_rdata)
								mem_state <= 0;
							else
								mem_state <= mem_do_rinst ? 0 : 3;
						end
					end
					
					2: begin
						if (mem_xfer) begin
							mem_valid <= 0;
							mem_state <= 0;
						end
					end
					
					3: begin
						mem_state <= 0;
					end
				endcase
			end
	end
	// Instruction Decoder
	reg instr_lui, instr_auipc, instr_jal, instr_jalr;
	reg instr_beq, instr_bne, instr_blt, instr_bge, instr_bltu, instr_bgeu;
	reg instr_lb, instr_lh, instr_lw, instr_lbu, instr_lhu; 
	reg instr_addi, instr_slti, instr_sltiu, instr_xori, instr_ori, instr_andi, instr_slli, instr_srli, instr_srai;
	reg instr_add, instr_sub, instr_sll, instr_slt, instr_sltu, instr_xor, instr_srl, instr_sra, instr_or, instr_and;
	reg instr_ecall_ebreak, instr_fence;
	wire instr_trap;
	reg [4:0] decoded_rs2;
	// decoder_pseudo_trigger is used for instructions that complete in the FETCH state without going through normal decode/execute states.
	reg decoder_pseudo_trigger;
	reg is_lui_auipc_jal;
	reg is_lb_lh_lw_lbu_lhu;
	reg is_slli_srli_srai;
	reg is_jalr_addi_slti_sltiu_xori_ori_andi;
	reg is_sb_sh_sw;
	reg is_sll_srl_sra;
	reg is_beq_bne_blt_bge_bltu_bgeu;
	reg is_alu_reg_imm;
	reg is_alu_reg_reg;
	assign instr_trap = !{instr_lui, instr_auipc, instr_jal, instr_jalr,
		instr_beq, instr_bne, instr_blt, instr_bge, instr_bltu, instr_bgeu,
		instr_lb, instr_lh, instr_lw, instr_lbu, instr_lhu, instr_sb, instr_sh, instr_sw,
		instr_addi, instr_slti, instr_sltiu, instr_xori, instr_ori, instr_andi, instr_slli, instr_srli, instr_srai,
		instr_add, instr_sub, instr_sll, instr_slt, instr_sltu, instr_xor, instr_srl, instr_sra, instr_or, instr_and,
		instr_fence, instr_mret, /*instr_maskirq, */instr_wfi};

	always @(posedge clk or negedge resetn) begin
		if (!resetn) begin
			instr_lui   <= 0;
			instr_auipc <= 0;
			instr_jal   <= 0;
			instr_jalr  <= 0;
			instr_wfi   <= 0;
			instr_mret  <= 0;
			is_lui_auipc_jal <= 0;
			is_beq_bne_blt_bge_bltu_bgeu <= 0;
			is_lb_lh_lw_lbu_lhu <= 0;
			is_sb_sh_sw <= 0;
			is_alu_reg_imm <= 0;
			is_alu_reg_reg <= 0;
			decoded_rd  <= 0;
			decoded_rs1 <= 0;
			decoded_rs2 <= 0;
			decoded_imm_j <= 0;
			decoded_pc  <= 32'hFFFFFFFF;
			instr_beq   <= 0;
			instr_bne   <= 0;
			instr_blt   <= 0;
			instr_bge   <= 0;
			instr_bltu  <= 0;
			instr_bgeu  <= 0;
			instr_lb    <= 0;
			instr_lh    <= 0;
			instr_lw    <= 0;
			instr_lbu   <= 0;
			instr_lhu   <= 0;
			instr_sb    <= 0;
			instr_sh    <= 0;
			instr_sw    <= 0;
			instr_addi  <= 0;
			instr_slti  <= 0;
			instr_sltiu <= 0;
			instr_xori  <= 0;
			instr_ori   <= 0;
			instr_andi  <= 0;
			instr_slli  <= 0;
			instr_srli  <= 0;
			instr_srai  <= 0;
			instr_add   <= 0;
			instr_sub   <= 0;
			instr_sll   <= 0;
			instr_slt   <= 0;
			instr_sltu  <= 0;
			instr_xor   <= 0;
			instr_srl   <= 0;
			instr_sra   <= 0;
			instr_or    <= 0;
			instr_and   <= 0;
			instr_fence <= 0;
			instr_ecall_ebreak <= 0;
			is_slli_srli_srai <= 0;
			is_jalr_addi_slti_sltiu_xori_ori_andi <= 0;
			is_sll_srl_sra <= 0;
			decoded_imm <= 0;
		end else begin
		// The decode stage 1: Decode the instruction
		// mem_do_rinst(memory do read instruction) is set when the CPU wants to fetch an instruction from memory.
		// when mem_xfer = mem_done(memory operation done) is set high, it means the instruction data is now available in mem_rdata.
		// !decoder_trigger means that decoder has not been triggered yet.
		if (mem_do_rinst && mem_xfer && !decoder_trigger && !decoder_pseudo_trigger) begin
			decoded_pc <= mem_addr;

			// Instruction Decoder / Control Unit - Decode Stage 1 (basic opcode decode)
			instr_lui     <= mem_rdata_latched[6:0] == 7'b0110111;
			instr_auipc   <= mem_rdata_latched[6:0] == 7'b0010111;
			instr_jal     <= mem_rdata_latched[6:0] == 7'b1101111;
			instr_jalr    <= mem_rdata_latched[6:0] == 7'b1100111 && mem_rdata_latched[14:12] == 3'b000;
			decoded_rd <= mem_rdata_latched[11:7];
			decoded_rs1 <= mem_rdata_latched[19:15];
			decoded_rs2 <= mem_rdata_latched[24:20];

			instr_wfi  <= mem_rdata_latched == 32'h10500073;  // WFI
			instr_mret <= mem_rdata_latched == 32'h30200073;  // MRET
			is_lui_auipc_jal <= (mem_rdata_latched[6:0] == 7'b0110111) ||  // LUI
							(mem_rdata_latched[6:0] == 7'b0010111) ||  // AUIPC
							(mem_rdata_latched[6:0] == 7'b1101111);    // JAL
			is_beq_bne_blt_bge_bltu_bgeu <= mem_rdata_latched[6:0] == 7'b1100011;
			is_lb_lh_lw_lbu_lhu          <= mem_rdata_latched[6:0] == 7'b0000011;
			is_sb_sh_sw                  <= mem_rdata_latched[6:0] == 7'b0100011;
			is_alu_reg_imm               <= mem_rdata_latched[6:0] == 7'b0010011;
			is_alu_reg_reg               <= mem_rdata_latched[6:0] == 7'b0110011;
			
			// Immediate Extend Unit - J-type Immediate Decode
			{ decoded_imm_j[31:20], decoded_imm_j[10:1], decoded_imm_j[11], decoded_imm_j[19:12], decoded_imm_j[0] } <= $signed({mem_rdata_latched[31:12], 1'b0});
		end
		// The decode stage 2 begins here
		if (decoder_trigger && !decoder_pseudo_trigger) begin
			instr_beq   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b000;
			instr_bne   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b001;
			instr_blt   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b100;
			instr_bge   <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b101;
			instr_bltu  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b110;
			instr_bgeu  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b111;
			instr_lb    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b000;
			instr_lh    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b001;
			instr_lw    <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b010;
			instr_lbu   <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b100;
			instr_lhu   <= is_lb_lh_lw_lbu_lhu && mem_rdata_q[14:12] == 3'b101;
			instr_sb    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b000;
			instr_sh    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b001;
			instr_sw    <= is_sb_sh_sw && mem_rdata_q[14:12] == 3'b010;
			instr_addi  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b000;
			instr_slti  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b010;
			instr_sltiu <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b011;
			instr_xori  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b100;
			instr_ori   <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b110;
			instr_andi  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b111;
		    instr_slli  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srli  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srai  <= is_alu_reg_imm && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000;
			
			// Instruction Decoder / Control Unit - Decode Stage 2 (funct3/funct7 decode)
			instr_add   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sub   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0100000;

			instr_sll   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000;
			instr_slt   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b010 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sltu  <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b011 && mem_rdata_q[31:25] == 7'b0000000;
			instr_xor   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b100 && mem_rdata_q[31:25] == 7'b0000000;
			instr_srl   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000;
			instr_sra   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000;
			instr_or    <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b110 && mem_rdata_q[31:25] == 7'b0000000;
			instr_and   <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b111 && mem_rdata_q[31:25] == 7'b0000000;
			instr_fence <= (mem_rdata_q[6:0] == 7'b0001111 && !mem_rdata_q[14:12]);
    		instr_ecall_ebreak <= (mem_rdata_q[6:0] == 7'b1110011 && !mem_rdata_q[31:21] && !mem_rdata_q[19:7]);
			// instr_maskirq <= mem_rdata_q[6:0] == 7'b0001011 && mem_rdata_q[31:25] == 7'b0000011 && ENABLE_IRQ;
			is_slli_srli_srai <= is_alu_reg_imm && |{
				mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000
			};
			is_jalr_addi_slti_sltiu_xori_ori_andi <= instr_jalr || is_alu_reg_imm && |{
				mem_rdata_q[14:12] == 3'b000,
				mem_rdata_q[14:12] == 3'b010,
				mem_rdata_q[14:12] == 3'b011,
				mem_rdata_q[14:12] == 3'b100,
				mem_rdata_q[14:12] == 3'b110,
				mem_rdata_q[14:12] == 3'b111
			};
			is_sll_srl_sra <= is_alu_reg_reg && |{
				mem_rdata_q[14:12] == 3'b001 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0000000,
				mem_rdata_q[14:12] == 3'b101 && mem_rdata_q[31:25] == 7'b0100000
			};
			
			// Immediate Extend Unit - ImmSrc Mux
			(* parallel_case *)
			case (1'b1)
				instr_jal:
					decoded_imm <= decoded_imm_j;
				|{instr_lui, instr_auipc}:
					decoded_imm <= mem_rdata_q[31:12] << 12; 
				|{instr_jalr, is_lb_lh_lw_lbu_lhu, is_alu_reg_imm}:
					decoded_imm <= $signed(mem_rdata_q[31:20]);
				is_beq_bne_blt_bge_bltu_bgeu:
					decoded_imm <= $signed({mem_rdata_q[31], mem_rdata_q[7], mem_rdata_q[30:25], mem_rdata_q[11:8], 1'b0});  // Changed
				is_sb_sh_sw: begin
					decoded_imm <= $signed({mem_rdata_q[31:25], mem_rdata_q[11:7]});
				end
				default:
					decoded_imm <= 32'b0;
			endcase
		end
		if (clear_instr_wfi)
            instr_wfi <= 0;
		end // else (not reset)
	end
	
	reg set_mem_do_rdata;
	reg set_mem_do_wdata;
	reg latched_store;
	reg latched_stalu;
	reg latched_branch;
	reg latched_is_lu;
	reg latched_is_lh;
	reg latched_is_lb;
	reg [3:0] latched_rd;
	reg [31:0] next_irq_pending;

	// ALU (Arithmetic Logic Unit)
	// Temporary Registers (A, B, ALUOut, Data)
	reg [31:0] alu_out_q;
	reg alu_out_0;
	reg [31:0] alu_add_sub;
	reg alu_eq, alu_ltu, alu_lts;
	always @* begin
		// ALU operations
		alu_add_sub = instr_sub ? reg_op1 - reg_op2 : reg_op1 + reg_op2;
		alu_eq = (reg_op1 == reg_op2);
		alu_lts = $signed(reg_op1) < $signed(reg_op2);
		alu_ltu = reg_op1 < reg_op2;
		
		// Branch/comparison result
		alu_out_0 = 1'b0;
		if (instr_beq)                              alu_out_0 = alu_eq;
		else if (instr_bne)                         alu_out_0 = !alu_eq;
		else if (instr_bge)                         alu_out_0 = !alu_lts;
		else if (instr_bgeu)                        alu_out_0 = !alu_ltu;
		else if (instr_slti || instr_blt || instr_slt)   alu_out_0 = alu_lts;
		else if (instr_sltiu || instr_bltu || instr_sltu) alu_out_0 = alu_ltu;
	end

	reg cpuregs_write; // Instruction Decoder / Control Unit - RegRwite
	// Result Mux (ResultSrc)
	reg [31:0] cpuregs_wrdata;
	reg [31:0] cpuregs_rs1;
	reg [31:0] cpuregs_rs2;
	always @* begin
		cpuregs_write  = 0;
		cpuregs_wrdata = reg_out;  // Default to reg_out

		if (cpu_state == 8'b01000000) begin
			if (latched_branch) begin
				cpuregs_write = (latched_rd != 0);
				// cpuregs_wrdata already reg_out
			end
			else if (latched_store) begin
				cpuregs_wrdata = latched_stalu ? alu_out_q : reg_out;
				cpuregs_write = (latched_rd != 0);
			end
			else if (irq_state[0]) begin
				cpuregs_wrdata = reg_next_pc;
				cpuregs_write = 1;
			end
			else if (irq_state[1]) begin
				cpuregs_wrdata = irq_pending & ~irq_mask;
				cpuregs_write = 1;
			end
		end
	end
	// Register File - Register Write (WE3 and WD3)
	always @(posedge clk) begin
		if (resetn && cpuregs_write && latched_rd != 0) begin
			cpuregs[latched_rd] <= cpuregs_wrdata;
		end
	end

	// Register File - Register Read with Forwarding (RD1, RD2)
	always @* begin
		// Write forwarding for rs1
		if (decoded_rs1 == 0)
			cpuregs_rs1 = 0;
		else if (cpuregs_write && latched_rd == decoded_rs1)
			cpuregs_rs1 = cpuregs_wrdata;
		else
			cpuregs_rs1 = cpuregs[decoded_rs1];
		
		// Write forwarding for rs2
		if (decoded_rs2 == 0)
			cpuregs_rs2 = 0;
		else if (cpuregs_write && latched_rd == decoded_rs2)
			cpuregs_rs2 = cpuregs_wrdata;
		else
			cpuregs_rs2 = cpuregs[decoded_rs2];
	end
	always @(posedge clk or negedge resetn) begin
		if (!resetn) begin
			// Program Counter - Reset Value
			reg_pc <= 32'h 0000_0000;
			reg_next_pc <= 32'h 0000_0000;
			reg_out <= 32'h0;
			trap <= 1'b0; 
    		do_wfi <= 1'b0;
			latched_store <= 0;
			latched_stalu <= 0;
			latched_branch <= 0;
			latched_is_lu <= 0;
			latched_is_lh <= 0;
			latched_is_lb <= 0;
			irq_active <= 0;
			irq_delay <= 0;
			irq_mask <= ~0;
			irq_state <= 0;
			eoi <= 0;
			irq_pending <= 0;
			mem_do_prefetch <= 0;
			mem_do_rinst <= 0;
			mem_do_rdata <= 0;
			mem_do_wdata <= 0;
			cpu_state <= 8'b01000000;
			decoder_trigger <= 0;
			decoder_trigger_q <= 0;
			decoder_pseudo_trigger <= 0;
			latched_rd <= 0;
		end else begin
		// Default assignments
		trap <= 0;
		clear_instr_wfi = 0;
		set_mem_do_rdata = 0;
		set_mem_do_wdata = 0;
		
		next_irq_pending = irq_pending;
		
		decoder_trigger <= mem_xfer && mem_do_rinst && !decoder_trigger && !decoder_trigger_q && !decoder_pseudo_trigger;
		decoder_trigger_q <= decoder_trigger;
		decoder_pseudo_trigger <= 0;

		if (|irq_pending)
			do_wfi <= 0;

		(* parallel_case, full_case *)
		case (cpu_state)
					8'b10000000: begin
						trap <= 1;
					end
					
					// State Machine Flow
					8'b01000000: begin
						// 1. Program Counter - PC Update in FETCH Stage
						if (latched_store && !(instr_wfi && irq && decoder_trigger)) begin
							if (latched_branch) begin
								if (latched_stalu)
									reg_pc <= alu_out_q & ~1;    // JALR: jump to rs1 + imm
								else
									reg_pc <= reg_out & ~1;      // jump to PC + imm
							end else
								reg_pc <= reg_next_pc;           // Normal: PC = PC + 4
						end
						
						trap <= do_wfi;
						mem_do_rinst <= !decoder_trigger && !do_wfi; // decoder_trigger low means decode is done
						mem_wordsize <= 0;
						
						(* parallel_case *)
						case (1'b1)
							latched_store && !latched_branch: begin
							end
							irq_state[0]: begin
								irq_active <= 1;
								mem_do_rinst <= 1;
							end
							irq_state[1]: begin
								eoi <= irq_pending & ~irq_mask;
								next_irq_pending = next_irq_pending & irq_mask;
							end
						endcase

						// Program Counter - Normal Sequence
						if (mem_xfer && mem_instr && !latched_branch && !do_wfi)
							reg_next_pc <= next_pc_raw;
						
						(* parallel_case *)
						case (1'b1)
							!instr_wfi && ((decoder_trigger && !irq_active && !irq_delay && |(irq_pending & ~irq_mask)) || irq_state): begin
								latched_rd <= irq_state[0] ? 4 : 3;
							end
							(decoder_trigger || do_wfi) && instr_wfi: begin
								if (decoder_trigger && decoded_pc != reg_pc) begin
									// Stale WFI decode - ignore
									decoder_pseudo_trigger <= 1;
								end else if (do_wfi) begin
									// Currently IN WFI state
									if (irq) begin
										// Wake from WFI
										clear_instr_wfi = 1;
										latched_store <= 1;
										mem_do_rinst <= 1;
										reg_pc <= reg_pc + 4;
										reg_next_pc <= reg_pc + 4;
									end
									// else: no IRQ, stay in WFI (do nothing)
								end else begin
									// NOT in WFI state - just decoded WFI instruction
									if (irq) begin
										// IRQ already pending - skip WFI, treat as NOP
										clear_instr_wfi = 1;
										decoder_pseudo_trigger <= 1;
										latched_store <= 1;
										mem_do_rinst <= 1;
										reg_pc <= reg_pc + 4;
										reg_next_pc <= reg_pc + 4;
									end else begin
										// No IRQ - enter WFI
										do_wfi <= 1;
									end
								end
							end
							// When decode completes, clear it and move to next state.
							decoder_trigger && !instr_wfi: begin
								if (decoded_pc != reg_pc) begin
									decoder_pseudo_trigger <= 1;
								end else begin
									latched_rd <= is_sb_sh_sw ? 0 : decoded_rd;
									reg_next_pc <= reg_pc + 4;
									irq_delay <= irq_active;
									
									(* parallel_case *)
									case (1'b1)
										// 1. Program Counter - JAL Instruction
										instr_jal: begin
											mem_do_rinst <= 1;
											reg_next_pc <= reg_pc + decoded_imm_j; // Jump target
											reg_pc <= reg_pc + decoded_imm_j; // Update PC
											latched_branch <= 0; 
											latched_store <= 1;
											reg_out <= reg_pc + 4; // Return address to rd
										end
										default: begin
											mem_do_rinst <= 0;
											mem_do_prefetch <= !instr_jalr && !instr_mret;
											latched_store <= 0;
											latched_stalu <= 0;
											latched_branch <= 0;
											latched_is_lu <= 0;
											latched_is_lh <= 0;
											latched_is_lb <= 0;
											cpu_state <= 8'b00100000;
										end
									endcase
								end
							end
						endcase
						if ((latched_branch || latched_store) && !decoder_trigger) begin
							latched_branch <= 0;
							latched_store <= 0;
						end
					end
					// State Machine Flow
					8'b00100000: begin
						if (stale_decode) begin
							latched_store <= 0;  // Prevent PC from advancing again
							latched_branch <= 0;
							decoder_pseudo_trigger <= 1; 
							cpu_state <= 8'b01000000;
						end else begin
							(* parallel_case *)
							case (1'b1)
								instr_trap: begin // illegal instruction
									if (!irq_mask[1] && !irq_active) begin
										next_irq_pending[1] = 1;
										cpu_state <= 8'b01000000;
									end else
										cpu_state <= 8'b10000000;
								end
								is_lui_auipc_jal: begin // U-type and J-type
									reg_op1 <= instr_lui ? 0 : reg_pc;
									reg_op2 <= decoded_imm;
									mem_do_rinst <= mem_do_prefetch;
									cpu_state <= 8'b00001000;
								end
								instr_mret: begin // Return from Interrupt
									eoi <= 0;
									irq_active <= 0;
									latched_branch <= 1;
									latched_store <= 1;
									reg_out <= (cpuregs_rs1 & 32'h fffffffe);
									cpu_state <= 8'b01000000;
								end
								/* instr_maskirq: begin // Mask Interrupts - Custom from PicoRV32
									latched_store <= 1;
									reg_out <= irq_mask;
									irq_mask <= cpuregs_rs1 | MASKED_IRQ;
									cpu_state <= 8'b01000000;
								end*/
								is_lb_lh_lw_lbu_lhu && !instr_trap: begin // Load Instructions
									reg_op1 <= ((decoded_rs1 == 0) ? 32'h00000000 : cpuregs_rs1) + decoded_imm;
									cpu_state <= 8'b00000001;
									mem_do_rinst <= 1;
								end
								is_slli_srli_srai: begin // Shift Immediate Instructions
									reg_op1 <= (decoded_rs1 == 0) ? 32'h00000000 : cpuregs_rs1;
									reg_sh <= decoded_imm[4:0];
									cpu_state <= 8'b00000100; // Go to SHIFT
								end
								is_jalr_addi_slti_sltiu_xori_ori_andi: begin // I-type ALU + JALR
									reg_op1 <= (decoded_rs1 == 0) ? 32'h00000000 : cpuregs_rs1;
									reg_op2 <= decoded_imm;
									mem_do_rinst <= mem_do_prefetch;
									cpu_state <= 8'b00001000;
								end
								default: begin // R-type and others needing RS2
									reg_op1 <= (decoded_rs1 == 0) ? 32'h00000000 : cpuregs_rs1;
									cpu_state <= 8'b00010000; // This loads rs2
								end
							endcase
						end
					end

					// SrcB Mux (ALUSrcB)
					8'b00010000: begin
						reg_sh <= cpuregs_rs2[4:0];
						reg_op2 <= (decoded_rs2 == 0) ? 32'h00000000 : cpuregs_rs2;
						
						(* parallel_case *)
						case (1'b1)
							instr_trap: begin // illegal instruction
								if (!irq_mask[1] && !irq_active) begin
									next_irq_pending[1] = 1;
									cpu_state <= 8'b01000000;
								end else begin
									cpu_state <= 8'b10000000;
								end
							end
							is_sb_sh_sw: begin // Store Instructions
								cpu_state <= 8'b00000010;
								mem_do_rinst <= 1;
							end
							is_sll_srl_sra: begin // Shift Insturctions
								mem_do_rinst <= mem_do_prefetch;
								cpu_state <= 8'b00001000;
							end
							default: begin // R-type ALU and Branch Instructions
								if (!is_beq_bne_blt_bge_bltu_bgeu) begin
									mem_do_rinst <= mem_do_prefetch;
								end
								cpu_state <= 8'b00001000;
							end
						endcase
					end
					8'b00001000: begin
						reg_out <= reg_pc + decoded_imm;
						
						(* parallel_case *)
						case (1'b1)
							instr_addi || instr_add || instr_sub: begin
								alu_out_q <= alu_add_sub; // alu_add_sub = reg_op1 + reg_op2
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_sll: begin
								alu_out_q <= reg_op1 << reg_op2[4:0];
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_srl: begin
								alu_out_q <= reg_op1 >> reg_op2[4:0];
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_sra: begin
								alu_out_q <= $signed(reg_op1) >>> reg_op2[4:0];
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_slti || instr_slt: begin
								alu_out_q <= {31'b0, alu_lts};
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_sltiu || instr_sltu: begin
								alu_out_q <= {31'b0, alu_ltu};
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_xori || instr_xor: begin
								alu_out_q <= reg_op1 ^ reg_op2;
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_ori || instr_or: begin
								alu_out_q <= reg_op1 | reg_op2;
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							instr_andi || instr_and: begin
								alu_out_q <= reg_op1 & reg_op2;
								latched_store <= 1;
								latched_stalu <= 1;
								cpu_state <= 8'b01000000;
							end
							
							is_beq_bne_blt_bge_bltu_bgeu: begin
								latched_rd <= 0;
								latched_store <= 1;
								latched_branch <= alu_out_0;
								cpu_state <= 8'b01000000;
								if (alu_out_0) begin
									decoder_trigger <= 0;
									reg_next_pc <= reg_pc + decoded_imm;
									reg_out <= reg_pc + decoded_imm; 
									mem_do_rinst <= 1;
								end
							end
							
							// Program Counter - JALR Instruction
							default: begin
								latched_branch <= instr_jalr;
								latched_store <= 1;
								latched_stalu <= 1; // JALR uses ALU result
								alu_out_q <= alu_add_sub;
								if (instr_jalr)
									reg_out <= reg_pc + 4; 
								cpu_state <= 8'b01000000;
							end
						endcase
					end

					8'b00000100: begin
						latched_store <= 1;
						
						(* parallel_case *)
						case (1'b1)
							(reg_sh == 0): begin
								reg_out <= reg_op1;
								mem_do_rinst <= mem_do_prefetch;
								cpu_state <= 8'b01000000;
							end
							
							(reg_sh >= 4): begin
								(* parallel_case, full_case *)
								case (1'b1)
									instr_slli || instr_sll: reg_op1 <= reg_op1 << 4;
									instr_srli || instr_srl: reg_op1 <= reg_op1 >> 4;
									instr_srai || instr_sra: reg_op1 <= $signed(reg_op1) >>> 4;
								endcase
								reg_sh <= reg_sh - 4;
							end
							
							default: begin
								(* parallel_case, full_case *)
								case (1'b1)
									instr_slli || instr_sll: reg_op1 <= reg_op1 << 1;
									instr_srli || instr_srl: reg_op1 <= reg_op1 >> 1;
									instr_srai || instr_sra: reg_op1 <= $signed(reg_op1) >>> 1;
								endcase
								reg_sh <= reg_sh - 1;
							end
						endcase
					end
					// Memory Operations - Store Path
					8'b00000010: begin
						(* parallel_case *)
						case (1'b1)
							(!mem_do_prefetch || mem_xfer): begin
								(* parallel_case *)
								case (1'b1)
									!mem_do_wdata: begin
										(* parallel_case, full_case *)
										case (1'b1)
											instr_sb: mem_wstrb_next <= 4'b0001 << reg_op1[1:0];
											instr_sh: mem_wstrb_next <= 4'b0011 << reg_op1[1:0];
											instr_sw: mem_wstrb_next <= 4'b1111;
										endcase
										
										reg_op1 <= reg_op1 + decoded_imm;
										mem_do_rinst <= 0;
										set_mem_do_wdata = 1;
									end
									
									(!mem_do_prefetch && mem_xfer): begin
										latched_store <= 1;
										mem_do_wdata <= 0;
										mem_do_rinst <= 1;
										cpu_state <= 8'b01000000;
									end
									
									default: begin
										// Wait for memory operation to complete
									end
								endcase
							end
							
							default: begin
								// Wait for prefetch or memory to be ready
							end
						endcase
					end

					// Memory Operations - Load Path
					8'b00000001: begin
						(* parallel_case *)
						case (1'b1)
							(!mem_do_prefetch || mem_xfer): begin
								(* parallel_case *)
								case (1'b1)
									!mem_do_rdata: begin
										(* parallel_case, full_case *)
										case (1'b1)
											instr_lb || instr_lbu: mem_wordsize <= 2;
											instr_lh || instr_lhu: mem_wordsize <= 1;
											instr_lw: mem_wordsize <= 0;
										endcase
										
										latched_is_lu <= instr_lbu || instr_lhu || instr_lw;
										latched_is_lh <= instr_lh;
										latched_is_lb <= instr_lb;
										latched_rd <= decoded_rd;
										set_mem_do_rdata = 1;
									end
									
									(!mem_do_prefetch && mem_xfer): begin
										(* parallel_case, full_case *)
										case (1'b1)
											latched_is_lu: reg_out <= mem_rdata_word;
											latched_is_lh: reg_out <= $signed(mem_rdata_word[15:0]);
											latched_is_lb: reg_out <= $signed(mem_rdata_word[7:0]);
										endcase
					
										latched_store <= 1;
										decoder_pseudo_trigger <= 1; 
										cpu_state <= 8'b01000000; 
									end
									
									default: begin
										// Wait for memory operation
									end
								endcase
							end
							default: begin
								// Wait for prefetch or memory to be ready
							end
						endcase
					end
				endcase
				// IRQ handling
				next_irq_pending = next_irq_pending | irq;
				

				// Misalignment checks
				(* parallel_case *)
				case (1'b1)
					resetn && (mem_do_rdata || mem_do_wdata) && (mem_wordsize == 0) && (reg_op1[1:0] != 0): begin
						(* parallel_case *)
						case (1'b1)
							!irq_mask[2] && !irq_active: 
								next_irq_pending[2] = 1;
							default: 
								cpu_state <= 8'b10000000;
						endcase
					end
					resetn && (mem_do_rdata || mem_do_wdata) && (mem_wordsize == 1) && (reg_op1[0] != 0): begin
						(* parallel_case *)
						case (1'b1)
							!irq_mask[2] && !irq_active: 
								next_irq_pending[2] = 1;
							default: 
								cpu_state <= 8'b10000000;
						endcase
					end
					resetn && mem_do_rinst && |reg_pc[1:0]: begin
						(* parallel_case *)
						case (1'b1)
							!irq_mask[2] && !irq_active: 
								next_irq_pending[2] = 1;
							default: 
								cpu_state <= 8'b10000000;
						endcase
					end
					
					default: ; // No misalignment or illegal instruction
				endcase

				// Memory control signals
				if (mem_xfer) begin
					if (mem_do_prefetch || mem_do_rinst) begin
						mem_do_prefetch <= 0;
						mem_do_rinst <= 0;
					end
					if (mem_do_rdata && mem_state == 1)
						mem_do_rdata <= 0;
					if (mem_do_wdata && mem_state == 2)
						mem_do_wdata <= 0;
				end

				// Set memory operations
				(* parallel_case *)
				case (1'b1)
					set_mem_do_rdata: begin
						mem_do_rdata <= 1;
					end
					set_mem_do_wdata: begin
						mem_do_wdata <= 1;
					end
					default: ;
				endcase
				// IRQ pending update
				irq_pending <= next_irq_pending;
		end  // else (not reset)
	end
endmodule

module pmu (
    input  wire        clk_4mhz,
    input  wire        clk_32khz,
    input  wire        rst_n,
    input  wire [7:0]  cpu_addr,
    input  wire [31:0] cpu_wdata,
    output reg  [31:0] cpu_rdata,
    input  wire [3:0]  cpu_wstrb,
    input  wire        cpu_valid,
    output reg         cpu_ready,
    input  wire        cpu_trap,
    output reg         cpu_reset,
    output wire        clk_cpu,
    input  wire        irq_pir,
    output reg  [31:0] irq_pending,
    output wire [31:0] pmu_control_out,
    output wire [31:0] pmu_state_out,
    output wire [31:0] pmu_wakeup_out,
    output reg         zigbee_pwr_en,
    output reg         flash_pwr_en,
    output wire        osc_4mhz_enable_internal,
    output wire        osc_32khz_enable,
    output wire [3:0]  debug_state, // current state
	output wire        clock_gate_enable_out
);
    
    // PMU Registers
    reg [1:0]  pmu_state;           // 4 power states
    reg [7:0]  pmu_control;         // oscillator control flags
    reg [7:0]  pmu_wakeup;          // wake source enables
    reg [15:0] rtc_last_motion;     // ~18 hours max timeout
    reg [15:0] retained_pan_id;     // Zigbee PAN ID
    reg [7:0]  retained_channel;    // Zigbee channel (11-26)
    reg [15:0] retained_magic;      // magic value (0xBEEF)
    reg [7:0]  retained_connected;  // connection status (0xA5)
    reg        irq_pir_latch; 
    reg        irq_pir_prev; 
    
    // Timeout Counter Registers
    reg [15:0]  timeout_value_reg;       // Timeout in seconds
    reg         timeout_enable_reg;      // Enable timeout counter
    wire [15:0] timeout_current_count;   // Current count (from module)
    wire        timeout_wake;            // Wake signal from timeout module
    
    // 4MHz Domain State Machine Registers
    reg [1:0]  current_state;
    reg        cpu_halted;
    reg        clock_gate_enable;
    reg        prev_trap;
    reg        osc_4mhz_enable_reg;
    reg        osc_32khz_enable_reg;
    reg        wake_ack;
    reg        pir_wake_sync2_prev;
    reg [11:0] wake_protection_counter;  // 12-bit for up to 4095 cycles (1ms at 4MHz)
    reg        just_woke;  // Set when waking, cleared after protection expires
    reg [4:0]  direct_pir_counter;  // Short counter for direct PIR path (16 cycles max)
    
    // 32kHz Domain Registers
    reg [14:0] rtc_divider;
    reg [15:0] rtc_counter;         // matches rtc_last_motion
    reg        rtc_tick;
    reg        pir_wake_request;
    reg        timeout_wake_request;
    reg [1:0]  wake_reason;
    reg        timeout_wake_sync1, timeout_wake_sync2; // Synchronizers (32kHz → 4MHz)
    reg        pir_wake_sync1, pir_wake_sync2;
    reg [1:0]  wake_reason_sync1, wake_reason_sync2;
    reg        rtc_tick_sync1, rtc_tick_sync2;
    reg        timeout_wake_sync2_prev;
    reg        wake_ack_sync1, wake_ack_sync2; // Synchronizers (4MHz → 32kHz)
    reg [1:0]  state_sync1, state_sync2, state_sync2_prev;
    reg        wakeup_pir_en_sync1, wakeup_pir_en_sync2;
    reg [15:0] timeout_value_sync1, timeout_value_sync2; // Timeout register synchronizers (4MHz → 32kHz)
    reg        timeout_enable_sync1, timeout_enable_sync2;
    reg        pir_sync1_32k, pir_sync2_32k, pir_sync2_32k_prev; // PIR edge detection in 32kHz domain
    wire       pir_edge_32k;
    reg [2:0]  sync_settling_counter; // Settling counter - prevents false PIR edges when 32kHz starts
    wire       sync_settled;
    assign     sync_settled = (sync_settling_counter == 0);
    
    wire network_connected = (retained_magic == 16'hBEEF) && (retained_connected == 8'hA5); // Combinational Logic
    wire [31:0] network_status = {31'h0, network_connected};
    wire wfi_detected = cpu_trap && !prev_trap && !cpu_reset; // Detect WFI (rising edge of cpu_trap)
    wire in_low_power_state = (current_state == 2'b01) || (current_state == 2'b00); // Async wake detection for forcing 4MHz on
    wire async_wake = (timeout_wake_request || pir_wake_request) && in_low_power_state && !wake_ack;
    wire entering_sleep = (state_sync2 == 2'b01) && (state_sync2_prev != 2'b01);
    assign pir_edge_32k = pir_sync2_32k && !pir_sync2_32k_prev && sync_settled; // PIR edge detection in 32kHz domain
    wire pir_wake_edge = pir_wake_sync2 && !pir_wake_sync2_prev && pmu_wakeup[0]; // Wake Edge Detection (4MHz domain)
    wire timeout_wake_edge = timeout_wake_sync2 && !timeout_wake_sync2_prev;
    wire deep_sleep_wake = (current_state == 2'b00) && (pir_wake_sync2 || (irq_pir && !wake_ack)); // Wake conditions per state
    wire sleep_pir_wake = (current_state == 2'b01) && !wake_ack && pir_wake_edge;
    wire sleep_timeout_wake = (current_state == 2'b01) && !wake_ack && timeout_wake_edge;
    wire do_wake = deep_sleep_wake || sleep_pir_wake || sleep_timeout_wake; // Any wake event

    reg clk_gate_latch; // Clock gat latch for cpu clock
    always @(negedge clk_4mhz or negedge rst_n) begin // Uses negedge latch to prevent glitches.
        if (!rst_n)
            clk_gate_latch <= 1'b1;
        else begin
            if (current_state == 2'b00 && irq_pir)
                clk_gate_latch <= 1'b1;  // Async wake from deep sleep
            else
                clk_gate_latch <= clock_gate_enable;
        end
    end
    assign clk_cpu = clk_4mhz & clk_gate_latch; // clk_cpu (gated clock output)
	assign clock_gate_enable_out = clock_gate_enable;
    assign osc_4mhz_enable_internal = osc_4mhz_enable_reg || async_wake || wake_ack;
    assign osc_32khz_enable = osc_32khz_enable_reg;
    assign debug_state = {2'b00, current_state};
    assign pmu_control_out = {24'h0, pmu_control}; // Zero-extend for 32-bit outputs
    assign pmu_state_out = {30'h0, pmu_state};
    assign pmu_wakeup_out = {24'h0, pmu_wakeup};

    // 32kHz CLOCK DOMAIN
    // Synchronizers: 4MHz → 32kHz
    always @(posedge clk_32khz or negedge rst_n) begin
        if (!rst_n) begin
            wake_ack_sync1 <= 1'b0;
            wake_ack_sync2 <= 1'b0;
            state_sync1 <= 2'b11;
            state_sync2 <= 2'b11;
            state_sync2_prev <= 2'b11;
            wakeup_pir_en_sync1 <= 1'b0;
            wakeup_pir_en_sync2 <= 1'b0;
            // Timeout register synchronizers
            timeout_value_sync1 <= 16'd5;   // Default 5 seconds
            timeout_value_sync2 <= 16'd5;
            timeout_enable_sync1 <= 1'b0;
            timeout_enable_sync2 <= 1'b0;
            // PIR synchronizer for 32kHz domain
            pir_sync1_32k <= 1'b0;
            pir_sync2_32k <= 1'b0;
            pir_sync2_32k_prev <= 1'b0;
            sync_settling_counter <= 3'd0;
        end else begin
            wake_ack_sync1 <= wake_ack;
            wake_ack_sync2 <= wake_ack_sync1;
            state_sync1 <= current_state;
            state_sync2 <= state_sync1;
            state_sync2_prev <= state_sync2;  // Track previous for edge detection
            wakeup_pir_en_sync1 <= pmu_wakeup[0];
            wakeup_pir_en_sync2 <= wakeup_pir_en_sync1;
            // Timeout register synchronizers
            timeout_value_sync1 <= timeout_value_reg;
            timeout_value_sync2 <= timeout_value_sync1;
            timeout_enable_sync1 <= timeout_enable_reg;
            timeout_enable_sync2 <= timeout_enable_sync1;
            // PIR synchronizer for 32kHz domain edge detection
            pir_sync1_32k <= irq_pir;
            pir_sync2_32k <= pir_sync1_32k;
            pir_sync2_32k_prev <= pir_sync2_32k;
            
            // Active -> Sleep/Deep Sleep transition
            if ((state_sync2 == 2'b01 || state_sync2 == 2'b00) &&
                (state_sync2_prev == 2'b11)) begin
                sync_settling_counter <= 3'd5;  // Wait 5 cycles for sync chain to stabilize
            end else if (sync_settling_counter != 0) begin
                sync_settling_counter <= sync_settling_counter - 1;
            end
        end
    end
    
    // RTC Counter (32kHz domain)
    // Generates a 1 Hz tick from 32.768 kHz clock, using a timeout counter.
    always @(posedge clk_32khz or negedge rst_n) begin
        if (!rst_n) begin
            rtc_divider <= 15'h0;
            rtc_counter <= 16'h0;
            rtc_tick <= 1'b0;
        end else if (osc_32khz_enable_reg) begin
            if (rtc_divider == 15'd32767) begin
                rtc_divider <= 15'h0;
                rtc_counter <= rtc_counter + 1'b1;
                rtc_tick <= 1'b1;
            end else begin
                rtc_divider <= rtc_divider + 1'b1;
                rtc_tick <= 1'b0;
            end
        end else begin
            rtc_tick <= 1'b0;
        end
    end
    
    timeout_counter u_timeout_counter (
        .clk_32khz      (clk_32khz),
        .rst_n          (rst_n),
        .enable         (timeout_enable_sync2),
        .timeout_value  (timeout_value_sync2),
        .entering_sleep (entering_sleep),
        .wake_ack       (wake_ack_sync2), 
        .rtc_tick       (rtc_tick),
        .pir_edge       (pir_edge_32k),  // PIR edge resets counter
        .timeout_wake   (timeout_wake),
        .current_count  (timeout_current_count)
    );
    
    // 32kHz Sleep Controller State Machine
    // Monitors wake sources while 4MHz is off.
    reg [1:0] sleep_ctrl_state;

    always @(posedge clk_32khz or negedge rst_n) begin
        if (!rst_n) begin
            sleep_ctrl_state <= 2'b00;
            timeout_wake_request <= 1'b0;
            pir_wake_request <= 1'b0;
            wake_reason <= 2'b00;
        end else begin
            case (sleep_ctrl_state)
                2'b00: begin
                    timeout_wake_request <= 1'b0;
                    pir_wake_request <= 1'b0;
                    wake_reason <= 2'b00;
                    if (state_sync2 == 2'b01 || state_sync2 == 2'b00) begin
                        sleep_ctrl_state <= 2'b01;
                    end
                end
                2'b01: begin
                    // PIR wake - highest priority
                    if (pir_edge_32k && wakeup_pir_en_sync2) begin
                        pir_wake_request <= 1'b1;
                        wake_reason <= 2'b01;
                        sleep_ctrl_state <= 2'b10;
                    end
                    // Timeout wake - only in SLEEP mode (not DEEP_SLEEP)
                    else if (timeout_wake && state_sync2 == 2'b01) begin
                        timeout_wake_request <= 1'b1;
                        wake_reason <= 2'b10;
                        sleep_ctrl_state <= 2'b10;
                    end
                    else if (state_sync2 == 2'b11) begin
                        sleep_ctrl_state <= 2'b00;
                    end
                end
                2'b10: begin
                    if (wake_ack_sync2) begin
                        sleep_ctrl_state <= 2'b11;
                    end
                    // Upgrade timeout wake to PIR if PIR triggers
                    if (pir_edge_32k && wakeup_pir_en_sync2 && wake_reason == 2'b10) begin
                        pir_wake_request <= 1'b1;
                        wake_reason <= 2'b01;
                    end
                end
                2'b11: begin
                    timeout_wake_request <= 1'b0;
                    pir_wake_request <= 1'b0;
                    wake_reason <= 2'b00;
                    if (!wake_ack_sync2) begin
                        sleep_ctrl_state <= 2'b00;
                    end
                end
                default: sleep_ctrl_state <= 2'b00;
            endcase
        end
    end
    
    // 4MHz CLOCK DOMAIN
    // Synchronizers: 32kHz → 4MHz
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            timeout_wake_sync1 <= 1'b0;
            timeout_wake_sync2 <= 1'b0;
            pir_wake_sync1 <= 1'b0;
            pir_wake_sync2 <= 1'b0;
            wake_reason_sync1 <= 2'b00;
            wake_reason_sync2 <= 2'b00;
            rtc_tick_sync1 <= 1'b0;
            rtc_tick_sync2 <= 1'b0;
        end else begin
            timeout_wake_sync1 <= timeout_wake_request;
            timeout_wake_sync2 <= timeout_wake_sync1;
            pir_wake_sync1 <= pir_wake_request;
            pir_wake_sync2 <= pir_wake_sync1;
            wake_reason_sync1 <= wake_reason;
            wake_reason_sync2 <= wake_reason_sync1;
            rtc_tick_sync1 <= rtc_tick;
            rtc_tick_sync2 <= rtc_tick_sync1;
        end
    end
    
    // CPU Ready Signal
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            cpu_ready <= 1'b0;
        end else begin
            cpu_ready <= cpu_valid;
        end
    end

    // CPU Register Access (Write)
    // pmu_state is handled in the state machine block for timing reasons
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            pmu_control <= 8'h01;
            pmu_wakeup <= 8'h01;
            zigbee_pwr_en <= 1'b0;
            // flash_pwr_en is driven by the state machine block only (avoids multi-driver)
            rtc_last_motion <= 16'h0;
            retained_pan_id <= 16'h0;
            retained_channel <= 8'h0;
            retained_magic <= 16'h0;
            retained_connected <= 8'h0;
            // Timeout registers
            timeout_value_reg <= 16'd5;    // Default 5 seconds - can be changed by firmware code
            timeout_enable_reg <= 1'b0;  
        end else begin
            if (cpu_valid && cpu_wstrb != 4'h0) begin
            case (cpu_addr)
                // PMU_CONTROL: 8 bits
                8'h04: begin
                    if (cpu_wstrb[0]) pmu_control <= cpu_wdata[7:0];
                end
                // PMU_WAKEUP: 8 bits
                8'h08: begin
                    if (cpu_wstrb[0]) pmu_wakeup <= cpu_wdata[7:0];
                end
                // ZIGBEE_CTRL: 1 bit
                8'h0C: zigbee_pwr_en <= cpu_wdata[0];
                // FLASH_CTRL: 1 bit
                // 8'h10: flash_pwr_en <= cpu_wdata[0];
                // RTC_LAST_MOTION: 16 bits
                8'h18: begin
                    if (cpu_wstrb[0]) rtc_last_motion[7:0] <= cpu_wdata[7:0];
                    if (cpu_wstrb[1]) rtc_last_motion[15:8] <= cpu_wdata[15:8];
                end
                // TIMEOUT_VALUE: 16 bits 
                8'h20: begin
                    if (cpu_wstrb[0]) timeout_value_reg[7:0] <= cpu_wdata[7:0];
                    if (cpu_wstrb[1]) timeout_value_reg[15:8] <= cpu_wdata[15:8];
                end
                // TIMEOUT_CTRL: 1 bit 
                8'h24: begin
                    if (cpu_wstrb[0]) timeout_enable_reg <= cpu_wdata[0];
                end
                // RETAINED_PAN_ID: 16 bits
                8'h40: begin 
                    if (cpu_wstrb[0]) retained_pan_id[7:0] <= cpu_wdata[7:0];
                    if (cpu_wstrb[1]) retained_pan_id[15:8] <= cpu_wdata[15:8];
                end
                // RETAINED_CHANNEL: 8 bits
                8'h44: begin
                    if (cpu_wstrb[0]) retained_channel <= cpu_wdata[7:0];
                end
                // RETAINED_MAGIC: 16 bits
                8'h48: begin
                    if (cpu_wstrb[0]) retained_magic[7:0] <= cpu_wdata[7:0];
                    if (cpu_wstrb[1]) retained_magic[15:8] <= cpu_wdata[15:8];
                end
                // RETAINED_CONNECTED: 8 bits
                8'h4C: begin
                    if (cpu_wstrb[0]) retained_connected <= cpu_wdata[7:0];
                end
                default: ; // No action
            endcase
            end
        end
    end
    
    // CPU Register Access (Read)
    always @(*) begin
        case (cpu_addr)
            8'h00: cpu_rdata = {30'h0, pmu_state};              // 2 bits
            8'h04: cpu_rdata = {24'h0, pmu_control};            // 8 bits
            8'h08: cpu_rdata = {24'h0, pmu_wakeup};             // 8 bits
            8'h0C: cpu_rdata = {31'h0, zigbee_pwr_en};          // 1 bit
            8'h10: cpu_rdata = {31'h0, flash_pwr_en};           // 1 bit
            8'h14: cpu_rdata = {16'h0, rtc_counter};            // 16 bits
            8'h18: cpu_rdata = {16'h0, rtc_last_motion};        // 16 bits
            8'h1C: cpu_rdata = {30'h0, wake_reason_sync2};      // 2 bits
            8'h20: cpu_rdata = {16'h0, timeout_value_reg};      // 16 bits
            8'h24: cpu_rdata = {31'h0, timeout_enable_reg};     // 1 bit
            8'h28: cpu_rdata = {16'h0, timeout_current_count};  // 16 bits
            8'h40: cpu_rdata = {16'h0, retained_pan_id};        // 16 bits
            8'h44: cpu_rdata = {24'h0, retained_channel};       // 8 bits
            8'h48: cpu_rdata = {16'h0, retained_magic};         // 16 bits
            8'h4C: cpu_rdata = {24'h0, retained_connected};     // 8 bits
            8'h64: cpu_rdata = network_status;                  // 1 bit
            8'h68: cpu_rdata = irq_pending;
            default: cpu_rdata = 32'h0;
        endcase
    end

    // Main Power State Machine (4MHz domain)
    
    // Reset hold counter: keeps cpu_reset=1 for 32 cycles after rst_n release.
    // PicoRV32 uses synchronous reset only. In gate-level simulation, its DFFs
    // start as X (TSMC UDP cells). The CPU needs multiple clock edges with
    // resetn=0 for reset values to propagate through all pipeline stages
    // with SDF cell delays. 32 cycles provides ample margin.
    reg [4:0] reset_hold_counter;
    wire cpu_reset_hold = (reset_hold_counter != 5'd0);
    
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n)
            reset_hold_counter <= 5'd31;
        else if (reset_hold_counter != 5'd0)
            reset_hold_counter <= reset_hold_counter - 1;
    end
    
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= 2'b11;
            pmu_state <= 2'b11;
            cpu_halted <= 1'b0;
            clock_gate_enable <= 1'b1;
            cpu_reset <= 1'b1;
            prev_trap <= 1'b0;
            osc_4mhz_enable_reg <= 1'b1;
            osc_32khz_enable_reg <= 1'b0;
            wake_ack <= 1'b0;
            pir_wake_sync2_prev <= 1'b0;
            wake_protection_counter <= 12'd0;
            just_woke <= 1'b0;
            direct_pir_counter <= 5'd0;
            flash_pwr_en <= 1'b1;
        end else begin
            // Handle CPU writes to PMU_STATE register
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h00) begin
                pmu_state <= cpu_wdata[1:0];
            end
            prev_trap <= cpu_trap;
            pir_wake_sync2_prev <= pir_wake_sync2;
            
            // Hold cpu_reset high until reset_hold_counter expires
            if (cpu_reset_hold)
                cpu_reset <= 1'b1;
            else
                cpu_reset <= 1'b0;
            
            // Centralized wake handling logic
            if (do_wake) begin
                wake_ack <= 1'b1;
                current_state <= 2'b11;
                pmu_state <= 2'b11;
                osc_4mhz_enable_reg <= 1'b1;
                flash_pwr_en <= 1'b1;
                clock_gate_enable <= 1'b1;
                cpu_halted <= 1'b0;
                wake_protection_counter <= 12'd1000;
                just_woke <= 1'b1;
                
                // PIR wake needs direct_pir_counter for IRQ handling
                if (deep_sleep_wake || sleep_pir_wake) begin
                    direct_pir_counter <= 5'd16;
                end
                
                // Keep 32kHz on if waking from SLEEP
                if (sleep_pir_wake || sleep_timeout_wake) begin
                    osc_32khz_enable_reg <= 1'b1;
                end
            end
            
            // State machine behavior when not waking
            if (!do_wake) begin
            case (current_state)
                // DEEP SLEEP: Everything off, waiting for PIR only
                2'b00: begin
                    osc_4mhz_enable_reg <= 1'b0;
                    osc_32khz_enable_reg <= 1'b0;
                    flash_pwr_en <= 1'b0;
                    clock_gate_enable <= 1'b0;
                    cpu_halted <= 1'b1;
                end
                
                // SLEEP (Count Mode): 32kHz on, 4MHz off, timeout/PIR wake
                2'b01: begin
                    osc_4mhz_enable_reg <= 1'b0;
                    osc_32khz_enable_reg <= 1'b1;
                    flash_pwr_en <= 1'b1;
                    clock_gate_enable <= 1'b0;
                    cpu_halted <= 1'b1;
                    if (wake_ack && !timeout_wake_sync2) begin
                        wake_ack <= 1'b0;
                    end
                end
                
                // ACTIVE: Full power, CPU running
                2'b11: begin
                    osc_4mhz_enable_reg <= 1'b1;
                    osc_32khz_enable_reg <= timeout_enable_reg; 
                    flash_pwr_en <= 1'b1;
                    cpu_halted <= 1'b0;
                    clock_gate_enable <= 1'b1;
                    
		    if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h10)
			flash_pwr_en <= cpu_wdata[0];
                    // Clear wake_ack when wake signals clear
                    if (!timeout_wake_sync2 && !pir_wake_sync2 && !irq_pir) begin
                        wake_ack <= 1'b0;
                    end
                    
                    // Decrement counters during wake protection period
                    if (just_woke) begin
                        if (wake_protection_counter > 0) begin
                            wake_protection_counter <= wake_protection_counter - 1;
                        end else begin
                            just_woke <= 1'b0;
                        end
                        if (direct_pir_counter > 0) begin
                            direct_pir_counter <= direct_pir_counter - 1;
                        end
                    end
                    
                    // Block WFI when IRQ is pending
                    if (|irq_pending) begin
                    end
                    // Process WFI when no IRQ is pending
                    else if (wfi_detected) begin
                        cpu_halted <= 1'b1;
                        case (pmu_state)
                            2'b00: begin
                                current_state <= 2'b00;
                                osc_4mhz_enable_reg <= 1'b0;
                                osc_32khz_enable_reg <= 1'b0;
                                flash_pwr_en <= 1'b0;
                                clock_gate_enable <= 1'b0;
                            end
                            2'b01: begin
                                current_state <= 2'b01;
                                osc_4mhz_enable_reg <= 1'b0;
                                osc_32khz_enable_reg <= 1'b1;
                                flash_pwr_en <= 1'b0;
                                clock_gate_enable <= 1'b0;
                            end
                            default: begin
                            end
                        endcase
                    end
                    
                    if (|irq_pending && cpu_halted) begin
                        cpu_halted <= 1'b0;
                        clock_gate_enable <= 1'b1;
                    end
                end
                
                default: begin
                    current_state <= 2'b11;
                    osc_4mhz_enable_reg <= 1'b1;
                    osc_32khz_enable_reg <= 1'b0;
                    clock_gate_enable <= 1'b1;
                    cpu_reset <= 1'b0;
                end
            endcase
            end 
        end
    end
    
    // Interrupt Aggregation - Edge-triggered PIR
    reg irq_rtc_latch;
    reg rtc_tick_sync2_prev;
    reg irq_timeout_latch;

    reg [7:0]  irq_hold_counter;   // Hold IRQ high for minimum cycles
    
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            irq_pending <= 32'h0;
            irq_pir_prev <= 1'b0;
            irq_pir_latch <= 1'b0;
            irq_rtc_latch <= 1'b0;
            irq_timeout_latch <= 1'b0;
            timeout_wake_sync2_prev <= 1'b0;
            rtc_tick_sync2_prev <= 1'b0;
            irq_hold_counter <= 8'd0;
        end else begin
            if (async_wake)
                timeout_wake_sync2_prev <= 1'b0;
            else
                timeout_wake_sync2_prev <= timeout_wake_sync2;
            
            // Edge detection for PIR - set latch on rising edge
            irq_pir_prev <= irq_pir;
            
            // Set IRQ latch on rising edge of irq_pir
            // Note: When waking from deep sleep, irq_pir_prev is 0 (preserved from before
            // clock stopped), so edge detection catches the wake correctly
            if (irq_pir && !irq_pir_prev) begin
                irq_pir_latch <= 1'b1;
                irq_hold_counter <= 8'd100;  // Hold IRQ high for 100 cycles minimum
            end
            
            // Track previous value for edge detection
            rtc_tick_sync2_prev <= rtc_tick_sync2;

            // Latch RTC tick on rising edge
            if (rtc_tick_sync2 && !rtc_tick_sync2_prev && current_state != 2'b00) begin
                irq_rtc_latch <= 1'b1;
            end
            
            // Latch timeout wake
            if (timeout_wake_sync2 && !timeout_wake_sync2_prev) begin
                irq_timeout_latch <= 1'b1;
                irq_hold_counter <= 8'd100;  // Hold IRQ high for 100 cycles
            end

            // IRQ hold counter
            if (irq_hold_counter > 0) begin
                irq_hold_counter <= irq_hold_counter - 1;
            end

            // Clear conditions for IRQ latches
            // Software acknowledge via IRQ_ACK register write
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h6C && irq_hold_counter == 0) begin
                if (cpu_wdata[3]) begin
                    irq_pir_latch <= 1'b0;
                end
                if (cpu_wdata[2]) irq_rtc_latch <= 1'b0;
                if (cpu_wdata[4]) irq_timeout_latch <= 1'b0;
            end

            // Auto-clear RTC and timeout latch during deep sleep
            if (current_state == 2'b00 && clock_gate_enable == 1'b0) begin
                irq_rtc_latch <= 1'b0;
                irq_timeout_latch <= 1'b0;
            end

            //  Auto-clear when entering sleep (firmware requested sleep)
            //  This prevents stale IRQ from immediately waking
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h00 && cpu_wdata[1:0] != 2'b11) begin 
                irq_rtc_latch <= 1'b0;
                irq_timeout_latch <= 1'b0;
                irq_pir_latch <= 1'b0;
            end
            
            // This handles wake from deep sleep where edge detection doesn't work
            // Only active for 16 cycles, not the full 1000-cycle just_woke period
            irq_pending <= {27'h0, 
                           irq_timeout_latch,                                    // bit 4
                           irq_pir_latch || (|direct_pir_counter && irq_pir),   // bit 3
                           irq_rtc_latch,                                        // bit 2
                           2'b00};                                               // bits 1:0
        end
    end

endmodule
module motion_sensor_chip_top (
    input  wire         clk_4mhz,           // 4MHz clock input
    input  wire         clk_32khz,          // 32kHz clock input
    input  wire         rst_n,              // Active-low asynchronous reset
    input  wire         pir_sensor,         // PIR sensor input (for PMU async wake)
    inout  wire [7:0]   gpio,               // General-purpose I/O
    output wire         uart0_tx,           // UART TX (to Zigbee end device module)
    input  wire         uart0_rx,           // UART RX (from Zigbee end device module)
    output wire         flash_spi_clk,      // SPI serial clock to external flash
    output wire         flash_spi_cs_n,     // SPI chip select
    output wire         flash_spi_mosi,     // SPI master-out slave-in
    input  wire         flash_spi_miso,     // SPI master-in slave-out
    output wire [3:0]   debug_state,        // PMU state machine
    output wire         debug_clk_cpu_en,   // Clock gate enable status
    output wire         debug_cpu_trap      // CPU trap/WFI status
);
   
    wire        rst_n_sync;         // Synchronized reset
    wire        clk_cpu;            // Gated clock from PMU
    wire        cpu_trap;           // CPU trap signal
    wire        cpu_do_wfi;         // CPU WFI signal
    wire        cpu_reset;          // CPU reset from PMU
    
    
    // One of the main struggles in synthesis was CPU output isolation. 
    // PicoRV32 uses synchronous reset only. In gate-level simulation, all its
    // output DFFs start as X. The isolation gates must stay closed long enough
    // for the CPU's sync reset to propagate through ALL pipeline stages.

    // And cpu_mem_ready must be gated during isolation. When addr=0 (from
    // isolation masking), the boot ROM responds with ready=1. If the CPU's
    // internal mem_valid is X, then mem_xfer = X & 1 = X, corrupting the
    // CPU's state machine before sync reset can fire.

    reg [7:0] cpu_reset_pipe;
    always @(posedge clk_4mhz or negedge rst_n_sync) begin
        if (!rst_n_sync)
            cpu_reset_pipe <= 8'hFF;
        else
            cpu_reset_pipe <= {cpu_reset_pipe[6:0], cpu_reset};
    end
    wire cpu_isolate = cpu_reset | cpu_reset_pipe[7];  // Stays high 8 cycles after cpu_reset
    
    wire        cpu_trap_safe    = cpu_trap   & ~cpu_isolate;
    wire        cpu_do_wfi_safe  = cpu_do_wfi & ~cpu_isolate;
    
    // CPU Memory Interface - RAW signals (directly from CPU, may be X during reset)
    wire        cpu_mem_valid_raw;
    wire        cpu_mem_instr_raw;
    wire [31:0] cpu_mem_addr_raw;
    wire [31:0] cpu_mem_wdata_raw;
    wire [3:0]  cpu_mem_wstrb_raw;
    
    // CPU Memory Interface - SAFE signals (isolated during cpu_reset + 8 cycles)
    wire        cpu_mem_valid = cpu_mem_valid_raw & ~cpu_isolate;
    wire        cpu_mem_instr = cpu_mem_instr_raw & ~cpu_isolate;
    wire [31:0] cpu_mem_addr  = cpu_mem_addr_raw  & {32{~cpu_isolate}};
    wire [31:0] cpu_mem_wdata = cpu_mem_wdata_raw  & {32{~cpu_isolate}};
    wire [3:0]  cpu_mem_wstrb = cpu_mem_wstrb_raw  & {4{~cpu_isolate}};
    wire        cpu_mem_ready_raw;
    wire [31:0] cpu_mem_rdata;
    
    // IRQ signals
    wire [31:0] irq_pending;
    wire [31:0] cpu_eoi;
    
    // PMU signals
    wire [31:0] pmu_rdata;
    wire        pmu_ready;
    wire [31:0] pmu_control;
    wire [31:0] pmu_state;
    wire [31:0] pmu_wakeup;
    
    // SRAM signals
    wire [31:0] sram_rdata;
    wire        sram_ready;
    
    // Flash signals
    wire [31:0] flash_rdata;
    wire        flash_ready;
    wire        flash_pwr_en;
    
    // Boot ROM signals
    wire [31:0] rom_rdata;
    
    // UART0 signals
    wire [31:0] uart0_rdata;
    wire        uart0_irq;
    
    // GPIO signals
    wire [31:0] gpio_rdata;
    wire        gpio_irq_pir;
    wire [7:0]  gpio_out;
    wire [7:0]  gpio_in;
    wire [7:0]  gpio_dir;

    // PIR sensor - dedicated input pin for PMU async wake (bypasses GPIO controller)
    wire        pir_raw = pir_sensor;

    // Memory Map:
    // 0x0000_0000 - 0x0000_003F : Boot ROM (64 bytes, hardwired copy loop)
    // 0x0800_0000 - 0x0800_FFFF : Flash via SPI (firmware storage)
    // 0x1000_0000 - 0x1000_00FF : UART0 Registers
    // 0x1000_0200 - 0x1000_02FF : PMU Registers
    // 0x1000_0300 - 0x1000_03FF : GPIO Registers
    // 0x2000_0000 - 0x2000_1FFF : SRAM (8KB, firmware runs here after boot)
    
    wire sel_rom   = (cpu_mem_addr[31:6]  == 26'h0);              // 0x0000_0000 - 0x0000_003F
    wire sel_flash = (cpu_mem_addr[31:16] == 16'h0800);           // 0x0800_xxxx
    wire sel_sram  = (cpu_mem_addr[31:16] == 16'h2000);           // 0x2000_xxxx
    wire sel_uart0 = (cpu_mem_addr[31:8]  == 24'h100000);         // 0x1000_00xx
    wire sel_pmu   = (cpu_mem_addr[31:8]  == 24'h100002);         // 0x1000_02xx
    wire sel_gpio  = (cpu_mem_addr[31:8]  == 24'h100003);         // 0x1000_03xx
    
    // Read data mux
    wire [31:0] mem_rdata_mux = sel_pmu   ? pmu_rdata :
                                sel_uart0 ? uart0_rdata :
                                sel_gpio  ? gpio_rdata :
                                sel_rom   ? rom_rdata :
                                sel_flash ? flash_rdata :
                                sel_sram  ? sram_rdata :
                                32'h0;
    
    assign cpu_mem_rdata = mem_rdata_mux;
    
    // Ready signal mux
    // Boot ROM and peripherals are always ready (combinational)
    assign cpu_mem_ready_raw = sel_flash ? flash_ready :
                               sel_sram  ? sram_ready :
                               sel_pmu   ? pmu_ready :
                               1'b1;
    
    // Gate ready signal during isolation - prevents CPU from seeing
    // false mem_ready=1 (from boot ROM at addr 0) while its internal
    // mem_valid is still X, which would corrupt mem_xfer = X & 1 = X
    wire cpu_mem_ready = cpu_mem_ready_raw & ~cpu_isolate;

    reset_sync u_reset_sync (
        .clk            (clk_4mhz),
        .rst_n_async    (rst_n),
        .rst_n_sync     (rst_n_sync)
    );
    

    pmu u_pmu (
        .clk_4mhz               	(clk_4mhz),
        .clk_32khz              (clk_32khz),
        .rst_n                  (rst_n_sync),
        
        // CPU register interface
        .cpu_addr               (cpu_mem_addr[7:0]),
        .cpu_wdata              (cpu_mem_wdata),
        .cpu_rdata              (pmu_rdata),
        .cpu_wstrb              (cpu_mem_wstrb),
        .cpu_valid              (cpu_mem_valid & sel_pmu),
        .cpu_ready              (pmu_ready),
        
        // CPU control signals
        .cpu_trap               (cpu_trap_safe | cpu_do_wfi_safe),
        .cpu_reset              (cpu_reset),
        .clk_cpu                (clk_cpu),
        
        // Wake sources - raw GPIO[0] pad value for async wake
        .irq_pir                (pir_raw),
        
        // IRQ output
        .irq_pending            (irq_pending),
        
        // Status outputs (directly expose for power analysis observation)
        .pmu_control_out        (pmu_control),
        .pmu_state_out          (pmu_state),
        .pmu_wakeup_out         (pmu_wakeup),
        
        // Power control
        .zigbee_pwr_en          (),
        .flash_pwr_en           (flash_pwr_en),
        .osc_4mhz_enable_internal (),
        .osc_32khz_enable       (),
        
        // Debug
        .debug_state            (debug_state),
		.clock_gate_enable_out  (debug_clk_cpu_en)
    );
    
    riscvmulti u_cpu (
        .clk                (clk_cpu),          // Gated clock from PMU!
        .resetn             (~cpu_reset),
        .trap               (cpu_trap),
        .do_wfi             (cpu_do_wfi),
        
        // Memory interface (outputs → raw, inputs → safe)
        .mem_valid          (cpu_mem_valid_raw),
        .mem_instr          (cpu_mem_instr_raw),
        .mem_ready          (cpu_mem_ready),
        .mem_addr           (cpu_mem_addr_raw),
        .mem_wdata          (cpu_mem_wdata_raw),
        .mem_wstrb          (cpu_mem_wstrb_raw),
        .mem_rdata          (cpu_mem_rdata),
        
        // IRQ interface
        .irq                (irq_pending),
        .eoi                (cpu_eoi),
        
        // Debug
        .dbg_pc             ()
    );

    // Generate sram_ready signal (1 cycle after valid)
    // sram_8kb_data doesn't have a ready output, so we create it here
    reg sram_ready_reg;
    
    always @(posedge clk_cpu or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            sram_ready_reg <= 1'b0;
        end else begin
            // Ready goes high one cycle after valid, then back to low
            sram_ready_reg <= (cpu_mem_valid & sel_sram) & ~sram_ready_reg;
        end
    end
    
    assign sram_ready = sram_ready_reg;
    
    // SRAM instantiation (mapped at 0x2000_0000)
    sram_8kb_data u_sram (
        .clk        (clk_cpu),
        .rst_n      (~cpu_reset),
        .addr       (cpu_mem_addr[12:2]),   // Word address: bits [12:2] = 11 bits
        .din        (cpu_mem_wdata),
        .dout       (sram_rdata),
        .we         (cpu_mem_wstrb),
        .en         (cpu_mem_valid & sel_sram),
        .retain     (1'b0),
        .isolate    (1'b0)
    );
    
    // Flash controller instantiation (mapped at 0x0000_0000, read-only code)
    flash_controller_external u_flash (
        .clk        (clk_4mhz),
        .rst_n      (rst_n_sync),
        .pwr_en     (flash_pwr_en),
        .addr       (cpu_mem_addr[15:0]),
        .rdata      (flash_rdata),
        .valid      (cpu_mem_valid & sel_flash),
        .ready      (flash_ready),
        .spi_clk    (flash_spi_clk),
        .spi_cs_n   (flash_spi_cs_n),
        .spi_mosi   (flash_spi_mosi),
        .spi_miso   (flash_spi_miso)
    );
    
    // UART0 controller (mapped at 0x1000_0000, for Zigbee communication)
    uart u_uart0 (
        .clk        (clk_cpu),
        .rst_n      (~cpu_reset),
        .addr       (cpu_mem_addr[3:0]),
        .wdata      (cpu_mem_wdata),
        .rdata      (uart0_rdata),
        .wstrb      (cpu_mem_wstrb),
        .valid      (cpu_mem_valid & sel_uart0),
        .tx         (uart0_tx),
        .rx         (uart0_rx),
        .irq        (uart0_irq),
        .baud_div   (16'd434)           // 4MHz / 9200 ≈ 434 (close to 9600 baud)
    );
    
    // GPIO controller (mapped at 0x1000_0300, GPIO[0] = PIR sensor)
    gpio_controller u_gpio (
        .clk        (clk_cpu),
        .rst_n      (~cpu_reset),
        .addr       (cpu_mem_addr[3:0]),
        .wdata      (cpu_mem_wdata),
        .rdata      (gpio_rdata),
        .wstrb      (cpu_mem_wstrb),
        .valid      (cpu_mem_valid & sel_gpio),
        .gpio_pad   (gpio),
        .gpio_out   (gpio_out),
        .gpio_in    (gpio_in),
        .gpio_dir   (gpio_dir),
        .irq_pir    (gpio_irq_pir)
    );
    
    // Boot ROM (64 bytes at 0x0000_0000, hardwired copy loop)
    // Copies firmware from flash (0x0800_0000) to SRAM (0x2000_0000)
    // then jumps to SRAM for full-speed execution
    boot_rom u_boot_rom (
        .addr   (cpu_mem_addr[5:0]),
        .rdata  (rom_rdata)
    );
    
    assign debug_cpu_trap = cpu_trap_safe | cpu_do_wfi_safe;

endmodule


module reset_sync (
    input  wire clk,
    input  wire rst_n_async,
    output reg  rst_n_sync
);
    reg rst_n_meta;
    
    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async) begin
            rst_n_meta <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_sync <= rst_n_meta;
        end
    end
endmodule

module sram_8kb_data (
    input  wire         clk,
    input  wire         rst_n,
    
    // Single port interface  
    input  wire [10:0]  addr,      // 2K words = 8KB
    input  wire [31:0]  din,
    output reg  [31:0]  dout,
    input  wire [3:0]   we,        // Byte write enables
    input  wire         en,
    
    // Power management
    input  wire         retain,
    input  wire         isolate
);

    // 8KB = 2K x 32-bit words
    reg [31:0] mem_array [0:2047];
    
    // Read/Write operation
    always @(posedge clk) begin
        if (!rst_n) begin
            dout <= 32'h0;
        end else if (en && !isolate) begin
            // Byte-wise write
            if (we[0]) mem_array[addr][7:0]   <= din[7:0];
            if (we[1]) mem_array[addr][15:8]  <= din[15:8];
            if (we[2]) mem_array[addr][23:16] <= din[23:16];
            if (we[3]) mem_array[addr][31:24] <= din[31:24];
            
            // Read
            dout <= mem_array[addr];
        end
    end
    

    integer i;
    initial begin
        // Initialize entire SRAM to zero
        for (i = 0; i < 2048; i = i + 1) begin
            mem_array[i] = 32'h0;
        end
    end

endmodule

module timeout_counter (
    input  wire        clk_32khz,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [15:0] timeout_value,
    input  wire        entering_sleep,  // Pulse when entering SLEEP state
    input  wire        wake_ack,        // From PMU - wake has been acknowledged
    input  wire        rtc_tick,
    input  wire        pir_edge,
    output reg         timeout_wake,
    output wire [15:0] current_count
);

    reg [15:0] counter;
    reg rtc_tick_prev;  // For edge detection
    
    assign current_count = counter;
    
    // Edge detection for rtc_tick
    wire rtc_tick_edge = rtc_tick && !rtc_tick_prev;

    always @(posedge clk_32khz or negedge rst_n) begin
    if (!rst_n) begin
        // Reset - must stay as if (async reset)
        counter <= 16'd0;
        timeout_wake <= 1'b0;
        rtc_tick_prev <= 1'b0;
    end
    else begin
        (* parallel_case, full_case *)
        case (1'b1)
            // Module disabled
            !enable: begin
                counter <= 16'd0;
                timeout_wake <= 1'b0;
                rtc_tick_prev <= rtc_tick;
            end
            
            // Entering sleep state
            entering_sleep: begin
                counter <= 16'd0;
                timeout_wake <= 1'b0;
                rtc_tick_prev <= rtc_tick;
            end
            
            // Wake acknowledged
            (wake_ack && timeout_wake): begin
                counter <= 16'd0;
                timeout_wake <= 1'b0;
                rtc_tick_prev <= rtc_tick;
            end
            
            // PIR edge resets counter
            pir_edge: begin
                counter <= 16'd0;
                timeout_wake <= 1'b0;
                rtc_tick_prev <= rtc_tick;
            end
            
            // RTC tick - count or trigger
            rtc_tick_edge: begin
                rtc_tick_prev <= rtc_tick;
                if (counter + 1 >= timeout_value) begin
                    timeout_wake <= 1'b1;
                end
                else begin
                    counter <= counter + 1'b1;
                end
            end
            
            // Default: Track RTC tick
            default: begin
                rtc_tick_prev <= rtc_tick;
            end
        endcase
    end
end

endmodule


// External Flash Controller
module flash_controller_external (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        pwr_en,
    input  wire [15:0] addr,
    output reg  [31:0] rdata,
    input  wire        valid,
    output wire        ready,
    output wire        spi_clk,
    output wire        spi_cs_n,
    output wire        spi_mosi,
    input  wire        spi_miso
);
    reg [3:0] state;
    reg [7:0] bit_count;
    reg [31:0] spi_addr;
    reg [31:0] spi_data;
    reg spi_clk_reg;
    reg spi_cs_n_reg;
    reg spi_mosi_reg;
    reg flash_ready;
    localparam IDLE = 4'd0, CMD = 4'd1, ADDR = 4'd2, DUMMY = 4'd3, DATA = 4'd4, DONE = 4'd5;
    localparam CMD_FAST_READ = 8'h0B;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; flash_ready <= 1'b0; spi_clk_reg <= 1'b0;
            spi_cs_n_reg <= 1'b1; spi_mosi_reg <= 1'b0; rdata <= 32'h0;
        end else if (!pwr_en) begin
            state <= IDLE; flash_ready <= 1'b0; spi_cs_n_reg <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    flash_ready <= 1'b0; spi_cs_n_reg <= 1'b1;
                    if (valid) begin
                        state <= CMD; spi_cs_n_reg <= 1'b0;
                        bit_count <= 8'd7; spi_addr <= {16'h0, addr};
                    end
                end
                CMD: begin
                    spi_mosi_reg <= CMD_FAST_READ[bit_count];
                    spi_clk_reg <= ~spi_clk_reg;
                    if (spi_clk_reg && bit_count == 0) begin 
                        state <= ADDR; bit_count <= 8'd23; 
                    end
                    else if (spi_clk_reg) 
                        bit_count <= bit_count - 1;
                end
                ADDR: begin
                    spi_mosi_reg <= spi_addr[bit_count];
                    spi_clk_reg <= ~spi_clk_reg;
                    if (spi_clk_reg && bit_count == 0) begin 
                        state <= DUMMY; bit_count <= 8'd7; 
                    end
                    else if (spi_clk_reg) 
                        bit_count <= bit_count - 1;
                end
                DUMMY: begin
                    spi_clk_reg <= ~spi_clk_reg;
                    if (spi_clk_reg && bit_count == 0) begin 
                        state <= DATA; bit_count <= 8'd31; 
                    end
                    else if (spi_clk_reg) bit_count <= bit_count - 1;
                end
                DATA: begin
                    spi_clk_reg <= ~spi_clk_reg;
                    if (!spi_clk_reg) 
                        spi_data[bit_count] <= spi_miso;
                    if (spi_clk_reg && bit_count == 0) begin 
                        state <= DONE; rdata <= spi_data; 
                    end
                    else if (spi_clk_reg) 
                        bit_count <= bit_count - 1;
                end
                DONE: begin
                    spi_cs_n_reg <= 1'b1;
                    flash_ready <= 1'b1;
                    if (!valid) begin
                        flash_ready <= 1'b0;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
    assign ready = flash_ready;
    assign spi_clk = spi_clk_reg;
    assign spi_cs_n = spi_cs_n_reg;
    assign spi_mosi = spi_mosi_reg;
endmodule

// GPIO Controller - 8-pin bidirectional GPIO with interrupt
// - 8 bidirectional GPIO pins
// - Individual direction control (1=output, 0=input)
module gpio_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  addr,           
    input  wire [31:0] wdata,
    output reg  [31:0] rdata, 
    input  wire [3:0]  wstrb,
    input  wire        valid,
    inout  wire [7:0]  gpio_pad,       // Physical GPIO pins
    output wire [7:0]  gpio_out,       // Output values
    inout  wire [7:0]  gpio_in,        // Input values
    output wire [7:0]  gpio_dir,       // Direction (1=out, 0=in)
    output reg         irq_pir         // PIR interrupt (GPIO[0] rising edge)
);

    // Register Map
    // 0x00: GPIO_OUT - Output values
    // 0x04: GPIO_DIR - Direction control
    // 0x08: GPIO_IN  - Input values (read-only)
    reg [7:0] gpio_out_reg;
    reg [7:0] gpio_dir_reg;
    reg [7:0] gpio_in_reg;
    reg [7:0] gpio_in_prev;
    
    assign gpio_out = gpio_out_reg;
    assign gpio_dir = gpio_dir_reg;
    
    // Bidirectional I/O
    // Each pin: output when dir=1, high-Z when dir=0
    assign gpio_pad[0] = gpio_dir_reg[0] ? gpio_out_reg[0] : 1'bz;
    assign gpio_pad[1] = gpio_dir_reg[1] ? gpio_out_reg[1] : 1'bz;
    assign gpio_pad[2] = gpio_dir_reg[2] ? gpio_out_reg[2] : 1'bz;
    assign gpio_pad[3] = gpio_dir_reg[3] ? gpio_out_reg[3] : 1'bz;
    assign gpio_pad[4] = gpio_dir_reg[4] ? gpio_out_reg[4] : 1'bz;
    assign gpio_pad[5] = gpio_dir_reg[5] ? gpio_out_reg[5] : 1'bz;
    assign gpio_pad[6] = gpio_dir_reg[6] ? gpio_out_reg[6] : 1'bz;
    assign gpio_pad[7] = gpio_dir_reg[7] ? gpio_out_reg[7] : 1'bz;
    
    // Input Sampling
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_in_reg <= 8'h0;
            gpio_in_prev <= 8'h0;
        end else begin
            gpio_in_reg <= gpio_pad;
            gpio_in_prev <= gpio_pad;
        end
    end
    
    assign gpio_in = gpio_in_reg;
    
    // CPU Register Access
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out_reg <= 8'h0;
            gpio_dir_reg <= 8'h0;  // All inputs by default
        end else if (valid && wstrb != 4'h0) begin
            case (addr[3:2])
                2'h0: begin  // GPIO_OUT
                    if (wstrb[0]) gpio_out_reg <= wdata[7:0];
                end
                
                2'h1: begin  // GPIO_DIR
                    if (wstrb[0]) gpio_dir_reg <= wdata[7:0];
                end
                // GPIO_IN is read-only
            endcase
        end
    end
    
    // CPU read
    always @(*) begin
        case (addr[3:2])
            2'h0: rdata = {24'h0, gpio_out_reg};
            2'h1: rdata = {24'h0, gpio_dir_reg};
            2'h2: rdata = {24'h0, gpio_in_reg};
            default: rdata = 32'h0;
        endcase
    end
    
    // PIR Interrupt (GPIO[0] rising edge)
    // This has been implemented in the motion sensor module, so it's not actually used.
    // It is left here to demonstrate how a GPIO-based interrupt could be implemented if needed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_pir <= 1'b0;
        end else begin
            // Rising edge detection on GPIO[0]
            irq_pir <= gpio_pad[0] && !gpio_in_prev[0];
        end
    end
endmodule

// UART Module - Universal Asynchronous Receiver/Transmitter
// Features:
// - 8 data bits, 1 stop bit, no parity
// - TX and RX with separate FIFOs (optional)
// - Interrupt on TX ready and RX valid
// - Baud rate = 4 MHz/ (baud_div + 1)

module uart (
    input  wire        clk,            // System clock
    input  wire        rst_n,          // Active-low reset
    input  wire [3:0]  addr,           // Register address (byte offset)
    input  wire [31:0] wdata,          // Write data
    output reg  [31:0] rdata,          // Read data
    input  wire [3:0]  wstrb,          // Write strobe
    input  wire        valid,          // Valid transaction
    output wire        tx,             // UART transmit pin
    input  wire        rx,             // UART receive pin
    output reg         irq,            // Interrupt request
    input  wire [15:0] baud_div        // Baud rate divisor
);

    
    // Register Map
    // 0x00: DATA    - TX/RX data register
    // 0x04: STATUS  - Status register (TX_READY, RX_VALID)
    // 0x08: CONTROL - Control register (enable, interrupts)
    reg [7:0]  tx_data;
    reg        tx_valid;
    reg        tx_ready;
    reg [7:0]  rx_data;
    reg        rx_valid;
    reg        rx_clear;  // Handshake: CPU block sets this, RX block clears rx_valid
    reg        uart_enable;
    reg        tx_irq_enable;
    reg        rx_irq_enable;
    
    // Status Bits
    wire [31:0] status_reg = {30'h0, rx_valid, tx_ready};
    wire [31:0] control_reg = {29'h0, rx_irq_enable, tx_irq_enable, uart_enable};
    
    // CPU Register Access
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid <= 1'b0;
            uart_enable <= 1'b1;      // Enabled by default
            tx_irq_enable <= 1'b0;
            rx_irq_enable <= 1'b0;
            rx_clear <= 1'b0;
        end else begin
            tx_valid <= 1'b0;  // Pulse
            rx_clear <= 1'b0;  // Pulse
            
            if (valid && wstrb != 4'h0) begin
                case (addr[3:2])
                    2'h0: begin  // DATA register
                        if (wstrb[0]) begin
                            tx_data <= wdata[7:0];
                            tx_valid <= 1'b1;
                        end
                    end
                    
                    2'h2: begin  // CONTROL register
                        if (wstrb[0]) begin
                            uart_enable <= wdata[0];
                            tx_irq_enable <= wdata[1];
                            rx_irq_enable <= wdata[2];
                        end
                    end
                endcase
            end
            
            // Signal RX block to clear rx_valid on read
            if (valid && addr[3:2] == 2'h0 && wstrb == 4'h0) begin
                rx_clear <= 1'b1;
            end
        end
    end
    
    // CPU read
    always @(*) begin
        case (addr[3:2])
            2'h0: rdata = {24'h0, rx_data};      // DATA
            2'h1: rdata = status_reg;             // STATUS
            2'h2: rdata = control_reg;            // CONTROL
            default: rdata = 32'h0;
        endcase
    end
    
    // Interrupt Generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq <= 1'b0;
        end else begin
            irq <= (tx_ready && tx_irq_enable) || (rx_valid && rx_irq_enable);
        end
    end
    
    // UART Transmitter
    reg [3:0]  tx_state;
    reg [15:0] tx_baud_cnt;
    reg        tx_out;
    
    localparam TX_IDLE  = 4'd0;
    localparam TX_START = 4'd1;
    localparam TX_BIT0  = 4'd2;
    localparam TX_BIT1  = 4'd3;
    localparam TX_BIT2  = 4'd4;
    localparam TX_BIT3  = 4'd5;
    localparam TX_BIT4  = 4'd6;
    localparam TX_BIT5  = 4'd7;
    localparam TX_BIT6  = 4'd8;
    localparam TX_BIT7  = 4'd9;
    localparam TX_STOP  = 4'd10;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
            tx_baud_cnt <= 16'h0;
            tx_out <= 1'b1;
            tx_ready <= 1'b1;
        end else if (uart_enable) begin
            if (tx_baud_cnt > 0) begin
                tx_baud_cnt <= tx_baud_cnt - 1;
            end else begin
                case (tx_state)
                    TX_IDLE: begin
                        tx_out <= 1'b1;
                        tx_ready <= 1'b1;
                        if (tx_valid) begin
                            tx_state <= TX_START;
                            tx_baud_cnt <= baud_div;
                            // tx_ready <= 1'b0;
                        end
                    end
                    
                    TX_START: begin
                        tx_out <= 1'b0;  // Start bit
                        tx_state <= TX_BIT0;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT0: begin
                        tx_out <= tx_data[0];
                        tx_state <= TX_BIT1;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT1: begin
                        tx_out <= tx_data[1];
                        tx_state <= TX_BIT2;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT2: begin
                        tx_out <= tx_data[2];
                        tx_state <= TX_BIT3;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT3: begin
                        tx_out <= tx_data[3];
                        tx_state <= TX_BIT4;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT4: begin
                        tx_out <= tx_data[4];
                        tx_state <= TX_BIT5;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT5: begin
                        tx_out <= tx_data[5];
                        tx_state <= TX_BIT6;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT6: begin
                        tx_out <= tx_data[6];
                        tx_state <= TX_BIT7;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_BIT7: begin
                        tx_out <= tx_data[7];
                        tx_state <= TX_STOP;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    TX_STOP: begin
                        tx_out <= 1'b1;  // Stop bit
                        tx_state <= TX_IDLE;
                        tx_baud_cnt <= baud_div;
                    end
                    
                    default: begin
                        tx_state <= TX_IDLE;
                    end
                endcase
            end
        end else begin
            tx_state <= TX_IDLE;
            tx_ready <= 1'b1;
            tx_out <= 1'b1;
        end
    end
    
    assign tx = tx_out;
    
    // UART Receiver
    reg [3:0]  rx_state;
    reg [15:0] rx_baud_cnt;
    reg [7:0]  rx_shift;
    reg        rx_sync1, rx_sync2;  // Synchronizer
    
    localparam RX_IDLE  = 4'd0;
    localparam RX_START = 4'd1;
    localparam RX_BIT0  = 4'd2;
    localparam RX_BIT1  = 4'd3;
    localparam RX_BIT2  = 4'd4;
    localparam RX_BIT3  = 4'd5;
    localparam RX_BIT4  = 4'd6;
    localparam RX_BIT5  = 4'd7;
    localparam RX_BIT6  = 4'd8;
    localparam RX_BIT7  = 4'd9;
    localparam RX_STOP  = 4'd10;
    
    // Synchronize RX input
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
            rx_baud_cnt <= 16'h0;
            rx_shift <= 8'h0;
            rx_data <= 8'h0;
            rx_valid <= 1'b0;
        end else if (uart_enable) begin
            // Clear rx_valid when CPU reads DATA register
            if (rx_clear) begin
                rx_valid <= 1'b0;
            end
            if (rx_baud_cnt > 0) begin
                rx_baud_cnt <= rx_baud_cnt - 1;
            end else begin
                case (rx_state)
                    RX_IDLE: begin
                        if (!rx_sync2) begin  // Start bit detected
                            rx_state <= RX_START;
                            rx_baud_cnt <= baud_div >> 1;  // Half bit time
                        end
                    end
                    
                    RX_START: begin
                        if (!rx_sync2) begin  // Verify start bit
                            rx_state <= RX_BIT0;
                            rx_baud_cnt <= baud_div;
                        end else begin
                            rx_state <= RX_IDLE;  // False start
                        end
                    end
                    
                    RX_BIT0: begin
                        rx_shift[0] <= rx_sync2;
                        rx_state <= RX_BIT1;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT1: begin
                        rx_shift[1] <= rx_sync2;
                        rx_state <= RX_BIT2;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT2: begin
                        rx_shift[2] <= rx_sync2;
                        rx_state <= RX_BIT3;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT3: begin
                        rx_shift[3] <= rx_sync2;
                        rx_state <= RX_BIT4;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT4: begin
                        rx_shift[4] <= rx_sync2;
                        rx_state <= RX_BIT5;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT5: begin
                        rx_shift[5] <= rx_sync2;
                        rx_state <= RX_BIT6;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT6: begin
                        rx_shift[6] <= rx_sync2;
                        rx_state <= RX_BIT7;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_BIT7: begin
                        rx_shift[7] <= rx_sync2;
                        rx_state <= RX_STOP;
                        rx_baud_cnt <= baud_div;
                    end
                    
                    RX_STOP: begin
                        if (rx_sync2) begin  // Valid stop bit
                            rx_data <= rx_shift;
                            rx_valid <= 1'b1;
                        end
                        rx_state <= RX_IDLE;
                    end
                    
                    default: begin
                        rx_state <= RX_IDLE;
                    end
                endcase
            end
        end else begin
            rx_state <= RX_IDLE;
        end
    end
endmodule
// Boot ROM - Hardwired firmware copy loop
// At power-on, CPU starts executing from 0x0000_0000 (boot ROM).
// This ROM copies 8KB from flash (0x0800_0000) to SRAM (0x2000_0000),
// then jumps to SRAM for full-speed execution.
//
// Boot time: ~81ms at 4MHz (2048 words × ~159 cycles per SPI read)
// After boot: CPU runs from SRAM at full speed (1-2 cycles per instruction)
//
// Assembly:
//   0x00: lui   x5, 0x08000        # x5 = 0x08000000 (flash source)
//   0x04: lui   x6, 0x20000        # x6 = 0x20000000 (SRAM dest)
//   0x08: lui   x7, 0x20002        # x7 = 0x20002000 (SRAM end = 8KB)
//   0x0C: lw    x8, 0(x5)          # Load word from flash
//   0x10: sw    x8, 0(x6)          # Store word to SRAM
//   0x14: addi  x5, x5, 4          # flash_ptr += 4
//   0x18: addi  x6, x6, 4          # sram_ptr += 4
//   0x1C: bne   x6, x7, -16        # Loop until done
//   0x20: lui   x5, 0x20000        # x5 = 0x20000000
//   0x24: jalr  x0, x5, 0          # Jump to SRAM entry point

module boot_rom (
    input  wire [5:0]  addr,
    output reg  [31:0] rdata
);

    always @(*) begin
        case (addr[5:2])
            4'd0:  rdata = 32'h080002B7;  // lui   x5, 0x08000
            4'd1:  rdata = 32'h20000337;  // lui   x6, 0x20000
            4'd2:  rdata = 32'h200023B7;  // lui   x7, 0x20002
            4'd3:  rdata = 32'h0002A403;  // lw    x8, 0(x5)
            4'd4:  rdata = 32'h00832023;  // sw    x8, 0(x6)
            4'd5:  rdata = 32'h00428293;  // addi  x5, x5, 4
            4'd6:  rdata = 32'h00430313;  // addi  x6, x6, 4
            4'd7:  rdata = 32'hFE7318E3;  // bne   x6, x7, -16
            4'd8:  rdata = 32'h200002B7;  // lui   x5, 0x20000
            4'd9:  rdata = 32'h00028067;  // jalr  x0, x5, 0
            default: rdata = 32'h00000013; // NOP
        endcase
    end

endmodule
