; vim: ft=avr

;.device ATmega8
.include "m8def.inc"

; global variable space 240 vars * 2 bytes, 0x0060-0x0240
; stores in z-machine order (H:L)
.equ z_global_vars = 0x0060

; story file header
.equ z_header = 0x0240

; z stack. word values are stored in local order (L:H), so H must be pushed first
; SP <-----------
;    ... LH LH LH
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

; current op and argtype
.def z_opcode = r20
.def z_argtype = r21

; start of last instruction (for debugging)
.def z_last_pc_l = r14
.def z_last_pc_h = r15

; last opcode and argtype (for debugging)
.def z_last_opcode = r13
.def z_last_argtype = r12


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

  ; wait for key
  rcall usart_rx_byte
  mov r17, r16

  rcall usart_newline

  cpi r17, 'r' ; run
  breq main

  cpi r17, 'l' ; load
  brne boot

  rcall xmodem_load_ram
  rjmp boot


main:

  ; distance from boot prompt
  rcall usart_newline

  ; zero stack
  ldi XL, low(z_stack_top)
  ldi XH, high(z_stack_top)

  ; load header
  clr r16
  clr r17
  clr r18
  rcall ram_read_start
  ldi ZL, low(z_header)
  ldi ZH, high(z_header)
  ldi r16, 0x40
  rcall ram_read_bytes
  rcall ram_end

  ;ldi ZL, low(z_header)
  ;ldi ZH, high(z_header)
  ;ldi r16, 0x40
  ;clr r17
  ;rcall usart_tx_bytes_hex

  ; XXX fill header?

  ; load globals
  lds r16, z_header+0xd
  lds r17, z_header+0xc
  clr r18
  rcall ram_read_start
  ldi ZL, low(z_global_vars)
  ldi ZH, high(z_global_vars)
  clr r16
  rcall ram_read_bytes
  ldi r16, 0xe0
  rcall ram_read_bytes
  rcall ram_end

  ; initialise PC
  lds z_pc_l, z_header+0x7
  lds z_pc_h, z_header+0x6

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

  ;mov r16, z_pc_h
  ;rcall usart_tx_byte_hex
  ;mov r16, z_pc_l
  ;rcall usart_tx_byte_hex
  ;ldi r16, ' '
  ;rcall usart_tx_byte

  ; note start of instruction for reporting
  movw z_last_pc_l, z_pc_l

  ; get opcode
  rcall ram_read_byte
  adiw z_pc_l, 1

  ; record opcode for reporting
  mov z_last_opcode, r16

  ;push r16
  ;rcall usart_tx_byte_hex
  ;rcall usart_newline
  ;pop r16

  ; instruction decode
  ; 0 t t xxxxx: long op (2op, 1-bit type)
  ; 10 tt  xxxx: short op (1op/0op, 2-bit type)
  ; 11 0  xxxxx: variable op (2op, type byte)
  ; 11 1  xxxxx: variable op (Vop, type byte)

  ; working towards:
  ; z_opcode: opcode
  ; z_argtype: type byte (4x2bits)
  ; on codepath for lookup for proper instruction type

  ; 0xxxxxxx: "long" op
  tst r16
  brpl decode_op_long

  ; 10xxxxxx: "short" op
  sbrs r16, 6
  rjmp decode_op_short

  ; 11axxxxx: "variable" op

  ; bottom five bits are opcode
  mov z_opcode, r16
  andi z_opcode, 0x1f

  ; take optype bit
  bst r16, 5

  ; type byte follows
  rcall ram_read_byte
  adiw z_pc_l, 1
  mov z_argtype, r16

  ; bit 5 clear=2op, set=vop
  brts decode_op_variable_vop

  ; ready 2op lookup
  ldi ZL, low(op_2_table)
  ldi ZH, high(op_2_table)

  ; 2op, take two
  mov r17, z_argtype
  rcall decode_arg
  movw r2, r0
  rcall decode_arg
  movw r4, r0

  rjmp run_op

decode_op_variable_vop:
  ; ready vop lookup
  ldi ZL, low(op_v_table)
  ldi ZH, high(op_v_table)

  ; vop, take up to four
  ; XXX loop and write to ramregs?
  mov r17, z_argtype

  mov r16, r17
  andi r16, 0xc0
  cpi r16, 0xc0
  breq decode_op_variable_done
  rcall decode_arg
  movw r2, r0

  mov r16, r17
  andi r16, 0xc0
  cpi r16, 0xc0
  breq decode_op_variable_done
  rcall decode_arg
  movw r4, r0

  mov r16, r17
  andi r16, 0xc0
  cpi r16, 0xc0
  breq decode_op_variable_done
  rcall decode_arg
  movw r6, r0

  mov r16, r17
  andi r16, 0xc0
  cpi r16, 0xc0
  breq decode_op_variable_done
  rcall decode_arg
  movw r8, r0

decode_op_variable_done:
  rjmp run_op

