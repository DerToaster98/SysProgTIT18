@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@     main.s
@@@ ---------------------------------------------------------------------------
@@@     author:  Lisa Binkert, Nikolai Klatt, Samuel Rundel, Oliver Seiler, Patrick Sewell
@@@     target:  Raspberry Pi
@@@     project: MM-Sorting-Machine
@@@     date:    2020/02/20
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

        .equ    yellow, 67
        .equ    green, 134
        .equ    blue, 200
        .equ    red, 268
        .equ    brown, 336
        .equ    orange, 0

              @Bits for the numbers on the seven segment display, they are already in the right order
         .equ       bits_nmbr_0, 0x77        @01110111
         .equ       bits_nmbr_1, 0x6         @00000110
         .equ       bits_nmbr_2, 0x5B       @01011011
         .equ       bits_nmbr_3, 0x4F       @01001111
         .equ       bits_nmbr_4, 0x66       @01100110
         .equ       bits_nmbr_5, 0x6D       @01101101
         .equ       bits_nmbr_6, 0x7D       @01111101
         .equ       bits_nmbr_7, 0x7       @00000111
         .equ       bits_nmbr_8, 0x7F       @01111111
         .equ       bits_nmbr_9, 0x67       @01100111

SNORKEL .req      r4
TMPREG  .req      r5
RETREG  .req      r6
IRQREG       .req         r7
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

mm_counter:
              .word         0

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
        .extern WS2812RPi_SetSingle           @ provide (uint8_t pos, uint32_t color);
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

        bl init_interrupt

        bl init_outlet

        bl init_leds

        bl wait_button_start

        bl mainloop

        bl turn_off

        b end_of_app


@ -----------------------------------------------------------------------------
@ Main loop
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
mainloop:
        push {lr}
        bl advance_colourwheel
        mov r6, #red
        bl move_snorkel_color
        mov r1, r6
        bl move_outlet_steps
        b mainloop_exit
        
        mov r1, #0x00080000        @ r1: Feeder bit
