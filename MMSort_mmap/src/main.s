@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@     main.s
@@@ ---------------------------------------------------------------------------
@@@     author:  ...
@@@     target:  Raspberry Pi
@@@     project: MM-Sorting-Machine
@@@     date:    YYYY/MM/DD
@@@     version: ...
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
        .equ    brown, 334
        .equ    orange, 0


SNORKEL .req      r4
TMPREG  .req      r5
RETREG  .req      r6
IRQREG	.req	  r7
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

        ldr 	  r1, =timerir_mmap_adr		  @ reload the addr for accessing the Interrupts
        ldr		  IRQREG, [r1]

        bl init_gpio

        bl init_interrupt

        bl init_outlet

        bl mainloop

        b end_of_app

        @   12 (Outlet Step) OUTPUT
        @   13 (Colour Wheel Step) OUTPUT
        @   19 (Feeder) OUTPUT
        @   20 (Colour Wheel Hall) INPUT
        @   21 (Outlet Hall) INPUT

@ PLEASE IGNORE START

turn_color_wheel:
		mov r1, #400

loop_cw:
		@13. Bit setzen und resetten -> Color Wheel Step
		mov r2, #0x02000
		@Setzen
		str r2, [GPIOREG, #0x1C]
		bl delay
		mov r2, #0x02000
		@Reset
		str r2, [GPIOREG, #0x28]
    bl delay
		sub r1, #1
		cmp r1, #0
		beq	turn_out_wheel
		b loop_cw

        @b logic_movement


delay: push {r1}
       mov r1,#0
delay_loop:
       add r1,#1
       cmp r1, #0x2D0000
       blt delay_loop
       pop {r1}
       bx lr

@ PLEASE IGNORE END

@ -----------------------------------------------------------------------------
@ Main loop
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
mainloop:
        mov r1, #1
        bl turn_feeder
mainloop_loop:
mainloop_exit:
        b end_of_app

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
        orr r1, #0x000A0000      @ Sets Feeder to activate turning the feeder and sets coulorwheel nRST
        orr r1, #0x00000800      @ Sets Outlet nRST
        str r1, [GPIOREG, #0x1C] @ Write to Set-GPIO register

        bx lr

init_interrupt:
		 @ Activate Falling Edge Detection for GPIO 9
        mov r1, #0x00400000
        str r1, [GPIOREG, #0x58]	@bit 10 to 1 in GPFEN0

        @ Clear Pending bit for GPIO 9
        mov r1, #0
        str r1, [GPIOREG, #0x40]	@bit 10 to 0 in GPEDS0

        @ Set Interrupt Enable bit for GPIO 9
        mov r1, #0x00008000
        str r1, [IRQREG, #0x214]	@bit 17 to 1 in IRQ enable 2

        bx lr

@ -----------------------------------------------------------------------------
@ Moves the outlet to its default position
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
init_outlet:
        push {r1, r2, lr}
        mov r1, #4 @ while !outlet.at(hall_sensor) do turn a bit
init_outlet_loop:
        ldr r2, [GPIOREG, #0x34]  @ Read outlet hall sensor state
 		tst r2, #0x00200000       @ Bit 21 is set, if the outlet isn't in front of the sensor (Z = 0)
 		blne move_outlet_steps    @ Hall sensor doesn't detect outlet
        bne init_outlet_loop
        mov r1, #32               @ Move to center of area in which the hall sensor detects
        bl move_outlet_steps
        mov SNORKEL, #0           @ Set position to 0
        pop {r1, r2, pc}

@ -----------------------------------------------------------------------------
@ Move the outlet the specified number of steps (updates SNORKEL (position))
@   param:     r1 -> The number of steps to move
@   return:    none
@ -----------------------------------------------------------------------------
move_outlet_steps:
        push {r0, r2, lr}                 @ for(int i = 0; i < STEPS; ++i)
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
        add SNORKEL, SNORKEL, r1
        cmp SNORKEL, #400
        subge SNORKEL, SNORKEL, #400
        pop {r0, r2, pc}

@ -----------------------------------------------------------------------------
@ Gets the difference between the current postition (SNORKEL) and the wanted Position (given from the get_color)
@   param:     r6 --> the wanted position
@   return:     r6 --> the needed amount of steps between current position and wanted position
@ -----------------------------------------------------------------------------
logic_movement:
        push {r0, r2, lr}
        mov r1, r6
        cmp SNORKEL, r1
        beq logic_end                                   @ The snorkel is already on the wanted position.
        bgt logic_backwards                         @ The snorkel is too far. a full turn is required
        blt logic_forwards                              @ The snorkel is in front of the wanted position. More steps are required

logic_backwards:
        sub r6, r1, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        add r6, #400
        bl turn_out_wheel
        b logic_end

logic_forwards:
        sub r6, r1, SNORKEL  @r1: Difference between current position and future position: Steps to take to get to next position.
        bl turn_out_wheel       
        b logic_end

logic_end:
        pop {r0, r2, pc}

@ -----------------------------------------------------------------------------
@ Gets the colour detected by the colour sensor
@   param:     none
@   return:    
@ -----------------------------------------------------------------------------
get_colour:
        @ TODO
        bx lr

@ -----------------------------------------------------------------------------
@ Delays execution by the time the step motor needs between edges
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
step_delay:
        push {r1, lr}
        mov r1, #0  @ for (int i = 0; i > 0x2D0000; --i)
step_delay_loop:
        add r1, #1
        cmp r1, 0x2D0000
        blt step_delay_loop
        pop {r1, pc}

@ -----------------------------------------------------------------------------
@ Advances the colour wheel by a quarter revolution or until on of its magnets
@ are detected by the hall sensor (but at least ... steps)
@   param:     none
@   return:    none
@ -----------------------------------------------------------------------------
advance_colourwheel:
        @ TODO
        bx

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
        pop {r1, pc}

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