decode_op_long:
  ; bottom five bits are opcode
  mov z_opcode, r16
  andi z_opcode, 0x1f

  ; this is a 2op, so %11 for bottom two args
  ldi z_argtype, 0xf

  ; type bit for first arg
  bst r16, 6
  brts PC+3
  ; %0 -> %01 (byte constant)
  sbr z_argtype, 0x40
  rjmp PC+2
  ; %1 -> %10 (variable number)
  sbr z_argtype, 0x80

  ; type bit for second arg
  bst r16, 5
  brts PC+3
  ; %0 -> %01 (byte constant)
  sbr z_argtype, 0x10
  rjmp PC+2
  ; %1 -> %10 (variable number)
  sbr z_argtype, 0x20

  ; ready 2op lookup
  ldi ZL, low(op_2_table)
  ldi ZH, high(op_2_table)

  ; 2op, take two
  mov r17, z_argtype
  rcall decode_arg
  movw r2, r0
  rcall decode_arg
  movw r4, r0

  rjmp run_op

decode_op_short:
  ; bottom four bits are opcode
  mov z_opcode, r16
  andi z_opcode, 0xf

  ; 1op (or 0op), type in bits 4 & 5, shift up to 6 & 7
  lsl r16
  lsl r16

  ; no-arg the remainder
  sbr r16, 0x3f
  mov z_argtype, r16

  ; test first arg, none=0op, something=1op
  andi r16, 0xc0
  cpi r16, 0xc0
  brne PC+4

  ; ready 0op lookup
  ldi ZL, low(op_0_table)
  ldi ZH, high(op_0_table)
  rjmp run_op

  ; ready 1op lookup
  ldi ZL, low(op_1_table)
  ldi ZH, high(op_1_table)

  ; 1op, take one
  mov r17, z_argtype
  rcall decode_arg
  movw r2, r0

  rjmp run_op


; take the next arg from PC
; inputs:
;   r17: arg type byte, %wwxxyyzz
;        top two bytes will be considered
;        rotated out, for repeated calls
; outputs:
;   r0:r1: decoded arg (low:high)
decode_arg:

  ; take top two bits
  clr r16
  lsl r17
  rol r16
  lsl r17
  rol r16

  ; set bottom two bits, so we always have an end state
  sbr r17, 0x3

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
  push r17
  rcall load_variable
  pop r17
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
  mov r0, r16
  clr r1
  adiw z_pc_l, 1
  ret


run_op:

  ; z_opcode: opcode
  ; z_argtype: type byte
  ; Z: op table
  ; args in r2:r3, r4:r5, r6:r7, r8:r9

  ; record argtype for reporting
  mov z_last_argtype, z_argtype

  add ZL, z_opcode
  brcc PC+2
  inc ZH

  ijmp


op_0_table:
  rjmp op_rtrue      ; rtrue
  rjmp op_rfalse     ; rfalse
  rjmp op_print      ; print (literal_string)
  rjmp unimpl        ; print_ret (literal-string)
  rjmp unimpl        ; nop
  rjmp unimpl        ; save ?(label) [v4 save -> (result)] [v5 illegal]
  rjmp unimpl        ; restore ?(label) [v4 restore -> (result)] [v5 illegal]
  rjmp unimpl        ; restart
  rjmp op_ret_popped ; ret_popped
  rjmp unimpl        ; pop [v5/6 catch -> (result)]
  rjmp unimpl        ; quit
  rjmp op_new_line   ; new_line
  rjmp unimpl        ; [v3] show_status [v4 illegal]
  rjmp unimpl        ; [v3] verify ?(label)
  rjmp unimpl        ; [v5] [extended opcode]
  rjmp unimpl        ; [v5] piracy ?(label)

op_1_table:
  rjmp op_jz         ; jz a ?(label)
  rjmp unimpl        ; get_sibling object -> (result) ?(label)
  rjmp op_get_child  ; get_child object -> (result) ?(label)
  rjmp op_get_parent ; get_parent object -> (result)
  rjmp unimpl        ; get_prop_len property-address -> (result)
  rjmp unimpl        ; inc (variable)
  rjmp unimpl        ; dec (variable)
  rjmp unimpl        ; print_addr byte-address-of-string
  rjmp unimpl        ; [v4] call_1s routine -> (result)
  rjmp unimpl        ; remove_obj object
  rjmp op_print_obj  ; print_obj object
  rjmp op_ret        ; ret value
  rjmp op_jump       ; jump ?(label)
  rjmp unimpl        ;  print_paddr packed-address-of-string
  rjmp unimpl        ; load (variable) -> result
  rjmp unimpl        ; not value -> (result) [v5 call_1n routine]

