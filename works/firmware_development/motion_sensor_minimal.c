/* 
 * Copyright (c) 2026 Jonghyeok Kim
 * MIT License.
 *
 * Firmware for motion sensor using UART for Zigbee communication.
 * SPI is used during boot only (firmware load from external flash).
 * 
 * Note: Status logging ("BOOT", "PIR", etc.) is commented out to avoid
 * conflict with the Zigbee protocol on the same UART line.
 * For dual-UART systems (one for logging, one for Zigbee), uncomment
 * the LOG_UART definitions and use a second UART instance.
 */
#include <stdint.h>

// Zigbee communication over UART
#define UART              (*(volatile uint32_t*)0x10000000)
#define UART_STATUS       (*(volatile uint32_t*)0x10000004)
#define UART_RXVALID_BIT  (1 << 1)

// PMU Registers
#define PMU_STATE         (*(volatile uint32_t*)0x10000200)
#define PMU_ZIGBEE_PWR    (*(volatile uint32_t*)0x1000020C)
#define PMU_TIMEOUT_VALUE (*(volatile uint32_t*)0x10000220)
#define PMU_TIMEOUT_CTRL  (*(volatile uint32_t*)0x10000224)
#define PMU_IRQ_PENDING   (*(volatile uint32_t*)0x10000268)
#define PMU_IRQ_CLEAR     (*(volatile uint32_t*)0x1000026C)

#define PWR_DEEP_SLEEP  0x00
#define PWR_SLEEP       0x01
#define IRQ_PIR         (1 << 3)
#define IRQ_TIMEOUT     (1 << 4)
#define TIMEOUT_SECONDS 1
#define WFI()   asm volatile("wfi" ::: "memory")
#define FENCE() asm volatile("fence" ::: "memory")

// Send a byte over UART to the Zigbee module
static inline void zigbee_send(uint8_t byte) {
    UART = byte;
}

// Send a "Light ON/OFF" packet to the Zigbee module via UART
static inline void zigbee_send_light(uint8_t on) {
    zigbee_send(0x02);   // TX command
    zigbee_send(0x03);   // Length
    zigbee_send('L');    // Light command
    zigbee_send(on);     // ON = 1, OFF = 0
    zigbee_send(0x00);   // Sequence
}

// Attempt to join the Zigbee network (simplified)
static inline void zigbee_join_attempt(void) {
    zigbee_send(0x01);   // Join command
    zigbee_send(0x00);   // Channel
}

void main(void) {
    // Zigbee connection: 5 attempts
    for (int attempt = 0; attempt < 5; attempt++) {
        PMU_ZIGBEE_PWR = 0x01;   // Power on Zigbee module
        zigbee_join_attempt();
        PMU_ZIGBEE_PWR = 0x00;   // Power off Zigbee module
        
#ifndef SIMULATION
        // Real hardware: brief wait for module response
        for (volatile int i = 0; i < 100; i++);
#endif
    }
    
    // Configure sleep timeout
    PMU_TIMEOUT_VALUE = TIMEOUT_SECONDS;
    
    // Main sensing loop
    while (1) {
        // Deep sleep - wait for PIR motion event
        PMU_TIMEOUT_CTRL = 0x00;
        PMU_IRQ_CLEAR = IRQ_PIR | IRQ_TIMEOUT;
        PMU_STATE = PWR_DEEP_SLEEP;
        FENCE();
        WFI();
        
        // PIR woke the chip - send "Light ON"
        PMU_IRQ_CLEAR = PMU_IRQ_PENDING;
        PMU_ZIGBEE_PWR = 0x01;
        zigbee_send_light(0x01);
        PMU_ZIGBEE_PWR = 0x00;
        
        // Sleep mode - wait for timeout (no new motion)
        PMU_TIMEOUT_CTRL = 0x01;
        PMU_IRQ_CLEAR = IRQ_TIMEOUT | IRQ_PIR;
        PMU_STATE = PWR_SLEEP;
        FENCE();
        WFI();
        
        // Timeout (or new PIR) woke the chip
        uint32_t irq = PMU_IRQ_PENDING;
        PMU_IRQ_CLEAR = irq;
        PMU_TIMEOUT_CTRL = 0x00;
        
        // If timeout expired, send "Light OFF"
        if (irq & IRQ_TIMEOUT) {
            PMU_ZIGBEE_PWR = 0x01;
            zigbee_send_light(0x00);
            PMU_ZIGBEE_PWR = 0x00;
        }
        // If PIR fired again, loop continues and next iteration
        // will send another "Light ON" then re-enter Sleep mode
    }
}
