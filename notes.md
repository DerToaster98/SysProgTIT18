Components:
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

Execution order:
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

Pseudoassembly:

```arm
outlet_pos = 0

init:
  mov ACTIVEREG, #0
  bl init_gpio
  bl init_outlet

interrupt_onButton:
  sei #0
  mvn ACTIVEREG, ACTIVEREG @ inverts ACTIVEREG
  sei #1

main:
  teq ACTIVEREG, #0 
  beq main
  bl position_colour_wheel
fetch_mm:
  bl check_mm_in_wheel
  teq RETREG, #1
  beq detect_colour
  bl turn_feeder
  b fetch_mm
detect_colour:
  bl get_colour
  mov r1, RETREG
  bl move_outlet
  bl spitout_mm
  b main

```    

Functions:
  - init\_gpio:
    - Configures the GPIO-Pins
  - init\_outlet:
    - Moves the outlet to its default position
  - position\_colour\_wheel:
    - Moves the colour wheel to a position, in which M&Ms can fall in
  - check\_mm\_in\_wheel:
    - Checks if an M&M is in the colour wheel
    - Return: 1 if there is an M&M, 0 otherwise
  - get\_colour:
    - Reads the colour from the colour pins
    - Return: A number where the 3 LSBs map to colourBit[0-2]
  - turn\_feeder:
    - Turns feeder "some"
  - move\_outlet:
    - Moves the outlet to the position corresponding to the provided colour
    - In r1: Colour code as defined for get\_colour
  - spitout\_mm:
    - turns colour\_wheel until the M&M fell out