op_2_table:
  rjmp unimpl       ; [nonexistent]
  rjmp op_je        ; je a b ?(label)
  rjmp unimpl       ; jl a b ?(label)
  rjmp unimpl       ; jg a b ?(label)
  rjmp unimpl       ; dec_chk (variable) value ?(label)
  rjmp op_inc_chk   ; inc_chk (variable) value ?(label)
  rjmp unimpl       ; jin obj1 obj2 ?(label)
  rjmp unimpl       ; test bitmap flags ?(label)
  rjmp unimpl       ; or a b -> (result)
  rjmp op_and       ; and a b -> (result)
  rjmp op_test_attr ; test_attr object attribute ?(label)
  rjmp op_set_attr  ; set_attr object attribute
  rjmp unimpl       ; clear_attr object attribute
  rjmp op_store     ; store (variable) value
  rjmp unimpl       ; insert_obj object destination
  rjmp op_loadw     ; loadw array word-index -> (result)
  rjmp op_loadb     ; loadb array byte-index -> (result)
  rjmp op_get_prop  ; get_prop object property -> (result)
  rjmp unimpl       ; get_prop_addr object property -> (result)
  rjmp unimpl       ; get_next_prop object property -> (result)
  rjmp op_add       ; add a b -> (result)
  rjmp op_sub       ; sub a b -> (result)
  rjmp unimpl       ; mul a b -> (result)
  rjmp unimpl       ; div a b -> (result)
  rjmp unimpl       ; mod a b -> (result)
  rjmp unimpl       ; [v4] call_2s routine arg1 -> (result)
  rjmp unimpl       ; [v5] call_2n routine arg1
  rjmp unimpl       ; [v5] set_colour foreground background [v6 set_colour foreground background window]
  rjmp unimpl       ; [v5] throw value stack-frame
  rjmp unimpl       ; [nonexistent]
  rjmp unimpl       ; [nonexistent]
  rjmp unimpl       ; [nonexistent]

