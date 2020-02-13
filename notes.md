## Components:
- Colour-Wheel
  - Set GPIO1[367] to output
  - Set GPIO20 to input
  - Set GPIO25  to input
- Colour detection
  - Set GPIO2[2-4] to input
- Outlet
  - Set GPIO1[12] to output
  - Set GPIO21 to input
- Feeder
  - Set GPIO19 to output
  - Set to turn if colourwheel empty
- Taster
  - Set GPIO9 to input
  - Register interrupt
- 7-Segment
  - Set GPIO[2-7] to output
  - Select digit via A, B
  - Set data via shift register
- LEDs
  - Use WS2812B library

## Execution order:
- Init GPIOs
- while active:
  - while GPIO25 == Nothing
    - Set GPIO1[36] = turn
  - Set GPIO1[36] = stop
  - Detect colour
  - Position feeder
  - while GPIO25 == Something
    - Set GPIO1[35] = turn
  - Set GPIO1[35] = stop

## Pseudoassembly:

```arm
outlet_pos = 0
mm_count = 0
active = 0

init:
  bl init_gpio
  bl init_outlet

interrupt_onButton: @ Nikolai Klatt
  @ Disable interrupts
  ldr r1, active
  cmp r1, #0
  bgt turn_on
  b exit
  mov r1, #0
  str r1, active
  str r1, mm_count
  bl turn_off_counter
turn_on:
  mov r1, #1
  str r1, active
  bl turn_on_counter
exit:
  @ Enable interrupts

main:
  teq ACTIVEREG, #0 
  beq main
  bl position_colour_wheel
  mov r1, #1
  bl turn_feeder
fetch_mm:
  bl check_mm_in_wheel
  teq RETREG, #1
  beq detect_colour
  b fetch_mm
detect_colour:
  mov r1, #0
  bl turn_feeder
  bl get_colour
  mov r1, RETREG
  bl light_led
  bl move_outlet
  bl spitout_mm
  bl increment_counter
  b main
```    

## Functions:
  - init\_gpio: @ Done
    - Configures the GPIO-Pins
  - init\_outlet: @ Samuel Rundel
    - Moves the outlet to its default position
  - position\_colour\_wheel: @ Lisa Binkert
    - Moves the colour wheel to a position, in which M&Ms can fall in
  - check\_mm\_in\_wheel: @ Lisa Binkert
    - Checks if an M&M is in the colour wheel
    - Return: 1 if there is an M&M, 0 otherwise
  - get\_colour: @ Lisa Binkert
    - Reads the colour from the colour pins
    - Return: A number where the 3 LSBs map to colourBit[0-2]
  - turn\_feeder: @ Nikolai Klatt
    - Toggles the turning state of the feeder
    - In r1: If set to #0, turn feeder on, otherwise turn it off
  - light\_led: @ Nikolai Klatt
    - Turns all LEDs off, except the ones corresponding to the provided colour; Turns those LEDs into that colour
    - In r1: Colour code as returned from get\_colour; r1 shall be immutable
  - move\_outlet: @ Samuel Rundel
    - Moves the outlet to the position corresponding to the provided colour
    - In r1: Colour code as returned from get\_colour; r1 shall be immutable
  - spitout\_mm: @ Lisa Binkert
    - turns colour\_wheel until the M&M fell out
  - increment\_counter: @ Oliver Seiler
    - Increments the counter by one and displays the number on the 7-Segment display
  - turn\_off\_counter: @ Oliver Seiler
    - Turns the 7-Segment display off
  - turn\_on\_counter: @ Oliver Seiler
    - Turns the 7-Segment display on and display the current count

