; vim: ft=avr

;.device ATmega8
.include "m8def.inc"

; general ram buffer
.equ ram_buffer_h = high(0x0300)

; global variable space 240 vars * 2 bytes
; 0x0060-0x0240
.equ z_global_vars = 0x0060

; empty stack
.equ z_stack_top = 0x03d0

; input buffer
.equ input_buffer     = 0x03d0
.equ input_buffer_end = 0x03ff

; zmachine program counter
.def z_pc_l = r24
.def z_pc_h = r25

; pointer to past arg0 on stack for current op
.def z_argp_l = r22
.def z_argp_h = r23


.cseg
.org 0x0000

  rjmp reset
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti
  reti


reset:

  ; setup stack pointer
  ldi r16, low(RAMEND)
  ldi r17, high(RAMEND)
  out SPL, r16
  out SPH, r17

  ; usart tx/rx enable
  ldi r16, (1<<RXEN | 1<<TXEN)
  out UCSRB, r16

  ; usart frame config: 8N1 (8 data bits => UCSZ2:0 = 011)
  ldi r16, (1<<URSEL) | (1<<UCSZ0) | (1<<UCSZ1)
  out UCSRC, r16

  ; usart 38400 baud at 16MHz => UBRR = 25
  ldi r16, 25
  ldi r17, 0
  out UBRRL, r16
  out UBRRH, r17

  ; output: PB0 = error LED, PB1 = user LED
  ;         PB2 = SPI /SS (SRAM /CS), PB3 = SPI MOSI, PB5 = SPI SCK
  ; input: PB4 = SPI MISO
  ; don't care: PB7
  ldi r16, (1<<PB0) | (1<<PB1) | (1<<PB2) | (1<<PB3) | (1<<PB5)
  out DDRB, r16
  ; drive SPI /SS high to disable it
  ldi r16, (1<<PB2)
  out PORTB, r16

  ; enable SPI, master mode, clock rate fck/4 (4MHz)
  ldi r16, (1<<SPE) | (1<<MSTR)
  out SPCR, r16
  ; SPI clock double (8MHz)
  ldi r16, (1<<SPI2X)
  out SPSR, r16


boot:

  ; boot prompt
  ldi ZL, low(text_boot_prompt*2)
  ldi ZH, high(text_boot_prompt*2)
  rcall usart_print_static

boot_loop:
  ; wait for key
  rcall usart_rx_byte
  mov r17, r16

  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rcall usart_tx_byte

  cpi r17, 'r' ; run
  breq main

  cpi r17, 'l' ; load
  brne boot

  rcall xmodem_load_ram
  rjmp boot


main:

  ; zero stack
  ldi XL, low(z_stack_top)
  ldi XH, high(z_stack_top)

  ; zero globals
  ldi ZL, low(z_global_vars)
  ldi ZH, high(z_global_vars)
  clr r16
  st Z+, r16
  cpi ZL, low(z_global_vars+0x240)
  brne PC-2
  cpi ZH, high(z_global_vars+0x240)
  brne PC-4

  ; load header
  clr r16
  clr r17
  ldi r18, 0x40
  rcall ram_load

  clr ZL
  ldi ZH, ram_buffer_h
  ldi r16, 0x40
  clr r17
  rcall usart_tx_bytes_hex

  ; XXX fill header?

  ; initialise PC
  lds z_pc_l, (ram_buffer_h<<8)+0x7
  lds z_pc_h, (ram_buffer_h<<8)+0x6

  ; set up to stream from PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start


