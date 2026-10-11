// Post-Synthesis Testbench for Motion Sensor IoT Chip
// Burt Kim

`timescale 1ns/1ps

module testbench();
    reg rst_n;
    reg xin_4mhz = 0;
    reg xin_32khz = 0;

    always #125    xin_4mhz  = ~xin_4mhz;    // 4MHz
    always #15258  xin_32khz = ~xin_32khz;    // 32.768kHz

    wire [7:0]  gpio;
    wire [3:0]  debug_state;
    wire        debug_clk_cpu_en;
    wire        debug_cpu_trap;
    wire        uart0_tx;
    reg         uart0_rx;

    wire        flash_spi_clk;
    wire        flash_spi_cs_n;
    wire        flash_spi_mosi;
    wire        flash_spi_miso;

    reg pir_trigger = 0;
    assign (weak0, weak1) gpio[0]   = pir_trigger;
    assign (weak0, weak1) gpio[7:1] = 7'b0;

    motion_sensor_chip_top dut (
        .clk_4mhz       (xin_4mhz),
        .clk_32khz      (xin_32khz),
        .rst_n           (rst_n),
        .pir_sensor      (pir_trigger),
        .gpio            (gpio),
        .uart0_tx        (uart0_tx),
        .uart0_rx        (uart0_rx),
        .flash_spi_clk   (flash_spi_clk),
        .flash_spi_cs_n  (flash_spi_cs_n),
        .flash_spi_mosi  (flash_spi_mosi),
        .flash_spi_miso  (flash_spi_miso),
        .debug_state     (debug_state),
        .debug_clk_cpu_en(debug_clk_cpu_en),
        .debug_cpu_trap  (debug_cpu_trap)
    );

    // VCD Dump
    initial begin
        $dumpfile("post_synth_sim.vcd");
        $dumpvars(0, testbench);
    end

    spi_flash_model u_flash_model (
        .spi_clk  (flash_spi_clk),
        .spi_cs_n (flash_spi_cs_n),
        .spi_mosi (flash_spi_mosi),
        .spi_miso (flash_spi_miso)
    );

    // clk_cpu edge counter
    integer clk_cpu_edges;
    initial clk_cpu_edges = 0;
    always @(posedge dut.clk_cpu) begin
        clk_cpu_edges = clk_cpu_edges + 1;
        if (clk_cpu_edges <= 5 || (clk_cpu_edges % 1000 == 0 && clk_cpu_edges <= 10000))
            $display("[CLK_CPU] Edge #%0d @ %0t", clk_cpu_edges, $time);
    end
    
    // Detailed state check 2ms after reset
    initial begin
        @(posedge rst_n);
        #2000000;  // 2ms after reset
        $display("\n======================================================");
        $display("2ms POST-RESET STATE CHECK");
        $display("  clk_cpu edges:     %0d", clk_cpu_edges);
        $display("  clk_gate_latch:    %b", dut.u_pmu_clk_gate_latch);
        $display("  clk_cpu:           %b", dut.clk_cpu);
        $display("  cpu_reset:         %b", dut.cpu_reset);
        $display("  cpu_trap:          %b", dut.cpu_trap);
        $display("  cpu_do_wfi:        %b", dut.cpu_do_wfi);
        $display("  cpu_mem_valid_raw: %b", dut.cpu_mem_valid_raw);
        $display("  debug_state:       %b", debug_state);
        $display("  debug_clk_cpu_en:  %b", debug_clk_cpu_en);
        $display("  flash_spi_cs_n:    %b", flash_spi_cs_n);
        $display("======================================================\n");
    end
    
    // PMU State Decode
    wire [1:0] pmu_state = debug_state[1:0];

    // Deep Sleep Counter - Auto stop after 2 deep sleep entries (one full cycle)
    integer deep_sleep_count;
    reg [1:0] last_pmu_state;

    initial begin
        deep_sleep_count = 0;
        last_pmu_state = 2'b11;
    end

    always @(pmu_state) begin
        if (pmu_state == 2'b00 && last_pmu_state != 2'b00) begin
            deep_sleep_count = deep_sleep_count + 1;
            $display("\n======================================================");
            $display(" DEEP SLEEP ENTRY #%0d @ %0t ms", deep_sleep_count, $time/1000000);
            $display("======================================================");

            if (deep_sleep_count == 2) begin
                uart_flush_buf;  // flush any remaining UART output
                $display("\n======================================================");
                $display("          SIMULATION COMPLETE                         ");
                $display("      One Complete Cycle Executed                     ");
                $display("======================================================\n");
                $finish;
            end
        end
        last_pmu_state = pmu_state;
    end

    // PMU State Monitor
    always @(pmu_state) begin
        case (pmu_state)
            2'b00: $display("[%0t ms] PMU -> DEEP_SLEEP",    $time/1000000);
            2'b01: $display("[%0t ms] PMU -> SLEEP",         $time/1000000);
            2'b10: $display("[%0t ms] PMU -> IDLE",          $time/1000000);
            2'b11: $display("[%0t ms] PMU -> ACTIVE",        $time/1000000);
        endcase
    end

    // Clock Gating & Trap Monitor
    always @(debug_clk_cpu_en) begin
        if (debug_clk_cpu_en === 1'b1)
            $display("[%0t ms] CPU Clock Gate: ENABLED", $time/1000000);
        else if (debug_clk_cpu_en === 1'b0)
            $display("[%0t ms] CPU Clock Gate: DISABLED", $time/1000000);
    end

    always @(posedge debug_cpu_trap) begin
        $display("[%0t ms] CPU TRAP/WFI asserted", $time/1000000);
    end

    always @(negedge debug_cpu_trap) begin
        if (rst_n)
            $display("[%0t ms] CPU TRAP/WFI deasserted", $time/1000000);
    end

    // GPIO Output Monitor
    reg [7:0] prev_gpio;
    initial prev_gpio = 8'h00;

    always @(gpio) begin
        if (^gpio !== 1'bx && gpio !== prev_gpio) begin
            case (gpio)
                8'h20: $display("[%0t ms] GPIO: DEEP_SLEEP marker",    $time/1000000);
                8'h30: $display("[%0t ms] GPIO: ACTIVE_MODE_1 marker", $time/1000000);
                8'h40: $display("[%0t ms] GPIO: COUNT_MODE marker",    $time/1000000);
                8'h41: $display("[%0t ms] GPIO: COUNT_MODE WAKEUP_SET",$time/1000000);
                8'h42: $display("[%0t ms] GPIO: COUNT_MODE SLEEP_LOOP",$time/1000000);
                8'h43: $display("[%0t ms] GPIO: COUNT_MODE WOKE",      $time/1000000);
                8'h50: $display("[%0t ms] GPIO: ACTIVE_MODE_2 marker", $time/1000000);
                default:
                    $display("[%0t ms] GPIO = 0x%02h", $time/1000000, gpio);
            endcase
            prev_gpio = gpio;
        end
    end

    // UART0 TX Monitor
    integer uart_state_var;
    integer uart_bit_cnt;
    reg [7:0] uart_rx_byte;

    // String buffer: collect characters until newline, then $display
    reg [7:0] uart_str_buf [0:79];  // 80-char buffer
    integer uart_str_len;
    integer uart_msg_time;

    initial begin
        uart_state_var = 0;
        uart_bit_cnt = 0;
        uart_rx_byte = 0;
        uart_str_len = 0;
        uart_msg_time = 0;
    end

    task uart_flush_buf;
        integer fi;
        begin
            if (uart_str_len > 0) begin
                $write("[%0d ms] UART TX: \"", uart_msg_time);
                for (fi = 0; fi < uart_str_len; fi = fi + 1)
                    $write("%c", uart_str_buf[fi]);
                $display("\"");
                uart_str_len = 0;
            end
        end
    endtask

    always @(negedge uart0_tx) begin
        if (uart_state_var == 0) begin
            uart_state_var = 1;
            uart_bit_cnt = 0;
            uart_rx_byte = 0;

            #54250;  // Half bit period (~9216 baud)

            repeat (8) begin
                #108500;  // Full bit period
                uart_rx_byte = {uart0_tx, uart_rx_byte[7:1]};
                uart_bit_cnt = uart_bit_cnt + 1;
            end

            #108500;  // Stop bit

            // Buffer printable characters, flush on newline
            if (uart_rx_byte == 10 || uart_rx_byte == 13) begin
                uart_flush_buf;
            end else if (uart_rx_byte >= 32 && uart_rx_byte < 127) begin
                if (uart_str_len == 0)
                    uart_msg_time = $time / 1000000;
                uart_str_buf[uart_str_len] = uart_rx_byte;
                uart_str_len = uart_str_len + 1;
                if (uart_str_len >= 80)
                    uart_flush_buf;
            end else if (uart_rx_byte != 0) begin
                uart_flush_buf;
                $display("[%0d ms] UART TX: [0x%02X]", $time/1000000, uart_rx_byte);
            end
            $fflush();

            uart_state_var = 0;
        end
    end

    // Bus-level UART Monitor (backup — monitors CPU writes to UART data register)
    always @(posedge dut.clk_cpu) begin
        if (dut.cpu_mem_valid && dut.cpu_mem_ready &&
            |dut.cpu_mem_wstrb &&
            dut.cpu_mem_addr[31:8] == 24'h100000 &&
            dut.cpu_mem_addr[7:0] == 8'h00) begin
            if (dut.cpu_mem_wdata[7:0] >= 8'h20 && dut.cpu_mem_wdata[7:0] < 8'h7F)
                $display("[%0t ms] UART BUS WRITE: '%c' (0x%02X)",
                         $time/1000000, dut.cpu_mem_wdata[7:0], dut.cpu_mem_wdata[7:0]);
            else
                $display("[%0t ms] UART BUS WRITE: [0x%02X]",
                         $time/1000000, dut.cpu_mem_wdata[7:0]);
        end
    end

    // PIR Trigger Monitor
    always @(posedge pir_trigger) begin
        $display("\n======================================================");
        $display(" [%0t ms] PIR TRIGGERED", $time/1000000);
        $display("   PMU State: %02b  Clock Gate: %b  Trap: %b",
                pmu_state, debug_clk_cpu_en, debug_cpu_trap);
        $display("======================================================\n");
    end

    // Test Stimulus
    initial begin
        $display("\n======================================================");
        $display(" MOTION SENSOR IOT CHIP - POST-SYNTHESIS SIMULATION   ");
        $display(" Auto-Stop After One Complete Cycle                    ");
        $display("======================================================\n");

        // Initialize
        rst_n = 0;
        pir_trigger = 0;
        uart0_rx = 1;

        // Hold reset
        #1000000;
        @(posedge xin_4mhz);
        @(posedge xin_32khz);
        @(posedge xin_4mhz);
        #30;
        $display("[%0t ms] Releasing reset...", $time/1000000);
        rst_n = 1;
        
        #1;

        // PMU hardware holds cpu_reset=1 for 32 extra cycles
        repeat(40) @(posedge xin_4mhz);
        $display("[%0t ms] CPU reset hold expired", $time/1000000);
        
        // Post-reset diagnostics
        #500;
        $display("[POST-RESET +500ns] debug_state=%b gate=%b trap=%b spi_cs=%b clk_cpu=%b latch=%b",
                debug_state, debug_clk_cpu_en, debug_cpu_trap, flash_spi_cs_n,
                dut.clk_cpu, dut.u_pmu_clk_gate_latch);
        #5000;
        $display("[POST-RESET +5us] debug_state=%b gate=%b trap=%b spi_cs=%b clk_cpu=%b latch=%b",
                debug_state, debug_clk_cpu_en, debug_cpu_trap, flash_spi_cs_n,
                dut.clk_cpu, dut.u_pmu_clk_gate_latch);
        #125000;
        $display("[POST-RESET +130us] debug_state=%b gate=%b trap=%b spi_cs=%b clk_cpu=%b latch=%b",
                debug_state, debug_clk_cpu_en, debug_cpu_trap, flash_spi_cs_n,
                dut.clk_cpu, dut.u_pmu_clk_gate_latch);

        // Wait for firmware boot and first deep sleep
        #120000000;  // 120ms

        // Trigger PIR
        $display("\n======================================================");
        $display(" Triggering PIR @ %0t ms", $time/1000000);
        $display("   PMU State: %02b  Clock Gate: %b",
                pmu_state, debug_clk_cpu_en);
        $display("======================================================\n");

        pir_trigger = 1;
        #2000000;
        pir_trigger = 0;

        // Safety timeout
        #2000000000;  // 2 seconds
        $display("\n======================================================");
        $display(" WARNING: Did not complete within 2s after PIR         ");
        $display("   PMU State: %02b  Deep Sleep Count: %0d",
                pmu_state, deep_sleep_count);
        $display("======================================================\n");
        $finish;
    end

    // Progress Monitor (every 10ms)
    initial begin
        @(posedge rst_n);
        forever begin
            #10000000;
            $display("[%0t ms] debug_state=%b  gate=%b  trap=%b  spi_cs=%b  spi_clk=%b  clk_edges=%0d  gpio=%b",
                    $time/1000000, debug_state, debug_clk_cpu_en,
                    debug_cpu_trap, flash_spi_cs_n, flash_spi_clk, clk_cpu_edges, gpio);
        end
    end

    // Absolute Safety Timeout
    initial begin
        #3000000000;  // 3 seconds absolute max
        $display("\n[TIMEOUT] Simulation exceeded 3 seconds");
        $finish;
    end

endmodule

// Behavioral SPI Flash Model
module spi_flash_model (
    input  wire spi_clk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output reg  spi_miso
);

    // 64KB flash
    reg [31:0] flash_mem [0:16383];
    integer i;

    initial begin
        for (i = 0; i < 16384; i = i + 1)
            flash_mem[i] = 32'h00000013;  // NOP
        $readmemh("motion_sensor_minimal.vhex", flash_mem);
        $display("======================================================");
        $display("SPI Flash Model Loaded");
        $display("Flash[0] = %h", flash_mem[0]);
        $display("Flash[1] = %h", flash_mem[1]);
    end

    reg [2:0]  state;
    reg [7:0]  cmd;
    reg [23:0] addr;
    reg [4:0]  bit_cnt;
    reg [31:0] data_out;

    localparam IDLE        = 3'd0;
    localparam CMD_PHASE   = 3'd1;
    localparam ADDR_PHASE  = 3'd2;
    localparam DUMMY_PHASE = 3'd3;
    localparam DATA_PHASE  = 3'd4;

    always @(posedge spi_cs_n) begin
        state    <= IDLE;
        spi_miso <= 1'bz;
    end

    always @(negedge spi_cs_n) begin
        state   <= CMD_PHASE;
        bit_cnt <= 5'd7;
        cmd     <= 8'd0;
    end

    always @(posedge spi_clk) begin
        if (!spi_cs_n) begin
            case (state)
                CMD_PHASE: begin
                    cmd[bit_cnt] <= spi_mosi;
                    if (bit_cnt == 0) begin
                        state   <= ADDR_PHASE;
                        bit_cnt <= 5'd23;
                        addr    <= 24'd0;
                    end else begin
                        bit_cnt <= bit_cnt - 1;
                    end
                end

                ADDR_PHASE: begin
                    addr[bit_cnt] <= spi_mosi;
                    if (bit_cnt == 0) begin
                        state   <= DUMMY_PHASE;
                        bit_cnt <= 5'd7;
                    end else begin
                        bit_cnt <= bit_cnt - 1;
                    end
                end

                DUMMY_PHASE: begin
                    if (bit_cnt == 0) begin
                        state    <= DATA_PHASE;
                        bit_cnt  <= 5'd31;
                        data_out <= flash_mem[addr[15:2]];
                    end else begin
                        bit_cnt <= bit_cnt - 1;
                    end
                end

                DATA_PHASE: begin
                    if (bit_cnt == 0) begin
                        bit_cnt  <= 5'd31;
                        data_out <= flash_mem[addr[15:2] + 1];
                        addr     <= addr + 4;
                    end else begin
                        bit_cnt <= bit_cnt - 1;
                    end
                end
            endcase
        end
    end

    always @(negedge spi_clk) begin
        if (!spi_cs_n && state == DATA_PHASE) begin
            spi_miso <= data_out[bit_cnt];
        end else begin
            spi_miso <= 1'bz;
        end
    end

endmodule