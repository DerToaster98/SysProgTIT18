@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@     main.s
@@@ ---------------------------------------------------------------------------
@@@     authors: Lisa Binkert, Nikolai Klatt, Samuel Rundel, Oliver Seiler,
@@@              Patrick Sewell
@@@     target:  Raspberry Pi
@@@     project: MM-Sorting-Machine
@@@     date:    2020/02/27
@@@     version: 0.1
@@@ ---------------------------------------------------------------------------
@@@ This program controls the MM-Sorting-Machine by reading two inputs,
@@@ controlling the motors(, serving the 7-segment display) and interacting
@@@ with the co-processor.
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

@ Constants for assembler
@ The following are defined in /usr/include/asm-generic/fcntl.h:
@ Note that the values are specified in octal.
        .equ      O_RDWR,00000002             @ open for read/write
        .equ      O_DSYNC,00010000            @ synchronize virtual memory
        .equ      __O_SYNC,04000000           @      programming changes with
        .equ      O_SYNC,__O_SYNC|O_DSYNC     @ I/O memory
@ The following are defined in /usr/include/asm-generic/mman-common.h:
        .equ      PROT_READ,0x1               @ page can be read
        .equ      PROT_WRITE,0x2              @ page can be written
        .equ      MAP_SHARED,0x01             @ share changes
@ The following are defined by me:
@       .equ      PERIPH,0x3f000000           @ RPi 2 & 3 peripherals
        .equ      PERIPH,0x20000000           @ RPi zero & 1 peripherals
        .equ      GPIO_OFFSET,0x200000        @ start of GPIO device
        .equ      TIMERIR_OFFSET,0xB000       @ start f�of IR and timer
        .equ      O_FLAGS,O_RDWR|O_SYNC       @ open file flags
        .equ      PROT_RDWR,PROT_READ|PROT_WRITE
        .equ      NO_PREF,0
        .equ      PAGE_SIZE,4096              @ Raspbian memory page
        .equ      FILE_DESCRP_ARG,0           @ file descriptor
        .equ      DEVICE_ARG,4                @ device address
        .equ      STACK_ARGS,8                @ sp already 8-byte aligned

        @ Positions of the respective colours. To be used with enum semantics in the code below
        .equ    yellow, 67
        .equ    green, 134
        .equ    blue, 200
        .equ    red, 268
        .equ    brown, 336
        .equ    orange, 0

        @ Offsets to GPIOREG
        .equ       set_pin_out, 0x1C
        .equ       clear_pin_out, 0x28
        .equ       pin_level, 0x34

SNORKEL .req      r4
TMPREG  .req      r5
RETREG  .req      r6
IRQREG  .req      r7
WAITREG .req      r8
RLDREG  .req      r9
GPIOREG .req      r10
COLREG  .req      r11

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@ - START OF DATA SECTION @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        .data
        .balign   4

gpiomem:
        .asciz    "/dev/gpiomem"
mem:
        .asciz    "/dev/mem"
fdMsg:
        .asciz    "File descriptor = %i\n"
memMsgGpio:
        .asciz    "(GPIO) Using memory at %p\n"
memMsgTimerIR:
        .asciz    "(Timer + IR) Using memory at %p\n"

IntroMsg:
        .asciz    "Welcome to the MM-Sorting-Machine!\n"
OutroMsg:
        .asciz    "Test"

        .balign   4
gpio_mmap_adr:
        .word     0               @ ...
gpio_mmap_fd:
        .word     0
timerir_mmap_adr:
        .word     0
timerir_mmap_fd:
        .word     0

mm_counter:             @ Holds the amount of counted M&Ms since the last activation
        .word         0

segment_pattern:        @ : int array; Bitpatterns for each digit to be displayed on the 7 segment display
        .word   0xEE    @ 2_11101110       @ 0
        .word   0x60    @ 2_01100000       @ 1
        .word   0xDA    @ 2_11011010       @ 2
        .word   0xF2    @ 2_11110010       @ 3
        .word   0x66    @ 2_01100110       @ 4
        .word   0xB6    @ 2_10110110       @ 5
        .word   0xBE    @ 2_10111110       @ 6
        .word   0xE0    @ 2_11100000       @ 7
        .word   0xFE    @ 2_11111110       @ 8
        .word   0xE6    @ 2_11100110       @ 9

