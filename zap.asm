; vim: ft=avr

;.device ATmega8
.include "m8def.inc"

; xmodem receive buffer (start of page)
.equ xr_buffer_h = high(0x0100)

; general ram buffer
.equ ram_buffer_h = high(0x0100)

; input buffer
.equ input_buffer     = 0x0060
.equ input_buffer_end = 0x00df


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
  breq zmain

  cpi r17, 'l' ; load
  brne boot

  rcall xmodem_load_ram
  rjmp boot


zmain:
  sbi PORTB, PB0
  rjmp PC


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
  ldi ZH, xr_buffer_h

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