decode_op:

  ;movw ZL, XL
  ;ldi r16, 0x20
  ;clr r17
  ;rcall usart_tx_bytes_hex

  ;ldi ZL, low(z_global_vars)
  ;ldi ZH, high(z_global_vars)
  ;ldi r16, 0x40
  ;ldi r17, 0x2
  ;rcall usart_tx_bytes_hex

  mov r16, z_pc_h
  rcall usart_tx_byte_hex
  mov r16, z_pc_l
  rcall usart_tx_byte_hex
  ldi r16, ' '
  rcall usart_tx_byte

  ; get opcode
  rcall ram_read_byte
  adiw z_pc_l, 1

  push r16
  rcall usart_tx_byte_hex
  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rcall usart_tx_byte
  pop r16

  ; instruction decode
  ; 0 t t xxxxx: long op (2op, 1-bit type)
  ; 10 tt  xxxx: short op (1op/0op, 2-bit type)
  ; 11 0  xxxxx: variable op (2op, type byte)
  ; 11 1  xxxxx: variable op (Vop, type byte)

  ; working towards:
  ; r20: opcode
  ; r21: type byte (4x2bits)
  ; on codepath for lookup for proper instruction type

  ; 0xxxxxxx: "long" op
  tst r16
  brpl decode_op_long

  ; 10xxxxxx: "short" op
  bst r16, 6
  brtc decode_op_short

  ; 11axxxxx: "variable" op

  ; bottom five bits are opcode
  mov r20, r16
  ldi r17, 0x1f
  and r20, r17

  ; take optype bit
  bst r16, 5

  ; type byte follows
  rcall ram_read_byte
  adiw z_pc_l, 1

  mov r21, r16

  ; bit 5 clear=2op, set=vop
  brts PC+8

  ; ready 2op lookup
  ldi ZL, low(op_2_table)
  ldi ZH, high(op_2_table)

  ; 2op, take two
  rcall decode_arg
  movw r2, r0
  rcall decode_arg
  movw r4, r0
  rjmp run_op

  ; ready vop lookup
  ldi ZL, low(op_v_table)
  ldi ZH, high(op_v_table)

  ; push type byte
  push r21

  ; vop, take up to four
  cpi r21, 0xc0
  brsh decode_op_short_done
  rcall decode_arg
  movw r2, r0
  cpi r21, 0xc0
  brsh decode_op_short_done
  rcall decode_arg
  movw r4, r0
  cpi r21, 0xc0
  brsh decode_op_short_done
  rcall decode_arg
  movw r6, r0
  cpi r21, 0xc0
  brsh decode_op_short_done
  rcall decode_arg
  movw r8, r0

decode_op_short_done:

  ; restore type byte
  pop r21

  rjmp run_op

decode_op_long:
  ; bottom five bits are opcode
  mov r20, r16
  ldi r17, 0x1f
  and r20, r17

  ; this is a 2op, so %11 for bottom two args
  ldi r17, 0xf

  ; type bit for first arg
  bst r16, 6
  brts PC+3
  ; %0 -> %01 (byte constant)
  sbr r17, 0x40
  rjmp PC+2
  ; %1 -> %10 (variable number)
  sbr r17, 0x80

  ; type bit for second arg
  bst r16, 5
  brts PC+3
  ; %0 -> %01 (byte constant)
  sbr r17, 0x10
  rjmp PC+2
  ; %1 -> %10 (variable number)
  sbr r17, 0x20

  ; move final type byte into place
  mov r21, r17

  ; save type byte
  push r21

  ; ready 2op lookup
  ldi ZL, low(op_2_table)
  ldi ZH, high(op_2_table)

  ; 2op, take two
  rcall decode_arg
  movw r2, r0
  rcall decode_arg
  movw r4, r0

  ; restore type byte
  pop r21

  rjmp run_op

decode_op_short:
  ; bottom four bits are opcode
  mov r20, r16
  ldi r17, 0x1f
  and r20, r17

  ; 1op (or 0op), type in bits 4 & 5, shift up to 6 & 7
  lsl r16
  lsl r16

  ; no-arg the remainder
  sbr r16, 0x3f
  mov r21, r16

  ; test first arg, none=0op, something=1op
  cpi r16, 0xc0
  brsh PC+4

  ; ready 0op lookup
  ldi ZL, low(op_0_table)
  ldi ZH, high(op_0_table)
  rjmp run_op

  ; ready 1op lookup
  ldi ZL, low(op_1_table)
  ldi ZH, high(op_1_table)

  ; save type byte
  push r21

  ; 1op, take one
  rcall decode_arg
  movw r2, r0

  ; restore type byte
  pop r21

  rjmp run_op


; take the next arg from PC
; inputs:
;   r21: arg type byte, %wwxxyyzz
; outputs:
;   r0:r1: decoded arg (low:high)
decode_arg:

  ; take top two bits
  clr r16
  lsl r21
  rol r16
  lsl r21
  rol r16

  ; set bottom two bits, so we always have an end state
  sbr r21, 0x3

  ; %00: word constant
  cpi r16, 0x0
  breq decode_word_constant

  ; %01: byte constant
  cpi r16, 0x1
  breq decode_byte_constant

  ; %10: variable number
  cpi r16, 0x2
  breq decode_variable_number

  ret

