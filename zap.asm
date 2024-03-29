; GOOD COMPUTER: Z-machine interpreter
; Copyright (c) 2020 Rob Norris

; This Source Code Form is subject to the terms of the Mozilla Public
; License, v. 2.0. If a copy of the MPL was not distributed with this
; file, You can obtain one at https://mozilla.org/MPL/2.0/.

.include "m88def.inc"

; global variable space 240 vars * 2 bytes, 0x0100-0x02e0
; stores in z-machine order (H:L)
.equ z_global_vars = 0x0100

; story file header (first 0x20 bytes)
.equ z_header = 0x02e0

; temp space for separator list during input parsing
.equ separator_buffer     = 0x0300
.equ separator_buffer_end = 0x0308

; temp space for expanding current dictionary word during input parsing
.equ word_buffer     = 0x0308
.equ word_buffer_end = 0x0320

; debug tracking
.equ z_last_pc_l    = 0x320 ; start of last instruction
.equ z_last_pc_h    = 0x321 ; /
.equ z_last_opcode  = 0x322 ; last opcode
.equ z_last_argtype = 0x323 ; last argtype

; storage for original zstring processing state while processing an abbreviation string
.equ zstring_state_adv_l         = 0x0323
.equ zstring_state_adv_h         = 0x0324
.equ zstring_state_ram_pos_l     = 0x0325
.equ zstring_state_ram_pos_m     = 0x0326
.equ zstring_state_ram_pos_h     = 0x0327
.equ zstring_state_word_pos      = 0x0328
.equ zstring_state_word_l        = 0x0329
.equ zstring_state_word_h        = 0x032a
.equ zstring_state_lock_alphabet = 0x032b
.equ zstring_state_flags         = 0x032c


; z stack. word values are stored in local order (L:H), so H must be pushed first
; SP <-----------
;    ... LH LH LH
.equ z_stack_top = 0x047e

.equ rand_l = 0x047e
.equ rand_h = 0x047f

; input buffer
; enough room for 0x44 requested by zork
.equ input_buffer     = 0x0480
.equ input_buffer_end = 0x04d0

; zmachine program counter
.def z_pc_l = r24
.def z_pc_h = r25

; pointer to past arg0 on stack for current op
.def z_argp_l = r22
.def z_argp_h = r23

; current op and argtype
.def z_opcode = r20
.def z_argtype = r21

; ram start position, updated by ram_ subs to shadow the internal sram address counter
.def ram_pos_l = r12
.def ram_pos_m = r13
.def ram_pos_h = r14


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

  ; clear reset state and disable watchdog
  cli
  wdr
  in r16, MCUSR
  cbr r16, (1<<WDRF)
  out MCUSR, r16
  lds r16, WDTCSR
  lds r16, WDTCSR
  sbr r16, (1<<WDCE) | (1<<WDE)
  sts WDTCSR, r16
  cbr r16, (1<<WDE)
  sts WDTCSR, r16
  sei

  ; setup stack pointer
  ldi r16, low(RAMEND)
  ldi r17, high(RAMEND)
  out SPL, r16
  out SPH, r17

  ; usart tx/rx enable
  ldi r16, (1<<RXEN0) | (1<<TXEN0)
  sts UCSR0B, r16

  ; usart frame format: 8N1 (8 data bits => UCSZ2:0 = 011, no parity => UPM1:0 = 00, 1 stop bit => USBS = 0)
  ldi r16, (1<<UCSZ00) | (1<<UCSZ01)
  sts UCSR0C, r16

  ; usart 38400 baud at 16MHz => UBRR = 25
  ldi r16, 25
  ldi r17, 0
  sts UBRR0L, r16
  sts UBRR0H, r17

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
boot_key:
  rcall usart_rx_byte
  mov r17, r16

  cpi r17, 0xd
  breq boot

  cpi r17, 'r' ; run
  breq main

  cpi r17, 'l' ; load
  brne boot_key

  rcall xmodem_load_ram
  rjmp wd_reset


main:

  ; distance from boot prompt
  rcall usart_newline
  rcall usart_newline

  ; reset rng
  clr r16
  sts rand_h, r16
  inc r16
  sts rand_l, r16

  ; zero stack
  ldi XL, low(z_stack_top)
  ldi XH, high(z_stack_top)

  ; zero argp as well, sorta meaningless in main but its where we expect it
  movw z_argp_l, XL

  ; load header
  clr ram_pos_l
  clr ram_pos_m
  clr ram_pos_h
  rcall ram_read_start
  ldi YL, low(z_header)
  ldi YH, high(z_header)
  ldi r16, 0x20
  rcall ram_read_bytes
  rcall ram_end

  ;ldi ZL, low(z_header)
  ;ldi ZH, high(z_header)
  ;ldi r16, 0x10
  ;clr r17
  ;rcall usart_tx_bytes_hex

  ; XXX fill header?

  ; version check
  lds r16, z_header
  tst r16
  breq PC+3
  cpi r16, 4 ; no support for v4+
  brlo PC+10

  ldi ZL, low(text_unsupported_version*2)
  ldi ZH, high(text_unsupported_version*2)
  rcall usart_print_static

  lds r16, z_header
  ori r16, 0x30
  rcall usart_tx_byte
  rcall usart_newline

  rjmp wd_reset

  ; load globals
  lds ram_pos_l, z_header+0xd
  lds ram_pos_m, z_header+0xc
  clr ram_pos_h
  rcall ram_read_start
  ldi YL, low(z_global_vars)
  ldi YH, high(z_global_vars)
  clr r16
  rcall ram_read_bytes
  ldi r16, 0xe0
  rcall ram_read_bytes
  rcall ram_end

  ; initialise PC
  lds z_pc_l, z_header+0x7
  lds z_pc_h, z_header+0x6

  ; clear string processing state
  clr r16
  sts zstring_state_flags, r16

  ; set up to stream from PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
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
  sts z_last_pc_l, z_pc_l
  sts z_last_pc_h, z_pc_h

  ; get opcode
  rcall ram_read_byte
  adiw z_pc_l, 1

  ; record opcode for reporting
  sts z_last_opcode, r16

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
  brts PC+4

  ; ready 2op lookup
  ldi ZL, low(op_2_table)
  ldi ZH, high(op_2_table)

  rjmp PC+3

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
  sts z_last_argtype, z_argtype

  add ZL, z_opcode
  brcc PC+2
  inc ZH

  ijmp


op_0_table:
  rjmp op_rtrue      ; rtrue
  rjmp op_rfalse     ; rfalse
  rjmp op_print      ; print (literal_string)
  rjmp op_print_ret  ; print_ret (literal-string)
  rjmp decode_op     ; nop
  rjmp unimpl        ; save ?(label) [v4 save -> (result)] [v5 illegal]
  rjmp unimpl        ; restore ?(label) [v4 restore -> (result)] [v5 illegal]
  rjmp unimpl        ; restart
  rjmp op_ret_popped ; ret_popped
  rjmp op_pop        ; pop [v5/6 catch -> (result)]
  rjmp wd_reset      ; quit
  rjmp op_new_line   ; new_line
  rjmp unimpl        ; [v3] show_status [v4 illegal]
  rjmp unimpl        ; [v3] verify ?(label)
  rjmp unimpl        ; [v5] [extended opcode]
  rjmp unimpl        ; [v5] piracy ?(label)

op_1_table:
  rjmp op_jz           ; jz a ?(label)
  rjmp op_get_sibling  ; get_sibling object -> (result) ?(label)
  rjmp op_get_child    ; get_child object -> (result) ?(label)
  rjmp op_get_parent   ; get_parent object -> (result)
  rjmp op_get_prop_len ; get_prop_len property-address -> (result)
  rjmp op_inc          ; inc (variable)
  rjmp op_dec          ; dec (variable)
  rjmp op_print_addr   ; print_addr byte-address-of-string
  rjmp unimpl          ; [v4] call_1s routine -> (result)
  rjmp op_remove_obj   ; remove_obj object
  rjmp op_print_obj    ; print_obj object
  rjmp op_ret          ; ret value
  rjmp op_jump         ; jump ?(label)
  rjmp op_print_paddr  ; print_paddr packed-address-of-string
  rjmp op_load         ; load (variable) -> (result)
  rjmp op_not          ; not value -> (result) [v5 call_1n routine]

