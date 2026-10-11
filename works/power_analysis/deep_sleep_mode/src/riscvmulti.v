
/*  Copyright (C) 2026  Jonghyeok (Burt) Kim <rhdtn1244@gmail.com>
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
 */

`timescale 1 ns / 1 ps

module pmu (
    input  wire        clk_4mhz,
    input  wire        clk,
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
    reg [1:0]  pmu_state;           // 2 bits: 4 power states
    reg [7:0]  pmu_control;         // 8 bits: oscillator control flags
    reg [7:0]  pmu_wakeup;          // 8 bits: wake source enables
    reg [15:0] rtc_last_motion;     // 16 bits: ~18 hours max timeout
    reg [15:0] retained_pan_id;     // 16 bits: Zigbee PAN ID
    reg [7:0]  retained_channel;    // 8 bits: Zigbee channel (11-26)
    reg [15:0] retained_magic;      // 16 bits: magic value (0xBEEF)
    reg [7:0]  retained_connected;  // 8 bits: connection status (0xA5)
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_ack_sync1 <= 1'b0;
            wake_ack_sync2 <= 1'b0;
            state_sync1 <= 2'b00; // Forcing DEEP SLEEP mode
            state_sync2 <= 2'b00; // Forcing DEEP SLEEP mode
            state_sync2_prev <= 2'b00; // Forcing DEEP SLEEP mode
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
    always @(posedge clk or negedge rst_n) begin
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
        .clk      (clk),
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

    always @(posedge clk or negedge rst_n) begin
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
            //flash_pwr_en <= 1'b1;
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
                //8'h10: flash_pwr_en <= cpu_wdata[0];
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
    always @(posedge clk_4mhz or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= 2'b00;
            pmu_state <= 2'b00;
            cpu_halted <= 1'b0;
            clock_gate_enable <= 1'b1;
            cpu_reset <= 1'b1;
            prev_trap <= 1'b0;
            osc_4mhz_enable_reg <= 1'b0;
            osc_32khz_enable_reg <= 1'b0;
            wake_ack <= 1'b0;
            pir_wake_sync2_prev <= 1'b0;
            wake_protection_counter <= 12'd0;
            just_woke <= 1'b0;
            direct_pir_counter <= 5'd0;
        end else begin
            // Handle CPU writes to PMU_STATE register
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h00) begin
                pmu_state <= cpu_wdata[1:0];
            end
            prev_trap <= cpu_trap;
            pir_wake_sync2_prev <= pir_wake_sync2;
            cpu_reset <= 1'b0;
            
            // CENTRALIZED WAKE HANDLER
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
            
            // STATE-SPECIFIC LOGIC (skip if wake transition is happening)
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
            end  // if (!do_wake)
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

            // Latch RTC tick on RISING EDGE only
            if (rtc_tick_sync2 && !rtc_tick_sync2_prev && current_state != 2'b00) begin
                irq_rtc_latch <= 1'b1;
            end
            
            // Latch timeout wake
            if (timeout_wake_sync2 && !timeout_wake_sync2_prev) begin
                irq_timeout_latch <= 1'b1;
                irq_hold_counter <= 8'd100;  // Hold IRQ high for 100 cycles
            end

            // IRQ hold counter - decrement but DON'T clear latch until 0
            if (irq_hold_counter > 0) begin
                irq_hold_counter <= irq_hold_counter - 1;
            end

            // Clear conditions - ONLY when hold counter has expired
            // 1. Software acknowledge via IRQ_ACK register write
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h6C && irq_hold_counter == 0) begin
                if (cpu_wdata[3]) begin
                    irq_pir_latch <= 1'b0;
                end
                if (cpu_wdata[2]) irq_rtc_latch <= 1'b0;
                if (cpu_wdata[4]) irq_timeout_latch <= 1'b0;
            end

            // 2. Auto-clear RTC and timeout latch during deep sleep
            if (current_state == 2'b00 && clock_gate_enable == 1'b0) begin
                irq_rtc_latch <= 1'b0;
                irq_timeout_latch <= 1'b0;
            end

            // 3. Auto-clear when entering sleep (firmware requested sleep)
            //    This prevents stale IRQ from immediately waking
            if (cpu_valid && cpu_wstrb[0] && cpu_addr == 8'h00 && cpu_wdata[1:0] != 2'b11) begin 
                irq_rtc_latch <= 1'b0;
                irq_timeout_latch <= 1'b0;
                irq_pir_latch <= 1'b0;
            end
            
            // Build irq_pending output - NO FEEDBACK, directly from latches
            // For PIR: during SHORT direct_pir window, also check direct irq_pir signal
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
module motion_sensor_chip_synth (
    //input  wire         clk_4mhz,           // 4MHz clock input
    input  wire         rst_n,              // Active-low reset
    input  wire         pir_sensor,         // PIR sensor input
    output wire [3:0]   debug_state,        // PMU state for debug
    output wire         debug_clk_cpu_en,   // Clock gating status
    output wire         debug_cpu_trap      // CPU trap/WFI status
);
    wire clk_4mhz = 1'b0;   // 4MHz disabled - deep sleep
    wire clk      = 1'b0;   // 32kHz disabled - deep sleep
    wire        rst_n_sync;         // Synchronized reset
    wire        clk_cpu;            // Gated clock from PMU
    wire        cpu_trap;           // CPU trap signal
    wire        cpu_do_wfi;         // CPU WFI signal
    wire        cpu_reset;          // CPU reset from PMU
    
    // CPU Memory Interface
    wire        cpu_mem_valid;
    wire        cpu_mem_ready;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0]  cpu_mem_wstrb;
    wire [31:0] cpu_mem_rdata;
    
    // IRQ signals
    wire [31:0] irq_pending;
    
    // PMU signals
    wire [31:0] pmu_rdata;
    wire        pmu_ready;

	assign cpu_mem_valid = 1'b0;
	assign cpu_mem_addr  = 32'h0;
	assign cpu_mem_wdata = 32'h0;
	assign cpu_mem_wstrb = 4'h0;
	assign cpu_trap      = 1'b0;
	assign cpu_do_wfi    = 1'b0;
    // Memory Map:
    // 0x0000_0000 - 0x0000_1FFF : SRAM (8KB)
    // 0x1000_0200 - 0x1000_02FF : PMU Registers
    
    wire sel_mem = (cpu_mem_addr[31:16] == 16'h0000);           // 0x0000_xxxx
    wire sel_pmu = (cpu_mem_addr[31:8]  == 24'h100002);         // 0x1000_02xx
    
	wire [31:0] mem_rdata = 32'h0;
	wire        mem_ready = 1'b0;
	wire [31:0] pmu_control;
	wire [31:0] pmu_state;
	wire [31:0] pmu_wakeup;

    // Read data mux
    wire [31:0] mem_rdata_mux = sel_pmu ? pmu_rdata :
                                sel_mem ? mem_rdata :
                                32'h0;
    
    assign cpu_mem_rdata = mem_rdata_mux;
    
    // Ready signal mux
    assign cpu_mem_ready = sel_pmu ? pmu_ready :
                           sel_mem ? mem_ready :
                           1'b1;

    assign rst_n_sync = rst_n;
    

    pmu u_pmu (
        .clk_4mhz       		(clk_4mhz),
        .clk              		(clk),
        .rst_n                  (rst_n_sync),
        
        // CPU register interface
        .cpu_addr               (cpu_mem_addr[7:0]),
        .cpu_wdata              (cpu_mem_wdata),
        .cpu_rdata              (pmu_rdata),
        .cpu_wstrb              (cpu_mem_wstrb),
        .cpu_valid              (cpu_mem_valid & sel_pmu),
        .cpu_ready              (pmu_ready),
        
        // CPU control signals
        .cpu_trap               (cpu_trap | cpu_do_wfi),
        .cpu_reset              (cpu_reset),
        .clk_cpu                (clk_cpu),
        
        // Wake sources
        .irq_pir                (pir_sensor),
        
        // IRQ output
        .irq_pending            (irq_pending),
        
        // Status outputs (directly expose for power analysis observation)
        .pmu_control_out        (pmu_control),
        .pmu_state_out          (pmu_state),
        .pmu_wakeup_out         (pmu_wakeup),
        
        // Power control (directly connect for power analysis)
        .zigbee_pwr_en          (),             // Not used in synthesis
        .flash_pwr_en           (),             // Not used in synthesis
        .osc_4mhz_enable_internal (),           // Not used in synthesis
        .osc_32khz_enable       (),             // Not used in synthesis
        
        // Debug
        .debug_state            (debug_state),
		.clock_gate_enable_out  (debug_clk_cpu_en)
    );
    
    assign debug_cpu_trap = cpu_trap | cpu_do_wfi;

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

module timeout_counter (
    input  wire        clk,
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

    always @(posedge clk or negedge rst_n) begin
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