decode_variable_number:
  ; variable number
  rcall ram_read_byte
  adiw z_pc_l, 1

  tst r16
  brne PC+4

  ; var 0: take top of stack
  ld r1, X+
  ld r0, X+
  ret

  cpi r16, 16
  brsh PC+8

  ; var 1-15: local var

  ; double for words
  lsl r16

  ; compute arg position on stack
  movw YL, z_argp_l
  sub YL, r16
  sbci YH, 0

  ; take it
  ld r1, Y+
  ld r0, Y+
  ret

  ; var 16-255: global var

  ; bring back to 0
  subi r16, 16

  ; double for words. 9-bit offset, so put the high in r17
  clr r17
  lsl r16
  rol r17

  ; compute offset into global list
  ldi YL, low(z_global_vars)
  ldi YH, high(z_global_vars)
  add YL, r16
  adc YH, r17

  ; take it
  ld r0, Y+
  ld r1, Y+
  ret

decode_word_constant:
  ; word constant, take two bytes
  rcall ram_read_byte
  mov r1, r16
  rcall ram_read_byte
  mov r0, r16
  adiw z_pc_l, 2
  ret

decode_byte_constant:
  ; byte constant, take one byte
  rcall ram_read_byte
  mov r1, r16
  clr r0
  adiw z_pc_l, 1
  ret


run_op:

  ; r20: opcode
  ; r21: type byte
  ; Z: op table
  ; args in r2:r3, r4:r5, r6:r7, r8:r9

  add ZL, r20
  brcc PC+2
  inc ZH

  ijmp


op_0_table:
  rjmp op_unimpl ; rtrue
  rjmp op_unimpl ; rfalse
  rjmp op_unimpl ; print (literal_string)
  rjmp op_unimpl ; print_ret (literal-string)
  rjmp op_unimpl ; nop
  rjmp op_unimpl ; save ?(label) [v4 save -> (result)] [v5 illegal]
  rjmp op_unimpl ; restore ?(label) [v4 restore -> (result)] [v5 illegal]
  rjmp op_unimpl ; restart
  rjmp op_unimpl ; ret_popped
  rjmp op_unimpl ; pop [v5/6 catch -> (result)]
  rjmp op_unimpl ; quit
  rjmp op_unimpl ; new_line
  rjmp op_unimpl ; [v3] show_status [v4 illegal]
  rjmp op_unimpl ; [v3] verify ?(label)
  rjmp op_unimpl ; [v5] [extended opcode]
  rjmp op_unimpl ; [v5] piracy ?(label)

op_1_table:
  rjmp op_jz     ; jz a ?(label)
  rjmp op_unimpl ; get_sibling object -> (result) ?(label)
  rjmp op_unimpl ; get_child object -> (result) ?(label)
  rjmp op_unimpl ; get_parent object -> (result)
  rjmp op_unimpl ; get_prop_len property-address -> (result)
  rjmp op_unimpl ; inc (variable)
  rjmp op_unimpl ; dec (variable)
  rjmp op_unimpl ; print_addr byte-address-of-string
  rjmp op_unimpl ; [v4] call_1s routine -> (result)
  rjmp op_unimpl ; remove_obj object
  rjmp op_unimpl ; print_obj object
  rjmp op_unimpl ; ret value
  rjmp op_unimpl ; jump ?(label)
  rjmp op_unimpl ;  print_paddr packed-address-of-string
  rjmp op_unimpl ; load (variable) -> result
  rjmp op_unimpl ; not value -> (result) [v5 call_1n routine]