op_2_table:
  rjmp unimpl           ; [nonexistent]
  rjmp op_je            ; je a b ?(label)
  rjmp op_jl            ; jl a b ?(label)
  rjmp op_jg            ; jg a b ?(label)
  rjmp op_dec_chk       ; dec_chk (variable) value ?(label)
  rjmp op_inc_chk       ; inc_chk (variable) value ?(label)
  rjmp op_jin           ; jin obj1 obj2 ?(label)
  rjmp op_test          ; test bitmap flags ?(label)
  rjmp op_or            ; or a b -> (result)
  rjmp op_and           ; and a b -> (result)
  rjmp op_test_attr     ; test_attr object attribute ?(label)
  rjmp op_set_attr      ; set_attr object attribute
  rjmp op_clear_attr    ; clear_attr object attribute
  rjmp op_store         ; store (variable) value
  rjmp op_insert_obj    ; insert_obj object destination
  rjmp op_loadw         ; loadw array word-index -> (result)
  rjmp op_loadb         ; loadb array byte-index -> (result)
  rjmp op_get_prop      ; get_prop object property -> (result)
  rjmp op_get_prop_addr ; get_prop_addr object property -> (result)
  rjmp op_get_next_prop ; get_next_prop object property -> (result)
  rjmp op_add           ; add a b -> (result)
  rjmp op_sub           ; sub a b -> (result)
  rjmp op_mul           ; mul a b -> (result)
  rjmp op_div           ; div a b -> (result)
  rjmp op_mod           ; mod a b -> (result)
  rjmp unimpl           ; [v4] call_2s routine arg1 -> (result)
  rjmp unimpl           ; [v5] call_2n routine arg1
  rjmp unimpl           ; [v5] set_colour foreground background [v6 set_colour foreground background window]
  rjmp unimpl           ; [v5] throw value stack-frame
  rjmp unimpl           ; [nonexistent]
  rjmp unimpl           ; [nonexistent]
  rjmp unimpl           ; [nonexistent]