mainloop_loop:
        ldr r2, [GPIOREG, #0x34]  @ Read the Pin Level Registry
        tst r2, #0x100     @ Bit 8 is set, --> button not pressed
        beq mainloop_exit         @ if button pressed, exit

        str r1, [GPIOREG, #0x1C]  @ Turn on feeder
mainloop_fetch_mm:
        mov RETREG, #0xFF000000   @ If colour is NA, r6 is left unchanged, thus NA = 0xFF000000
        bl get_colour
        cmp RETREG, #0xFF000000
        bne mainloop_fetch_mm_end
        bl advance_colourwheel
        @bl step_delay            @ Give the colour sensor time to think
        b mainloop_fetch_mm
mainloop_fetch_mm_end:
        str r1, [GPIOREG, #0x28]  @ Turn off feeder

        mov r1, RETREG            @ r1: Colour
        bl show_led
        bl move_snorkel_color
        mov r1, RETREG            @ r1: Steps to move
        bl move_outlet_steps      @ Position outlet

        bl advance_colourwheel

        bl increment_counter

        b mainloop_loop

mainloop_exit:
        pop {pc}

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
        str r1, [GPIOREG, #0x1C] @ Write to Set-GPIO register

        bx lr

@ -----------------------------------------------------------------------------
@ Pooling function for the start_button. Afther the button was pressed the mail loop will be started
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------

wait_button_start:
        ldr r2, [GPIOREG, #0x34]  @ Read the Pin Level Registry
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
init_outlet: @ TODO Centre properly
        push {r1, r2, lr}
        mov r1, #1                

init_outlet_loop_until_detected:  @ while !outlet.detected_by(hall_sensor) do turn
        ldr r2, [GPIOREG, #0x34]  @ Read outlet hall sensor state
        tst r2, #0x00200000       @ Bit 21 is set, if the outlet isn't in front of the sensor (Z = 0)
        beq init_outlet_loop_while_detected @ if detected, move to next loop
        bl move_outlet_steps    @ Hall sensor doesn't detect outlet
        b init_outlet_loop_until_detected

init_outlet_loop_while_detected:  @ while outlet.detected_by(hall_sensor) do turn 
                                  @ (ensures the outlet is on the edge of the sensors detection range)
        ldr r2, [GPIOREG, #0x34]  @ Read outlet hall sensor state
        tst r2, #0x00200000       @ Bit 21 is set, if the outlet isn't in front of the sensor (Z = 0)
        bne init_outlet_exit      @ if not detected any more, exit
        bl move_outlet_steps      @ Hall sensor detects outlet
        b init_outlet_loop_while_detected

init_outlet_exit:
        mov SNORKEL, #20          @ Set position to 32 (edge of hall sensor detection)
        pop {r1, r2, pc}


init_leds:
        push {GPIOREG, lr}

        bl WS2812RPi_Init

        mov r0, #100
        bl WS2812RPi_SetBrightness

        mov r0, #1                @ Sets orange LED (ifm-orange)
        mov r1, #0xFF0000
        orr r1, #0x009600
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #2                @ Sets yellow LED (dhl-yellow)
        mov r1, #0xFF0000
        orr r1, #0x00CC00
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #3                @ Sets green LED (nvidia-green)
        mov r1, #0x760000
        orr r1, #0x00B900
        orr r1, #0x000000
        bl WS2812RPi_SetSingle

        mov r0, #4                @ Sets blue LED (google-blue)
        mov r1, #0x420000
        orr r1, #0x008500
        orr r1, #0x0000F4
        bl WS2812RPi_SetSingle

        mov r0, #5                @ Sets red LED (edag-red)
        mov r1, #0xD70000
        orr r1, #0x001900
        orr r1, #0x000046
        bl WS2812RPi_SetSingle

        mov r0, #6                @ Sets brown LED (m&m-brown)
        mov r1, #0x5B0000
        orr r1, #0x003500
        orr r1, #0x00002D
        bl WS2812RPi_SetSingle

        pop {GPIOREG, pc}


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
        str r2, [GPIOREG, #0x1C]  @ Rising edge
        bl step_delay
        str r2, [GPIOREG, #0x28]  @ Falling edge
        bl step_delay
        add r0, r0, #1
        b move_outlet_steps_loop
move_outlet_steps_exit:
        add SNORKEL, SNORKEL, r1  @ Update SNORKEL position
        cmp SNORKEL, #400         @ Do a wrap around at 400
        subge SNORKEL, SNORKEL, #400
        pop {r0, r2, pc}

@ -----------------------------------------------------------------------------
@ Gets the difference between the current postition (SNORKEL) and the wanted Position (given from the get_color)
@   param:     r1 --> the wanted position
@   return:    r6 --> the needed amount of steps between current position and wanted position
@ -----------------------------------------------------------------------------
move_snorkel_color:
        push {r0, r2, lr}
        mov r6, r1
        cmp SNORKEL, r6
        beq move_snorkel_color_end                                   @ The snorkel is already on the wanted position.
        bgt move_snorkel_color_backwards                         @ The snorkel is too far. a full turn is required
        blt move_snorkel_color_forwards                              @ The snorkel is in front of the wanted position. More steps are required

move_snorkel_color_backwards:
        add r6, #400
        sub r6, r6, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        @bl move_outlet_steps
        b move_snorkel_color_end

move_snorkel_color_forwards:
        sub r6, r6, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        @bl move_outlet_steps
        b move_snorkel_color_end

move_snorkel_color_end:
        pop {r0, r2, pc}

@ -----------------------------------------------------------------------------
@ Gets the colour detected by the colour sensor
@   param:     none
@   return:    
@ -----------------------------------------------------------------------------
get_colour:
        @ TODO
              ldr  r1,[GPIOREG, #0x34]
              tst  r1,#0x0400000    @Is Color red?
              bne color_red

              tst  r1,#0x0800000    @Is Color green?
              bne color_green

              tst  r1,#0x0C00000    @Is Color blue?
              bne  color_blue

              tst  r1,#0x1000000    @Is Color brown?
              bne  color_brown

              tst  r1,#0x1400000    @Is Color orange?
              bne  color_orange

              tst  r1,#0x1800000    @Is Color yellow?
              bne color_yellow

        bx lr

color_yellow:
           mov RETREG,#yellow
              bx lr
color_orange:
              mov RETREG,#orange
              bx lr
color_brown:
              mov RETREG,#brown
              bx lr
color_blue:
              mov RETREG,#blue
              bx lr
color_green:
              mov RETREG,#green
              bx lr
color_red:
              mov RETREG,#red
              bx lr


@ -----------------------------------------------------------------------------
@ Shows the specified LED
@   param:     r1 -> The colour as specified above
@   return:    none
@ -----------------------------------------------------------------------------
show_led:
        push {r0, r1, r2, r3, SNORKEL, GPIOREG, RETREG, lr}
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
        bl init_gpio              @ Don't trust the library
        pop {r0, r1, r2, r3, SNORKEL, GPIOREG, RETREG, pc}
   
show_led_orange:
        mov r0, #1
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_yellow:
        mov r0, #2
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_green:
        mov r0, #3
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_blue:
        mov r0, #4
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_red:
        mov r0, #5
        bl WS2812RPi_SetOthersOff
        b show_led_exit
   
show_led_brown:
        mov r0, #6
        bl WS2812RPi_SetOthersOff
        b show_led_exit

@ -----------------------------------------------------------------------------
@ Delays execution by the time the step motor needs between edges
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
step_delay: @ TODO implement with hardware timer
        push {r1, lr}
        mov r1, #0  @ for (int i = 0; i > 0x2D0000; --i)
step_delay_loop:
        add r1, #1
        cmp r1, #0x2D0000
        blt step_delay_loop
        pop {r1, pc}


@ step_delay: @ TODO implement with hardware timer
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
advance_colourwheel: @ TODO Centre properly
        push {r1, r2, lr}         @ for (int i = 0; i < 200 || sensor == 1; ++i)
       mov r1, #0                @ r1: i
        mov r2, #0x00002000       @ Bit to toggle for step motor

advance_colourwheel_loop:
        str r2, [GPIOREG, #0x1C]  @ Rising edge
        bl step_delay
        str r2, [GPIOREG, #0x28]  @ Falling edge
        bl step_delay
        add r1, #1                @ if i < 50 continue, else check if hall sensor detects
        cmp r1, #200
        blt advance_colourwheel_loop
        ldr r2, [GPIOREG, #0x34]  @ Read outlet hall sensor state
        tst r2, #0x00100000       @ Bit 20 is set, if the outlet isn't in front of the sensor (Z = 0)
        bne advance_colourwheel_loop    @ Hall sensor doesn't detect outlet
        pop {r1, r2, pc}

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
        str r1, [GPIOREG, #0x28] @ Write to Reset-GPIO register

        bl WS2812RPi_DeInit
        
        pop {r1, pc}

@ -----------------------------------------------------------------------------
@ Increments the 7 segment display and shows the number
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
increment_counter:
              @ DONE: Increment counter number by one
              push        {r1, r2}
              ldr        r2, =mm_counter
              ldr              r1, [r2]
              add              r1, #1
              str              r1, [r2]
              pop        {r1, r2}

              @Temporary code for displaying ###4 on the display
              push       {r1}
              mov              r1, #0x10                     @sets nSRCLR to high, its the 5th bit in the bit mask -> 10000
              str        r1, [GPIOREG, #0x1C]

              push       {r2}

              mov              r2, #0x4
              str              r2, [GPIOREG, #0x1C]

              @Rising edge on SRCLK
              mov              r1, #0x8
              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

			  mov              r1, #0xC0                    @sets A and B to low, they are bit 7 and 8 ->       11000000
              str              r1, [GPIOREG, #0x28]

              mov              r1, #0x20					@Bit 5 setzen -> RCLK
              str              r1, [GPIOREG, #0x1C]
              str              r1, [GPIOREG, #0x28]

              mov              r1, #0x10                    @sets nSRCLR to low, its the 5th bit in the bit mask -> 10000
              str       	   r1, [GPIOREG, #0x28]


              pop              {r2}
              pop              {r1}

              bx               lr

@ -----------------------------------------------------------------------------
@ Sets counter to 0
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
turn_off_counter:
              @ TODO: Reset counter to 0

@ -----------------------------------------------------------------------------
@ Initializes counter and number display and displays the current number
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
turn_on_counter:
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