@ - END OF DATA SECTION @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@ - START OF TEXT SECTION @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        .text

        @ externals for making use of std-functions
        .extern printf

        @ externals for making use of wiringPI
        .extern wiringPiSetup
        .extern delay
        .extern digitalWrite
        .extern pinMode

        @ externals for RGB LEDs
        .extern WS2812RPi_Init
        .extern WS2812RPi_DeInit
        .extern WS2812RPi_SetBrightness       @ provide (uint8_t brightness);
        .extern WS2812RPi_SetSingle           @ provide (uint8_t pos, uint32_t colour);
        .extern WS2812RPi_SetOthersOff        @ provide (uint8_t pos);
        .extern WS2812RPi_AllOff              @ provide (void);
        .extern WS2812RPi_AnimDo              @ provide (uint32_t cntCycles);
        .extern WS2812RPi_Show

        .balign   4
        .global   main
        .type     main, %function
@ -----------------------------------------------------------------------------
@ main entry point of the application
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
main:

		@Init IRQ-ISR
		ldr pc, _interrupt_vector_h

_interrupt_vector_h:		.word   irq
        ldr r0, =IntroMsg
        bl  printf

        @ GET GPIO VIRTUAL MEMORY ---------------------------------------------
        @ create backup and reserve stack space
        sub       sp, sp, #16                 @ space for saving regs
        str       r4, [sp, #0]                @ save r4
        str       r5, [sp, #4]                @      r5
        str       fp, [sp, #8]                @      fp
        str       lr, [sp, #12]               @      lr
        add       fp, sp, #12                 @ set our frame pointer
        sub       sp, sp, #STACK_ARGS         @ sp on 8-byte boundary

        @ open /dev/gpiomem for read/write and syncing
        ldr       r0, =gpiomem                 @ address of /dev/gpiomem
        ldr       r1, openMode                @ flags for accessing device
        bl        open
        mov       r4, r0                      @ use r4 for file descriptor

        @ display file descriptor
        ldr       r0, =fdMsg                  @ format for printf
        mov       r1, r4                      @ file descriptor
        bl        printf

        @ map the GPIO registers to a virtual memory location so we can access them
        str       r4, [sp, #FILE_DESCRP_ARG]  @ /dev/gpiomem file descriptor
        ldr       r0, gpio                    @ address of GPIO
        str       r0, [sp, #DEVICE_ARG]       @ location of GPIO
        mov       r0, #NO_PREF                @ let kernel pick memory
        mov       r1, #PAGE_SIZE              @ get 1 page of memory
        mov       r2, #PROT_RDWR              @ read/write this memory
        mov       r3, #MAP_SHARED             @ share with other processes
        bl        mmap

        @ save virtual memory address
        ldr       r1, =gpio_mmap_adr          @ store gpio mmap (virtual address)
        str       r0, [r1]
        ldr       r1, =gpio_mmap_fd           @ store the file descriptor
        str       r4, [r1]

        ldr       r6, [r1]
        mov       r1, r0                      @ display virtual address
        ldr       r0, =memMsgGpio
        bl        printf
        mov       r1, r6
        ldr       r0, =memMsgGpio
        bl        printf

        @ restore sp and free stack
        add       sp, sp, #STACK_ARGS         @ fix sp
        ldr       r4, [sp, #0]                @ restore r4
        ldr       r5, [sp, #4]                @      r5
        ldr       fp, [sp, #8]                @         fp
        ldr       lr, [sp, #12]               @         lr
        add       sp, sp, #16                 @ restore sp

        @ GET TIMER + IR VIRTUAL MEMORY ---------------------------------------
        @ create backup and reserve stack space
        sub       sp, sp, #16                 @ space for saving regs
        str       r4, [sp, #0]                @ save r4
        str       r5, [sp, #4]                @      r5
        str       fp, [sp, #8]                @      fp
        str       lr, [sp, #12]               @      lr
        add       fp, sp, #12                 @ set our frame pointer
        sub       sp, sp, #STACK_ARGS         @ sp on 8-byte boundary

        @ open /dev/gpiomem for read/write and syncing
        ldr       r0, =mem                    @ address of /dev/mem
        ldr       r1, openMode                @ flags for accessing device
        bl        open
        mov       r4, r0                      @ use r4 for file descriptor

        @ display file descriptor
        ldr       r0, =fdMsg                  @ format for printf
        mov       r1, r4                      @ file descriptor
        bl        printf

        @ map the GPIO registers to a virtual memory location so we can access them
        str       r4, [sp, #FILE_DESCRP_ARG]  @ /dev/mem file descriptor
        ldr       r0, timerIR                 @ address of timer + IR
        str       r0, [sp, #DEVICE_ARG]       @ location of timer +IR
        mov       r0, #NO_PREF                @ let kernel pick memory
        mov       r1, #PAGE_SIZE              @ get 1 page of memory
        mov       r2, #PROT_RDWR              @ read/write this memory
        mov       r3, #MAP_SHARED             @ share with other processes
        bl        mmap

        @ save virtual memory address
        ldr       r1, =timerir_mmap_adr       @ store timer + IR mmap (virtual address)
        str       r0, [r1]
        ldr       r1, =timerir_mmap_fd        @ store the file descriptor
        str       r4, [r1]

        ldr       r6, [r1]
        mov       r1, r0                      @ display virtual address
        ldr       r0, =memMsgTimerIR
        bl        printf
        mov       r1, r6
        ldr       r0, =memMsgTimerIR
        bl        printf

        @ restore sp and free stack
        add       sp, sp, #STACK_ARGS         @ fix sp
        ldr       r4, [sp, #0]                @ restore r4
        ldr       r5, [sp, #4]                @      r5
        ldr       fp, [sp, #8]                @         fp
        ldr       lr, [sp, #12]               @         lr
        add       sp, sp, #16                 @ restore sp

        @ initialize all other hardware
        b         hw_init

hw_init:
        ldr       r1, =gpio_mmap_adr          @ reload the addr for accessing the GPIOs
        ldr       GPIOREG, [r1]

        ldr          r1, =timerir_mmap_adr                @ reload the addr for accessing the Interrupts
        ldr                IRQREG, [r1]

        bl init_gpio

        @bl init_interrupt  @ Commented out

        bl init_outlet

        bl init_leds

        bl wait_button_start

        bl turn_on_counter

        bl mainloop

        bl turn_off

        b end_of_app


@ -----------------------------------------------------------------------------
@ Main loop
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
mainloop:
        push {r1, r2, lr}
        mov r1, #0x00080000        @ r1: Feeder bit
mainloop_loop:
        str r1, [GPIOREG, #set_pin_out]  @ Turn on feeder
        mov RETREG, #0xFF000000   @ If colour is NA, r6 is left unchanged, thus NA = 0xFF000000
mainloop_fetch_mm:
        bl get_colour
        cmp RETREG, #0xFF000000   @ If colour == NA : advance_colourwheel, continue; else: exit
        bne mainloop_fetch_mm_end
        bl advance_colourwheel
        b mainloop_fetch_mm
mainloop_fetch_mm_end:
        str r1, [GPIOREG, #clear_pin_out]  @ Turn off feeder

        mov r1, RETREG            @ r1: Colour
        bl show_led               
        bl move_snorkel_colour

        bl advance_colourwheel    @ Cause M&M to fall out

        bl increment_counter

        ldr r2, [GPIOREG, #pin_level]  @ Read the Pin Level Registry
        tst r2, #0x100     @ Bit 8 is set, --> button not pressed
        bne mainloop_loop @ if not taster.isPressed : continue

mainloop_exit:
        pop {r1, r2, pc}

@ -----------------------------------------------------------------------------
@ Sets up GPIOs for later use
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
init_gpio:
        @ GPIO CONFIGURATION
        @ Input:
        @   9 (Mittlerer Taster),
        @   20 (Colour Wheel Hall),
        @   21 (Outlet Hall),
        @   22 - 23 (Farberkennung),
        @   25 (Objektsensor)
        @ Output:
        @   2 - 7 (7-Segment),
        @   11 (Outlet nRST),
        @   12 (Outlet Step),
        @   13 (Colour Wheel Step),
        @   16 (Colour Wheel Direction),
        @   17 (Colour Wheel nRST),
        @   19 (Feeder),
        @   26 (Outlet Direction),
        @   27 (Co-Processor nSLP)
        @ GPFSEL0: Value: 00011111100 = 0x00249240
        @ GPFSEL1: Value: 01011001110 = 0x08240248
        @ GPFSEL2: Value: 00011000000 = 0x00240000

        @ Set GPFSEL0
        mov r1, #0x00240000 @ r1: New configuration
        orr r1, #0x00009200
        orr r1, #0x00000040
        str r1, [GPIOREG]

        @ Set GPFSEL1
        mov r1, #0x08000000     @ r1: New configuration
        orr r1, #0x00240000
        orr r1, #0x00000200
        orr r1, #0x00000048
        str r1, [GPIOREG, #4]

        @ Set GPFSEL2
        mov r1, #0x00240000     @ r1: New configuration
        str r1, [GPIOREG, #8]

        mov r1, #0x08000000      @ Sets Co-Processor nSLP, so it wakes up
        orr r1, #0x00020000      @ Sets colourwheel nRST
        orr r1, #0x00000800      @ Sets Outlet nRST
        str r1, [GPIOREG, #set_pin_out] @ Write to Set-GPIO register

        bx lr

@ -----------------------------------------------------------------------------
@ Pooling function for the start_button. Afther the button was pressed the mail loop will be started
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------

wait_button_start:
        ldr r2, [GPIOREG, #pin_level]  @ Read the Pin Level Registry
        tst r2, #0x100     @ Bit 8 is set, --> button not pressed
        bne wait_button_start
        bx lr

@ -----------------------------------------------------------------------------
@ Sets the button interrupt up
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
init_interrupt:
               @ Activate Falling Edge Detection for GPIO 9
        mov r1, #0x00400000
        str r1, [GPIOREG, #0x58]       @bit 10 to 1 in GPFEN0

        @ Clear Pending bit for GPIO 9
        mov r1, #0
        str r1, [GPIOREG, #0x40]       @bit 10 to 0 in GPEDS0

        @ Set Interrupt Enable bit for GPIO 9
        mov r1, #0x00008000
        str r1, [IRQREG, #0x214]       @bit 17 to 1 in IRQ enable 2

        bx lr

@ -----------------------------------------------------------------------------
@ Moves the outlet to a known position and sets SNORKEL
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
init_outlet:
        push {r1, r2, lr}
        mov r1, #1                

init_outlet_loop_until_detected:  @ while !outlet.detected_by(hall_sensor) do turn
        ldr r2, [GPIOREG, #pin_level]  @ Read outlet hall sensor state
        tst r2, #0x00200000       @ Bit 21 is set, if the outlet isn't in front of the sensor (Z = 0)
        beq init_outlet_loop_while_detected @ if detected, move to next loop
        bl move_outlet_steps    @ Hall sensor doesn't detect outlet
        b init_outlet_loop_until_detected

init_outlet_loop_while_detected:  @ while outlet.detected_by(hall_sensor) do turn 
                                  @ (ensures the outlet is on the edge of the sensors detection range)
        ldr r2, [GPIOREG, #pin_level]  @ Read outlet hall sensor state
        tst r2, #0x00200000       @ Bit 21 is set, if the outlet isn't in front of the sensor (Z = 0)
        bne init_outlet_exit      @ if not detected any more, exit
        bl move_outlet_steps      @ Hall sensor detects outlet
        b init_outlet_loop_while_detected

init_outlet_exit:
        mov SNORKEL, #20          @ Set position to 32 (edge of hall sensor detection)
        pop {r1, r2, pc}


init_leds:
        push {r0, r1, r2, r3, SNORKEL, RETREG, GPIOREG, lr}

        bl WS2812RPi_Init

        mov r0, #50
        bl WS2812RPi_SetBrightness

        mov r0, #2                @ Sets orange LED (ifm-orange)
        mov r1, #0xFF0000
        orr r1, #0x00A500
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #1                @ Sets yellow LED (dhl-yellow)
        mov r1, #0xFF0000
        orr r1, #0x00FF00
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #3                @ Sets green LED (nvidia-green)
        mov r1, #0x000000
        orr r1, #0x00FF00
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #5                @ Sets blue LED (google-blue)
        mov r1, #0x000000
        orr r1, #0x000000
        orr r1, #0x0000FF
        bl WS2812RPi_SetSingle

        mov r0, #6                @ Sets red LED (edag-red)
        mov r1, #0xFF0000
        orr r1, #0x000000
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #4                @ Sets brown LED (m&m-brown)
        mov r1, #0x8B0000
        orr r1, #0x005A00
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        bl WS2812RPi_Show
        @bl init_gpio              @ Don't trust the library  Commented out
        pop {r0, r1, r2, r3, SNORKEL, RETREG, GPIOREG, pc}


@ -----------------------------------------------------------------------------
@ Move the outlet the specified number of steps (updates SNORKEL (position))
@   param:     r1 -> The number of steps to move
@   return:    none
@ -----------------------------------------------------------------------------
move_outlet_steps:
        push {r0, r2, lr}                 @ for(int i = 0; i < STEPS; ++i)
        @mov r1, r6
        mov r0, #0                @ r0 = i; r1 = STEPS
        mov r2, #0x00001000       @ Selects bit to toggle for the step motor
move_outlet_steps_loop:
        cmp r0, r1                @ continue if i < STEPS, else break loop
        bge move_outlet_steps_exit
        str r2, [GPIOREG, #set_pin_out]  @ Rising edge
        bl step_delay
        str r2, [GPIOREG, #clear_pin_out]  @ Falling edge
        bl step_delay
        add r0, r0, #1
        b move_outlet_steps_loop
move_outlet_steps_exit:
        add SNORKEL, SNORKEL, r1  @ Update SNORKEL position
        cmp SNORKEL, #400         @ Do a wrap around at 400
        subge SNORKEL, SNORKEL, #400
        pop {r0, r2, pc}

@ -----------------------------------------------------------------------------
@ Moves the snorkel to the specified colour
@   param:     r1 -> the wanted position
@   return:    None
@ -----------------------------------------------------------------------------
move_snorkel_colour:
        push {r0, r1, r2, lr}
        cmp SNORKEL, r1
        beq move_snorkel_colour_end                                   @ The snorkel is already on the wanted position.
        bgt move_snorkel_colour_backwards                         @ The snorkel is too far. a full turn is required
        blt move_snorkel_colour_forwards                              @ The snorkel is in front of the wanted position. More steps are required

move_snorkel_colour_backwards:
        add r1, #400
        sub r1, r1, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        bl move_outlet_steps
        b move_snorkel_colour_end

move_snorkel_colour_forwards:
        sub r1, r1, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        bl move_outlet_steps
        b move_snorkel_colour_end

move_snorkel_colour_end:
        pop {r0, r1, r2, pc}

@ -----------------------------------------------------------------------------
@ Gets the colour detected by the colour sensor
@   param:     none
@   return:    The colour as defined above
@ -----------------------------------------------------------------------------
get_colour:
        ldr  r1,[GPIOREG, #pin_level]
        and r1, r1, #0x01C00000

        cmp r1, #0x00400000     @Is colour red?
        beq colour_red

        cmp r1, #0x00800000    @Is colour green?
        beq colour_green

        cmp r1, #0x00C00000    @Is colour blue?
        beq colour_blue

        cmp r1, #0x01000000    @Is colour brown?
        beq colour_brown

        cmp r1, #0x01400000    @Is colour orange?
        beq colour_orange

        cmp r1, #0x01800000    @Is colour yellow?
        beq colour_yellow

        bx lr

colour_yellow:
        mov RETREG,#yellow
        bx lr
colour_orange:
        mov RETREG,#orange
        bx lr
colour_brown:
        mov RETREG,#brown
        bx lr
colour_blue:
        mov RETREG,#blue
        bx lr
colour_green:
        mov RETREG,#green
        bx lr
colour_red:
        mov RETREG,#red
        bx lr


@ -----------------------------------------------------------------------------
@ Shows the specified LED
@   param:     r1 -> The colour as specified above
@   return:    none
@ -----------------------------------------------------------------------------
show_led:
        push {r0, r1, r2, r3, SNORKEL, RETREG, GPIOREG, lr}
        cmp r1, #orange
        beq show_led_orange
        cmp r1, #yellow
        beq show_led_yellow
        cmp r1, #green
        beq show_led_green
        cmp r1, #blue
        beq show_led_blue
        cmp r1, #red
        beq show_led_red
        cmp r1, #brown
        beq show_led_brown
        bl WS2812RPi_AllOff

show_led_exit:
        bl WS2812RPi_Show
        @bl init_gpio              @ Don't trust the library    Commented out
        pop {r0, r1, r2, r3, SNORKEL, RETREG, GPIOREG, pc}
   
show_led_orange:
        mov r0, #2
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_yellow:
        mov r0, #1
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_green:
        mov r0, #3
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_blue:
        mov r0, #5
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_red:
        mov r0, #6
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_brown:
        mov r0, #4
        bl WS2812RPi_SetOthersOff
        b show_led_exit

@ -----------------------------------------------------------------------------
@ Delays execution by the time the step motor needs between edges
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
step_delay: @ TODO implement with hardware timer
        push {r1, r2, lr}
        mov r2, #0xFF00
        orr r2, #0x00FF   @ r2: When to show counter
        mov r1, #0  @ for (int i = 0; i > 0x2D0000; --i)
step_delay_loop:
        add r1, #1
        @tst r1, r2
        @bleq show_counter @ Do every 0x10000th cycle  Commented out
        cmp r1, #0x200000
        blt step_delay_loop
        pop {r1, r2, pc}


@ step_delay:
@         @hardware timer offset: TIMERIR_OFFSET
@         push {r1, lr}
@         mov r1, [TIMERIR_OFFSET, #0x4]
@         tst r1, #FFFFFFFF
@         moveq r1, [TIMERIR_OFFSET, #0x8]
@         add r1, #0x2D0000
@ step_delay_high:
@         cmp r1, [TIMERIR_OFFSET, #0x4]
@         blt step_delay_high
@         pop {r1, pc}
@ step_delay_low:
@         cmp r1, [TIMERIR_OFFSET, #0x8]
@         blt step_delay_low
@         pop {r1, pc}

@ -----------------------------------------------------------------------------
@ Advances the colour wheel until on of its magnets are detected by the hall
@ sensor but at least 200 steps
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
advance_colourwheel:
        push {r1, r2, r3, lr}         @ for (int i = 0; i < 200 || sensor == 1; ++i)
        mov r1, #0                @ r1: i
        mov r2, #0x00002000       @ Bit to toggle for step motor

advance_colourwheel_loop:
        str r2, [GPIOREG, #set_pin_out]  @ Rising edge
        bl step_delay
        str r2, [GPIOREG, #clear_pin_out]  @ Falling edge
        bl step_delay
        add r1, #1                @ ++i
        cmp r1, #200              @ if i < 200 continue, else check if hall sensor detects
        blt advance_colourwheel_loop
        ldr r3, [GPIOREG, #pin_level]  @ Read outlet hall sensor state
        tst r3, #0x00100000       @ Bit 20 is set, if the outlet isn't in front of the sensor (Z = 0)
        bne advance_colourwheel_loop    @ Hall sensor doesn't detect outlet
        pop {r1, r2, r3, pc}

@ -----------------------------------------------------------------------------
@ Turns off stuff that needs turning off
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
turn_off:
        push {r1, lr}
        
        mov r1, #0x08000000      @ Resets Co-Processor nSLP, so it goes to sleep
        orr r1, #0x000A0000      @ Resets Feeder to activate turning the feeder and resets coulourwheel nRST
        orr r1, #0x00000800      @ Resets Outlet nRST
        str r1, [GPIOREG, #clear_pin_out] @ Write to Reset-GPIO register

        bl WS2812RPi_DeInit
        bl turn_off_counter
        
        pop {r1, pc}


@ --------------------------------------------------------------------------------------------------------------------
@
@ 7 SEGMENT DISPLAY
@
@ --------------------------------------------------------------------------------------------------------------------

        @ Segment '1' is the far left segment
        @ Parse counter and set the segments
        @ Bit values for things:
        @ 0: 0-1-1-1-0-1-1-1
        @ 1: 0-0-0-0-0-1-1-0
        @ 2: 0-1-0-1-1-0-1-1
        @ 3: 0-1-0-0-1-1-1-1
        @ 4: 0-1-1-0-0-1-1-0
        @ 5: 0-1-1-0-1-1-0-1
        @ 6: 0-1-1-1-1-1-0-1
        @ 7: 0-0-0-0-0-1-1-1
        @ 8: 0-1-1-1-1-1-1-1
        @ 9: 0-1-1-0-0-1-1-1
        @ A und B setzen

        @ nSRCLR auf HIGH setzen -> Warten auf Werte

        @ Push bits into register according to the wished number
                @ SER set to the bits value

                @ SRCLK rising edge to confirm the value and to push

        @ RCLK rising edge to confirm bits

        @ nSRCLK set to low again so it knows we are done


@ -----------------------------------------------------------------------------
@ Increments the 7 segment display and shows the number
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
increment_counter:
        push {r1, r2, r3, r4, r5, lr}
        ldr r2, =mm_counter     @ r2: &counter
        ldr r1, [r2]            @ r1: counter (BCD)
        and r3, r1, #0xF         @ r3: counter digit
        mov r4, #0              @ r4: digit position in r1

increment_counter_loop:         @ while r3 >= 9 : set r3 = 0, set r1[r4] = r3, set r3 = r1[++r4]

        mov r3, r1              @ load r3
        lsr r3, r4
        and r3, r3, #0xF

        cmp r3, #9
        blt increment_counter_loop_end @ if r3 < 9 : exit

        mov r3, #0xF            @ Set r3 to zero and store the respective digit in r1
        lsl r3, r4
        neg r3, r3 
        and r1, r1, r3

        add r4, #4              @ Next digit
        b increment_counter_loop


increment_counter_loop_end:     @ if r4 >= 5thdigit : set r1 = 0; else : r1[r4] = ++r3
        cmp r4, #16
        bge increment_counter_reset

        add r3, r3, #1          @ Increment and move digit to correct position
        lsl r3, r4

        mov r5, #0xF
        lsl r5, r4
        neg r5, r5
        and r1, r1, r5          @ First clear the digits bits, then orr the new digit onto it
        orr r1, r1, r3
        b increment_counter_end

increment_counter_reset:
        mov r1, #0
        b increment_counter_end

increment_counter_end:
        bl show_number
        str r1, [r2]
        pop {r1, r2, r3, r4, r5, pc}


@ -----------------------------------------------------------------------------
@ Displays the saved count of sorted M&Ms on the segment display
@   param:     none
@   return:    none
@ ----------------------------------------------------------------------------
show_counter:
        push {r1, r2, lr}
        ldr r2, =mm_counter
        ldr r1, [r2]
        bl show_number
        pop {r1, r2, pc}

@ -----------------------------------------------------------------------------
@ Displays the provided BCD 4-digit number on the 7-Segment display
@   param:     r1 -> The number to display
@   return:    none
@ ----------------------------------------------------------------------------
show_number:
        push {r1, r2, r3, r4, lr}
        ldr r2, =segment_pattern        @ r2: &segment_pattern[0]
        mov r4, #0                      @ r4: i
show_number_loop:                        @ for (int i = 0; i < 4; ++i)
        cmp r4, #4                      @ if i >= 4 : exit
        bge show_number_loop_end

        mov r3, r1
        and r3, #0xF                    @ r3: digit[i]
        ldr r3, [r2, r3]                @ r3: segment_pattern[digit[i]]    TODO Verify

        push {r1, r2}
        mov r1, r3                      @ Param1: Bitpattern
        mov r2, r4                      @ Param2: Which segment to output to
        bl print_digit
        pop {r1, r2}

        lsr r1, r1, #4                  @ Next digit
        add r4, #1                      @ ++i
        b show_number_loop

show_number_loop_end:
        pop {r1, r2, r3, r4, pc}


@ -----------------------------------------------------------------------------
@ Outputs the provided bitpattern on the specified segment display
@   param:     r1 -> The bitpattern to output
@   param:     r2 -> The display to output to (Value between 0 and 3)
@   return:    none
@ ----------------------------------------------------------------------------
print_digit:
        push {r1, r2, r3, r4, r5, lr}

        mov r3, #0x10           @ sets nSRCLR to high, so the SR can be filled
        str r3, [GPIOREG, #set_pin_out]

        mov r5, #0x4            @ 0x4: SER, the signal that gets stored in the next SR bit
        mov r4, #0x8            @ 0x8: SRCLK, demermines the rate at which the SR is filled by SER

        mov r3, #0              @ r3: i
print_digit_loop:               @ for (int i = 0; i < 8; ++i)
        cmp r3, #8
        bge print_digit_loop_end

        str r4, [GPIOREG, #clear_pin_out] @ Falling edge

        tst r1, #1              @ Set SER according to current bit
        streq r5, [GPIOREG, #set_pin_out]
        strne r5, [GPIOREG, #clear_pin_out]

        str r4, [GPIOREG, #set_pin_out] @ Rising edge -> Store bit

        lsr r1, #1              @ Next bit
        add r3, #1
        b print_digit_loop

print_digit_loop_end:

        @ Store byte

        lsl r2, #7              @ Set A / B to select segment display
        str r2, [GPIOREG, #set_pin_out]
        neg r2, r2              @ Reset A / B accordingly
        and r2, #0xC0
        str r2, [GPIOREG, #clear_pin_out]

        mov r1, #0x20           @ Reset and Set RCLK to force a rising edge, causes the SRs content to be stored
        str r1, [GPIOREG, #clear_pin_out]
        str r1, [GPIOREG, #set_pin_out]

        mov r1, #0x10           @ Reset nSRCLR
        str r1, [GPIOREG, #clear_pin_out]

        pop {r1, r2, r3, r4, r5, pc}

@ -----------------------------------------------------------------------------
@ Causes segment-display to not display anything
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
turn_off_counter:
        push {r1, r2, lr}

        mov r1, #0      @ r1: Bitpattern (nothing);
        mov r2, #0      @ r2: Segment address (0 - 3)
        bl print_digit
        add r2, #1
        bl print_digit
        add r2, #2
        bl print_digit
        add r2, #3
        bl print_digit

        pop {r1, r2, pc}

@ -----------------------------------------------------------------------------
@ Initializes counter and number display and displays the number (0 at first)
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
turn_on_counter:
        push {r1, r2, lr}
        ldr r2, =mm_counter     @ r2: &counter
        mov r1, #0              @ r1: counter
        str r1, [r2]
        bl show_number
        pop {r1, r2, pc}



@ --------------------------------------------------------------------------------------------------------------------
@
@ ADDRESSES: Further definitions.
@
@ --------------------------------------------------------------------------------------------------------------------
        .balign   4
@ addresses of messages
openMode:
        .word     O_FLAGS
gpio:
        .word     PERIPH+GPIO_OFFSET
timerIR:
        .word     PERIPH+TIMERIR_OFFSET

@ --------------------------------------------------------------------------------------------------------------------
@
@ END OF APPLICATION
@
@ --------------------------------------------------------------------------------------------------------------------
end_of_app:
        ldr       r1, =gpio_mmap_adr          @ reload the addr for accessing the GPIOs
        ldr       r0, [r1]                    @ memory to unmap
        mov       r1, #PAGE_SIZE              @ amount we mapped
        bl        munmap                      @ unmap it
        ldr       r1, =gpio_mmap_fd           @ reload the addr for accessing the GPIOs
        ldr       r0, [r1]                    @ memory to unmap
        bl        close                       @ close the file

        ldr       r1, =timerir_mmap_adr       @ reload the addr for accessing the Timer + IR
        ldr       r0, [r1]                    @ memory to unmap
        mov       r1, #PAGE_SIZE              @ amount we mapped
        bl        munmap                      @ unmap it
        ldr       r1, =timerir_mmap_fd        @ reload the addr for accessing the Timer + IR
        ldr       r0, [r1]                    @ memory to unmap
        bl        close                       @ close the file

        mov       r0, #0                      @ return code 0
        mov       r7, #1                      @ exit app
        svc       0
        .end

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