op_v_table:
  rjmp op_call       ; call routine (0..3) -> (result) [v4 call_vs routine (0..3) -> (result)
  rjmp op_storew     ; storew array word-index value
  rjmp op_storeb     ; storeb array byte-index value
  rjmp op_put_prop   ; put_prop object property value
  rjmp op_sread      ; sread text parse [v4 sread text parse time routing] [v5 aread text parse time routine -> (result)]
  rjmp op_print_char ; print_char output-character-code
  rjmp op_print_num  ; print_num value
  rjmp op_random     ; random range -> (result)
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


; READING AND WRITING MEMORY

; load (variable) -> (result)
op_load:

  ; load value
  mov r16, r2
  rcall load_variable

  ; copy result to arg0 and store it
  movw r2, r0
  rjmp store_op_result


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

  ; index is a word offset
  lsl r4
  rol r5

  ; compute array index address
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram at array cell
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_read_start

  ; get value
  rcall ram_read_pair
  mov r3, r16
  mov r2, r17

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; done, store value
  rjmp store_op_result


; storew array word-index value
op_storew:

  ; index is a word offset
  lsl r4
  rol r5

  ; compute array index address
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram for write at array cell
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_write_start

  ; write value
  mov r16, r7
  mov r17, r6
  rcall ram_write_pair

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; done!
  rjmp decode_op


; loadb array byte-index -> (result)
op_loadb:

  ; XXX life & share with loadw

  ; compute array index address
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram at array cell
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_read_start

  ; get value
  rcall ram_read_byte
  mov r2, r16
  clr r3

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; done, store value
  rjmp store_op_result


; storeb array byte-index value
op_storeb:

  ; compute array index address
  add r2, r4
  adc r3, r5

  ; close ram
  rcall ram_end

  ; open ram for write at array cell
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_write_start

  ; write value
  mov r16, r6
  rcall ram_write_byte

  ; close ram again
  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; done!
  rjmp decode_op


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


; pop [v5/6 catch -> (result)]
op_pop:

  ; take top item on stack and drop it
  adiw XL, 2

  rjmp decode_op


; ARITHMETIC

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


; mul a b -> (result)
op_mul:

  ; just the bottom part of a 16x16 multiply chain, because we don't care about
  ; the top 16 result bits
  mul r2, r4
  movw r6, r0
  mul r3, r4
  add r7, r0
  mul r2, r5
  add r7, r0

  movw r2, r6
  rjmp store_op_result


; div a b -> (result)
op_div:

  ; check divide-by-zero
  tst r4
  brne PC+4
  tst r5
  brne PC+2

  ; I mean, what else can you do?
  rjmp fatal

  movw r16, r2
  movw r18, r4
  rcall divide

  ; move result to arg0 for store
  movw r2, r16

  rjmp store_op_result


; mod a b -> (result)
op_mod:

  ; check divide-by-zero
  tst r4
  brne PC+4
  tst r5
  brne PC+2

  ; I mean, what else can you do?
  rjmp fatal

  movw r16, r2
  movw r18, r4
  rcall divide

  ; remainder already in r2:r3
  rjmp store_op_result


; inc (variable)
op_inc:
  rcall inc_variable
  rjmp decode_op


; dec (variable)
op_dec:
  rcall dec_variable
  rjmp decode_op


; inc_chk (variable) value ?(label)
op_inc_chk:

  rcall inc_variable

  ; compare backwards, for less-than test
  clt
  cp r4, r0
  cpc r5, r1
  brpl PC+2
  set

  ; complete branch
  rjmp branch_generic


; dec_chk (variable) value ?(label)
op_dec_chk:

  rcall dec_variable

  ; compare
  set
  cp r0, r4
  cpc r1, r5
  brmi PC+2
  clt

  ; complete branch
  rjmp branch_generic


; and a b -> (result)
op_and:
  and r2, r4
  and r3, r5
  rjmp store_op_result


; or a b -> (result)
op_or:
  or r2, r4
  or r3, r5
  rjmp store_op_result


; not value -> (result) [v5 call_1n routine]
op_not:

  ; flip those bits
  com r2
  com r3
  rjmp store_op_result


; COMPARISONS AND JUMPS

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
  ; assume no match
  clt

  ; second arg
  cp r2, r4
  cpc r3, r5
  brne PC+3
  set
  rjmp branch_generic

  ; third arg?
  mov r16, z_argtype
  andi r16, 0xc
  cpi r16, 0xc
  brne PC+2
  rjmp branch_generic

  ; compare with third
  cp r2, r6
  cpc r3, r7
  brne PC+3
  set
  rjmp branch_generic

  ; fourth arg?
  mov r16, z_argtype
  andi r16, 0x3
  cpi r16, 0x3
  brne PC+2
  rjmp branch_generic

  ; compare with fourth
  cp r2, r8
  cpc r3, r9
  brne PC+2
  set

  ; oof
  rjmp branch_generic


; jl a b ?(label)
op_jl:

  ; compare
  set
  cp r2, r4
  cpc r3, r5
  brmi PC+2
  clt

  rjmp branch_generic


; jg a b ?(label)
op_jg:

  ; reverse compare so we can avoid an extra equality check
  clt
  cp r4, r2
  cpc r5, r3
  brpl PC+2
  set

  rjmp branch_generic


; jin obj1 obj2 ?(label)
op_jin:
  ; get_parent obj1 ST
  ; je ST obj2

  ; null object check
  tst r2
  brne PC+5
  tst r3
  brne PC+3
  clt
  rjmp branch_generic

  ; close ram
  rcall ram_end

  ; get the object pointer
  mov r16, r2
  rcall get_object_pointer

  ; add 4 bytes for parent number
  adiw YL, 4

  ; open ram at object parent number
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; read parent number
  rcall ram_read_byte

  rcall ram_end

  ; compare
  clt
  cp r16, r4
  brne PC+2
  set

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp branch_generic


; test bitmap flags ?(label)
op_test:

  and r2, r4
  and r3, r5

  clt
  cp r2, r4
  cpc r3, r5
  brne PC+2
  set

  rjmp branch_generic


; jump ?(label)
op_jump:
  ; add offset ot PC
  add z_pc_l, r2
  adc z_pc_h, r3
  sbiw z_pc_l, 2

  ; close ram
  rcall ram_end

  ; reopen ram at new PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; CALL AND RETURN

; call routine (0..3) -> (result) [v4 call_vs routine (0..3) -> (result)
op_call:

  ; zero routine address?
  tst r2
  brne PC+6
  tst r3
  brne PC+4

  ; special case for zero, just push false and return
  clr r2
  clr r3
  rjmp store_op_result

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
  movw ram_pos_l, r2
  clr ram_pos_h
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
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; PC now at return var for previous instruction, and we can return
  rjmp store_op_result


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


; ret_popped
op_ret_popped:

  ; load var 0 (stack pull)
  clr r16
  rcall load_variable

  ; move to arg1
  movw r2, r0

  ; and return
  rjmp op_ret


; OBJECTS, ATTRIBUTES AND PROPERTIES

; get_sibling object -> (result) ?(label)
op_get_sibling:
  ; 5 byte offset for sibling
  ldi r17, 5
  rjmp get_child_or_sibling

; get_child object -> (result) ?(label)
op_get_child:
  ; 6 byte offset for child
  ldi r17, 6
  ; fall through

get_child_or_sibling:

  ; get target var
  rcall ram_read_byte
  adiw z_pc_l, 1

  ; null object check
  tst r2
  brne PC+5
  tst r3
  brne PC+3
  clt
  rjmp branch_generic

  ; close ram
  rcall ram_end

  ; push target var number
  push r16

  ; save pointer offset
  push r17

  ; get the object pointer
  mov r16, r2
  rcall get_object_pointer

  ; add offset to child/sibling pointer
  pop r17
  add YL, r17
  brcc PC+2
  inc YH

  ; open ram at wanted object number
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; read wanted object number
  rcall ram_read_byte

  rcall ram_end

  ; get var number back
  pop r17

  ; store result
  mov r0, r16
  clr r1
  mov r16, r17
  rcall store_variable

  ; take branch if we found it
  clt
  tst r0
  breq PC+2
  set

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
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
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; read parent number
  rcall ram_read_byte

  rcall ram_end

  ; move to arg0 for result
  mov r2, r16
  clr r3

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp store_op_result


; insert_obj object destination
op_insert_obj:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp decode_op

  ; null destination check
  tst r4
  brne PC+4
  tst r5
  brne PC+2
  rjmp decode_op

  rcall ram_end

  rcall detach_object

  ; O->parent = D;
  ; O->sibling = D->child;
  ; D->child = O;

  ; get the destinations child object, so we can hook it up as our sibling
  mov r16, r4
  rcall get_object_pointer
  adiw YL, 6 ; move to child

  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; get child
  rcall ram_read_byte
  mov r6, r16

  rcall ram_end

  ; and replacing destination child with moving object
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  mov r16, r2
  rcall ram_write_byte

  rcall ram_end

  ; now set up to write to the moving object
  mov r16, r2
  rcall get_object_pointer
  adiw YL, 4 ; move to parent

  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  ; write new parent and sibling (dest, and dest's child)
  mov r16, r4
  mov r17, r6
  rcall ram_write_pair

  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; remove_obj object
op_remove_obj:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp decode_op

  rcall ram_end

  rcall detach_object

  ; zero parent/sibling on the target object

  mov r16, r2
  rcall get_object_pointer
  adiw YL, 4 ; move to parent

  ; prep for write
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  ; zero parent and sibling
  clr r16
  clr r17
  rcall ram_write_pair

  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; detach object in r2 from its parent
detach_object:

  ; if (O->parent->child == O) {
  ;   O->parent->child = O->sibling;
  ; }
  ; else {
  ;   for (OS = O->parent->child; OS; OS = OS->sibling) {
  ;     if (OS->sibling = O) {
  ;       OS->sibling = O->sibling;
  ;       break;
  ;     }
  ;   }
  ; }

  ; first we need to detach the object from its parent's list of children

  ; load our object to get its parent pointer
  mov r16, r2
  rcall get_object_pointer
  adiw YL, 4 ; move to parent

  ; prep for read
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; load parent and sibling object number
  rcall ram_read_pair
  movw r6, r16

  rcall ram_end

  ; now load first child of parent
  mov r16, r6
  rcall get_object_pointer
  adiw YL, 6 ; move to child

  ; prep for read
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; load first child object number
  rcall ram_read_byte

  rcall ram_end

  ; if moving object is the first child of its parent, then detaching it is
  ; easy: just point the parent to our sibling
  cp r2, r16
  brne unlink_object

  ; prep for write
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  ; write new child to our sibling
  mov r16, r7
  rcall ram_write_byte

  rcall ram_end

  ret

unlink_object:

  ; moving object is somewhere in its parent's child list, so need to walk the
  ; list, find it and remove it

  ; r16 is currently object number of first child, good place to start

  ; end of list
  tst r16
  brne PC+2
  ret

  rcall get_object_pointer
  adiw YL, 5 ; move to sibling

  ; prep for read
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; get sibling
  rcall ram_read_byte

  rcall ram_end

  ; is the sibling the object we're moving?
  cp r16, r2

  ; no, so loop to load the sibling object and continue down the list
  brne unlink_object

  ; yes, the currently-pointed-at object points to the moving object, so we
  ; need to repoint it to the moving object's sibling
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  ; write new sibling
  mov r16, r7
  rcall ram_write_byte

  rjmp ram_end


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
  movw ram_pos_l, YL
  clr ram_pos_h
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
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp branch_generic


; set/clear attr main routine
; T: value to set bit to
write_attr:

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
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; read the single byte
  rcall ram_read_byte

  rcall ram_end

  ; save previous value
  push r16

  ; set up for write to attribute position
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_write_start

  ; get value and mask back
  pop r16
  pop r17

  ; set or clear bit
  brtc PC+3

  ; set, just or with the mask
  or r16, r17
  rjmp PC+3

  ; clear, complement the mask then and
  com r17
  and r16, r17

  ; write it out
  rcall ram_write_byte

  rcall ram_end

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op

; set_attr object attribute
op_set_attr:
  set
  rjmp write_attr


; clear_attr object attribute
op_clear_attr:
  clt
  rjmp write_attr


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
  movw ram_pos_l, YL
  clr ram_pos_h
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
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


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
  lds ram_pos_l, z_header+0xb
  lds ram_pos_m, z_header+0xa

  ; properties are counted from 1
  dec r4

  ; property values are words, so double property number to make an offset
  lsl r4

  ; offset into default table
  add ram_pos_l, r4
  brcc PC+2
  inc ram_pos_m

  ; ready read
  clr ram_pos_h
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
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; return!
  rjmp store_op_result


; get_prop_addr object property -> (result)
op_get_prop_addr:

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

  ; check if we got it
  tst r16
  brne PC+4

  ; not found, zero return
  clr YL
  clr YH
  rjmp PC+2

  ; if found, ram is waiting at property, close it
  rcall ram_end

  ; move return into first arg for store
  movw r2, YL

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; great
  rjmp store_op_result


; get_prop_len property-address -> (result)
op_get_prop_len:

  rcall ram_end

  ; length is stored one behind given address, so take it back one
  movw r16, r2
  subi r16, 1
  sbci r17, 0

  ; setup for read
  movw ram_pos_l, r16
  clr ram_pos_h
  rcall ram_read_start

  ; read length
  rcall ram_read_byte

  rcall ram_end

  ; top three bits are the length-1, so shift down and increment
  lsr r16
  lsr r16
  lsr r16
  lsr r16
  lsr r16
  inc r16

  ; move to arg0 for result
  mov r2, r16
  clr r3

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp store_op_result


; get_next_prop object property -> (result)
op_get_next_prop:

  ; null object check
  tst r2
  brne PC+4
  tst r3
  brne PC+2
  rjmp store_op_result

  ; close ram
  rcall ram_end

  ; prep for search
  mov r16, r2
  mov r17, r4

  ; see if we want property zero (the first)
  tst r17
  brne PC+2

  ; no, so set the "want next" marker bit
  sbr r17, 0x80

  ; the hunt begins
  rcall get_object_property_pointer

  ; anything found?
  tst r16
  brne PC+2

  ; yes, close ram
  rcall ram_end

  ; prep return value
  mov r2, r17
  clr r3

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp store_op_result


; INPUT

; sread text parse [v4 sread text parse time routing] [v5 aread text parse time routine -> (result)]
op_sread:

  ; close ram
  rcall ram_end

  ; write zero to parse buffer +1, this is count of parsed tokens, which starts at zero
  movw ram_pos_l, r4
  inc ram_pos_l
  brne PC+2
  inc ram_pos_m
  clr ram_pos_h
  rcall ram_write_start

  ; write zero
  clr r16
  rcall ram_write_byte

  rcall ram_end

  ; setup to read buffer
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_read_start

  ; read max length
  rcall ram_read_byte

  rcall ram_end

  ; clamp max buffer size to what we actually have internal memory for
  ldi r17, low(input_buffer_end-input_buffer)
  cp r16, r17
  brlo PC+2
  mov r16, r17

  ; get a line
  rcall usart_line_input

  ; set up to write text buffer
  movw ram_pos_l, r2
  inc ram_pos_l
  brne PC+2
  inc ram_pos_m
  clr ram_pos_h
  rcall ram_write_start

  ; copy text into memory, including trailing null
  ldi ZL, low(input_buffer)
  ldi ZH, high(input_buffer)

  ld r17, Z+

  ; convert to lowercase
  cpi r17, 'A'
  brlo PC+4
  cpi r17, 'Z'+1
  brsh PC+2
  ori r17, 0x20 ; convert

  mov r16, r17
  rcall ram_write_byte
  tst r17
  brne PC-9

  rcall ram_end

  ; dictionary location
  lds ram_pos_l, z_header+0x9
  lds ram_pos_m, z_header+0x8
  clr ram_pos_h
  rcall ram_read_start

  ; number of word separators
  rcall ram_read_byte
  mov r17, r16

  ; crash if theres more separators that we have room for
  ; XXX this is sorta dumb, because we know zork only has three separators, and
  ;     we don't have memory for a lot more, but lets try to do it right
  cpi r17, low(separator_buffer_end-separator_buffer)
  brlo PC+2
  rjmp fatal

  ; while we're here, compute the offset of the first entry in the dictionary;
  ; we'll need it later
  ldi r16, 4 ; num separators (1) + entry length (1) + num entries (2)
  add r16, r17
  mov r15, r16

  ; make word separators into a null-terminated string
  ldi ZL, low(separator_buffer)
  ldi ZH, high(separator_buffer)

  ; copy separators
  tst r17
  breq PC+5
  rcall ram_read_byte
  st Z+, r16
  dec r17
  brne PC-5

  ; terminator
  clr r16
  st Z+, r16

  ; size of dictionary entry
  rcall ram_read_byte

  ; reduce by 4 to get number of bytes to skip after each entry
  subi r16, 4
  push r16

  ; read number of words
  rcall ram_read_pair
  mov r2, r17
  mov r3, r16

  ; start of input
  ldi ZL, low(input_buffer)
  ldi ZH, high(input_buffer)

parse_next_input:
  rcall ram_end

  ; discard leading spaces
  ld r16, Z
  cpi r16, ' '
  brne PC+3
  adiw ZL, 1
  rjmp PC-4

  ; if after eating all the space we're now at null, then there's nothing left to parse
  tst r16
  brne PC+6

  ; drop the skip count
  pop r16

  ; reopen ram at PC
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  ; wow
  rjmp decode_op

  ; set input position aside to reload later
  movw r6, ZL

  ; set word count (eventual token) to zero
  clr r8
  clr r9

  ; so the plan here is to read each dictionary word, decode it, then compare
  ; it with the current input position. if it matches, then set the word number
  ; as the token and go to the next one

  ; set up for read from start of dictionary

  ; dictionary pointer + offset
  lds ram_pos_l, z_header+0x9
  lds ram_pos_m, z_header+0x8
  clr ram_pos_h

  add ram_pos_l, r15
  adc ram_pos_m, ram_pos_h
  adc ram_pos_h, ram_pos_h

  rcall ram_read_start

dict_word_next:
  ; output space for word expansion
  ldi ZL, low(word_buffer)
  ldi ZH, high(word_buffer)

  ; start expand
  rcall zstring_init

dict_char_next:
  ; get a char
  push ZL
  push ZH
  rcall zstring_next
  pop ZH
  pop ZL

  ; done?
  tst r16
  breq dict_word_done

  ; high bit set means nothing to output, but more to take
  brmi PC+2

  ; real char, store it
  st Z+, r16

  ; it seems that not all words have end markers, so we'll have figure it out
  ; ourselves. if YL (count of bytes taken) is 4, and r19 (remaining chars in
  ; current 2-byte word) is 0, then we're done (that is, we're exactly six
  ; zchars in, which is the max length of a dictionary word)
  cpi YL, 4
  brne dict_char_next
  tst r19
  brne dict_char_next

dict_word_done:
  rcall zstring_done

  ; trailing null
  clr r16
  st Z, r16

  ; walk back and zero all the 0x5 padding bytes
  ; XXX I'm not sure there can be any 0x5 padding bytes here, as 0x5 has
  ;     meaning to the zstring exploder, which won't ever return one
  ld r17, -Z
  cpi r17, 0x5
  brne PC+3
  st Z, r16
  rjmp PC-4

  ; ok. current word is in word_buffer, bring input pointer back to Z
  movw ZL, r6

  ; ready for word walk
  ldi YL, low(word_buffer)
  ldi YH, high(word_buffer)

  ; get input byte and word byte
  ld r16, Y+
  ld r17, Z

  ; compare
  cp r16, r17
  brne PC+5

  ; reached the end of matchword, leave, so that we keep the nulls in registers for testing
  tst r16
  breq PC+3

  ; advance input and compare next
  adiw ZL, 1
  rjmp PC-7

  ; fell out of compare loop; lets find out why

  ; remember the current buffer position at end of word, so we can restore it
  ; later to compute token length and also continue parse from this point
  movw r20, ZL

  ; get the skip count back off the stack. we'll re-push it before we loop, if we loop
  pop r18

  ; did we reach the end of the match word? if not, then there's no further
  ; magic available: we just didn't match
  tst r16
  brne failed_match

  ; if we're at the end of the word buffer, then this is full match on what
  ; might be a longer word, but we're allowed to be ambiguous (because the
  ; words in the dictionary are only six chars)
  cpi YL, low(word_buffer+6)
  brsh matched_word

  ; are we at a separator?
  tst r17
  breq matched_word
  cpi r17, ' '
  breq matched_word

  ; consider the declared separators
  ldi ZL, low(separator_buffer)
  ldi ZH, high(separator_buffer)

  ; did we match one?
  ld r16, Z+
  cp r17, r16
  breq matched_word

  ; are there more separators?
  tst r16
  brne PC-4

failed_match:

  ; failed word match. prepare for next word

  ; bring Z back to start
  movw ZL, r6

  ; inc word count
  inc r8
  brne PC+2
  inc r9

  ; have we reached the last one?
  cp r2, r8
  cpc r3, r9
  breq failed_all_matches

  ; push the skip count back
  push r18

  ; no, move ram forward to next word
  mov r16, r18
  rcall ram_skip_bytes

  rjmp dict_word_next

failed_all_matches:

  ; we've tried every word in the dictionary and none matched, so we have to
  ; record an empty token block
  clr r10
  clr r11
  rjmp consume_up_to_separator

matched_word:

  ; now need to calculate the position of this in the dictionary

  ; recalc entry size (skip+4)
  mov r16, r18
  ldi r17, 4
  add r16, r17

  ; multiply word number by entry size
  mul r8, r16
  movw r10, r0
  mul r9, r16
  add r11, r0

  ; add location of dictionary start
  lds r16, z_header+0x9
  lds r17, z_header+0x8
  add r10, r16
  adc r11, r17

  ; and offset to first entry
  clr r16
  add r10, r15
  adc r11, r16

  ; location of matched entry now in r10:r11

consume_up_to_separator:

  ; bring Z back to end of word
  movw ZL, r20

consume_next:
  ; consume input up to next separator

  ldi YL, low(separator_buffer)
  ldi YH, high(separator_buffer)

  ; get the byte
  ld r16, Z

  ; null? end of the world
  tst r16
  breq compute_text_position

  ; space is the ultimate separator
  cpi r16, ' '
  breq compute_text_position

  ; try declared separators
  ld r17, Y+

  ; ran out?
  tst r17
  breq PC+5

  ; matched a separator?
  cp r16, r17
  breq compute_text_position

  ; not a separator, advance and retry
  adiw ZL, 1
  rjmp consume_next

compute_text_position:

  ; push the skip count back
  push r18

  ; start of input text is in r6:r7, end in r20, so we can compute length
  mov r0, r20
  sub r0, r6

  ; and position
  ldi r17, low(input_buffer)
  mov r1, r6
  sub r1, r17
  inc r1 ; move past max count

  ; set up to write the current block out to the word buffer
  ldi YL, low(word_buffer)
  ldi YH, high(word_buffer)

  ; location of matching dictionary word
  st Y+, r11
  st Y+, r10

  ; word length
  st Y+, r0

  ; word position
  st Y+, r1

  rcall ram_end

  ;push ZL
  ;push ZH
  ;push r16
  ;push r17
  ;ldi ZL, low(word_buffer)
  ;ldi ZH, high(word_buffer)
  ;ldi r16, 4
  ;clr r17
  ;rcall usart_tx_bytes_hex
  ;pop r17
  ;pop r16
  ;pop ZH
  ;pop ZL

  ; time to store it! parse buffer position is in r4:r5
  movw ram_pos_l, r4
  clr ram_pos_h
  rcall ram_read_start

  ; load max tokens and count of tokens
  rcall ram_read_pair
  rcall ram_end

  ; if we're already out of token space, just drop it on the floor
  cp r16, r17
  breq word_done

  ; set it aside
  push r17

  ; multiply token count by block size (4) to get offset
  mov r16, r17
  clr r17
  lsl r16
  rol r17
  lsl r16
  rol r17

  ; add parse buffer addr
  add r16, r4
  adc r17, r5

  ; +2 past max/count
  ldi r18, 2
  add r16, r18
  brcc PC+2
  inc r17

  ; set up for write
  movw ram_pos_l, r16
  clr ram_pos_h
  rcall ram_write_start

  ldi YL, low(word_buffer)
  ldi YH, high(word_buffer)
  ldi r16, 4
  rcall ram_write_bytes

  rcall ram_end

  ; set up to increment token count
  movw ram_pos_l, r4
  inc ram_pos_l
  brne PC+2
  inc ram_pos_m
  clr ram_pos_h
  rcall ram_write_start

  ; bump and store it
  pop r16
  inc r16
  rcall ram_write_byte

  rcall ram_end

word_done:
  ; get some more!
  rjmp parse_next_input


; CHARACTER BASED OUTPUT

; print_char output-character-code
op_print_char:

  ; XXX handle about ZSCII and high-order chars
  mov r16, r2
  cpi r16, 0x20
  brlo PC+4
  cpi r16, 0x7f
  brsh PC+2
  rcall usart_tx_byte
  rjmp decode_op


; new_line
op_new_line:
  rcall usart_newline
  rjmp decode_op


; print (literal_string)
op_print:

  rcall print_zstring

  ; advance PC
  add z_pc_l, YL
  adc z_pc_h, YH

  rjmp decode_op


; print_ret (literal-string)
op_print_ret:

  rcall print_zstring

  ; advance PC
  add z_pc_l, YL
  adc z_pc_h, YH

  rcall usart_newline

  rjmp op_rtrue


; print_addr byte-address-of-string
op_print_addr:

  ; close ram
  rcall ram_end

  ; open ram at address
  movw ram_pos_l, r2
  clr ram_pos_h
  rcall ram_read_start

  rcall print_zstring

  rcall ram_end

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; print_paddr packed-address-of-string
op_print_paddr:

  ; close ram
  rcall ram_end

  ; unpack address. string table for zork extends past 0xffff, so we need to
  ; run 17 bits here
  movw ram_pos_l, r2
  clr ram_pos_h
  lsl ram_pos_l
  rol ram_pos_m
  rol ram_pos_h

  ; open ram at address
  rcall ram_read_start

  rcall print_zstring

  rcall ram_end

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

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
  movw ram_pos_l, YL
  clr ram_pos_h
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
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  rcall print_zstring

  rcall ram_end

  ; reset ram
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; MISCELLANEOUS

; random range -> (result)
op_random:

  ; reseed test
  tst r2
  brmi rand_neg
  brne PC+3
  tst r3
  breq rand_zero

  ; load seed
  lds r16, rand_l
  lds r17, rand_h

  ; Xorshift (Marsaglia 2003) variant RNG
  ; adapted from http://www.retroprogramming.com/2017/07/xorshift-pseudorandom-numbers-in-z80.html
  mov r18, r17
  lsr r18
  mov r18, r16
  ror r18
  eor r18, r17
  mov r17, r18
  ror r18
  eor r18, r16
  mov r16, r18
  eor r18, r17
  mov r17, r18

  ; store result as new seed
  sts rand_l, r16
  sts rand_h, r17

  ; divide by incoming range
  movw r18, r2
  rcall divide

  ; remainder in r2:r3, add one to bring it into range
  inc r2
  brne PC+2
  inc r3

  rjmp store_op_result

rand_neg:
  ; negative, seed from arg
  sts rand_l, r2
  sts rand_h, r3

  ; return 0
  clr r2
  clr r3
  rjmp store_op_result

rand_zero:
  ; zero, reseed and return 0
  ; XXX if we had a clock, we'd use that. we don't, so just reset to "normal"
  clr r16
  sts rand_h, r16
  inc r16
  sts rand_l, r16

  ; r2:r3 already zero
  rjmp store_op_result



; UTILITY ROUTINES

; get value of variable
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


; store value to variable
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


; increment variable
; inputs:
;   r2: variable number
; outputs:
;   r0:r1: new value
inc_variable:

  mov r16, r2
  rcall load_variable

  ; increment
  inc r0
  brne PC+2
  inc r1

  ; store value back
  mov r16, r2
  rcall store_variable

  ret


; decrement variable
; inputs:
;   r2: variable number
; outputs:
;   r0:r1: new value
dec_variable:

  mov r16, r2
  rcall load_variable

  ; decrement
  movw r16, r0
  subi r16, 1
  sbci r17, 0
  movw r0, r16

  ; store value back
  mov r16, r2
  rcall store_variable

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

  ; bottom six bits are the offset
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

  ; original offset bits are the high byte
  mov r19, r18

  ; second byte is the low byte
  mov r18, r16

  ; this 14-bit offset is actually signed, so if its negative, need to extend it
  sbrc r19, 5

  ; set top two bits, extending the sign
  sbr r19, 0xc0

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

  ; consider "fast return" cases
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
  movw ram_pos_l, z_pc_l
  clr ram_pos_h
  rcall ram_read_start

  rjmp decode_op


; perform signed divide r16:r17 / r18:r19
; returns quotient in r16:r17, remainder in r2:r3
divide:
  ; taken from app note AVR200 (div16s)
  mov  r4, r17        ; move dividend High to sign register
  eor  r4, r19        ; xor divisor High with sign register
  sbrs r17, 7         ; if MSB in dividend set
  rjmp PC+5
  com  r17            ;    change sign of dividend
  com  r16
  subi r16, 0xff
  sbci r16, 0xff
  sbrs r19, 7         ; if MSB in divisor set
  rjmp PC+4
  com  r19            ;    change sign of divisor
  neg  r18
  sbci r19, 0xff
  clr  r2             ; clear remainder Low byte
  sub  r3, r3         ; clear remainder High byte and carry
  ldi  r20, 17        ; init loop counter
div_loop:
  rol  r16            ; shift left dividend
  rol  r17
  dec  r20            ; decrement counter
  brne PC+7           ; if done
  sbrs r4, 7          ;    if MSB in sign register set
  ret
  com  r17            ;        change sign of result
  neg  r16
  sbci r17, 0xff
  ret                 ;    return
  rol  r2             ; shift dividend into remainder
  rol  r3
  sub  r2, r18        ; remainder = remainder - divisor
  sbc  r3, r19        ;
  brcc PC+5           ; if result negative
  add  r2, r18        ;    restore remainder
  adc  r3, r19
  clc                 ;    clear carry to be shifted into result
  rjmp div_loop       ; else
  sec                 ;    set carry to be shifted into result
  rjmp div_loop


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
  sts WDTCSR, r16
  rjmp PC

dump:
  ldi ZL, low(text_pc*2)
  ldi ZH, high(text_pc*2)
  rcall usart_print_static
  lds r16, z_last_pc_h
  rcall usart_tx_byte_hex
  lds r16, z_last_pc_l
  rcall usart_tx_byte_hex
  rcall usart_newline

  ldi ZL, low(text_opcode*2)
  ldi ZH, high(text_opcode*2)
  rcall usart_print_static
  lds r16, z_last_opcode
  rcall usart_tx_byte_hex
  rcall usart_newline

  ldi ZL, low(text_argtype*2)
  ldi ZH, high(text_argtype*2)
  rcall usart_print_static
  lds r16, z_last_argtype
  rcall usart_tx_byte_hex
  rcall usart_newline

  ; XXX roll this up
  lds r16, z_last_argtype
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

  lds r16, z_last_argtype
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

  lds r16, z_last_argtype
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

  ; divide attribute number by 8 to get number of bytes to skip
  mov r16, r17
  lsr r16
  lsr r16
  lsr r16

  ; and skip them
  add YL, r16
  brcc PC+2
  inc YH

  ; take bottom bits to compute mask
  andi r17, 0x7

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
;   r17: property number (set bit 7 for next)
; outputs:
;   Y: location of property value
;   r16: length of property (0 if not found)
;   r17: property number found (if 0 or next requested)
; if found, leaves ram open for read at property value
get_object_property_pointer:

  ; save property number
  push r17

  ; get the object pointer
  rcall get_object_pointer

  ; add 7 bytes for property pointer
  adiw YL, 7

  ; open ram at object property pointer
  movw ram_pos_l, YL
  clr ram_pos_h
  rcall ram_read_start

  ; read property pointer
  rcall ram_read_pair
  mov YL, r17
  mov YH, r16

  ; close ram again
  rcall ram_end

  ; open for read at start of property table
  movw ram_pos_l, YL
  clr ram_pos_h
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

  ; if they asked for property 0, exit at first one
  tst r18
  brne PC+2
  ret

  ; did we find it? great if so!
  cp r17, r18
  brne PC+2
  ret

  ; are we looking for the next one? if not, loop
  tst r18
  brpl prop_next

  ; we want the next one after the named one. so take off the marker bit, then
  ; see if we hit the named one
  mov r19, r18
  cbr r19, 0x80

  ; now compare. if they're not the same, we can just loop
  cp r17, r19
  brne prop_next

  ; same! we want the next one, so we can just ask for property 0
  clr r18
  rjmp prop_next


; print zstring at current RAM position (assumed open for reading)
; outputs:
;   Y: number of RAM bytes taken
print_zstring:
  rcall zstring_init

print_next:
  rcall zstring_next

  ; done?
  tst r16
  brne PC+2

  ; yep
  rjmp zstring_done

  ; high bit set means nothing to print, but more to take
  brmi print_next

  ; newline?
  cpi r16, 0xa
  brne PC+3

  ; yep, handle that
  rcall usart_newline
  rjmp print_next

  ; something printable!
  rcall usart_tx_byte
  rjmp print_next


; zstring decoder
;
; 1. call zstring_init
; 2. call zstring_next
;  2a. if r16 is 0, string is done and go to 3
;  2b. if r16 bit 7 is set, last char was non-printable, go to 2
;  2c. anything else, take r16 it (0xa indicates newline)
; 3. call zstring_done
;
; state tracking (do not modify between calls)
;   Y: number of RAM bytes advanced (for moving PC, see op_print)
;   r10: lock alphabet
;   r11: current alphabet
;   r18 (bit 7 clear): number of remaining chars to read for wide character
;   r18 (bit 7 set):   next byte is an abbreviation index, bottom bits are abbreviation bank
;   r19: number of remaining chars in current word (0=new word will be read on next call)
;   r20,r21: current 3-char word (remaining bits)
;   T: end-of-string flag, further calls to zstring_next will return 0

zstring_init:
  ; clear byte count
  clr YL
  clr YH

  ; reset lock alphabet to A0
  clr r10

  ; reset current alphabet to A0
  clr r11

  ; handle decoded bytes directly, don't stack them
  clr r18

  ; no chars remaining, load new word
  clr r19

  ; probably not at end of string
  clt

  ; ready to go
  ret

zstring_next:

  dec r19

  ; start of new word?
  brpl next_zchar

  ; was previous word the last one?
  brtc next_zword

  ; yes, are we doing abbreviation subprocessing?
  lds r16, zstring_state_flags
  tst r16
  brpl PC+2
  rjmp finish_abbreviation

  ; so there's nothing else to do
  clr r16
  ret

next_zword:
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
  ldi r19, 2

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

  ;push r16
  ;push r17
  ;rcall usart_tx_byte_hex
  ;pop r17
  ;pop r16

  ; handline widechar or abbreviation?
  tst r18
  brpl PC+2
  rjmp expand_abbreviation
  breq PC+6

  ; widechar, set it aside
  st -X, r16

  ; got them all?
  dec r18
  breq convert_wide_zchar

  ; nope, report non-printable
  sbr r16, 0x80
  ret

  ; decode!
  rcall lookup_zchar

  ; if its printable, just return it
  cpi r16, 0x20
  brlo PC+3

  ; reset to lock alphabet
  mov r11, r10

  ret

  ; set up for zchar op call
  ldi ZL, low(zchar_op_table)
  ldi ZH, high(zchar_op_table)

  ; add the opcode to get the op vector
  add ZL, r16
  brcc PC+2
  inc ZH

  ; flag response as unprintable
  sbr r16, 0x80

  ; call op!
  ijmp

convert_wide_zchar:

  ; take two 5-bit items off stack
  ld r16, X+
  ld r17, X+

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

  ; return it
  ret

lookup_zchar:

  ; set up pointer to start of alphabets for this version
  lds r17, z_header
  cpi r17, 1
  brne PC+4
  ldi ZL, low(zchar_alphabet_v1*2)
  ldi ZH, high(zchar_alphabet_v1*2)
  rjmp alphabet_ready
  cpi r17, 2
  brne PC+4
  ldi ZL, low(zchar_alphabet_v2*2)
  ldi ZH, high(zchar_alphabet_v2*2)
  rjmp alphabet_ready
  ldi ZL, low(zchar_alphabet_v3*2)
  ldi ZH, high(zchar_alphabet_v3*2)

alphabet_ready:
  ; compute and add alphabet offset
  mov r0, r11
  ldi r17, 0x20
  mul r0, r17
  add ZL, r0
  brcc PC+2
  inc ZH

  ; add character offset
  add ZL, r16
  brcc PC+2
  inc ZH

  ; load byte
  lpm r16, Z
  ret

expand_abbreviation:

  ; we're going to call back into the zstring system, so we need to save its
  ; state, or at least enough that we can recreate its state
  rcall ram_end

  ; save advance position
  sts zstring_state_adv_l, YL
  sts zstring_state_adv_h, YH

  ; save ram pointer, so we can reopen in the right place
  sts zstring_state_ram_pos_l, ram_pos_l
  sts zstring_state_ram_pos_m, ram_pos_m
  sts zstring_state_ram_pos_h, ram_pos_h

  ; save word position
  sts zstring_state_word_pos, r19

  ; and word in progress
  sts zstring_state_word_l, r20
  sts zstring_state_word_h, r21

  ; save alphabets
  sts zstring_state_lock_alphabet, r10

  ; save flags
  ldi r17, 0x80 ; top bit is "doing abbreviation" flag
  bld r17, 0    ; bottom bit is original "end of string" flag
  sts zstring_state_flags, r17

  ; compute start of wanted bank and add to index
  andi r18, 0x3
  ldi r17, 0x20
  mul r18, r17
  add r16, r0

  ;push r16
  ;ldi r16, '['
  ;rcall usart_tx_byte
  ;pop r16
  ;push r16
  ;rcall usart_tx_byte_hex
  ;ldi r16, ':'
  ;rcall usart_tx_byte
  ;pop r16

  ; index is into a table of words, so double the offset to get bytes
  lsl r16

  ; abbreviation table location
  lds ram_pos_l, z_header+0x19
  lds ram_pos_m, z_header+0x18
  clr ram_pos_h

  ; add offset
  add ram_pos_l, r16
  adc ram_pos_m, ram_pos_h
  adc ram_pos_h, ram_pos_h

  ; go
  rcall ram_read_start

  ;mov r16, ram_pos_h
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_m
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_l
  ;rcall usart_tx_byte_hex
  ;ldi r16, '>'
  ;rcall usart_tx_byte

  ; read string location
  rcall ram_read_pair
  rcall ram_end

  ; complete string location and set up ram
  mov ram_pos_l, r17
  mov ram_pos_m, r16
  clr ram_pos_h

  ;mov r16, ram_pos_h
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_m
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_l
  ;rcall usart_tx_byte_hex
  ;ldi r16, '*'
  ;rcall usart_tx_byte

  ; string location is a word, so shift to get a byte address
  lsl ram_pos_l
  rol ram_pos_m
  rol ram_pos_h
  rcall ram_read_start

  ;mov r16, ram_pos_h
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_m
  ;rcall usart_tx_byte_hex
  ;mov r16, ram_pos_l
  ;rcall usart_tx_byte_hex

  ; reset zstring processing state
  rcall zstring_init

  ; finally, jump back and get the "next" char from the new string
  rjmp zstring_next

finish_abbreviation:

  rcall zstring_done

  rcall ram_end

  ;ldi r16, ']'
  ;rcall usart_tx_byte

  ; restore advance position
  lds YL, zstring_state_adv_l
  lds YH, zstring_state_adv_h

  ; reopen ram at the previous position
  lds ram_pos_l, zstring_state_ram_pos_l
  lds ram_pos_m, zstring_state_ram_pos_m
  lds ram_pos_h, zstring_state_ram_pos_h
  rcall ram_read_start

  ; restore word position
  lds r19, zstring_state_word_pos

  ; and word in progress
  lds r20, zstring_state_word_l
  lds r21, zstring_state_word_h

  ; restore alphabets
  lds r10, zstring_state_lock_alphabet
  mov r11, r10

  ; restore flags
  lds r16, zstring_state_flags
  bst r16, 0

  ; not currently in a widechar
  clr r18

  ; clear "doing abbreviation" flag
  clr r16
  sts zstring_state_flags, r16

  ; continue with the original string
  rjmp zstring_next

zstring_done:
  ; if we ended mid wide-byte, then drop the single sitting on the stack
  ; shouldn't happen but we can't recover if we get this wrong
  cpi r18, 1
  brne PC+2
  adiw XL, 1

  ret

; the three alphabets: A0, A1, A2

; normally they start at 6, leaving 26 printable chars. values below 6 are
; control codes, affecting alphabet selection, printing newlines, etc. in v2+,
; it starts getting more complicated, with newlines moving into printable
; space, changes to lock control, etc

; instead of testing for control codes explicitly, instead we embed our own
; control codes into the alphabet conversion output. any value <32 is an index
; into a jump table that implements that code

; 0x0 newline
; 0x1 wide char
; 0x2 inc current alphabet
; 0x3 dec current alphabet
; 0x4 inc current alphabet, set lock
; 0x5 dec current alphabet, set lock
; 0x6 abbreviation (bank 1)
; 0x7 abbreviation (bank 2)
; 0x8 abbreviation (bank 3)
; 0x9 switch to alphabet A1
; 0xa switch to alphabet A2

zchar_alphabet_v1:
  ; A0
  .db " ", 0x0, 0x2, 0x3, 0x4, 0x5, "abcdefghijklmnopqrstuvwxyz"
  ; A1
  .db " ", 0x0, 0x2, 0x3, 0x4, 0x5, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  ; A2
  .db " ", 0x0, 0x2, 0x3, 0x4, 0x5, 0x1, "0123456789.,!?_#'"
    .db 0x22, "/\<-:()" ; work around avra's buggy string parser (raw double-quote byte)

zchar_alphabet_v2:
  ; A0
  .db " ", 0x6, 0x2, 0x3, 0x4, 0x5, "abcdefghijklmnopqrstuvwxyz"
  ; A1
  .db " ", 0x6, 0x2, 0x3, 0x4, 0x5, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  ; A2
  .db " ", 0x6, 0x2, 0x3, 0x4, 0x5, 0x1, 0x0, "0123456789.,!?_#"
    .db 0x27, 0x22, "/\-:()"

zchar_alphabet_v3:
  ; A0
  .db " ", 0x6, 0x7, 0x8, 0x9, 0xa, "abcdefghijklmnopqrstuvwxyz"
  ; A1
  .db " ", 0x6, 0x7, 0x8, 0x9, 0xa, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  ; A2
  .db " ", 0x6, 0x7, 0x8, 0x9, 0xa, 0x1, 0x0, "0123456789.,!?_#"
    .db 0x27, 0x22, "/\-:()"

zchar_op_table:
  rjmp zchar_op_newline
  rjmp zchar_op_widechar
  rjmp zchar_op_inc_alphabet
  rjmp zchar_op_dec_alphabet
  rjmp zchar_op_inc_lock_alphabet
  rjmp zchar_op_dec_lock_alphabet
  rjmp zchar_op_abbrev_bank1
  rjmp zchar_op_abbrev_bank2
  rjmp zchar_op_abbrev_bank3
  rjmp zchar_op_switch_alphabet_a1
  rjmp zchar_op_switch_alphabet_a2

zchar_op_newline:
  ldi r16, 0xa
  ret

zchar_op_widechar:
  ; stack next two chars and deal with them
  ldi r18, 2
  ret

zchar_op_inc_alphabet:
  inc r11
  mov r17, r11
  cpi r17, 3
  brne PC+2
  clr r11
  ret

zchar_op_dec_alphabet:
  dec r11
  sbrs r11, 7
  ret
  ldi r17, 2
  mov r11, r17
  ret

zchar_op_inc_lock_alphabet:
  rcall zchar_op_inc_alphabet
  mov r10, r11
  ret

zchar_op_dec_lock_alphabet:
  rcall zchar_op_dec_alphabet
  mov r10, r11
  ret

zchar_op_abbrev_bank1:
  ; flag abbrev for next char
  ldi r18, 0x80
  ret

zchar_op_abbrev_bank2:
  ; flag abbrev for next char
  ldi r18, 0x81
  ret

zchar_op_abbrev_bank3:
  ; flag abbrev for next char
  ldi r18, 0x82
  ret

zchar_op_switch_alphabet_a1:
  ldi r17, 1
  mov r11, r17
  ret

zchar_op_switch_alphabet_a2:
  ldi r17, 2
  mov r11, r17
  ret


xmodem_load_ram:

  ; error indicator off
  cbi PORTB, PB0

  ; try to get their attention
  sbi PORTB, PB1
  ldi ZL, low(text_xmodem_start*2)
  ldi ZH, high(text_xmodem_start*2)
  rcall usart_print_static

  ; xmodem receiver: send NAK, wait for data to arrive
  ; XXX implement 10x10 retry

  ; CTC mode, /1024 prescaler
  ldi r16, (1<<WGM12)|(1<<CS12)|(1<<CS10)
  sts TCCR1B, r16

  ; ~2-3s
  ldi r16, low(0xb718)
  ldi r17, high(0xb718)
  sts OCR1AH, r17
  sts OCR1AL, r16

  ; 10 tries
  ldi r17, 10

xlr_try_handshake:
  ; ready to receive
  ldi r16, 0x15 ; NAK
  rcall usart_tx_byte

  ; clear counter
  clr r16
  sts TCNT1H, r16
  sts TCNT1L, r16

  ; loop until timer expires, or usart becomes readable
xlr_timer_wait:
  in r16, TIFR1
  sbrc r16, OCF1A
  rjmp xlr_timer_expired
  lds r18, UCSR0A
  sbrc r18, RXC0
  rjmp xlr_ready
  rjmp xlr_timer_wait

xlr_timer_expired:

  ; acknowledge timer
  ldi r16, (1<<OCF1A)
  out TIFR1, r16

  ; out of tries?
  dec r17
  brne xlr_try_handshake

  ; disable timer
  clr r16
  sts TCCR1B, r16

  ; error indicator on, waiting indicator off
  sbi PORTB, PB0
  cbi PORTB, PB1

  ldi ZL, low(text_xmodem_timeout*2)
  ldi ZH, high(text_xmodem_timeout*2)
  rjmp usart_print_static

xlr_ready:

  ; waiting indicator off
  cbi PORTB, PB1

  ; disable timer
  clr r16
  sts TCCR1B, r16

  ; ok, we're really doing this. set up to recieve

  ; initialise RAM for write
  clr ram_pos_l
  clr ram_pos_m
  clr ram_pos_h
  rcall ram_write_start

  ; point to receive buffer
  ldi YH, high(0x100)

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
  clr YL

  ; prepare for checksum
  clr r17

  ; want 128 bytes
  ldi r18, 127

  ; take a byte
  rcall usart_rx_byte

  ; add to buffer
  st Y+, r16

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
  clr YL
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
  lds r16, UCSR0A
  sbrs r16, RXC0
  rjmp PC-3
  lds r16, UDR0
  ret


; receive a byte from the usart if there's one waiting
; outputs:
;   T: set if something was read, clear otherwise
;   r16: received byte, if there was one
usart_rx_byte_maybe:
  clt
  lds r16, UCSR0A
  sbrs r16, RXC0
  ret
  lds r16, UDR0
  set
  ret


; transmit a byte via the usart
; inputs:
;   r16: byte to send
usart_tx_byte:
  push r16
  lds r16, UCSR0A
  sbrs r16, UDRE0
  rjmp PC-3
  pop r16
  sts UDR0, r16
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
  ldi r16, 0xd
  rcall usart_tx_byte
  ldi r16, 0xa
  rjmp usart_tx_byte


; receive a line of input into the input buffer, with simple editing controls
; inputs:
  ; r16: max number of chars
usart_line_input:
  ldi ZL, low(input_buffer)
  ldi ZH, high(input_buffer)

  movw YL, ZL
  add YL, r16
  brcc PC+2
  inc YH

uli_next_char:
  rcall usart_rx_byte

  ; printable ascii range is 0x20-0x7e
  ; XXX any computer made in 2020 needs to support unicode
  cpi r16, 0x20
  brlo uli_handle_control_char
  cpi r16, 0x7f
  brsh uli_handle_control_char

  ; something printable, make sure there's room in the buffer for it
  cp ZL, YL
  cpc ZH, YH
  brsh uli_next_char

  ; append to buffer and echo it
  st Z+, r16
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
  st Z+, r16

  ; echo newline
  ldi r16, 0xd
  rcall usart_tx_byte
  ldi r16, 0xa
  rjmp usart_tx_byte

  ; that's all the input!

uli_do_backspace:
  ; start-of-buffer check
  cpi ZL, low(input_buffer)
  brne PC+3
  cpi ZH, high(input_buffer)
  breq uli_next_char

  ; move buffer pointer back
  subi ZL, 1
  sbci ZH, 0

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

  ldi r16, 0xd
  rcall usart_tx_byte
  ldi r16, 0xa
  rcall usart_tx_byte

  rjmp usart_tx_bytes_hex_next

usart_tx_bytes_hex_done:
  ldi r16, 0xd
  rcall usart_tx_byte
  ldi r16, 0xa
  rcall usart_tx_byte

  ret


; begin read from SRAM
; inputs
;   ram_pos_[lmh]: 24-bit address
ram_read_start:
  ldi r16, 0x3 ; READ
  rjmp ram_start

; begin write to SRAM
; inputs
;   ram_pos_[lmh]: 24-bit address
ram_write_start:
  ldi r16, 0x2 ; WRITE

  ; fall through

; start SRAM read/write op
;   ram_pos_[lmh]: 24-bit address
;   r16: command (0x2 read, 0x3 write)
ram_start:

  ; pull /CS low to enable device
  cbi PORTB, PB2

  ; send command
  out SPDR, r16
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2

  ; send address
  out SPDR, ram_pos_h
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2
  out SPDR, ram_pos_m
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2
  out SPDR, ram_pos_l
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2

  ret

ram_end:
  ; drive /CS high to indicate end of operation
  sbi PORTB, PB2
  ret

; pull stuff from SRAM, previously set up with ram_read_start
;   r16: number of bytes to read
;   Y: where to store it
ram_read_bytes:
  clr r17
  add ram_pos_l, r16
  adc ram_pos_m, r17
  adc ram_pos_h, r17

  out SPDR, r16
  in r17, SPSR
  sbrs r17, SPIF
  rjmp PC-2
  in r17, SPDR
  st Y+, r17
  dec r16
  brne ram_read_bytes
  ret

; read single byte from SRAM, previously set up with ram_read_start
;   r16: byte read
ram_read_byte:
  ldi r16, 1
  add ram_pos_l, r16
  clr r16
  adc ram_pos_m, r16
  adc ram_pos_h, r16

  out SPDR, r16
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2
  in r16, SPDR
  ret

; read two bytes from SRAM, previously set up with ram_read_start
;   r16:r17: byte pair read
ram_read_pair:
  ldi r16, 2
  add ram_pos_l, r16
  clr r16
  adc ram_pos_m, r16
  adc ram_pos_h, r16

  out SPDR, r16
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2
  in r16, SPDR
  out SPDR, r17
  in r17, SPSR
  sbrs r17, SPIF
  rjmp PC-2
  in r17, SPDR
  ret

; write stuff to SRAM, previously set up with ram_write_start
;   r16: number of bytes to write
;   Y: pointer to stuff to write
ram_write_bytes:
  clr r17
  add ram_pos_l, r16
  adc ram_pos_m, r17
  adc ram_pos_h, r17

  ld r17, Y+
  out SPDR, r17
  in r17, SPSR
  sbrs r17, SPIF
  rjmp PC-2
  dec r16
  brne ram_write_bytes
  ret

; write single byte to SRAM, previously set up with ram_write_start
;   r16: byte to write
ram_write_byte:
  out SPDR, r16
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2

  ldi r16, 1
  add ram_pos_l, r16
  clr r16
  adc ram_pos_m, r16
  adc ram_pos_h, r16
  ret

; write two bytse to SRAM, previously set up with ram_write_start
;   r16: first byte to write
;   r17: second byte to write
ram_write_pair:
  out SPDR, r16
  in r16, SPSR
  sbrs r16, SPIF
  rjmp PC-2
  out SPDR, r17
  in r17, SPSR
  sbrs r17, SPIF
  rjmp PC-2

  ldi r16, 2
  add ram_pos_l, r16
  clr r16
  adc ram_pos_m, r16
  adc ram_pos_h, r16
  ret

; skip bytes
;   r16: number to skip
ram_skip_bytes:
  clr r17
  add ram_pos_l, r16
  adc ram_pos_m, r17
  adc ram_pos_h, r17

  out SPDR, r16
  in r17, SPSR
  sbrs r17, SPIF
  rjmp PC-2
  dec r16
  brne ram_skip_bytes
  ret


text_boot_prompt:
  .db 0xd, 0xa, 0xd, 0xa, "[zap] (r)un (l)oad: ", 0
text_unimplemented:
  .db 0xd, 0xa, 0xd, 0xa, "unimplemented!", 0xd, 0xa, 0
text_fatal:
  .db 0xd, 0xa, 0xd, 0xa, "fatal!", 0xd, 0xa, 0
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

text_xmodem_start:
  .db 0xd, 0xa, 0xd, 0xa, "start XMODEM send now", 0xd, 0xa, 0
text_xmodem_timeout:
  .db "timed out", 0xd, 0xa, 0

text_unsupported_version:
  .db 0xd, 0xa, 0xd, 0xa, "unsupported version ", 0

; vim: ft=avr