op_2_table:
  rjmp op_unimpl ; [nonexistent]
  rjmp op_je     ; je a b ?(label)
  rjmp op_unimpl ; jl a b ?(label)
  rjmp op_unimpl ; jg a b ?(label)
  rjmp op_unimpl ; dec_chk (variable) value ?(label)
  rjmp op_unimpl ; inc_chk (variable) value ?(label)
  rjmp op_unimpl ; jin obj1 obj2 ?(label)
  rjmp op_unimpl ; test bitmap flags ?(label)
  rjmp op_unimpl ; or a b -> (result)
  rjmp op_unimpl ; and a b -> (result)
  rjmp op_unimpl ; test_attr object attribute ?(label)
  rjmp op_unimpl ; set_attr object attribute
  rjmp op_unimpl ; clear_attr object attribute
  rjmp op_unimpl ; store (variable) value
  rjmp op_unimpl ; insert_obj object destination
  rjmp op_loadw  ; loadw array word-index -> (result)
  rjmp op_unimpl ; loadb array byte-index -> (result)
  rjmp op_unimpl ; get_prop object property -> (result)
  rjmp op_unimpl ; get_prop_addr object property -> (result)
  rjmp op_unimpl ; get_next_prop object property -> (result)
  rjmp op_add    ; add a b -> (result)
  rjmp op_sub    ; sub a b -> (result)
  rjmp op_unimpl ; mul a b -> (result)
  rjmp op_unimpl ; div a b -> (result)
  rjmp op_unimpl ; mod a b -> (result)
  rjmp op_unimpl ; [v4] call_2s routine arg1 -> (result)
  rjmp op_unimpl ; [v5] call_2n routine arg1
  rjmp op_unimpl ; [v5] set_colour foreground background [v6 set_colour foreground background window]
  rjmp op_unimpl ; [v5] throw value stack-frame
  rjmp op_unimpl ; [nonexistent]
  rjmp op_unimpl ; [nonexistent]
  rjmp op_unimpl ; [nonexistent]