op_v_table:
  rjmp op_call       ; call routine (0..3) -> (result) [v4 call_vs routine (0..3) -> (result)
  rjmp op_storew     ; storew array word-index value
  rjmp unimpl        ; storeb array byte-index value
  rjmp op_put_prop   ; put_prop object property value
  rjmp unimpl        ; sread text parse [v4 sread text parse time routing] [v5 aread text parse time routine -> (result)]
  rjmp op_print_char ; print_char output-character-code
  rjmp op_print_num  ; print_num value
  rjmp unimpl        ; random range -> (result)
  rjmp op_push       ; push value
  rjmp op_pull       ; pull (variable) [v6 pull stack -> (result)]
  rjmp unimpl        ; [v3] split_window lines
  rjmp unimpl        ; [v3] set_window lines
  rjmp unimpl        ; [v4] call_vs2 routine (0..7) -> (result)
  rjmp unimpl        ; [v4] erase_window window
  rjmp unimpl        ; [v4] erase_line value [v6 erase_line pixels]
  rjmp unimpl        ; [v4] set_cursor line column [v6 set_cursor line column window]
  rjmp unimpl        ; [v4] get_cursor array
  rjmp unimpl        ; [v4] set_text_style style
  rjmp unimpl        ; [v4] buffer_mode flag
  rjmp unimpl        ; [v3] output_stream number [v5 output_stream number table] [v6 output_stream number table width]
  rjmp unimpl        ; [v3] input_stream number
  rjmp unimpl        ; [v5] sound_effect number effect volume routine
  rjmp unimpl        ; [v4] read_char 1 time routine -> (result)
  rjmp unimpl        ; [v4] scan_table x table len form -> (result)
  rjmp unimpl        ; [v5] not value -> (result)
  rjmp unimpl        ; [v5] call_vn routine (0..3)
  rjmp unimpl        ; [v5] call_vn2 routine (0..7)
  rjmp unimpl        ; [v5] tokenise text parse dictionary flag
  rjmp unimpl        ; [v5] encode_text zscii-text length from coded-text
  rjmp unimpl        ; [v5] copy_table first second size
  rjmp unimpl        ; [v5] print_table zscii-text width height skip
  rjmp unimpl        ; [v5] check_arg_count argument-number


; rtrue
op_rtrue:

  ; ret 1
  ldi r16, 1
  mov r2, r16
  clr r3
  rjmp op_ret


; rfalse
op_rfalse:

  ; ret 0
  clr r2
  clr r3
  rjmp op_ret


; print (literal_string)
op_print:

  rcall print_zstring

  ; advance PC
  add z_pc_l, YL
  adc z_pc_h, YH

  rjmp decode_op


; ret_popped
op_ret_popped:

  ; load var 0 (stack pull)
  clr r16
  rcall load_variable

  ; move to arg1
  movw r2, r0

  ; and return
  rjmp op_ret


; new_line
op_new_line:
  rcall usart_newline
  rjmp decode_op


; jz a ?(label)
op_jz:
  clt

  tst r2
  brne PC+4
  tst r3
  brne PC+2

  set

  rjmp branch_generic


; get_child object -> (result) ?(label)
op_get_child:

  ; null object check
  tst r2
  brne PC+5
  tst r3
  brne PC+3
  clt
  rjmp branch_generic

  ; get target var and stash it
  rcall ram_read_byte
  adiw z_pc_l, 1
  push r16

  ; close ram
  rcall ram_end

  ; get the object pointer
  mov r16, r2
  rcall get_object_pointer

  ; add 6 bytes for child number
  adiw YL, 6

  ; open ram at object child number
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read child number
  rcall ram_read_byte

  rcall ram_end

  ; default not found, no branch
  clt

  ; did we find it?
  tst r16
  breq PC+6

  ; found, so stack it
  mov r0, r16
  clr r1
  pop r16 ; get var number back
  rcall store_variable

  ; take branch
  set

  ; reset ram
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp branch_generic


; get_parent object -> (result)
op_get_parent:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp store_op_result

  ; close ram
  rcall ram_end

  ; get the object pointer
  mov r16, r2
  rcall get_object_pointer

  ; add 4 bytes for parent number
  adiw YL, 4

  ; open ram at object parent number
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read parent number
  rcall ram_read_byte

  rcall ram_end

  ; move to arg0 for result
  mov r2, r16
  clr r3

  ; reset ram
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp store_op_result


; print_obj object
op_print_obj:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp decode_op

  ; close ram
  rcall ram_end

  ; get the object pointer
  mov r16, r2
  rcall get_object_pointer

  ; add 7 bytes for property pointer
  adiw YL, 7

  ; open ram at object property pointer
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read property pointer
  rcall ram_read_pair
  mov YL, r17
  mov YH, r16

  ; close ram again
  rcall ram_end

  ; move past short name length, don't need it
  adiw YL, 1

  ; open for read at object name
  movw r16, YL
  clr r18
  rcall ram_read_start

  rcall print_zstring

  rcall ram_end

  ; reset ram
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


; ret value
op_ret:

  ; close ram
  rcall ram_end

  ; move SP back to before args
  movw XL, z_argp_l

  ; restore previous argp
  ld z_argp_l, X+
  ld z_argp_h, X+

  ; restore previous PC
  ld z_pc_l, X+
  ld z_pc_h, X+

  ; reopen ram at restored PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  ; get return var
  ld r16, X+

  ; store value there
  movw r0, r2
  rcall store_variable

  rjmp decode_op


; jump ?(label)
op_jump:
  ; add offset ot PC
  add z_pc_l, r2
  adc z_pc_h, r3
  sbiw z_pc_l, 2

  ; close ram
  rcall ram_end

  ; reopen ram at new PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


; je a b ?(label)
op_je:
  ; assume no match
  clt

  ; initial compare on already-decoded args
  cp r2, r4
  cpc r3, r5
  brne PC+3
  set
  rjmp branch_generic

  ; more args?
  mov r17, z_argtype
  andi r17, 0xf
  cpi r17, 0xf
  brne PC+2

  ; nope
  rjmp branch_generic

  ; more args! set up for arg decode
  lsl r17
  lsl r17
  lsl r17
  lsl r17
  sbr r17, 0xf

  ; first arg
  rcall decode_arg

  ; compare
  cp r2, r0
  cpc r3, r1
  brne PC+3
  set
  rjmp branch_generic

  ; any more?
  mov r16, r17
  andi r16, 0xc0
  cpi r16, 0xc0
  breq PC+2
  rjmp branch_generic

  ; second arg
  rcall decode_arg

  ; compare
  cp r2, r0
  cp r3, r1
  brne PC+2
  set

  ; oof
  rjmp branch_generic


; inc_chk (variable) value ?(label)
op_inc_chk:

  mov r16, r2
  rcall load_variable

  ; increment
  inc r0
  brne PC+2
  inc r1

  ; compare backwards, for less-than test
  cp r4, r0
  cpc r5, r1

  ; set T with result
  clt
  brsh PC+2
  set

  ; store value back
  mov r16, r2
  rcall store_variable

  ; complete branch
  rjmp branch_generic


; and a b -> (result)
op_and:
  and r2, r4
  and r3, r5
  rjmp store_op_result


; test_attr object attribute ?(label)
op_test_attr:

  ; null object check
  tst r2
  brne PC+5
  tst r3
  brne PC+3
  clt
  rjmp branch_generic

  ; close ram
  rcall ram_end

  ; find the attribute
  mov r16, r2
  mov r17, r4
  rcall get_attribute_pointer

  ; save bit mask
  push r16

  ; open ram at attribute position
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read the single byte
  rcall ram_read_byte

  rcall ram_end

  ; get bit mask back
  pop r17

  ; set T if bit is set
  clt
  and r16, r17
  breq PC+2
  set

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp branch_generic


; set_attr object attribute
op_set_attr:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp decode_op

  ; close ram
  rcall ram_end

  ; find the attribute
  mov r16, r2
  mov r17, r4
  rcall get_attribute_pointer

  ; save bitmask
  push r16

  ; open ram at attribute position
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read the single byte
  rcall ram_read_byte

  rcall ram_end

  ; save previous value
  push r16

  ; set up for write to attribute position
  movw r16, YL
  clr r18
  rcall ram_write_start

  ; get value and mask back
  pop r16
  pop r17

  ; set bit
  or r16, r17

  ; write it out
  rcall ram_write_byte

  rcall ram_end

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


; store (variable) value
op_store:

  ; get variable name
  mov r16, r2

  ; store value there
  movw r0, r4
  rcall store_variable

  rjmp decode_op


; loadw array word-index -> (result)
op_loadw:

  ; compute array index address
  lsl r4
  rol r5
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


; loadb array byte-index -> (result)
op_loadb:

  ; XXX life & share with loadw

  ; compute array index address
  lsl r4
  rol r5
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram at array cell
  movw r16, r2
  clr r18
  rcall ram_read_start

  ; get value
  rcall ram_read_byte
  mov r2, r16
  clr r3

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  ; done, store value
  rjmp store_op_result


; get_prop object property -> (result)
op_get_prop:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp store_op_result

  ; close ram
  rcall ram_end

  ; find the property value
  mov r16, r2
  mov r17, r4
  rcall get_object_property_pointer

  ; not found?
  tst r16
  brne get_prop_value

  ; prep load from defaults

  ; object table location
  lds r16, z_header+0xb
  lds r17, z_header+0xa

  ; words, so double property number to make an offset
  lsl r4

  ; offset into default table
  add r16, r4
  brcc PC+2
  inc r17

  ; ready read
  clr r18
  rcall ram_read_start

  ; two-byte length
  ldi r16, 2

get_prop_value:
  ; zero response to cover all cases
  clr r2
  clr r3

  ; length two?
  cpi r16, 2
  brne PC+5

  ; read two bytes and swap
  rcall ram_read_pair
  mov r3, r16
  mov r2, r17
  rjmp PC+5

  ; length one?
  cpi r16, 1
  brlo PC+3

  ; read one as low byte
  rcall ram_read_byte
  mov r2, r16

  ; anything other length is undefined, so we will just return zero

  ; done read
  rcall ram_end

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  ; return!
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

  ; save current PC (stack order, push high first)
  st -X, z_pc_h
  st -X, z_pc_l

  ; save current argp (stack order, push high first)
  st -X, z_argp_h
  st -X, z_argp_l

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
  mov r18, r16

  ; location of arg1 registers (r4:r5) in RAM, so we can walk like memory
  ldi YL, low(0x0004)
  ldi YH, high(0x0004)

op_call_set_arg:
  ; got them all yet?
  tst r18
  breq op_call_args_ready

  ; shift type down two (doing first, to throw away first arg which is raddr)
  lsl z_argtype
  lsl z_argtype
  sbr z_argtype, 0x3

  ; do we have an arg
  mov r16, z_argtype
  andi r16, 0xc0
  cpi r16, 0xc0
  breq op_call_default_args

  ; yes, stack it (stack order, push high first)
  ld r16, Y+
  ld r17, Y+
  st -X, r17
  st -X, r16

  ; skip two default bytes
  rcall ram_read_byte
  rcall ram_read_byte
  subi r18, 2

  rjmp op_call_set_arg

op_call_default_args:
  ; fill the rest with default args
  ; reading z order (h:l), so stacking in stack order (push high first)
  tst r18
  breq op_call_args_ready
  rcall ram_read_byte
  st -X, r16
  dec r18
  rjmp op_call_default_args

op_call_args_ready:

  ; - PC is set
  ; - argp is set
  ; - args are filled
  ; - RAM is open at PC position

  rjmp decode_op


; storew array word-index value
op_storew:

  ; compute array index address
  lsl r4
  rol r5
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram for write at array cell
  movw r16, r2
  clr r18
  rcall ram_write_start

  ; write value
  mov r16, r7
  mov r17, r6
  rcall ram_write_pair

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  ; done!
  rjmp decode_op


; put_prop object property value
op_put_prop:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp decode_op

  ; close ram
  rcall ram_end

  ; find the property value
  mov r16, r2
  mov r17, r4
  rcall get_object_property_pointer

  ; done reading properties
  rcall ram_end

  tst r16
  brne PC+2

  ; not found, but the spec says it has to be here, so its quite ok to just abort
  ; XXX idk maybe just return and then we never have fatalities
  rjmp fatal

  ; put the length aside
  push r16

  ; prep for write
  movw r16, YL
  clr r18
  rcall ram_write_start

  ; get the length back
  pop r17

  ; should be two bytes
  cpi r17, 2
  brne PC+4

  mov r16, r7
  rcall ram_write_byte
  dec r17

  ; but might be one byte, so just store the low byte
  cpi r17, 1
  brne PC+4

  mov r16, r6
  rcall ram_write_byte
  dec r17

  ; all written (or not, for any other lengths, behaviour is undefined, so we do nothing)
  rcall ram_end

  ; reset ram to PC
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


; print_char output-character-code
op_print_char:

  ; XXX handle about ZSCII and high-order chars
  mov r16, r2
  rcall usart_tx_byte
  rjmp decode_op


; print_num value
op_print_num:
  ; move to more convenient registers
  movw r18, r2

  ; decades to consider
  ldi ZL, low(decades*2)
  ldi ZH, high(decades*2)

  ; accumulator, to handle zero padding
  clr r17

  ; test negative
  tst r19
  brpl format_number_loop

  ; negate
  com r19
  neg r18
  sbci r19, 0xff

  ; emit leading minus sign
  ldi r16, '-'
  rcall usart_tx_byte

format_number_loop:
  ldi r16, '0'-1

  ; get decade (10 multiplier)
  lpm r2, Z+
  lpm r3, Z+

  ; repeatedly subtract until we go negative
  inc r16
  sub r18, r2
  sbc r19, r3
  brsh PC-3

  ; add back the remainder
  add r18, r2
  adc r19, r3

  ; accumulate bottom bits of result; while its zero, we're in leading zeros
  ; and shouldn't emit anything
  add r17, r16
  andi r17, 0xf
  breq PC+2

  ; emit a digit!
  rcall usart_tx_byte

  ; move to next decade
  cpi ZL, low((decades+5)*2)
  brne format_number_loop

  ; if we didn't emit anything, then it was zero
  tst r17
  brne PC+3

  ldi r16, '0'
  rcall usart_tx_byte

  rjmp decode_op

decades:
  .dw 10000, 1000, 100, 10, 1


; push value
op_push:

  ; setup for var 0 (stack push)
  clr r16

  ; store value there
  movw r0, r2
  rcall store_variable

  rjmp decode_op


; pull (variable) [v6 pull stack -> (result)]
op_pull:

  ; load var 0 (stack pull)
  clr r16
  rcall load_variable

  ; store to the named var
  mov r16, r2
  rcall store_variable

  rjmp decode_op


; inputs:
;   r16: variable number
; outputs:
;   r0:r1: value
load_variable:
  tst r16
  brne PC+4

  ; var 0: take top of stack (stack order, pop low first)
  ld r0, X+
  ld r1, X+
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

  ; take it (stack order, pop low first)
  ld r0, Y+
  ld r1, Y+
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

  ; take it (z order, so high byte first)
  ld r1, Y+
  ld r0, Y+
  ret

; inputs:
;   r16: variable number
;   r0:r1: value
store_variable:
  tst r16
  brne PC+4

  ; var 0: push onto stack (stack order, push high first)
  st -X, r1
  st -X, r0
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

  ; store it (stack order, store low first)
  st Y+, r0
  st Y+, r1
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

  ; store it (z order, store high first)
  st Y+, r1
  st Y+, r0
  ret


; take output location from PC, and store r2:r3 in it, then jump to next op
store_op_result:

  ; take the return byte
  rcall ram_read_byte
  adiw z_pc_l, 1

  movw r0, r2
  rcall store_variable
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
  brne PC+7

  tst r18
  brne PC+2

  ; 0, return false
  rjmp op_rfalse

  cpi r18, 1
  brne PC+2

  ; 1, return true
  rjmp op_rtrue

  ; add offset to PC
  add z_pc_l, r18
  adc z_pc_h, r19
  sbiw z_pc_l, 2

  ; reset ram
  movw r16, z_pc_l
  clr r18
  rcall ram_read_start

  rjmp decode_op


unimpl:
  ldi ZL, low(text_unimplemented*2)
  ldi ZH, high(text_unimplemented*2)
  rcall usart_print_static
  rcall dump

  rjmp wd_reset

fatal:
  ldi ZL, low(text_fatal*2)
  ldi ZH, high(text_fatal*2)
  rcall usart_print_static

  ; XXX dump stack and global vars?

  rjmp wd_reset

wd_reset:
  ; enable watchdog timer to force reset in ~16ms
  cli
  ldi r16, (1<<WDE)
  out WDTCR, r16
  rjmp PC

dump:
  ldi ZL, low(text_pc*2)
  ldi ZH, high(text_pc*2)
  rcall usart_print_static
  mov r16, z_last_pc_h
  rcall usart_tx_byte_hex
  mov r16, z_last_pc_l
  rcall usart_tx_byte_hex
  rcall usart_newline

  ldi ZL, low(text_opcode*2)
  ldi ZH, high(text_opcode*2)
  rcall usart_print_static
  mov r16, z_last_opcode
  rcall usart_tx_byte_hex
  rcall usart_newline

  ldi ZL, low(text_argtype*2)
  ldi ZH, high(text_argtype*2)
  rcall usart_print_static
  mov r16, z_last_argtype
  rcall usart_tx_byte_hex
  rcall usart_newline

  ; XXX roll this up
  mov r16, z_last_argtype
  andi r16, 0xc0
  cpi r16, 0xc0
  breq dump_done
  ldi ZL, low(text_arg0*2)
  ldi ZH, high(text_arg0*2)
  rcall usart_print_static
  mov r16, r3
  rcall usart_tx_byte_hex
  mov r16, r2
  rcall usart_tx_byte_hex
  rcall usart_newline

  mov r16, z_last_argtype
  andi r16, 0x30
  cpi r16, 0x30
  breq dump_done
  ldi ZL, low(text_arg1*2)
  ldi ZH, high(text_arg1*2)
  rcall usart_print_static
  mov r16, r5
  rcall usart_tx_byte_hex
  mov r16, r4
  rcall usart_tx_byte_hex
  rcall usart_newline

  mov r16, z_last_argtype
  andi r16, 0x0c
  cpi r16, 0x0c
  breq dump_done
  ldi ZL, low(text_arg2*2)
  ldi ZH, high(text_arg2*2)
  rcall usart_print_static
  mov r16, r7
  rcall usart_tx_byte_hex
  mov r16, r6
  rcall usart_tx_byte_hex
  rcall usart_newline

  mov r16, z_argtype
  andi r16, 0x03
  cpi r16, 0x03
  breq dump_done
  ldi ZL, low(text_arg3*2)
  ldi ZH, high(text_arg3*2)
  rcall usart_print_static
  mov r16, r9
  rcall usart_tx_byte_hex
  mov r16, r8
  rcall usart_tx_byte_hex
  rcall usart_newline

dump_done:
  ret


; get pointer to start of object
; inputs:
;   r16: object number
; outputs:
;   Y: location of start of object
get_object_pointer:

  ; object table location
  lds YL, z_header+0xb
  lds YH, z_header+0xa

  ; skip 31 words of property defaults table
  adiw YL, 62

  ; objects number from 1, so subtract to number from 0
  dec r16

  ; clear high byte
  clr r17

  ; copy so we can add it back later
  movw r18, r16

  ; 9 bytes per object, so multiply to make byte offset

  ; shift right for x8
  lsl r16
  rol r17
  lsl r16
  rol r17
  lsl r16
  rol r17

  ; then add for x9
  add r16, r18
  adc r17, r19

  ; add to object table location
  add YL, r16
  adc YH, r17

  ret


; get pointer and mask to attribute byte
; inputs:
;   r16: object number
;   r17: attribute number
; outputs:
;   Y: location to attribute byte in object
;   r16: mask for bit in attribute
get_attribute_pointer:

  ; save attribute number
  push r17

  ; get the object pointer
  rcall get_object_pointer

  ; get attribute number back
  pop r17

  ; skip attribute bytes until we get to the right one
  cpi r17, 8
  brlo PC+4
  adiw YL, 1
  subi r17, 8
  rjmp PC-4

  ; start at top bit
  ldi r16, 0x80

  ; shift bits until we get to the right one
  tst r17
  breq PC+4
  lsr r16
  dec r17
  rjmp PC-4

  ret


; get pointer to object property
; inputs:
;   r16: object number
;   r17: property number
; outputs:
;   Y: location of property value
;   r16: length of property (0 if not found)
; if found, leaves ram open for read at property value
get_object_property_pointer:

  ; save property number
  push r17

  ; get the object pointer
  rcall get_object_pointer

  ; add 7 bytes for property pointer
  adiw YL, 7

  ; open ram at object property pointer
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; read property pointer
  rcall ram_read_pair
  mov YL, r17
  mov YH, r16

  ; close ram again
  rcall ram_end

  ; open for read at start of property table
  movw r16, YL
  clr r18
  rcall ram_read_start

  ; get short name length
  rcall ram_read_byte
  adiw YL, 1

  ; its a word count
  lsl r16

  ; get property number back for matching
  pop r18

prop_next:
  ; add to position
  add YL, r16
  brcc PC+2
  inc YH

  ; advance past it (could just reset ram position, but its only a few bytes)
  mov r17, r16
  tst r17
  breq PC+4
  rcall ram_read_byte
  dec r17
  rjmp PC-4

  ; now searching for the named property, in r18

  ; size byte
  rcall ram_read_byte
  adiw YL, 1

  tst r16
  brne PC+4

  ; not found, flag zero length and bail
  rcall ram_end
  clr r16
  ret

  ; this byte is two things!
  mov r17, r16

  ; top three bits are length-1
  andi r16, 0xe0
  lsr r16
  lsr r16
  lsr r16
  lsr r16
  lsr r16
  inc r16

  ; bottom five bits are property number
  andi r17, 0x1f

  ; did we find it? if not, loop to advance #r16 and retry
  cp r17, r18
  brne prop_next

  ; there we go
  ret


; print zstring at current RAM position (assumed open for reading)
; outputs:
;   Y: number of RAM bytes taken
print_zstring:

  ; clear byte count
  clr YL
  clr YH

  ; reset lock alphabet to A0
  clr r2

  ; reset current alphabet to A0
  clr r3

  ; handle decoded bytes directly, don't stack them
  clr r18

next_zchar_word:
  ; read the word
  rcall ram_read_pair
  adiw YL, 2
  movw r20, r16

  ; save the last-word marker
  bst r20, 7

  ; and shift it off
  lsl r21
  rol r20

  ; three zchars to do
  ldi r19, 3

next_zchar:
  ; shift five bits into r16
  clr r16
  lsl r21
  rol r20
  rol r16
  lsl r21
  rol r20
  rol r16
  lsl r21
  rol r20
  rol r16
  lsl r21
  rol r20
  rol r16
  lsl r21
  rol r20
  rol r16

  ; handline widechar?
  tst r18
  breq PC+5

  ; set it aside
  push r16

  ; got them all?
  dec r18
  breq print_wide_zchar

  ; nope, go again
  rjmp done_zchar

  ; decode!
  cpi r16, 7
  brsh print_zchar

  ; check for the "wide char" flag (A2:6)
  cpi r16, 6
  brne PC+6
  ; its 6, so check alphabet
  mov r17, r3
  cpi r17, 2
  brne print_zchar

  ; stack next two chars and deal with them
  ldi r18, 2
  rjmp done_zchar

  ; handle control char
  tst r16
  brne PC+4

  ; 0: space
  ldi r16, ' '
  rcall usart_tx_byte
  rjmp done_zchar

  cpi r16, 1
  brne PC+3

  ; 1: newline
  rcall usart_newline
  rjmp done_zchar

  ; 2-5: change alphabets

  ; 2 010 inc current
  ; 3 011 dec current
  ; 4 110 inc current, set lock
  ; 5 111 dec current, set lock

  ; bit 0: clear=inc, set=dec
  sbrc r16, 0
  rjmp PC+3
  inc r3
  rjmp PC+2
  dec r3

  ; clamp r3 to 0-2 (sigh)
  mov r17, r3
  sbrc r17, 7
  ldi r17, 2
  cpi r17, 3
  brne PC+2
  ldi r17, 0
  mov r3, r17

  ; bit 2: if set, also set lock
  sbrc r16, 2
  mov r2, r3

  rjmp done_zchar

print_wide_zchar:

  ; take two 5-bit items off stack
  pop r16
  pop r17

  ; r17      r16
  ; ---xxxxx ---xxxxx

  ; bring bottom bits up
  lsl r16
  lsl r16
  lsl r16

  ; r17      r16
  ; ---xxxxx xxxxx000

  ; rotate top bits down into single byte
  lsr r17
  ror r16
  lsr r17
  ror r16
  lsr r17
  ror r16

  ; r17      r16
  ; 000---xx xxxxxxxx

  ; print it and go again
  rcall usart_tx_byte

  rjmp done_zchar

print_zchar:

  ; compute alphabet offset
  mov r0, r3
  ldi r17, 26
  mul r0, r17

  ; compute pointer to start of wanted alphabet
  ldi ZL, low(zchar_alphabet*2)
  ldi ZH, high(zchar_alphabet*2)
  add ZL, r0
  brcc PC+2
  inc ZH

  ; adjust character offset
  subi r16, 6

  ; add character offset
  add ZL, r16
  brcc PC+2
  inc ZH

  ; load byte and print it
  lpm r16, Z
  rcall usart_tx_byte

  ; reset to lock alphabet
  mov r3, r2

done_zchar:
  dec r19
  breq PC+2
  rjmp next_zchar

  ; if this wasn't the last word, go get another!
  brts PC+2
  rjmp next_zchar_word

  ; if we ended mid wide-byte, then drop the single sitting on the stack
  ; shouldn't happen but we can't recover if we get this wrong
  cpi r18, 1
  brne PC+2
  pop r16

  ret

; alphabets, 26 chars each
zchar_alphabet:
  .db "abcdefghijklmnopqrstuvwxyz"
  .db "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  .db " 0123456789.,!?_#'" ; avra's string parsing is buggy as shit
    .db 0x22, "/\<-:()"


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
  ldi ZH, high(0x100)

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


; print a newline
; just a convenience, we do this a lot
usart_newline:
  ldi r16, 0xa
  rcall usart_tx_byte
  ldi r16, 0xd
  rjmp usart_tx_byte


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
text_unimplemented:
  .db 0xa, 0xd, 0xa, 0xd, "unimplemented!", 0xa, 0xd, 0
text_fatal:
  .db 0xa, 0xd, 0xa, 0xd, "fatal!", 0xa, 0xd, 0
text_pc:
  .db "     PC: ", 0
text_opcode:
  .db " opcode: ", 0
text_argtype:
  .db "argtype: ", 0
text_arg0:
  .db "  arg 0: ", 0
text_arg1:
  .db "  arg 1: ", 0
text_arg2:
  .db "  arg 2: ", 0
text_arg3:
  .db "  arg 3: ", 0