op_v_table:
  rjmp op_call   ; call routine (0..3) -> (result) [v4 call_vs routine (0..3) -> (result)
  rjmp op_unimpl ; storew array word-index value
  rjmp op_unimpl ; storeb array byte-index value
  rjmp op_unimpl ; put_prop object property value
  rjmp op_unimpl ; sread text parse [v4 sread text parse time routing] [v5 aread text parse time routine -> (result)]
  rjmp op_unimpl ; print_char output-character-code
  rjmp op_unimpl ; print_num value
  rjmp op_unimpl ; random range -> (result)
  rjmp op_unimpl ; push value
  rjmp op_unimpl ; pull (variable) [v6 pull stack -> (result)]
  rjmp op_unimpl ; [v3] split_window lines
  rjmp op_unimpl ; [v3] set_window lines
  rjmp op_unimpl ; [v4] call_vs2 routine (0..7) -> (result)
  rjmp op_unimpl ; [v4] erase_window window
  rjmp op_unimpl ; [v4] erase_line value [v6 erase_line pixels]
  rjmp op_unimpl ; [v4] set_cursor line column [v6 set_cursor line column window]
  rjmp op_unimpl ; [v4] get_cursor array
  rjmp op_unimpl ; [v4] set_text_style style
  rjmp op_unimpl ; [v4] buffer_mode flag
  rjmp op_unimpl ; [v3] output_stream number [v5 output_stream number table] [v6 output_stream number table width]
  rjmp op_unimpl ; [v3] input_stream number
  rjmp op_unimpl ; [v5] sound_effect number effect volume routine
  rjmp op_unimpl ; [v4] read_char 1 time routine -> (result)
  rjmp op_unimpl ; [v4] scan_table x table len form -> (result)
  rjmp op_unimpl ; [v5] not value -> (result)
  rjmp op_unimpl ; [v5] call_vn routine (0..3)
  rjmp op_unimpl ; [v5] call_vn2 routine (0..7)
  rjmp op_unimpl ; [v5] tokenise text parse dictionary flag
  rjmp op_unimpl ; [v5] encode_text zscii-text length from coded-text
  rjmp op_unimpl ; [v5] copy_table first second size
  rjmp op_unimpl ; [v5] print_table zscii-text width height skip
  rjmp op_unimpl ; [v5] check_arg_count argument-number


op_unimpl:

  ; flash the lights so I know what happened
  sbi PORTB, PB0
  cbi PORTB, PB1

  ; ~500ms
  ldi  r18, 41
  ldi  r19, 150
  ldi  r20, 128
  dec  r20
  brne PC-1
  dec  r19
  brne PC-3
  dec  r18
  brne PC-5

  cbi PORTB, PB0
  sbi PORTB, PB1

  ; ~500ms
  ldi  r18, 41
  ldi  r19, 150
  ldi  r20, 128
  dec  r20
  brne PC-1
  dec  r19
  brne PC-3
  dec  r18
  brne PC-5

  rjmp op_unimpl


; jz a ?(label)
op_jz:
  clt

  tst r2
  brne PC+4
  tst r3
  brne PC+2

  set

  rjmp branch_generic


; je a b ?(label)
op_je:
  ; compare
  cp r2, r4
  cpc r3, r5

  set
  breq PC+2
  clt
  rjmp branch_generic


; loadw array word-index -> (result)
op_loadw:

  ; compute array index address
  lsr r4
  ror r5
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram at array cell
  movw r16, r2
  clr r18
  rcall ram_read_start

  ; get value
  rcall ram_read_pair
  mov r3, r16
  mov r2, r17

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  ; done, store value
  rjmp store_op_result


; add a b -> (result)
op_add:
  ; add the args
  add r2, r4
  adc r3, r5
  rjmp store_op_result


; sub a b -> (result)
op_sub:
  ; math up my dudes
  sub r2, r4
  sbc r3, r5
  rjmp store_op_result


; call routine (0..3) -> (result) [v4 call_vs routine (0..3) -> (result)
op_call:

  ; take return var and stack it, for return
  rcall ram_read_byte
  adiw z_pc_l, 1
  st -X, r16

  ; close current rem read (instruction)
  rcall ram_end

  ; save current PC
  st -X, z_pc_l
  st -X, z_pc_h

  ; save current argp
  st -X, z_argp_l
  st -X, z_argp_h

  ; set new argp to top of stack
  movw z_argp_l, XL

  ; unpack address
  lsl r2
  rol r3

  ; set up to read routine header
  movw r16, r2
  clr r18
  rcall ram_read_start

  ; read local var count
  rcall ram_read_byte

  ; double it to get number of bytes
  lsl r16

  ; calculate new PC: start of header + 2x num locals + 1
  movw z_pc_l, r2
  add z_pc_l, r16
  brcc PC+2
  inc z_pc_h
  adiw z_pc_l, 1

  ; copy initial values into stacked local vars
  mov r17, r16

  ; location of arg1 registers (r4:r5) in RAM, so we can walk like memory
  ldi YL, low(0x0004)
  ldi YH, high(0x0004)

op_call_set_arg:
  ; got them all yet?
  tst r17
  breq op_call_args_ready

  ; shift type down two (doing first, to throw away first arg which is raddr)
  lsl r21
  lsl r21
  sbr r21, 0x3

  ; do we have an arg
  mov r16, r21
  andi r16, 0xc0
  cpi r16, 0xc0
  breq op_call_default_args

  ; yes, stack it
  ld r16, Y+
  st -X, r16
  ld r16, Y+
  st -X, r16

  ; skip two default bytes
  rcall ram_read_byte
  rcall ram_read_byte
  subi r17, 2

  rjmp op_call_set_arg

op_call_default_args:
  ; fill the rest with default args
  tst r17
  breq op_call_args_ready
  rcall ram_read_byte
  st -X, r16
  dec r17
  rjmp op_call_default_args

op_call_args_ready:

  ; - PC is set
  ; - argp is set
  ; - args are filled
  ; - RAM is open at PC position

  rjmp decode_op


; common branch implementation
; call with T set if condition was true, clear if false
branch_generic:
  ; get branch arg
  rcall ram_read_byte
  adiw z_pc_l, 1

  ; bottom six bits are the low part of the offset
  mov r18, r16
  andi r18, 0x3f

  ; high part is zero
  clr r19

  ; bit 6 clear means there's an extra offset byte
  sbrc r16, 6
  rjmp branch_check_invert

  ; save first byte, it has our invert bit in it still
  push r16

  ; get next byte
  rcall ram_read_byte
  adiw z_pc_l, 1

  ; bring bottom two bits into top two bits of low offset (erk)
  lsr r16
  ror r19
  lsr r16
  ror r19
  or r18, r19

  ; remaining six bits to high byte off offset
  mov r19, r16

  ; bring back first byte
  pop r16

branch_check_invert:

  ; if bit 7 is set, branch if T true
  sbrs r16, 7
  rjmp PC+3

  ; branch if condition true
  brts PC+4
  rjmp decode_op

  ; branch if condition false
  brtc PC+2
  rjmp decode_op

  ; branch take, reset PC

  ; close ram
  rcall ram_end

  ; XXX consider "fast return" cases
  tst r19
  brne PC+9

  tst r18
  brne PC+3

  ; 0, return false
  sbi PORTB, PB0
  rjmp PC

  cpi r18, 1
  brne PC+3

  ; 1, return true
  sbi PORTB, PB0
  rjmp PC

  ; add offset to PC
  add z_pc_l, r18
  adc z_pc_h, r19
  sbiw z_pc_l, 2

  ; reset ram
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


store_op_result:

  ; take the return byte
  rcall ram_read_byte
  adiw z_pc_l, 1

  tst r16
  brne PC+4

  ; var 0: push onto stack
  st -X, r2
  st -X, r3
  rjmp decode_op

  cpi r16, 16
  brsh PC+8

  ; var 1-15: local var

  ; double for words
  lsl r16

  ; compute arg position on stack
  movw YL, z_argp_l
  sub YL, r16
  sbci YH, 0

  ; store it
  st Y+, r3
  st Y+, r2
  rjmp decode_op

  ; var 16-255: global var

  ; bring back to 0
  subi r16, 16

  ; double for words. 9-bit offset, so put the high in r17
  clr r17
  lsl r16
  rol r17

  ; compute offset into global list
  ldi YL, low(z_global_vars)
  ldi YH, high(z_global_vars)
  add YL, r16
  adc YH, r17

  ; store it
  ld r0, Y+
  ld r1, Y+
  rjmp decode_op


xmodem_load_ram:

  ; error indicator off
  cbi PORTB, PB0

  ; xmodem receiver: send NAK, wait for data to arrive
  ; XXX implement 10x10 retry

  ; CTC mode, /1024 prescaler
  ldi r16, (1<<WGM12)|(1<<CS12)|(1<<CS10)
  out TCCR1B, r16

  ; ~2-3s
  ldi r16, low(0xb718)
  ldi r17, high(0xb718)
  out OCR1AH, r17
  out OCR1AL, r16

  ; 10 tries
  ldi r17, 10

xlr_try_handshake:
  ; ready to receive
  ldi r16, 0x15 ; NAK
  rcall usart_tx_byte

  ; clear counter
  clr r16
  out TCNT1H, r16
  out TCNT1L, r16

  ; loop until timer expires, or usart becomes readable
  in r16, TIFR
  sbrc r16, OCF1A
  rjmp xlr_timer_expired
  sbic UCSRA, RXC
  rjmp xlr_ready
  rjmp PC-5

xlr_timer_expired:

  ; acknowledge timer
  ldi r16, (1<<OCF1A)
  out TIFR, r16

  ; out of tries?
  dec r17
  brne xlr_try_handshake

  ; disable timer
  clr r16
  out TCCR1B, r16

  ; error indicator on
  sbi PORTB, PB0
  ret

xlr_ready:

  ; disable timer
  clr r16
  out TCCR1B, r16

  ; ok, we're really doing this. set up to recieve

  ; initialise RAM for write
  clr r16
  clr r17
  clr r18
  rcall ram_write_start

  ; point to receive buffer
  ldi ZH, ram_buffer_h

xlr_rx_packet:

  ; look for start of packet
  rcall usart_rx_byte
  cpi r16, 0x04 ; EOT
  breq xlr_done
  cpi r16, 0x01 ; SOH
  breq PC+3

  ; error indicator on
  sbi PORTB, PB0
  ret

  ; sequence byte
  rcall usart_rx_byte
  ; XXX check it

  ; sequence complement
  rcall usart_rx_byte
  ; XXX check it

  ; start of buffer
  clr ZL

  ; prepare for checksum
  clr r17

  ; want 128 bytes
  ldi r18, 127

  ; take a byte
  rcall usart_rx_byte

  ; add to buffer
  st Z+, r16

  ; add to checksum
  add r17, r16

  ; continue for 128 bytes
  dec r18
  brpl PC-4

  ; read checksum
  rcall usart_rx_byte

  ; compare recieved checksum with computed
  cp r16, r17
  breq PC+5

  sbi PORTB, PB0

  ; checksum fail, inform transmitter
  ldi r16, 0x15 ; NAK
  rcall usart_tx_byte

  ; reinit ram and go again
  rjmp xlr_rx_packet

  ; checksum match, packet received! ack it
  ldi r16, 0x06 ; ACK
  rcall usart_tx_byte

  ; move to external ram
  clr ZL
  ldi r16, 0x80
  rcall ram_write_bytes

  ; go again
  rjmp xlr_rx_packet

xlr_done:

  ; received EOT, ack it
  ldi r16, 0x06
  rcall usart_tx_byte

  ; write done
  rjmp ram_end


; receive a byte from the usart
; outputs:
;   r16: received byte
usart_rx_byte:
  sbis UCSRA, RXC
  rjmp PC-1

  in r16, UDR

  ret


; receive a byte from the usart if there's one waiting
; outputs:
;   T: set if something was read, clear otherwise
;   r16: received byte, if there was one
usart_rx_byte_maybe:
  clt
  sbis UCSRA, RXC
  ret
  in r16, UDR
  set
  ret


; transmit a byte via the usart
; inputs:
;   r16: byte to send
usart_tx_byte:
  sbis UCSRA, UDRE
  rjmp PC-1

  out UDR, r16

  ret


; transmit a null-terminated string via the usart
; inputs:
;   Z: pointer to start of string in program memory
usart_print_static:
  lpm r16, Z+
  tst r16
  breq PC+3
  rcall usart_tx_byte
  rjmp PC-4
  ret

; transmit a null-terminated string via the usart
; inputs:
;   Z: pointer to start of string in sram
usart_print:
  ld r16, Z+
  tst r16
  breq PC+3
  rcall usart_tx_byte
  rjmp PC-4
  ret


; receive a line of input into the input buffer, with simple editing controls
usart_line_input:

  ldi XL, low(input_buffer)
  ldi XH, high(input_buffer)

uli_next_char:
  rcall usart_rx_byte

  ; printable ascii range is 0x20-0x7e
  ; XXX any computer made in 2020 needs to support unicode
  cpi r16, 0x20
  brlo uli_handle_control_char
  cpi r16, 0x7f
  brsh uli_handle_control_char

  ; something printable, make sure there's room in the buffer for it
  cpi XL, low(input_buffer_end)
  brne PC+3
  cpi XH, high(input_buffer_end)
  breq uli_next_char

  ; append to buffer and echo it
  st X+, r16
  rcall usart_tx_byte

  rjmp uli_next_char

uli_handle_control_char:

  ; enter/return
  cpi r16, 0x0d
  brne PC+2
  rjmp uli_do_enter

  ; delete/backspace
  cpi r16, 0x7f
  brne PC+2
  rjmp uli_do_backspace

  ; ignore everything else
  rjmp uli_next_char

uli_do_enter:
  ; zero end of buffer
  clr r16
  st X+, r16

  ; echo newline
  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rjmp usart_tx_byte

  ; that's all the input!

uli_do_backspace:
  ; start-of-buffer check
  cpi XL, low(input_buffer)
  brne PC+3
  cpi XH, high(input_buffer)
  breq uli_next_char

  ; move buffer pointer back
  subi XL, 1
  brcc PC+2
  dec XH

  ; echo destructive backspace
  ldi r16, 0x08
  rcall usart_tx_byte
  ldi r16, 0x20
  rcall usart_tx_byte
  ldi r16, 0x08
  rcall usart_tx_byte

  rjmp uli_next_char


; transmit a hex representation of a byte via the usart
; inputs:
;   r16: byte to send
usart_tx_byte_hex:
  ; high nybble
  push r16
  swap r16,
  andi r16, 0x0f
  ldi r17, 0x30
  add r16, r17
  cpi r16, 0x3a
  brlo PC+3
  ldi r17, 0x27
  add r16, r17
  rcall usart_tx_byte

  ; low nybble
  pop r16
  andi r16, 0x0f
  ldi r17, 0x30
  add r16, r17
  cpi r16, 0x3a
  brlo PC+3
  ldi r17, 0x27
  add r16, r17
  rjmp usart_tx_byte


; transmit a hex representation of a block of data via the usart
; inputs:
;   Z: pointer to start of data in sram
;   r16:r17: number of bytes to transmit
usart_tx_bytes_hex:
  movw r18, r16
  clr r20

usart_tx_bytes_hex_next:
  tst r18
  brne PC+3
  tst r19
  breq usart_tx_bytes_hex_done

  subi r18, 1
  brcc PC+2
  dec r19

  tst r20
  brne PC+8

  mov r16, ZH
  rcall usart_tx_byte_hex
  mov r16, ZL
  rcall usart_tx_byte_hex
  ldi r16, ' '
  rcall usart_tx_byte
  rcall usart_tx_byte

  ld r16, Z+
  rcall usart_tx_byte_hex

  inc r20
  cpi r20, 0x10
  breq PC+4

  ldi r16, ' '
  rcall usart_tx_byte
  rjmp usart_tx_bytes_hex_next

  clr r20

  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rcall usart_tx_byte

  rjmp usart_tx_bytes_hex_next

usart_tx_bytes_hex_done:
  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rcall usart_tx_byte

  ret


; read from ram into general buffer
; wraps start, read and end
; inputs:
;   r16:r17: location to read from
;   r18: length
ram_load:

  ; save length
  push r18

  ; bank 0
  clr r18
  rcall ram_read_start

  ; restore length, set up buffer and read
  pop r16
  clr ZL
  ldi ZH, ram_buffer_h
  rcall ram_read_bytes

  rjmp ram_end

; write from general buffer into ram
; wraps start, read and end
; inputs:
;   r16:r17: location to write to
;   r18: length
ram_save:

  ; save length
  push r18

  ; bank 0
  clr r18
  rcall ram_write_Start

  ; restore length, set up buffer and read
  pop r16
  clr ZL
  ldi ZH, ram_buffer_h
  rcall ram_write_bytes

  rjmp ram_end


; begin read from SRAM
; inputs
;   r16:r17:r18: 24-bit address
ram_read_start:
  ldi r19, 0x3 ; READ
  rjmp ram_start

; begin write to SRAM
; inputs
;   r16:r17:r18: 24-bit address
ram_write_start:
  ldi r19, 0x2 ; WRITE

  ; fall through

; start SRAM read/write op
;   r16:r17:r18: 24-bit address
;   r19: command (0x2 read, 0x3 write)
ram_start:

  ; pull /CS low to enable device
  cbi PORTB, PB2

  ; send command
  out SPDR, r19
  sbis SPSR, SPIF
  rjmp PC-1

  ; send address
  out SPDR, r18
  sbis SPSR, SPIF
  rjmp PC-1
  out SPDR, r17
  sbis SPSR, SPIF
  rjmp PC-1
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1

  ret

ram_end:
  ; drive /CS high to indicate end of operation
  sbi PORTB, PB2
  ret

; pull stuff from SRAM, previously set up with ram_read_start
;   r16: number of bytes to read
;   Z: where to store it
ram_read_bytes:
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1
  in r17, SPDR
  st Z+, r17
  dec r16
  brne ram_read_bytes
  ret

; read single byte from SRAM, previously set up with ram_read_start
;   r16: byte read
ram_read_byte:
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1
  in r16, SPDR
  ret

; read two bytes from SRAM, previously set up with ram_read_start
;   r16:r17: byte pair read
ram_read_pair:
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1
  in r16, SPDR
  out SPDR, r17
  sbis SPSR, SPIF
  rjmp PC-1
  in r17, SPDR
  ret

; write stuff to SRAM, previously set up with ram_write_start
;   r16: number of bytes to write
;   Z: pointer to stuff to write
ram_write_bytes:
  ld r17, Z+
  out SPDR, r17
  sbis SPSR, SPIF
  rjmp PC-1
  dec r16
  brne ram_write_bytes
  ret

; write single byte to SRAM, previously set up with ram_write_start
;   r16: byte to write
ram_write_byte:
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1
  ret

; write two bytse to SRAM, previously set up with ram_write_start
;   r16: first byte to write
;   r17: second byte to write
ram_write_pair:
  out SPDR, r16
  sbis SPSR, SPIF
  rjmp PC-1
  out SPDR, r17
  sbis SPSR, SPIF
  rjmp PC-1
  ret


text_boot_prompt:
  .db 0xa, 0xd, 0xa, 0xd, "[zap] (r)un (l)oad: ", 0
