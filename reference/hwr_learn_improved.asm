SEEDN equ 4369
NPROTO equ 134

; ============================================================================
;  HWR-LEARN  -  Handwriting recognizer that LEARNS FROM YOUR CORRECTIONS
;  16-bit 8086 real mode, MASM 6.x / TASM (VGA mode 12h 640x480, INT 33h mouse)
;
;  Combines the two uploaded programs:
;    [A] EMNIST 8x8 perceptron (62 classes, INT8 weights)   - now TRAINABLE
;    [B] 5x7 multi-prototype matcher (134 prototypes)       - now TRAINABLE
;  plus:
;    [C] Nearest-neighbour memory: 4369 pre-computed 8x8 glyph seeds
;        (font skeletons) + every character YOU correct
;    [D] Fusion of A + B + C, size/baseline/word-context logic for case
;        (c/C, o/O/0, s/S/5, l/I/1 ...), multi-line, spaces, punctuation
;    [E] Click a character -> type the right key -> it is remembered,
;        re-verified against the screen and saved to LEARN.DAT
;
;  Build (MASM 6.11):  ML hwr.asm            (makes HWR.EXE)
;  Build (TASM):        TASM hwr.asm  then  TLINK hwr.obj
;  Run in DOS / DOSBox / FreeDOS / 86Box with a mouse driver.
; ============================================================================
IFDEF ??version
 JUMPS                          ; TASM: allow long conditional jumps
ENDIF
; TESTBUILD is disabled for the normal DOS executable.
; Change this to 1 only when compiling the optional test build.
TESTBUILD equ 0

.model small
.stack 400h

; ------------------------------ layout ---------------------------------------
CANV_Y1     equ 34             ; first drawable canvas row
CANV_Y2     equ 330            ; last drawable canvas row
SEP_TOP     equ 32
SEP_BOT     equ 331
BTN_Y1      equ 440
BTN_Y2      equ 468
YOFF_DEF    equ 0

PENCOL      equ 14             ; ink colour (yellow)
LINECOL     equ 15
GUIDECOL    equ 8
COL_SURE    equ 10
COL_UNSURE  equ 12
COL_SEL     equ 11

; ----------------------------- limits ----------------------------------------
MAXPTS      equ 6000
MAXSTK      equ 200
MAXCH       equ 120
MAXLINES    equ 8
MARGIN      equ 2              ; horizontal merge tolerance (px)
MARGIN_Y    equ 16             ; vertical merge tolerance (dots of i, j, !)
BANKMAX     equ 400
BENT        equ 18             ; bank entry: g8[8] g57[7] class flag aspect
LPROTMAX    equ 64
FBUFSZ      equ 12000

CLS_NOISE   equ 1              ; class code meaning "ignore this blob"

.data
; ---- mouse / drawing state ----
CURX     dw 0
CURY     dw 0
RAWY     dw 0
PREVX    dw 0
PREVY    dw 0
WASDOWN  db 0
STARTFLG db 0
DEBOUNCE db 0
HOLDSKIP db 0                  ; 1 = current press is not a drawing stroke
YOFF     dw YOFF_DEF           ; calibration: pen_y = mouse_y + YOFF
MODE     db 0                  ; 0 AUTO, 1 ABC, 2 abc, 3 123
STATE    db 0                  ; 0 draw, 1 review
SELCH    dw 0FFFFh             ; selected character (index) or FFFF
PTCOUNT  dw 0
PTS      dw MAXPTS*2 dup(0)

; ---- line drawing / rect ----
X0 dw 0
Y0 dw 0
X1 dw 0
Y1 dw 0
DELX dw 0
DELY dw 0
STEPX dw 0
STEPY dw 0
ERRV dw 0
RX1 dw 0
RY1 dw 0
RX2 dw 0
RY2 dw 0
RCOL db 0
TCOL db 15

; ---- stroke grouping ----
NSTK    dw 0
NEND    dw 0
CHG     db 0
GMINX   dw MAXSTK dup(0)
GMAXX   dw MAXSTK dup(0)
GMINY   dw MAXSTK dup(0)
GMAXY   dw MAXSTK dup(0)
GALIVE  dw MAXSTK dup(0)
BMINX dw 0
BMAXX dw 0
BMINY dw 0
BMAXY dw 0
BOXW  dw 0
BOXH  dw 0

; ---- pixel -> grid ----
GNR     dw 8                   ; rows of grid being built
GNC     dw 8                   ; cols
GDIV    dw 350                 ; ink threshold divisor
GLO     dw 2
GHI     dw 14
GOUT    dw 0                   ; offset of output byte array
CELLR dw 0
CELLC dw 0
CELLX1 dw 0
CELLX2 dw 0
CELLY1 dw 0
CELLY2 dw 0
INKCNT dw 0
DYN_INKMIN dw 4
GRID8   db 8 dup(0)
G57     db 8 dup(0)

; ---- per-character results (reading order after SortChars) ----
NCH     dw 0
CX1     dw MAXCH dup(0)
CX2     dw MAXCH dup(0)
CY1     dw MAXCH dup(0)
CY2     dw MAXCH dup(0)
CLINE   db MAXCH dup(0)
CFLAG   db MAXCH dup(0)       ; b0 tall b1 desc b2 tiny b3 dash b4 abs-rule b5 bank-hit
CASP    db MAXCH dup(0)
CRATIO  db MAXCH dup(0)       ; height*100/lineheight (0..255)
CRAW    db MAXCH dup(0)       ; best raw class (ASCII)
CGRPV   db MAXCH dup(0)       ; group id or FF
CMARG   db MAXCH dup(0)       ; fusion margin (capped 255)
CCLS    db MAXCH dup(0)       ; final class (ASCII), CLS_NOISE = ignore
CCONF   db MAXCH dup(0)       ; 0 unsure, 1 sure, 2 taught by user
CWORD   db MAXCH dup(0)
CFIRST  db MAXCH dup(0)
CGRID   db MAXCH*8 dup(0)
CG57    db MAXCH*8 dup(0)
TMPW    dw 0
TMPI    dw 0

; ---- lines ----
NLINE   dw 0
LY1     dw MAXLINES dup(0)
LY2     dw MAXLINES dup(0)
LRANK   db MAXLINES dup(0)
LR      dw MAXLINES dup(0)    ; tallest real glyph height in the line
LHMIN   dw MAXLINES dup(0)    ; shortest real glyph height
LBASE   dw MAXLINES dup(0)    ; baseline (median bottom)
LGAP    dw MAXLINES dup(0)    ; space threshold
SORTV   dw MAXCH dup(0)
SORTH   dw MAXCH dup(0)
DCUR    db 8 dup(0)           ; current 8x8 grid dilated by one cell
DSTO    db 8 dup(0)           ; stored grid dilated by one cell
DTMP    db 8 dup(0)       ; sorted glyph heights of one line (robust reference)
LX      dw MAXLINES dup(0)    ; x-height estimate per line (0 = unknown)
LC      dw MAXLINES dup(0)    ; capital-height estimate per line
MODEP   db 0
REFUSED db 0
REFBORD db 0

; ---- scoring scratch ----
DK      db 128 dup(0)
DPR      db 128 dup(0)
PSC     dw 64 dup(0)
PSMAX   dw 0
POPT    db 256 dup(0)
NLEFT   dw 0
BESTC   db 0
BESTF   dw 0
BEST2F  dw 0
BANKHIT db 0
BKD     db 0
BKC     db 0
CURFLAG db 0                   ; flags of the character being scored
CURASP  db 0                   ; aspect (w*16/h) of the character being scored
MARG    dw 0
FOUND   db 0
UNIFORM db 0

; ---- learned memory ----
BANK    db BANKMAX*BENT dup(0) ; 8x8 grid, 5x7 grid, class, flag, aspect
NBANK   dw 0
BANKNXT dw 0
LPROT   db LPROTMAX*8 dup(0)   ; 7 rows + class
NLPROT  dw 0
LPNXT   dw 0
CASE_T  dw 68                  ; relative height % deciding "tall"
ABS_T   dw 42                  ; absolute px deciding "tall" in uniform lines
WTS     db 62*64 dup(0)        ; live perceptron weights (INT8)
BIAS    dw 62 dup(0)
NTAUGHT dw 0                   ; corrections this session
CHKSUM  dw 0
LOADOK  db 0

; ---- word / output ----
NOUT    dw 0
OUTCH   db MAXCH*2+8 dup(0)
OUTIDX  dw MAXCH*2+8 dup(0)
NUNSURE dw 0
SAVEHND dw 0
FBUF    db FBUFSZ dup(0)

; ---- text ----
msgTitle  db 'HWR-LEARN  handwriting OCR that learns from you',0
msgModeA  db 'Mode:AUTO ',0
msgModeC  db 'Mode:ABC  ',0
msgModeS  db 'Mode:abc  ',0
msgModeN  db 'Mode:123  ',0
btnRead   db 'READ',0
btnUndo   db 'UNDO',0
btnClear  db 'CLEAR',0
btnExit   db 'EXIT',0
lblAuto   db 'MODE: AUTO',0
lblCaps   db 'MODE: ABC ',0
lblSmall  db 'MODE: abc ',0
lblNums   db 'MODE: 123 ',0
msgNoMs   db 'Mouse/touch driver not found. Load a DOS mouse driver (e.g. CTMOUSE) and run again.',13,10,'$'
msgNoVga  db 'VGA mode 12h (640x480x16) is not available on this display.',13,10,'$'
msgHelp   db 'Draw with left button. READ, then click a char and type the right key. F1 help',0
msgReady  db 'Ready. Write text on the lines, then press READ (or Enter).',0
msgNoInk  db 'Nothing to read - draw some letters or digits first.',0
msgCleared db 'Canvas cleared.',0
msgSaved  db 'Learning saved to LEARN.DAT',0
msgSaveFail db 'Could not write LEARN.DAT (disk full or read-only?)',0
msgLoaded db 'Loaded your learned corrections from LEARN.DAT',0
msgBadFile db 'LEARN.DAT damaged - ignored, starting fresh',0
msgForget db 'Forget ALL learning? Press Y to confirm, any other key cancels',0
msgForgot db 'All learning erased - back to factory memory',0
msgCancel db 'Cancelled',0
msgSelA   db 'Char ',0
msgSelB   db ' selected = ',0
msgSelC   db '   Type the correct key, ENTER=confirm, DEL=ignore, arrows=move',0
msgNoSel  db 'Click a character box first, then type its correct key',0
msgLearnA db 'LEARNED: ',0
msgVerOK  db '  -> re-read from screen: VERIFIED',0
msgVerBad db '  -> still differs: looks like another taught letter, write it a bit more distinctly',0
msgNoiseA db 'Ignored that blob and will ignore similar blobs',0
msgConfA  db 'Confirmed and reinforced: ',0
msgYoff   db 'Pen offset (F2/F3) = ',0
msgRes    db 'RECOGNIZED TEXT ',0
msgChars  db ' chars, ',0
msgUnsure db ' red = unsure',0
fnLearn   db 'LEARN.DAT',0
fnText    db 'TEXT.OUT',0
magic     db 'HWR3'
msgHelp1  db 'F1 help | F2/F3 pen offset | F4 forget all | F5 save | F6 read | F7 undo | F8 clear | F9 mode | F10 exit',0
msgNumBuf db 8 dup(0)
CRLF2     db 13,10
BTNX1 dw 8,126,224,322,530
BTNX2 dw 118,216,314,452,630
msgTeachN db 'taught:',0
ROWN db 0
COLN db 0
GRP label byte
 db 255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
 db 255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
 db 255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
 db 3,12,11,255,255,5,255,255,13,255,255,255,255,255,255,255
 db 255,255,13,0,255,255,255,255,255,12,255,1,255,2,255,3
 db 4,255,255,5,255,6,7,8,9,10,11,255,255,255,255,255
 db 255,255,255,0,255,255,255,255,255,255,255,1,12,2,255,3
 db 4,255,255,5,255,6,7,8,9,10,11,255,255,255,255,255
GRPMEM label byte
 db 67,99,0
 db 75,107,0
 db 77,109,0
 db 79,111,48
 db 80,112,0
 db 83,115,53
 db 85,117,0
 db 86,118,0
 db 87,119,0
 db 88,120,0
 db 89,121,0
 db 90,122,50
 db 73,108,49
 db 66,0,56


.code
; ============================================================================
;                                   MAIN
; ============================================================================
main proc
    mov  ax, @data
    mov  ds, ax
    mov  ax, 0012h                 ; 640x480x16
    int  10h
    mov  ah, 0Fh                   ; verify the mode really is active
    int  10h
    cmp  al, 12h
    je   mn_vga_ok
    mov  ax, 0003h
    int  10h
    mov  dx, offset msgNoVga
    jmp  mn_fail
mn_vga_ok:
    xor  ax, ax                    ; mouse / touch driver present?
    int  33h
    cmp  ax, 0
    jne  mn_mouse_ok
    mov  ax, 0003h
    int  10h
    mov  dx, offset msgNoMs
mn_fail:
    mov  ah, 9
    int  21h
    jmp  mn_exit
mn_mouse_ok:
    mov  ax, 7                     ; X range
    xor  cx, cx
    mov  dx, 639
    int  33h
    mov  ax, 8                     ; Y range
    xor  cx, cx
    mov  dx, 479
    int  33h
    call InitPop
    call ResetModel
    call LoadLearn
    call DrawScreen
IF TESTBUILD
    call TestRun
    jmp  quit
ENDIF
    mov  ax, 1
    int  33h

poll:
    call KeyPoll
    cmp  al, 1
    jne  pl_mouse
    jmp  quit
pl_mouse:
    mov  ax, 3
    int  33h
    mov  RAWY, dx
    add  dx, YOFF
    jge  pl_yok
    xor  dx, dx
pl_yok:
    mov  CURX, cx
    mov  CURY, dx
    test bx, 1
    jnz  pl_down
    cmp  DEBOUNCE, 3               ; button must stay up for 3 polls
    jae  pl_deb_done
    inc  DEBOUNCE
pl_deb_done:
    cmp  DEBOUNCE, 3
    jb   poll
    mov  WASDOWN, 0
    mov  HOLDSKIP, 0
    jmp  poll
pl_down:
    mov  DEBOUNCE, 0
    cmp  WASDOWN, 1
    jne  pl_new
    cmp  HOLDSKIP, 1
    je   poll
    call DoDraw
    jmp  poll
pl_new:
    call HandlePress               ; AL: 0 handled, 1 start stroke, 2 quit
    cmp  al, 2
    jne  pl_n1
    jmp  quit
pl_n1:
    cmp  al, 1
    je   pl_draw
    mov  WASDOWN, 1
    mov  HOLDSKIP, 1
    jmp  poll
pl_draw:
    mov  HOLDSKIP, 0
    call DoDraw
    jmp  poll

quit:
    call SaveLearn                 ; never lose what was learned
    mov  ax, 2
    int  33h
    mov  ax, 0003h
    int  10h
    xor  ax, ax
    int  33h
mn_exit:
    mov  ax, 4C00h
    int  21h
main endp

; ----------------------------------------------------------------------------
;  HandlePress : a new left-button press.   AL = 0 done, 1 begin stroke, 2 quit
; ----------------------------------------------------------------------------

HandlePress proc
    push bx
    push cx
    push si
    mov  ax, RAWY
    cmp  ax, BTN_Y1
    jb   hp_canvas
    cmp  ax, BTN_Y2
    ja   hp_canvas
    xor  si, si
    xor  bx, bx
hp_btn:
    mov  ax, CURX
    cmp  ax, BTNX1[bx]
    jb   hp_next
    cmp  ax, BTNX2[bx]
    ja   hp_next
    cmp  si, 0
    jne  hp_b1
    call DoRead
    jmp  hp_done0
hp_b1:
    cmp  si, 1
    jne  hp_b2
    call DoUndo
    jmp  hp_done0
hp_b2:
    cmp  si, 2
    jne  hp_b3
    call DoClear
    jmp  hp_done0
hp_b3:
    cmp  si, 3
    jne  hp_b4
    call DoMode
    jmp  hp_done0
hp_b4:
    mov  al, 2
    jmp  hp_ret
hp_next:
    add  bx, 2
    inc  si
    cmp  si, 5
    jb   hp_btn
hp_done0:
    mov  al, 0
    jmp  hp_ret
hp_canvas:
    mov  ax, CURY
    cmp  ax, CANV_Y1
    jb   hp_done0
    cmp  ax, CANV_Y2
    ja   hp_done0
    cmp  STATE, 1
    jne  hp_stroke
    call HitChar                   ; AX = char index or FFFF
    cmp  ax, 0FFFFh
    je   hp_leave
    mov  SELCH, ax
    call ShowReview
    jmp  hp_done0
hp_leave:
    mov  STATE, 0                  ; new ink: leave review mode
    mov  SELCH, 0FFFFh
    mov  ax, 2
    int  33h
    call Redraw
    call ShowTitle
    mov  ax, 1
    int  33h
hp_stroke:
    mov  al, 1
hp_ret:
    pop  si
    pop  cx
    pop  bx
    ret
HandlePress endp

; ----------------------------------------------------------------------------
;  KeyPoll : keyboard shortcuts / correction typing.  AL = 1 -> quit
; ----------------------------------------------------------------------------
KeyPoll proc
    push bx
    push cx
    push dx
    mov  ah, 1
    int  16h
    jnz  kp_have
    jmp  kp_none
kp_have:
    xor  ah, ah
    int  16h
    cmp  al, 0
    je   kp_ext
    cmp  al, 0E0h
    je   kp_ext
    cmp  al, 27
    je   kp_esc
    cmp  al, 13
    je   kp_enter
    cmp  al, 8
    je   kp_noise
    cmp  al, 1Ah                   ; Ctrl+Z
    jne  kp_c1
    call DoUndo
    jmp  kp_none
kp_c1:
    cmp  al, 20h
    je   kp_noise
    jb   kp_none
    cmp  al, 7Eh
    ja   kp_none
    mov  dl, al                    ; a printable key = the correct character
    cmp  SELCH, 0FFFFh
    jne  kp_teach
    mov  si, offset msgNoSel
    call SetStatus
    jmp  kp_none
kp_teach:
    mov  ax, SELCH
    call TeachChar                 ; AX = char index, DL = correct ASCII
    jmp  kp_none
kp_noise:
    cmp  SELCH, 0FFFFh
    je   kp_none
    mov  ax, SELCH
    mov  dl, CLS_NOISE
    call TeachChar
    jmp  kp_none
kp_enter:
    cmp  STATE, 1
    jne  kp_read
    cmp  SELCH, 0FFFFh
    je   kp_read
    mov  ax, SELCH                 ; confirm the shown prediction
    mov  bx, ax
    mov  dl, CCLS[bx]
    call TeachChar
    jmp  kp_none
kp_read:
    call DoRead
    jmp  kp_none
kp_esc:
    cmp  SELCH, 0FFFFh
    je   kp_quit
    mov  SELCH, 0FFFFh
    call ShowReview
    jmp  kp_none
kp_ext:
    mov  al, ah
    cmp  al, 3Bh                   ; F1 help
    jne  kp_f2
    mov  si, offset msgHelp1
    call SetStatus
    jmp  kp_none
kp_f2:
    cmp  al, 3Ch                   ; F2 pen offset -1
    jne  kp_f3
    dec  YOFF
    call ShowYoff
    jmp  kp_none
kp_f3:
    cmp  al, 3Dh                   ; F3 pen offset +1
    jne  kp_f4
    inc  YOFF
    call ShowYoff
    jmp  kp_none
kp_f4:
    cmp  al, 3Eh                   ; F4 forget everything
    jne  kp_f5
    call DoForget
    jmp  kp_none
kp_f5:
    cmp  al, 3Fh                   ; F5 save
    jne  kp_f6
    call SaveLearn
    mov  si, offset msgSaved
    cmp  LOADOK, 3
    je   kp_f5s
    mov  si, offset msgSaveFail
kp_f5s:
    call SetStatus
    jmp  kp_none
kp_f6:
    cmp  al, 40h
    jne  kp_f7
    call DoRead
    jmp  kp_none
kp_f7:
    cmp  al, 41h
    jne  kp_f8
    call DoUndo
    jmp  kp_none
kp_f8:
    cmp  al, 42h
    jne  kp_f9
    call DoClear
    jmp  kp_none
kp_f9:
    cmp  al, 43h
    jne  kp_f10
    call DoMode
    jmp  kp_none
kp_f10:
    cmp  al, 44h
    je   kp_quit
    cmp  al, 4Bh                   ; left arrow
    jne  kp_right
    call SelPrev
    jmp  kp_none
kp_right:
    cmp  al, 4Dh
    jne  kp_del
    call SelNext
    jmp  kp_none
kp_del:
    cmp  al, 53h                   ; Delete = ignore this blob
    jne  kp_none
    jmp  kp_noise
kp_quit:
    mov  al, 1
    jmp  kp_ret
kp_none:
    mov  al, 0
kp_ret:
    pop  dx
    pop  cx
    pop  bx
    ret
KeyPoll endp

; ---- selection movement ----
SelPrev proc
    cmp  STATE, 1
    jne  sp_ret
    cmp  NCH, 0
    je   sp_ret
    mov  ax, SELCH
    cmp  ax, 0FFFFh
    jne  sp_p1
    mov  ax, NCH
    dec  ax
    jmp  sp_set
sp_p1:
    cmp  ax, 0
    je   sp_ret
    dec  ax
sp_set:
    mov  SELCH, ax
    call ShowReview
sp_ret:
    ret
SelPrev endp

SelNext proc
    cmp  STATE, 1
    jne  sn_ret
    cmp  NCH, 0
    je   sn_ret
    mov  ax, SELCH
    cmp  ax, 0FFFFh
    jne  sn_p1
    xor  ax, ax
    jmp  sn_set
sn_p1:
    inc  ax
    cmp  ax, NCH
    jb   sn_set
    jmp  sn_ret
sn_set:
    mov  SELCH, ax
    call ShowReview
sn_ret:
    ret
SelNext endp

; ----------------------------------------------------------------------------
;  HitChar : which recognised character box contains the pointer?  AX / FFFF
; ----------------------------------------------------------------------------
HitChar proc
    push bx
    push cx
    push dx
    push si
    mov  dx, 0FFFFh                ; best area
    mov  TMPI, 0FFFFh
    xor  si, si
hc_lp:
    cmp  si, NCH
    jae  hc_done
    mov  bx, si
    shl  bx, 1
    mov  ax, CX1[bx]
    sub  ax, 4
    cmp  CURX, ax
    jl   hc_nx
    mov  ax, CX2[bx]
    add  ax, 4
    cmp  CURX, ax
    jg   hc_nx
    mov  ax, CY1[bx]
    sub  ax, 4
    cmp  CURY, ax
    jl   hc_nx
    mov  ax, CY2[bx]
    add  ax, 4
    cmp  CURY, ax
    jg   hc_nx
    mov  ax, CX2[bx]               ; area ~ w*h (smaller box wins)
    sub  ax, CX1[bx]
    inc  ax
    mov  cx, CY2[bx]
    sub  cx, CY1[bx]
    inc  cx
    push dx
    mul  cx
    mov  cx, ax
    pop  dx
    cmp  cx, dx
    jae  hc_nx
    mov  dx, cx
    mov  TMPI, si
hc_nx:
    inc  si
    jmp  hc_lp
hc_done:
    mov  ax, TMPI
    pop  si
    pop  dx
    pop  cx
    pop  bx
    ret
HitChar endp

; ============================================================================
;                          DRAWING (ink on the canvas)
; ============================================================================
DoDraw proc
    push ax
    mov  ax, CURY
    cmp  ax, CANV_Y1
    jb   dd_out
    cmp  ax, CANV_Y2
    jbe  dd_inside
dd_out:
    mov  WASDOWN, 0
    jmp  dd_ret
dd_inside:
    cmp  PTCOUNT, MAXPTS
    jb   dd_room
    jmp  dd_ret
dd_room:
    cmp  WASDOWN, 0
    jne  dd_cont
    mov  ax, CURX
    mov  PREVX, ax
    mov  ax, CURY
    mov  PREVY, ax
    mov  STARTFLG, 1
    jmp  dd_record
dd_cont:
    mov  ax, CURX
    cmp  ax, PREVX
    jne  dd_moved
    mov  ax, CURY
    cmp  ax, PREVY
    jne  dd_moved
    jmp  dd_ret
dd_moved:
    mov  STARTFLG, 0
dd_record:
    call AddPoint
    mov  ax, PREVX
    mov  X0, ax
    mov  ax, PREVY
    mov  Y0, ax
    mov  ax, CURX
    mov  X1, ax
    mov  ax, CURY
    mov  Y1, ax
    mov  ax, 2
    int  33h
    call DrawLine
    mov  ax, 1
    int  33h
    mov  ax, CURX
    mov  PREVX, ax
    mov  ax, CURY
    mov  PREVY, ax
    mov  WASDOWN, 1
dd_ret:
    pop  ax
    ret
DoDraw endp

AddPoint proc
    push ax
    push bx
    mov  bx, PTCOUNT
    shl  bx, 1
    shl  bx, 1
    mov  ax, CURX
    mov  PTS[bx], ax
    mov  ax, CURY
    cmp  STARTFLG, 0
    je   ap_store
    or   ax, 8000h                 ; bit 15 = first point of a stroke
ap_store:
    mov  PTS[bx+2], ax
    inc  PTCOUNT
    pop  bx
    pop  ax
    ret
AddPoint endp

DoUndo proc                        ; removes the last stroke
    push ax
    push bx
    mov  ax, 2
    int  33h
    mov  bx, PTCOUNT
un_find:
    cmp  bx, 0
    je   un_set
    dec  bx
    push bx
    shl  bx, 1
    shl  bx, 1
    test word ptr PTS[bx+2], 8000h
    pop  bx
    jz   un_find
un_set:
    mov  PTCOUNT, bx
    mov  STATE, 0
    mov  SELCH, 0FFFFh
    call Redraw
    call ShowTitle
    mov  ax, 1
    int  33h
    pop  bx
    pop  ax
    ret
DoUndo endp

DoClear proc
    push ax
    push si
    mov  ax, 2
    int  33h
    mov  PTCOUNT, 0
    mov  NCH, 0
    mov  STATE, 0
    mov  SELCH, 0FFFFh
    call Redraw
    call ClearOutputPanel
    mov  si, offset msgCleared
    call SetStatus
    call ShowTitle
    mov  ax, 1
    int  33h
    pop  si
    pop  ax
    ret
DoClear endp

DoMode proc
    push ax
    mov  ax, 2
    int  33h
    inc  MODE
    cmp  MODE, 4
    jb   dm_ok
    mov  MODE, 0
dm_ok:
    call DrawModeBtn
    call ShowTitle
    mov  ax, 1
    int  33h
    pop  ax
    ret
DoMode endp

ShowYoff proc
    push ax
    push si
    mov  ax, 2
    int  33h
    mov  si, offset msgYoff
    mov  ax, YOFF
    call SetStatusNum
    mov  ax, 1
    int  33h
    pop  si
    pop  ax
    ret
ShowYoff endp

; ----------------------------------------------------------------------------
;  Redraw : clear canvas, guides, replay every stroke
; ----------------------------------------------------------------------------
Redraw proc
    push ax
    push bx
    push cx
    push dx
    push si
    call ClearCanvas
    call DrawFrame
    xor  si, si
rd_loop:
    cmp  si, PTCOUNT
    jb   rd_body
    jmp  rd_done
rd_body:
    mov  bx, si
    shl  bx, 1
    shl  bx, 1
    mov  ax, PTS[bx]
    mov  X1, ax
    mov  ax, PTS[bx+2]
    mov  cx, ax
    and  ax, 7FFFh
    mov  Y1, ax
    test cx, 8000h
    jz   rd_draw
    mov  ax, X1
    mov  X0, ax
    mov  ax, Y1
    mov  Y0, ax
rd_draw:
    call DrawLine
    inc  si
    jmp  rd_loop
rd_done:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
Redraw endp

ClearCanvas proc                   ; BIOS scroll-clear: text rows 2..20
    push ax
    push bx
    push cx
    push dx
    mov  ax, 0600h
    mov  bh, 0
    mov  cx, 0200h
    mov  dx, 144Fh
    int  10h
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ClearCanvas endp

ClearOutputPanel proc              ; text rows 21..26
    push ax
    push bx
    push cx
    push dx
    mov  ax, 0600h
    mov  bh, 0
    mov  cx, 1500h
    mov  dx, 1A4Fh
    int  10h
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ClearOutputPanel endp

DrawFrame proc                     ; separators + dotted writing guides
    push ax
    push bx
    push cx
    push dx
    mov  RX1, 0
    mov  RX2, 639
    mov  RCOL, LINECOL
    mov  RY1, SEP_TOP
    mov  RY2, SEP_TOP
    call FillRect
    mov  RY1, SEP_BOT
    mov  RY2, SEP_BOT
    call FillRect
    mov  bx, 118                   ; guide baselines
df_g:
    xor  cx, cx
df_x:
    mov  dx, bx
    mov  al, GUIDECOL
    call PutPix
    add  cx, 4
    cmp  cx, 640
    jb   df_x
    add  bx, 100
    cmp  bx, 330
    jbe  df_g
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawFrame endp

; ----------------------------------------------------------------------------
;  DrawScreen / title / buttons
; ----------------------------------------------------------------------------
DrawScreen proc
    push ax
    push si
    call Redraw
    call DrawButtons
    call ClearOutputPanel
    call ShowTitle
    mov  si, offset msgReady
    cmp  LOADOK, 1
    jne  ds_b
    mov  si, offset msgLoaded
ds_b:
    cmp  LOADOK, 2
    jne  ds_say
    mov  si, offset msgBadFile
ds_say:
    call SetStatus
    pop  si
    pop  ax
    ret
DrawScreen endp

ShowTitle proc
    push ax
    push dx
    push si
    mov  RX1, 0
    mov  RY1, 0
    mov  RX2, 639
    mov  RY2, 15
    mov  RCOL, 0
    call FillRect
    mov  TCOL, 15
    mov  dh, 0
    mov  dl, 1
    mov  si, offset msgTitle
    call PrintStr
    mov  TCOL, 11
    mov  dh, 0
    mov  dl, 50
    mov  si, offset msgModeA
    cmp  MODE, 1
    jne  st_m2
    mov  si, offset msgModeC
st_m2:
    cmp  MODE, 2
    jne  st_m3
    mov  si, offset msgModeS
st_m3:
    cmp  MODE, 3
    jne  st_m4
    mov  si, offset msgModeN
st_m4:
    call PrintStr
    mov  TCOL, 10
    mov  dh, 0
    mov  dl, 62
    mov  si, offset msgTeachN
    call PrintStr
    mov  ax, NBANK
    call PrintNum
    pop  si
    pop  dx
    pop  ax
    ret
ShowTitle endp

DrawButtons proc
    push ax
    push dx
    push si
    mov  RY1, BTN_Y1
    mov  RY2, BTN_Y2
    mov  RX1, 8
    mov  RX2, 118
    mov  RCOL, 2
    call FillRect
    mov  RX1, 126
    mov  RX2, 216
    mov  RCOL, 1
    call FillRect
    mov  RX1, 224
    mov  RX2, 314
    mov  RCOL, 5
    call FillRect
    mov  RX1, 530
    mov  RX2, 630
    mov  RCOL, 4
    call FillRect
    mov  TCOL, 15
    mov  dh, 28
    mov  dl, 6
    mov  si, offset btnRead
    call PrintStr
    mov  dh, 28
    mov  dl, 18
    mov  si, offset btnUndo
    call PrintStr
    mov  dh, 28
    mov  dl, 29
    mov  si, offset btnClear
    call PrintStr
    mov  dh, 28
    mov  dl, 69
    mov  si, offset btnExit
    call PrintStr
    call DrawModeBtn
    pop  si
    pop  dx
    pop  ax
    ret
DrawButtons endp

DrawModeBtn proc
    push ax
    push dx
    push si
    mov  RY1, BTN_Y1
    mov  RY2, BTN_Y2
    mov  RX1, 322
    mov  RX2, 452
    mov  RCOL, 3
    call FillRect
    mov  TCOL, 15
    mov  si, offset lblAuto
    cmp  MODE, 1
    jne  mb1
    mov  si, offset lblCaps
mb1:
    cmp  MODE, 2
    jne  mb2
    mov  si, offset lblSmall
mb2:
    cmp  MODE, 3
    jne  mb3
    mov  si, offset lblNums
mb3:
    mov  dh, 28
    mov  dl, 42
    call PrintStr
    pop  si
    pop  dx
    pop  ax
    ret
DrawModeBtn endp

; ----------------------------------------------------------------------------
;  Status line (text row 1)
; ----------------------------------------------------------------------------
SetStatus proc                     ; SI = ASCIIZ
    push ax
    push dx
    mov  RX1, 0
    mov  RY1, 16
    mov  RX2, 639
    mov  RY2, 31
    mov  RCOL, 0
    call FillRect
    mov  TCOL, 14
    mov  dh, 1
    mov  dl, 1
    call PrintStr
    pop  dx
    pop  ax
    ret
SetStatus endp

SetStatusNum proc                  ; SI = text, AX = signed number
    push ax
    push dx
    push ax
    mov  RX1, 0
    mov  RY1, 16
    mov  RX2, 639
    mov  RY2, 31
    mov  RCOL, 0
    call FillRect
    mov  TCOL, 14
    mov  dh, 1
    mov  dl, 1
    call PrintStr
    pop  ax
    cmp  ax, 0
    jge  ssn_pos
    push ax
    mov  al, '-'
    mov  bl, 14
    call PrintChar
    pop  ax
    neg  ax
ssn_pos:
    call PrintNum
    pop  dx
    pop  ax
    ret
SetStatusNum endp

; ============================================================================
;                          LOW LEVEL VIDEO HELPERS
; ============================================================================
PutPix proc                        ; CX = x, DX = y, AL = colour
    push ax
    push bx
    mov  ah, 0Ch
    xor  bh, bh
    int  10h
    pop  bx
    pop  ax
    ret
PutPix endp

FillRect proc
    push ax
    push bx
    push cx
    push dx
    mov  dx, RY1
fr_row:
    mov  cx, RX1
fr_col:
    mov  ah, 0Ch
    mov  al, RCOL
    xor  bh, bh
    int  10h
    inc  cx
    cmp  cx, RX2
    jbe  fr_col
    inc  dx
    cmp  dx, RY2
    jbe  fr_row
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
FillRect endp

DrawBox proc                       ; outline RX1,RY1,RX2,RY2 in RCOL
    push ax
    push bx
    push cx
    push dx
    mov  ax, RX1
    mov  bx, RY1
    mov  cx, RX2
    mov  dx, RY2
    push ax
    push bx
    push cx
    push dx
    mov  RY2, bx                   ; top edge
    call FillRect
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    push ax
    push bx
    push cx
    push dx
    mov  RY1, dx                   ; bottom edge
    call FillRect
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    push ax
    push bx
    push cx
    push dx
    mov  RX2, ax                   ; left edge
    call FillRect
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    mov  RX1, cx                   ; right edge
    call FillRect
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DrawBox endp

PrintStr proc                      ; DH row, DL col, SI string, TCOL colour
    push ax
    push bx
    push si
    mov  ah, 2
    xor  bh, bh
    int  10h
ps_next:
    lodsb
    cmp  al, 0
    je   ps_done
    mov  ah, 0Eh
    xor  bh, bh
    mov  bl, TCOL
    int  10h
    jmp  ps_next
ps_done:
    pop  si
    pop  bx
    pop  ax
    ret
PrintStr endp

PrintChar proc                     ; AL = char, BL = colour (cursor already set)
    push ax
    push bx
    mov  ah, 0Eh
    int  10h
    pop  bx
    pop  ax
    ret
PrintChar endp

PrintNum proc                      ; AX unsigned, printed in colour TCOL at cursor
    push ax
    push bx
    push cx
    push dx
    xor  cx, cx
    mov  bx, 10
pn_div:
    xor  dx, dx
    div  bx
    push dx
    inc  cx
    cmp  ax, 0
    jne  pn_div
pn_out:
    pop  dx
    mov  al, dl
    add  al, '0'
    mov  bl, TCOL
    mov  ah, 0Eh
    int  10h
    loop pn_out
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
PrintNum endp

PlotPt proc                        ; 2x2 pen nib at X0,Y0
    push ax
    push bx
    push cx
    push dx
    mov  al, PENCOL
    mov  cx, X0
    mov  dx, Y0
    call PutPix
    inc  cx
    call PutPix
    inc  dx
    call PutPix
    dec  cx
    call PutPix
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
PlotPt endp

DrawLine proc                      ; Bresenham from (X0,Y0) to (X1,Y1)
    push ax
    push bx
    push cx
    mov  ax, X1
    sub  ax, X0
    mov  STEPX, 1
    jge  dl_dx
    neg  ax
    mov  STEPX, -1
dl_dx:
    mov  DELX, ax
    mov  ax, Y1
    sub  ax, Y0
    mov  STEPY, 1
    jge  dl_dy
    neg  ax
    mov  STEPY, -1
dl_dy:
    mov  DELY, ax
    mov  ax, DELX
    sub  ax, DELY
    mov  ERRV, ax
dl_loop:
    call PlotPt
    mov  ax, X0
    cmp  ax, X1
    jne  dl_cont
    mov  ax, Y0
    cmp  ax, Y1
    je   dl_done
dl_cont:
    mov  bx, ERRV
    shl  bx, 1
    mov  cx, DELY
    neg  cx
    cmp  bx, cx
    jle  dl_s1
    mov  ax, DELY
    sub  ERRV, ax
    mov  ax, STEPX
    add  X0, ax
dl_s1:
    cmp  bx, DELX
    jge  dl_s2
    mov  ax, DELX
    add  ERRV, ax
    mov  ax, STEPY
    add  Y0, ax
dl_s2:
    jmp  dl_loop
dl_done:
    pop  cx
    pop  bx
    pop  ax
    ret
DrawLine endp


; ============================================================================
;                           RECOGNITION ENGINE
; ============================================================================

InitPop proc                       ; POPT[i] = number of set bits of i
    push ax
    push bx
    push cx
    push dx
    xor  bx, bx
ip_lp:
    mov  ax, bx
    xor  dl, dl
    mov  cx, 8
ip_b:
    shr  al, 1
    adc  dl, 0
    loop ip_b
    mov  POPT[bx], dl
    inc  bx
    cmp  bx, 256
    jb   ip_lp
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
InitPop endp

; ----------------------------------------------------------------------------
;  Recognize : screen (strokes already redrawn) -> NCH characters, text
; ----------------------------------------------------------------------------
Recognize proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  NCH, 0
    mov  NOUT, 0
    mov  NUNSURE, 0
    call BuildStrokes
    mov  ax, NSTK
    shl  ax, 1
    mov  NEND, ax
    call MergeGroups
    call CollectChars
    cmp  NCH, 0
    je   rc_done
    call AssignLines
    call SortChars
    call LineStats
    call ClassifyAll
    call LineRefs
    call WordSeg
    call ResolveAll
    call BuildOutput
rc_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
Recognize endp

; ---------------------------- stroke bounding boxes -------------------------
BuildStrokes proc
    push ax
    push bx
    push cx
    push si
    push di
    mov  NSTK, 0
    xor  si, si
bs_loop:
    cmp  si, PTCOUNT
    jb   bs_body
    jmp  bs_done
bs_body:
    mov  bx, si
    shl  bx, 1
    shl  bx, 1
    mov  ax, PTS[bx]
    mov  cx, PTS[bx+2]
    test cx, 8000h
    jz   bs_extend
    and  cx, 7FFFh
    cmp  NSTK, MAXSTK
    jb   bs_new
    jmp  bs_done
bs_new:
    mov  di, NSTK
    shl  di, 1
    mov  GMINX[di], ax
    mov  GMAXX[di], ax
    mov  GMINY[di], cx
    mov  GMAXY[di], cx
    mov  GALIVE[di], 1
    inc  NSTK
    jmp  bs_next
bs_extend:
    cmp  NSTK, 0
    je   bs_next
    and  cx, 7FFFh
    mov  di, NSTK
    dec  di
    shl  di, 1
    cmp  ax, GMINX[di]
    jge  bs_a
    mov  GMINX[di], ax
bs_a:
    cmp  ax, GMAXX[di]
    jle  bs_b
    mov  GMAXX[di], ax
bs_b:
    cmp  cx, GMINY[di]
    jge  bs_c
    mov  GMINY[di], cx
bs_c:
    cmp  cx, GMAXY[di]
    jle  bs_next
    mov  GMAXY[di], cx
bs_next:
    inc  si
    jmp  bs_loop
bs_done:
    pop  di
    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
BuildStrokes endp

MergeGroups proc                   ; merge strokes whose boxes touch (one glyph)
    push ax
    push si
    push di
mg_again:
    mov  CHG, 0
    xor  si, si
mg_i:
    cmp  si, NEND
    jb   mg_ichk
    jmp  mg_chk
mg_ichk:
    cmp  GALIVE[si], 0
    jne  mg_istart
    jmp  mg_inext
mg_istart:
    mov  di, si
    add  di, 2
mg_j:
    cmp  di, NEND
    jae  mg_inext
    cmp  GALIVE[di], 0
    je   mg_jnext
    call Overlap
    cmp  al, 1
    jne  mg_jnext
    call UnionJ
mg_jnext:
    add  di, 2
    jmp  mg_j
mg_inext:
    add  si, 2
    jmp  mg_i
mg_chk:
    cmp  CHG, 0
    je   mg_done
    jmp  mg_again
mg_done:
    pop  di
    pop  si
    pop  ax
    ret
MergeGroups endp

Overlap proc
    mov  ax, GMAXX[si]
    add  ax, MARGIN
    cmp  GMINX[di], ax
    jg   ov_no
    mov  ax, GMAXX[di]
    add  ax, MARGIN
    cmp  GMINX[si], ax
    jg   ov_no
    mov  ax, GMAXY[si]
    add  ax, MARGIN_Y
    cmp  GMINY[di], ax
    jg   ov_no
    mov  ax, GMAXY[di]
    add  ax, MARGIN_Y
    cmp  GMINY[si], ax
    jg   ov_no
    mov  al, 1
    ret
ov_no:
    mov  al, 0
    ret
Overlap endp

UnionJ proc
    push ax
    mov  ax, GMINX[di]
    cmp  ax, GMINX[si]
    jge  uj1
    mov  GMINX[si], ax
uj1:
    mov  ax, GMAXX[di]
    cmp  ax, GMAXX[si]
    jle  uj2
    mov  GMAXX[si], ax
uj2:
    mov  ax, GMINY[di]
    cmp  ax, GMINY[si]
    jge  uj3
    mov  GMINY[si], ax
uj3:
    mov  ax, GMAXY[di]
    cmp  ax, GMAXY[si]
    jle  uj4
    mov  GMAXY[si], ax
uj4:
    mov  GALIVE[di], 0
    mov  CHG, 1
    pop  ax
    ret
UnionJ endp

; ------------------------------- character list -----------------------------
CollectChars proc
    push ax
    push bx
    push si
    mov  NCH, 0
    xor  si, si
cc_lp:
    cmp  si, NEND
    jae  cc_done
    cmp  GALIVE[si], 0
    je   cc_nx
    cmp  NCH, MAXCH
    jae  cc_done
    mov  bx, NCH
    shl  bx, 1
    mov  ax, GMINX[si]
    mov  CX1[bx], ax
    mov  ax, GMAXX[si]
    inc  ax
    mov  CX2[bx], ax
    mov  ax, GMINY[si]
    mov  CY1[bx], ax
    mov  ax, GMAXY[si]
    inc  ax
    mov  CY2[bx], ax
    inc  NCH
cc_nx:
    add  si, 2
    jmp  cc_lp
cc_done:
    pop  si
    pop  bx
    pop  ax
    ret
CollectChars endp

GetWH proc                         ; DI = char -> AX = width, CX = height, BX = di*2
    mov  bx, di
    shl  bx, 1
    mov  ax, CX2[bx]
    sub  ax, CX1[bx]
    inc  ax
    mov  cx, CY2[bx]
    sub  cx, CY1[bx]
    inc  cx
    ret
GetWH endp

; BX = line word offset, TA1/TA2/TH = char y-range. AL=1 if it belongs.
TA1 dw 0
TA2 dw 0
TH  dw 0
LineFits proc
    push cx
    mov  ax, TA2
    cmp  ax, LY2[bx]
    jbe  lf1
    mov  ax, LY2[bx]
lf1:
    mov  dx, TA1
    cmp  dx, LY1[bx]
    jae  lf2
    mov  dx, LY1[bx]
lf2:
    sub  ax, dx
    inc  ax
    jle  lf_no
    push ax                        ; vertical overlap
    mov  dx, LY2[bx]
    sub  dx, LY1[bx]
    inc  dx
    cmp  dx, TH
    jbe  lf3
    mov  dx, TH
lf3:
    mov  ax, dx
    mov  cx, 45
    mul  cx                        ; 45 * smaller height
    mov  cx, ax
    pop  ax
    mov  dx, 100
    mul  dx                        ; overlap * 100
    cmp  ax, cx
    jb   lf_no
    mov  al, 1
    pop  cx
    ret
lf_no:
    xor  al, al
    pop  cx
    ret
LineFits endp

AssignLines proc                   ; vertical clustering -> text lines
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  NLINE, 0
    xor  si, si
al_ch:
    cmp  si, NCH
    jb   al_c1
    jmp  al_rank
al_c1:
    mov  bx, si
    shl  bx, 1
    mov  ax, CY1[bx]
    mov  TA1, ax
    mov  ax, CY2[bx]
    mov  TA2, ax
    sub  ax, TA1
    inc  ax
    mov  TH, ax
    mov  di, 0FFFFh
    xor  cx, cx
al_find:
    cmp  cx, NLINE
    jae  al_chosen
    mov  bx, cx
    shl  bx, 1
    call LineFits
    cmp  al, 1
    je   al_hit
    inc  cx
    jmp  al_find
al_hit:
    mov  di, cx
    jmp  al_extend
al_chosen:
    cmp  NLINE, MAXLINES
    jae  al_last
    mov  di, NLINE
    mov  bx, di
    shl  bx, 1
    mov  ax, TA1
    mov  LY1[bx], ax
    mov  ax, TA2
    mov  LY2[bx], ax
    inc  NLINE
    jmp  al_set
al_last:
    mov  di, MAXLINES-1
al_extend:
    mov  bx, di
    shl  bx, 1
    mov  ax, TA1
    cmp  ax, LY1[bx]
    jge  al_e1
    mov  LY1[bx], ax
al_e1:
    mov  ax, TA2
    cmp  ax, LY2[bx]
    jle  al_set
    mov  LY2[bx], ax
al_set:
    mov  ax, di
    mov  CLINE[si], al
    inc  si
    jmp  al_ch
al_rank:
    xor  si, si                    ; rank lines top -> bottom
ar_l:
    cmp  si, NLINE
    jae  ar_apply
    mov  bx, si
    shl  bx, 1
    mov  ax, LY1[bx]
    add  ax, LY2[bx]
    mov  dx, ax                    ; my centre*2
    xor  cx, cx                    ; rank
    xor  di, di
ar_m:
    cmp  di, NLINE
    jae  ar_store
    cmp  di, si
    je   ar_mn
    mov  bx, di
    shl  bx, 1
    mov  ax, LY1[bx]
    add  ax, LY2[bx]
    cmp  ax, dx
    jb   ar_less
    ja   ar_mn
    cmp  di, si                    ; equal centres: lower index first
    jae  ar_mn
ar_less:
    inc  cx
ar_mn:
    inc  di
    jmp  ar_m
ar_store:
    mov  LRANK[si], cl
    inc  si
    jmp  ar_l
ar_apply:
    xor  si, si
ap_c:
    cmp  si, NCH
    jae  al_end
    mov  al, CLINE[si]
    xor  ah, ah
    mov  bx, ax
    mov  al, LRANK[bx]
    mov  CLINE[si], al
    inc  si
    jmp  ap_c
al_end:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
AssignLines endp

SwapCh proc                        ; swap characters SI-1 and SI
    push ax
    push bx
    push di
    mov  bx, si
    dec  bx
    shl  bx, 1
    mov  di, si
    shl  di, 1
    mov  ax, CX1[bx]
    xchg ax, CX1[di]
    mov  CX1[bx], ax
    mov  ax, CX2[bx]
    xchg ax, CX2[di]
    mov  CX2[bx], ax
    mov  ax, CY1[bx]
    xchg ax, CY1[di]
    mov  CY1[bx], ax
    mov  ax, CY2[bx]
    xchg ax, CY2[di]
    mov  CY2[bx], ax
    mov  bx, si
    dec  bx
    mov  al, CLINE[bx]
    xchg al, CLINE[si]
    mov  CLINE[bx], al
    pop  di
    pop  bx
    pop  ax
    ret
SwapCh endp

SortChars proc                     ; reading order: line, then left -> right
    push ax
    push bx
    push si
    push di
    mov  TMPI, 1
sc_i:
    mov  ax, TMPI
    cmp  ax, NCH
    jae  sc_done
    mov  si, ax
sc_j:
    cmp  si, 0
    je   sc_nexti
    mov  bx, si
    dec  bx
    mov  al, CLINE[bx]
    cmp  al, CLINE[si]
    ja   sc_swap
    jb   sc_nexti
    shl  bx, 1
    mov  di, si
    shl  di, 1
    mov  ax, CX1[bx]
    cmp  ax, CX1[di]
    jbe  sc_nexti
sc_swap:
    call SwapCh
    dec  si
    jmp  sc_j
sc_nexti:
    inc  TMPI
    jmp  sc_i
sc_done:
    pop  di
    pop  si
    pop  bx
    pop  ax
    ret
SortChars endp

; ---------------- per-line statistics (height, baseline, gap) ---------------
NSRT dw 0
LineStats proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  TMPW, 0
ls_line:
    mov  ax, TMPW
    cmp  ax, NLINE
    jb   ls_l1
    jmp  ls_done
ls_l1:
    mov  bx, ax
    shl  bx, 1
    mov  LR[bx], 0
    mov  LHMIN[bx], 0FFFFh
    mov  LBASE[bx], 0
    mov  NSRT, 0
    xor  di, di
    mov  si, 0                     ; max bottom of any char (fallback baseline)
ls_ch:
    cmp  di, NCH
    jae  ls_med
    mov  al, CLINE[di]
    xor  ah, ah
    cmp  ax, TMPW
    jne  ls_nx
    call GetWH                     ; AX=w CX=h BX=di*2
    mov  dx, CY2[bx]
    cmp  dx, si
    jbe  ls_f1
    mov  si, dx
ls_f1:
    cmp  ax, 12
    ja   ls_real
    cmp  cx, 12
    jbe  ls_nx
ls_real:
    mov  bx, TMPW
    shl  bx, 1
    cmp  cx, LR[bx]
    jbe  ls_r1
    mov  LR[bx], cx
ls_r1:
    cmp  cx, LHMIN[bx]
    jae  ls_r2
    mov  LHMIN[bx], cx
ls_r2:
    mov  bx, di                    ; insert CY2 into sorted list SORTV
    shl  bx, 1
    mov  dx, CY2[bx]
    mov  bx, NSRT
    shl  bx, 1
    mov  SORTV[bx], dx
    inc  NSRT
ls_bub:
    cmp  bx, 0
    je   ls_nx
    mov  ax, SORTV[bx-2]
    cmp  ax, SORTV[bx]
    jbe  ls_nx
    xchg ax, SORTV[bx]
    mov  SORTV[bx-2], ax
    sub  bx, 2
    jmp  ls_bub
ls_nx:
    inc  di
    jmp  ls_ch
ls_med:
    mov  bx, TMPW
    shl  bx, 1
    cmp  NSRT, 0
    jne  ls_have
    mov  LBASE[bx], si             ; no real glyph: use lowest ink
    mov  LHMIN[bx], 0
    mov  LGAP[bx], 20
    jmp  ls_next
ls_have:
    call RobustLR                  ; ignore one huge outlier blob when judging the line
    mov  ax, NSRT
    shr  ax, 1
    shl  ax, 1
    mov  di, ax
    mov  ax, SORTV[di]
    mov  LBASE[bx], ax
    mov  ax, LR[bx]                ; gap = 45% of glyph height, 16..60
    mov  cx, 45
    mul  cx
    mov  cx, 100
    div  cx
    cmp  ax, 16
    jge  ls_g1
    mov  ax, 16
ls_g1:
    cmp  ax, 60
    jle  ls_g2
    mov  ax, 60
ls_g2:
    mov  LGAP[bx], ax
ls_next:
    inc  TMPW
    jmp  ls_line
ls_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
LineStats endp

; ---- RobustLR: LR of line TMPW := tallest glyph that is not an outlier
;      (outlier = taller than max(1.6 x median, 1.25 x P75) glyph height of the line).
;      One long tail / merged scribble must not turn every normal letter
;      into "tiny punctuation".
RobustLR proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor  si, si                    ; si = number of real glyphs
    xor  di, di
rl_ch:
    cmp  di, NCH
    jae  rl_med
    mov  al, CLINE[di]
    xor  ah, ah
    cmp  ax, TMPW
    jne  rl_nx
    call GetWH                     ; AX=w CX=h BX=di*2
    cmp  ax, 12
    ja   rl_real
    cmp  cx, 12
    jbe  rl_nx
rl_real:
    mov  bx, si
    shl  bx, 1
    mov  SORTH[bx], cx
    inc  si
rl_bub:
    cmp  bx, 0
    je   rl_nx
    mov  ax, SORTH[bx-2]
    cmp  ax, SORTH[bx]
    jbe  rl_nx
    xchg ax, SORTH[bx]
    mov  SORTH[bx-2], ax
    sub  bx, 2
    jmp  rl_bub
rl_nx:
    inc  di
    jmp  rl_ch
rl_med:
    cmp  si, 3
    jb   rl_done                   ; too few glyphs to judge
    mov  bx, si
    shr  bx, 1
    shl  bx, 1
    mov  ax, SORTH[bx]             ; median height
    mov  cx, 8
    mul  cx
    mov  cx, 5
    div  cx
    mov  dx, ax                    ; dx = 1.6 * median
    mov  ax, si
    mov  cx, 3
    mul  cx
    shr  ax, 1
    shr  ax, 1                     ; ax = n*3/4
    cmp  ax, si
    jb   rl_p1
    mov  ax, si
    dec  ax
rl_p1:
    shl  ax, 1
    mov  bx, ax
    mov  ax, SORTH[bx]             ; 75th percentile height
    mov  cx, 5
    mul  cx
    shr  ax, 1
    shr  ax, 1                     ; ax = 1.25 * p75
    cmp  ax, dx
    jbe  rl_c1
    mov  dx, ax                    ; cap = max(1.6*median, 1.25*p75)
rl_c1:
    xor  bx, bx
    mov  cx, si
    xor  ax, ax                    ; ax = best (largest non-outlier)
rl_f:
    mov  di, SORTH[bx]
    cmp  di, dx
    ja   rl_set
    mov  ax, di
    add  bx, 2
    loop rl_f
rl_set:
    cmp  ax, 0
    je   rl_done
    mov  bx, TMPW
    shl  bx, 1
    mov  LR[bx], ax
rl_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
RobustLR endp

; ---- Dilate8: DS:SI = 8 row bytes -> DS:DI = same grid grown by one cell
Dilate8 proc
    push ax
    push bx
    push cx
    push dx
    xor  bx, bx
dl_h:
    mov  al, [si+bx]
    mov  ah, al
    shl  ah, 1
    mov  dh, al
    shr  dh, 1
    or   al, ah
    or   al, dh
    mov  DTMP[bx], al
    inc  bx
    cmp  bx, 8
    jb   dl_h
    xor  bx, bx
dl_v:
    mov  al, DTMP[bx]
    cmp  bx, 0
    je   dl_v1
    or   al, DTMP[bx-1]
dl_v1:
    cmp  bx, 7
    je   dl_v2
    or   al, DTMP[bx+1]
dl_v2:
    mov  [di+bx], al
    inc  bx
    cmp  bx, 8
    jb   dl_v
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
Dilate8 endp

; ---- TolDist8: SI = bank entry.  AL = tolerant 8x8 distance to GRID8
;      (ink that has no ink within one cell on the other side, both ways)
TolDist8 proc
    push bx
    push cx
    push di
    push si
    mov  di, offset DSTO
    call Dilate8                   ; SI = stored grid
    pop  si
    mov  bx, offset POPT
    xor  cl, cl
    xor  di, di
td_r:
    mov  al, GRID8[di]
    mov  ah, DSTO[di]
    not  ah
    and  al, ah
    xlat
    add  cl, al
    mov  al, [si]
    inc  si
    mov  ah, DCUR[di]
    not  ah
    and  al, ah
    xlat
    add  cl, al
    inc  di
    cmp  di, 8
    jb   td_r
    sub  si, 8
    mov  al, cl
    pop  di
    pop  cx
    pop  bx
    ret
TolDist8 endp


; ---- per-line x-height / capital-height from the unambiguous glyphs ----
LineRefs proc
    push ax
    push bx
    push cx
    push dx
    push di
    mov  TMPW, 0
lr_line:
    mov  ax, TMPW
    cmp  ax, NLINE
    jae  lr_done
    mov  bx, ax
    shl  bx, 1
    mov  LX[bx], 0
    mov  LC[bx], 0
    mov  MODEP, 0
lr_pass:
    mov  NSRT, 0
    xor  di, di
lr_ch:
    cmp  di, NCH
    jae  lr_med
    mov  al, CLINE[di]
    xor  ah, ah
    cmp  ax, TMPW
    jne  lr_nx
    cmp  CGRPV[di], 0FFh
    jne  lr_nx
    test CFLAG[di], 0Ch
    jnz  lr_nx
    mov  al, CCLS[di]
    cmp  al, 0
    jne  lr_c
    mov  al, CRAW[di]
lr_c:
    cmp  MODEP, 0
    jne  lr_caps
    cmp  al, 'a'
    je   lr_ok
    cmp  al, 'e'
    je   lr_ok
    cmp  al, 'n'
    je   lr_ok
    cmp  al, 'r'
    je   lr_ok
    jmp  lr_nx
lr_caps:
    cmp  al, 'A'
    jb   lr_nx
    cmp  al, 'Z'
    ja   lr_nx
lr_ok:
    mov  bx, di
    shl  bx, 1
    mov  dx, CY2[bx]
    sub  dx, CY1[bx]
    inc  dx
    mov  bx, NSRT
    shl  bx, 1
    mov  SORTV[bx], dx
    inc  NSRT
lr_bub:
    cmp  bx, 0
    je   lr_nx
    mov  ax, SORTV[bx-2]
    cmp  ax, SORTV[bx]
    jbe  lr_nx
    xchg ax, SORTV[bx]
    mov  SORTV[bx-2], ax
    sub  bx, 2
    jmp  lr_bub
lr_nx:
    inc  di
    jmp  lr_ch
lr_med:
    cmp  NSRT, 0
    je   lr_np
    mov  ax, NSRT
    shr  ax, 1
    shl  ax, 1
    mov  bx, ax
    mov  dx, SORTV[bx]
    mov  bx, TMPW
    shl  bx, 1
    cmp  MODEP, 0
    jne  lr_stc
    mov  LX[bx], dx
    jmp  lr_np
lr_stc:
    mov  LC[bx], dx
lr_np:
    cmp  MODEP, 0
    jne  lr_next
    mov  MODEP, 1
    jmp  lr_pass
lr_next:
    inc  TMPW
    jmp  lr_line
lr_done:
    pop  di
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
LineRefs endp

; ---- TallRef : SI = glyph.  AL = 1 tall (capital height), 0 short, 2 unknown
TallRef proc
    push bx
    push cx
    push dx
    mov  bl, CLINE[si]
    xor  bh, bh
    shl  bx, 1
    mov  cx, LX[bx]
    mov  dx, LC[bx]
    cmp  cx, 0
    je   trf_nox
    cmp  dx, 0
    jne  trf_both
    mov  dx, LR[bx]
trf_both:
    cmp  dx, cx
    jbe  trf_unk
    add  dx, cx
    shr  dx, 1                     ; midway between x-height and capital height
    jmp  trf_cmp
trf_nox:
    cmp  dx, 0
    je   trf_unk
    mov  ax, dx
    mov  cx, 75
    mul  cx
    mov  cx, 100
    div  cx
    mov  dx, ax
trf_cmp:
    mov  bx, si
    shl  bx, 1
    mov  ax, CY2[bx]
    sub  ax, CY1[bx]
    inc  ax
    mov  REFBORD, 0
    mov  cx, ax
    sub  cx, dx
    jge  trf_a
    neg  cx
trf_a:
    cmp  cx, 3
    ja   trf_b
    mov  REFBORD, 1
trf_b:
    cmp  ax, dx
    jb   trf_short
    mov  al, 1
    jmp  trf_ret
trf_short:
    xor  al, al
    jmp  trf_ret
trf_unk:
    mov  al, 2
trf_ret:
    pop  dx
    pop  cx
    pop  bx
    ret
TallRef endp

; ============================================================================
;                    PIXELS  ->  GRID  (8x8 and 5x7)
; ============================================================================
SetBox proc                        ; DI = char -> BMINX..BOXH
    push ax
    push bx
    mov  bx, di
    shl  bx, 1
    mov  ax, CX1[bx]
    mov  BMINX, ax
    mov  ax, CX2[bx]
    dec  ax
    mov  BMAXX, ax
    mov  ax, CY1[bx]
    mov  BMINY, ax
    mov  ax, CY2[bx]
    dec  ax
    mov  BMAXY, ax
    mov  ax, BMAXX
    sub  ax, BMINX
    add  ax, 2
    mov  BOXW, ax
    mov  ax, BMAXY
    sub  ax, BMINY
    add  ax, 2
    mov  BOXH, ax
    pop  bx
    pop  ax
    ret
SetBox endp

ScaleDiv proc                      ; AX = AX*CX/BX
    push dx
    mul  cx
    div  bx
    pop  dx
    ret
ScaleDiv endp

BuildGridN proc
    push ax
    push bx
    push cx
    push dx
    push di
    mov  di, GOUT
    mov  cx, 8
    xor  al, al
bgn_clr:
    mov  [di], al
    inc  di
    loop bgn_clr
    mov  ax, BOXW
    mul  BOXH
    div  GDIV
    cmp  ax, GLO
    jge  bgn_1
    mov  ax, GLO
bgn_1:
    cmp  ax, GHI
    jle  bgn_2
    mov  ax, GHI
bgn_2:
    mov  DYN_INKMIN, ax
    mov  CELLR, 0
bgn_r:
    mov  CELLC, 0
bgn_c:
    call DoCell
    inc  CELLC
    mov  ax, CELLC
    cmp  ax, GNC
    jb   bgn_c
    inc  CELLR
    mov  ax, CELLR
    cmp  ax, GNR
    jb   bgn_r
    pop  di
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
BuildGridN endp

DoCell proc
    push ax
    push bx
    push cx
    push dx
    mov  ax, CELLR
    mov  cx, BOXH
    mov  bx, GNR
    call ScaleDiv
    add  ax, BMINY
    mov  CELLY1, ax
    mov  ax, CELLR
    inc  ax
    mov  cx, BOXH
    mov  bx, GNR
    call ScaleDiv
    add  ax, BMINY
    dec  ax
    cmp  ax, CELLY1
    jge  dc_y
    mov  ax, CELLY1
dc_y:
    mov  CELLY2, ax
    mov  ax, CELLC
    mov  cx, BOXW
    mov  bx, GNC
    call ScaleDiv
    add  ax, BMINX
    mov  CELLX1, ax
    mov  ax, CELLC
    inc  ax
    mov  cx, BOXW
    mov  bx, GNC
    call ScaleDiv
    add  ax, BMINX
    dec  ax
    cmp  ax, CELLX1
    jge  dc_x
    mov  ax, CELLX1
dc_x:
    mov  CELLX2, ax
    call CellInk
    cmp  al, 1
    jne  dc_done
    mov  cx, GNC
    dec  cx
    sub  cx, CELLC
    mov  al, 1
    shl  al, cl
    mov  bx, GOUT
    add  bx, CELLR
    or   [bx], al
dc_done:
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
DoCell endp

CellInk proc                       ; reads the SCREEN: enough yellow ink in cell?
    push bx
    push cx
    push dx
    mov  INKCNT, 0
    mov  dx, CELLY1
ci_row:
    mov  cx, CELLX1
ci_col:
    push cx
    push dx
    mov  ah, 0Dh
    xor  bh, bh
    int  10h
    pop  dx
    pop  cx
    cmp  al, PENCOL
    jne  ci_no
    inc  INKCNT
    mov  ax, INKCNT
    cmp  ax, DYN_INKMIN
    jae  ci_yes
ci_no:
    inc  cx
    cmp  cx, CELLX2
    jbe  ci_col
    inc  dx
    cmp  dx, CELLY2
    jbe  ci_row
    xor  al, al
    jmp  ci_ret
ci_yes:
    mov  al, 1
ci_ret:
    pop  dx
    pop  cx
    pop  bx
    ret
CellInk endp

AutoCenterGrid proc                ; shift 8x8 grid so ink touches the edges
    push ax
    push bx
    xor  al, al
    xor  bx, bx
ac_or:
    or   al, GRID8[bx]
    inc  bx
    cmp  bx, 8
    jb   ac_or
    test al, al
    jz   ac_done
    test al, 80h
    jnz  ac_chk_right
    test al, 01h
    jz   ac_vert
    xor  bx, bx
ac_shl:
    shl  GRID8[bx], 1
    inc  bx
    cmp  bx, 8
    jb   ac_shl
    jmp  ac_vert
ac_chk_right:
    test al, 01h
    jnz  ac_vert
    xor  bx, bx
ac_shr:
    shr  GRID8[bx], 1
    inc  bx
    cmp  bx, 8
    jb   ac_shr
ac_vert:
    cmp  GRID8[0], 0
    jne  ac_chk_bot
    cmp  GRID8[7], 0
    je   ac_done
    xor  bx, bx
ac_up:
    mov  al, GRID8[bx+1]
    mov  GRID8[bx], al
    inc  bx
    cmp  bx, 7
    jb   ac_up
    mov  GRID8[7], 0
    jmp  ac_done
ac_chk_bot:
    cmp  GRID8[7], 0
    jne  ac_done
    mov  bx, 7
ac_dn:
    mov  al, GRID8[bx-1]
    mov  GRID8[bx], al
    dec  bx
    jnz  ac_dn
    mov  GRID8[0], 0
ac_done:
    pop  bx
    pop  ax
    ret
AutoCenterGrid endp

; ----------------------------------------------------------------------------
;  GridsFor : DI = char -> GRID8 and G57 (read from the screen)
; ----------------------------------------------------------------------------
GridsFor proc
    call SetBox
    mov  GNR, 8
    mov  GNC, 8
    mov  GDIV, 350
    mov  GLO, 2
    mov  GHI, 14
    mov  GOUT, offset GRID8
    call BuildGridN
    call AutoCenterGrid
    mov  GNR, 7
    mov  GNC, 5
    mov  GDIV, 210
    mov  GLO, 1
    mov  GHI, 5
    mov  GOUT, offset G57
    call BuildGridN
    ret
GridsFor endp

; ============================================================================
;                    CLASSIFY EVERY CHARACTER (raw pass)
; ============================================================================
TKEY db 0
ClassifyAll proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor  di, di
ca_next:
    cmp  di, NCH
    jb   ca_go
    jmp  ca_done
ca_go:
    call GetWH                     ; AX=w CX=h BX=di*2
    mov  TA1, ax                   ; w
    mov  TA2, cx                   ; h
    mov  al, CLINE[di]
    xor  ah, ah
    mov  si, ax
    shl  si, 1                     ; SI = line word offset
    mov  CFLAG[di], 0
    mov  CRATIO[di], 0
    mov  CCLS[di], 0
    mov  CCONF[di], 0
    mov  CGRPV[di], 0FFh
    mov  CMARG[di], 0
    ; ---- tiny / dash detection (needs line height) ----
    mov  ax, TA1
    cmp  ax, 12
    ja   ca_chk_rel
    mov  ax, TA2
    cmp  ax, 12
    ja   ca_chk_rel
    or   CFLAG[di], 4              ; absolutely tiny
    jmp  ca_tiny
ca_chk_rel:
    mov  bx, LR[si]
    cmp  bx, 0
    jne  ca_haveR
    or   CFLAG[di], 4
    jmp  ca_tiny
ca_haveR:
    mov  ax, TA2                   ; h*100 < 32*R and w*100 < 45*R ?
    mov  cx, 100
    mul  cx
    mov  cx, ax
    mov  ax, bx
    mov  dx, 32
    mul  dx
    cmp  cx, ax
    jae  ca_chk_dash
    mov  ax, TA1
    mov  cx, 100
    mul  cx
    mov  cx, ax
    mov  ax, bx
    mov  dx, 45
    mul  dx
    cmp  cx, ax
    jae  ca_chk_dash
    or   CFLAG[di], 4
    jmp  ca_tiny
ca_chk_dash:
    mov  ax, TA2                   ; h*100 < 24*R and w >= 2h and w*100 >= 28*R
    mov  cx, 100
    mul  cx
    mov  cx, ax
    mov  ax, bx
    mov  dx, 24
    mul  dx
    cmp  cx, ax
    jae  ca_normal
    mov  ax, TA2
    shl  ax, 1
    cmp  TA1, ax
    jb   ca_normal
    mov  ax, TA1
    mov  cx, 100
    mul  cx
    mov  cx, ax
    mov  ax, bx
    mov  dx, 28
    mul  dx
    cmp  cx, ax
    jb   ca_normal
    or   CFLAG[di], 8
    jmp  ca_tiny
ca_normal:
    ; ---- ratio, tall, descender ----
    mov  ax, TA2                   ; ratio = h*100/R
    mov  cx, 100
    mul  cx
    div  bx
    cmp  ax, 255
    jbe  ca_r1
    mov  ax, 255
ca_r1:
    mov  CRATIO[di], al
    mov  cx, ax                    ; cx = ratio
    ; uniform line? LHMIN*100 >= 78*R
    mov  ax, LHMIN[si]
    mov  dx, 100
    mul  dx
    push ax
    mov  ax, bx
    mov  dx, 78
    mul  dx
    mov  dx, ax
    pop  ax
    cmp  ax, dx
    jb   ca_rel
    or   CFLAG[di], 10h            ; use absolute height
    mov  ax, TA2
    cmp  ax, ABS_T
    jb   ca_desc
    or   CFLAG[di], 1
    jmp  ca_desc
ca_rel:
    cmp  cx, CASE_T
    jb   ca_desc
    or   CFLAG[di], 1
ca_desc:
    mov  bx, di
    shl  bx, 1
    mov  ax, CY2[bx]
    sub  ax, LBASE[si]
    jle  ca_grid
    mov  dx, 100
    mul  dx
    mov  cx, TA2
    mov  bx, 12
    xchg ax, cx
    mul  bx                        ; h*12 (descender if drop > 12%)
    cmp  cx, ax
    jbe  ca_grid
    or   CFLAG[di], 2
ca_grid:
    call GridsFor
    mov  ax, TA1                   ; aspect = w*16/h
    mov  cx, 16
    mul  cx
    div  TA2
    cmp  ax, 255
    jbe  ca_as
    mov  ax, 255
ca_as:
    mov  CURASP, al
    mov  CASP[di], al
    mov  al, CFLAG[di]
    and  al, 1
    mov  CURFLAG, al
    mov  bx, di
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    push di
    mov  si, offset GRID8
    lea  di, CGRID[bx]
    push ds
    pop  es
    mov  cx, 8
    cld
    rep  movsb
    mov  si, offset G57
    pop  di
    push di
    mov  bx, di
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    lea  di, CG57[bx]
    mov  cx, 8
    rep  movsb
    pop  di
    call ScoreChar
    mov  al, BESTC
    mov  CRAW[di], al
    mov  ax, MARG
    cmp  ax, 255
    jbe  ca_m1
    mov  ax, 255
ca_m1:
    mov  CMARG[di], al
    mov  bl, BESTC
    xor  bh, bh
    mov  al, GRP[bx]
    mov  CGRPV[di], al
    cmp  BANKHIT, 1
    jne  ca_nbk
    or   CFLAG[di], 20h
    mov  al, BESTC
    mov  CCLS[di], al
    mov  CCONF[di], 2
ca_nbk:
    jmp  ca_nxt
ca_tiny:
    call TinyClass                 ; sets CCLS / CCONF for punctuation marks
ca_nxt:
    inc  di
    jmp  ca_next
ca_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ClassifyAll endp

; ---- punctuation by geometry (. , ' - ) with learnable override ----
;  in: DI = char, SI = line word offset
TinyClass proc
    push ax
    push bx
    push cx
    push dx
    mov  TKEY, 0
    mov  ax, LBASE[si]
    mov  TA1, ax                   ; baseline
    mov  ax, LR[si]
    mov  TMPI, ax                  ; glyph height R
    test CFLAG[di], 8
    jz   tc_dotlike
    jmp  tc_dash
tc_dotlike:
    mov  ax, TMPI
    mov  bx, 15
    mul  bx
    mov  bx, 100
    div  bx
    mov  TMPW, ax
    mov  ax, TA1
    sub  ax, TMPW                  ; low line = baseline - 15%R
    mov  TMPW, ax
    mov  bx, di
    shl  bx, 1
    cmp  TMPI, 0
    je   tc_low
    mov  ax, CY2[bx]
    cmp  ax, TMPW
    jge  tc_low
    mov  ax, TMPI
    mov  cx, 55
    mul  cx
    mov  cx, 100
    div  cx
    mov  cx, TA1
    sub  cx, ax                    ; high line = baseline - 55%R
    mov  ax, CY1[bx]
    cmp  ax, cx
    jle  tc_high
    mov  TKEY, 4
    mov  al, CLS_NOISE
    jmp  tc_look
tc_low:
    call GetWH                     ; AX=w CX=h
    cmp  cx, 6
    jb   tc_dot
    mov  TMPW, ax
    mov  ax, cx
    mov  bx, 10
    mul  bx
    mov  cx, ax                    ; h*10
    mov  ax, TMPW
    mov  bx, 16
    mul  bx                        ; w*16
    cmp  cx, ax
    jb   tc_dot
    mov  TKEY, 1
    mov  al, ','
    jmp  tc_look
tc_dot:
    mov  al, '.'
    jmp  tc_look
tc_high:
    mov  TKEY, 2
    mov  al, 27h
    jmp  tc_look
tc_dash:
    mov  TKEY, 16
    mov  al, '-'
tc_look:
    mov  bl, TKEY
    mov  CRATIO[di], bl
    mov  CCLS[di], al
    mov  CCONF[di], 1
    mov  si, offset BANK
    mov  cx, NBANK
    jcxz tc_done
tc_lp:
    test byte ptr [si+9], 4
    jz   tc_nx
    mov  al, [si]
    cmp  al, TKEY
    jne  tc_nx
    mov  al, [si+8]
    mov  CCLS[di], al
    mov  CCONF[di], 2
tc_nx:
    add  si, 10
    dec  cx
    jz   tc_done
    jmp  tc_lp
tc_done:
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
TinyClass endp

; ============================================================================
;                   SCORING: seeds + learned bank + prototypes + perceptron
; ============================================================================
ModeOK proc                        ; BL = class -> AL=1 if allowed by MODE
    mov  al, MODE
    cmp  al, 0
    je   mo_yes
    cmp  al, 1
    jne  mo_2
    cmp  bl, 'A'
    jb   mo_no
    cmp  bl, 'Z'
    ja   mo_no
    jmp  mo_yes
mo_2:
    cmp  al, 2
    jne  mo_3
    cmp  bl, 'a'
    jb   mo_no
    cmp  bl, 'z'
    ja   mo_no
    jmp  mo_yes
mo_3:
    cmp  bl, '0'
    jb   mo_no
    cmp  bl, '9'
    ja   mo_no
mo_yes:
    mov  al, 1
    ret
mo_no:
    xor  al, al
    ret
ModeOK endp

ClsIdx proc                        ; BL = ASCII -> AX = perceptron class 0..61 or FFFF
    xor  ah, ah
    cmp  bl, 'A'
    jb   ci_n
    cmp  bl, 'Z'
    ja   ci_l
    mov  al, bl
    sub  al, 'A'
    ret
ci_l:
    cmp  bl, 'a'
    jb   ci_n
    cmp  bl, 'z'
    ja   ci_n
    mov  al, bl
    sub  al, 'a'-26
    ret
ci_n:
    cmp  bl, '0'
    jb   cls_no
    cmp  bl, '9'
    ja   cls_no
    mov  al, bl
    sub  al, '0'-52
    ret
cls_no:
    mov  ax, 0FFFFh
    ret
ClsIdx endp

IdxCls proc                        ; AX = 0..61 -> AL = ASCII
    cmp  al, 26
    jae  ic_1
    add  al, 'A'
    ret
ic_1:
    cmp  al, 52
    jae  ic_2
    add  al, 'a'-26
    ret
ic_2:
    add  al, '0'-52
    ret
IdxCls endp

ACT   db 64 dup(0)
NACT  dw 0
BuildAct proc                      ; GRID8 -> list of active pixel numbers
    push ax
    push bx
    push cx
    push dx
    mov  NACT, 0
    xor  bx, bx                    ; row
ba_row:
    mov  dl, GRID8[bx]
    mov  cx, 8
    mov  dh, 0                     ; column
ba_bit:
    shl  dl, 1
    jnc  ba_skip
    push bx
    mov  ax, bx
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    mov  bl, dh
    xor  bh, bh
    add  ax, bx
    mov  bx, NACT
    mov  ACT[bx], al
    inc  NACT
    pop  bx
ba_skip:
    inc  dh
    loop ba_bit
    inc  bx
    cmp  bx, 8
    jb   ba_row
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
BuildAct endp

ScorePerc proc                     ; PSC[0..61], PSMAX from GRID8 (live weights)
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    call BuildAct
    mov  PSMAX, 8000h
    xor  di, di
    mov  si, offset WTS
sp_cls:
    mov  bx, di
    shl  bx, 1
    mov  dx, BIAS[bx]
    mov  cx, NACT
    xor  bx, bx
    cmp  cx, 0
    je   sp_store
sp_j:
    mov  al, ACT[bx]
    xor  ah, ah
    push bx
    mov  bx, ax
    mov  al, [si+bx]
    cbw
    add  dx, ax
    pop  bx
    inc  bx
    loop sp_j
sp_store:
    mov  bx, di
    shl  bx, 1
    mov  PSC[bx], dx
    cmp  dx, PSMAX
    jle  sp_nx
    mov  PSMAX, dx
sp_nx:
    add  si, 64
    inc  di
    cmp  di, 62
    jb   sp_cls
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ScorePerc endp

FSC dw 128 dup(0)

ScoreChar proc
    push bx
    push cx
    push dx
    push si
    push di
    push es
    ; ---- init ----
    xor  bx, bx
sc_init:
    mov  DK[bx], 99
    mov  DPR[bx], 0FFh
    inc  bx
    cmp  bx, 128
    jb   sc_init
    mov  BKD, 255
    mov  BKC, 0
    mov  BANKHIT, 0
    ; ---- [C] seed memory (read-only far segment) ----
    mov  ax, RODATA
    mov  es, ax
    mov  si, offset SEEDS
    mov  NLEFT, SEEDN
    mov  bx, offset POPT
sd_lp:
    mov  al, es:[si+8]
    xor  ah, ah
    mov  di, ax
    mov  dl, DK[di]
    xor  ch, ch
k = 0
REPT 4
    mov  al, es:[si+k]
    xor  al, GRID8+k
    xlat
    add  ch, al
k = k+1
ENDM
    cmp  ch, dl
    jae  sd_nx
REPT 4
    mov  al, es:[si+k]
    xor  al, GRID8+k
    xlat
    add  ch, al
k = k+1
ENDM
    cmp  ch, dl
    jae  sd_nx
    mov  DK[di], ch
sd_nx:
    add  si, 9
    dec  NLEFT
    jz   sd_end
    jmp  sd_lp
sd_end:
    mov  si, offset GRID8
    mov  di, offset DCUR
    call Dilate8
    ; ---- [C] learned bank (your corrections) ----
    mov  si, offset BANK
    mov  NLEFT, 0
    mov  ax, NBANK
    mov  NLEFT, ax
    cmp  ax, 0
    je   bk_end
    mov  bx, offset POPT
bk_lp:
    test byte ptr [si+16], 4
    jz   bk_grid
    jmp  bk_nx
bk_grid:
    call TolDist8                  ; shift-tolerant 8x8 distance -> AL
    mov  dl, al
k = 0
REPT 7
    mov  al, [si+k+8]
    xor  al, G57+k
    xlat
    add  dl, al
k = k+1
ENDM
    mov  al, [si+17]               ; aspect difference / 8
    mov  ah, CURASP
    cmp  al, ah
    jae  bk_a1
    xchg al, ah
bk_a1:
    sub  al, ah
    shr  al, 1
    shr  al, 1
    shr  al, 1
    add  dl, al
    mov  al, [si+16]               ; size flag differs?  (matters for c/C etc.)
    xor  al, CURFLAG
    and  al, 1
    jz   bk_ok
    mov  al, [si+15]
    xor  ah, ah
    mov  di, ax
    cmp  GRP[di], 0FFh
    je   bk_ok
    add  dl, 4
bk_ok:
    cmp  dl, BKD
    jae  bk_eff
    mov  BKD, dl
    mov  al, [si+15]
    mov  BKC, al
bk_eff:
    mov  al, [si+15]
    xor  ah, ah
    mov  di, ax
    mov  al, dl                    ; bank distance covers 8x8+5x7 (~2x seed scale):
    xor  ah, ah                    ; normalise (x5/8) and trust own samples (-3)
    mov  cx, ax
    shl  ax, 1
    shl  ax, 1
    add  ax, cx
    shr  ax, 1
    shr  ax, 1
    shr  ax, 1
    sub  al, 3
    jnc  bk_e2
    xor  al, al
bk_e2:
    cmp  al, DK[di]
    jae  bk_nx
    mov  DK[di], al
bk_nx:
    add  si, BENT
    dec  NLEFT
    jz   bk_end
    jmp  bk_lp
bk_end:
    ; ---- [B] 5x7 prototypes: factory (far) then learned ----
    mov  ax, RODATA
    mov  es, ax
    mov  si, offset BASEP
    mov  NLEFT, NPROTO
    mov  bx, offset POPT
pr_lp:
    xor  dl, dl
k = 0
REPT 7
    mov  al, es:[si+k]
    xor  al, G57+k
    xlat
    add  dl, al
k = k+1
ENDM
    mov  al, es:[si+7]
    xor  ah, ah
    mov  di, ax
    cmp  dl, DPR[di]
    jae  pr_nx
    mov  DPR[di], dl
pr_nx:
    add  si, 8
    dec  NLEFT
    jz   pr_end
    jmp  pr_lp
pr_end:
    mov  si, offset LPROT
    mov  ax, NLPROT
    mov  NLEFT, ax
    cmp  ax, 0
    je   lp_end
lp_lp:
    xor  dl, dl
k = 0
REPT 7
    mov  al, [si+k]
    xor  al, G57+k
    xlat
    add  dl, al
k = k+1
ENDM
    mov  al, [si+7]
    xor  ah, ah
    mov  di, ax
    cmp  dl, DPR[di]
    jae  lp_nx
    mov  DPR[di], dl
lp_nx:
    add  si, 8
    dec  NLEFT
    jz   lp_end
    jmp  lp_lp
lp_end:
    ; ---- [A] perceptron ----
    call ScorePerc
    ; ---- fuse:  F = -16*knn - 4*proto + (perceptron - best)/8 ----
    mov  BESTF, 8000h
    mov  BESTC, 0
    mov  bx, 33
fz_lp:
    cmp  DK[bx], 99
    jae  fz_nx
    push bx
    call ModeOK                    ; BL = class
    pop  bx
    cmp  al, 1
    je   fz_ok
    mov  DK[bx], 99                ; filtered out by MODE
    jmp  fz_nx
fz_ok:
    mov  al, DK[bx]
    xor  ah, ah
    mov  cl, 4
    shl  ax, cl
    neg  ax                        ; -16*knn
    mov  dl, DPR[bx]
    cmp  dl, 0FFh
    jne  fz_d1
    mov  dl, 8                     ; class without prototypes: neutral
fz_d1:
    xor  dh, dh
    shl  dx, 1
    shl  dx, 1
    sub  ax, dx                    ; -4*proto
    push ax
    call ClsIdx                    ; AX = index (BL = class, preserved)
    mov  di, ax
    pop  ax
    cmp  di, 0FFFFh
    jne  fz_p
    sub  ax, 12                    ; no perceptron opinion
    jmp  fz_store
fz_p:
    shl  di, 1
    mov  dx, PSC[di]
    sub  dx, PSMAX
    mov  cl, 3
    sar  dx, cl
    add  ax, dx
fz_store:
    mov  di, bx
    shl  di, 1
    mov  FSC[di], ax
    cmp  ax, BESTF
    jle  fz_nx
    mov  BESTF, ax
    mov  BESTC, bl
fz_nx:
    inc  bx
    cmp  bx, 127
    jb   fz_lp
    ; margin to the best class of a DIFFERENT shape group
    mov  BEST2F, 8000h
    mov  bl, BESTC
    xor  bh, bh
    mov  dl, GRP[bx]               ; DL = group of the winner
    mov  bx, 33
fz2:
    cmp  DK[bx], 99
    jae  fz2n
    cmp  bl, BESTC
    je   fz2n
    cmp  dl, 0FFh
    je   fz2c
    cmp  GRP[bx], dl
    je   fz2n
fz2c:
    mov  di, bx
    shl  di, 1
    mov  ax, FSC[di]
    cmp  ax, BEST2F
    jle  fz2n
    mov  BEST2F, ax
fz2n:
    inc  bx
    cmp  bx, 127
    jb   fz2
    mov  ax, BESTF
    sub  ax, BEST2F
    cmp  BEST2F, 8000h
    jne  fz_m
    mov  ax, 255
fz_m:
    cmp  ax, 0
    jge  fz_m2
    xor  ax, ax
fz_m2:
    mov  MARG, ax
    ; ---- your taught samples override when (almost) identical ----
    cmp  BKD, 14                   ; close match to a taught sample wins outright
    ja   sc_ret
    mov  bl, BKC
    cmp  bl, CLS_NOISE
    je   sc_ovr
    call ModeOK
    cmp  al, 1
    jne  sc_ret
sc_ovr:
    mov  al, BKC
    mov  BESTC, al
    mov  BANKHIT, 1
sc_ret:
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    ret
ScoreChar endp

; ============================================================================
;                         WORDS  and  CONTEXT RESOLUTION
; ============================================================================
WordSeg proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    xor  si, si                    ; si = char
    mov  dx, 0FFFFh                ; previous real char
    mov  TMPW, 0                   ; word number
ws_lp:
    cmp  si, NCH
    jae  ws_done
    mov  CFIRST[si], 0
    mov  ax, TMPW
    mov  CWORD[si], al
    cmp  CCLS[si], CLS_NOISE
    je   ws_nx
    cmp  dx, 0FFFFh
    jne  ws_cmp
    mov  CFIRST[si], 1             ; first glyph of all
    jmp  ws_set
ws_cmp:
    mov  bx, dx
    mov  al, CLINE[si]
    cmp  al, CLINE[bx]
    jne  ws_new
    mov  al, CLINE[si]             ; same line: horizontal gap vs threshold
    xor  ah, ah
    mov  di, ax
    shl  di, 1
    mov  ax, si
    shl  ax, 1
    mov  di, ax                    ; (reuse) di = si*2
    mov  bx, dx
    shl  bx, 1
    mov  ax, CX1[di]
    sub  ax, CX2[bx]               ; gap
    mov  cx, ax
    mov  al, CLINE[si]
    xor  ah, ah
    mov  bx, ax
    shl  bx, 1
    cmp  cx, LGAP[bx]
    jl   ws_set
ws_new:
    inc  TMPW
    mov  ax, TMPW
    mov  CWORD[si], al
    mov  CFIRST[si], 1
ws_set:
    mov  dx, si
ws_nx:
    inc  si
    jmp  ws_lp
ws_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
WordSeg endp

ND dw 0
NU dw 0
NL dw 0
WLEN dw 0
WCUR dw 0
FAMILY db 0
UNSUREF db 0
ResolveAll proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  WCUR, 0
ra_word:
    ; -- is there any char left with this word number?
    xor  si, si
    mov  ND, 0
    mov  NU, 0
    mov  NL, 0
    mov  WLEN, 0
    mov  FOUND, 0
ra_cnt:
    cmp  si, NCH
    jae  ra_cnt_done
    mov  al, CWORD[si]
    xor  ah, ah
    cmp  ax, WCUR
    jne  ra_cn
    cmp  CCLS[si], CLS_NOISE
    je   ra_cn
    mov  FOUND, 1
    inc  WLEN
    cmp  CCLS[si], 0
    jne  ra_have
    cmp  CGRPV[si], 0FFh
    jne  ra_cn                     ; ambiguous glyph: decided later
    mov  al, CRAW[si]              ; unambiguous: take the winner
    mov  CCLS[si], al
    mov  CCONF[si], 1
    cmp  CMARG[si], 32
    jae  ra_have
    mov  CCONF[si], 0
ra_have:
    mov  al, CCLS[si]
    cmp  al, '0'
    jb   ra_cn
    cmp  al, '9'
    ja   ra_up
    inc  ND
    jmp  ra_cn
ra_up:
    cmp  al, 'A'
    jb   ra_cn
    cmp  al, 'Z'
    ja   ra_lo
    inc  NU
    jmp  ra_cn
ra_lo:
    cmp  al, 'a'
    jb   ra_cn
    cmp  al, 'z'
    ja   ra_cn
    inc  NL
ra_cn:
    inc  si
    jmp  ra_cnt
ra_cnt_done:
    cmp  FOUND, 0
    jne  ra_res
    ; no glyph with this word number: finished when WCUR exceeds the last
    mov  ax, WCUR
    cmp  ax, 255
    jae  ra_done
    ; look ahead: any char with larger word number?
    xor  si, si
ra_ahead:
    cmp  si, NCH
    jae  ra_done
    mov  al, CWORD[si]
    xor  ah, ah
    cmp  ax, WCUR
    ja   ra_more
    inc  si
    jmp  ra_ahead
ra_more:
    inc  WCUR
    jmp  ra_word
ra_res:
    xor  si, si
ra_r1:
    cmp  si, NCH
    jae  ra_nextword
    mov  al, CWORD[si]
    xor  ah, ah
    cmp  ax, WCUR
    jne  ra_r2
    cmp  CCLS[si], 0
    jne  ra_r2
    call ResolveOne
ra_r2:
    inc  si
    jmp  ra_r1
ra_nextword:
    inc  WCUR
    jmp  ra_word
ra_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ResolveAll endp

; ----------------------------------------------------------------------------
;  ResolveOne : SI = ambiguous glyph (c/C, o/O/0, s/S/5, l/I/1 ...)
;  decides digit-vs-letter by word context, case by size/baseline geometry
; ----------------------------------------------------------------------------
ResolveOne proc
    push ax
    push bx
    push cx
    push dx
    push di
    mov  UNSUREF, 0
    mov  al, CGRPV[si]
    xor  ah, ah
    mov  bx, ax
    shl  ax, 1
    add  ax, bx                    ; 3*group
    mov  bx, ax
    mov  dl, GRPMEM[bx]            ; DL = upper member
    mov  dh, GRPMEM[bx+1]          ; DH = lower member (0 none)
    mov  cl, GRPMEM[bx+2]          ; CL = digit member (0 none)
    cmp  MODE, 0
    je   ro_auto
    mov  al, CRAW[si]              ; forced mode: raw winner already filtered
    jmp  ro_set
ro_auto:
    ; ---- digit or letter? ----
    mov  FAMILY, 1                 ; 1 = letter
    cmp  cl, 0
    je   ro_letter
    mov  ax, NU
    add  ax, NL                    ; letters in the word
    cmp  ND, ax
    ja   ro_dig
    jb   ro_letter
    mov  UNSUREF, 1                ; tie: follow the raw shape vote
    mov  al, CRAW[si]
    cmp  al, '0'
    jb   ro_letter
    cmp  al, '9'
    ja   ro_letter
ro_dig:
    mov  al, cl
    jmp  ro_set
ro_letter:
    cmp  dh, 0
    jne  ro_both
    mov  al, dl                    ; only an upper-case form exists (B)
    jmp  ro_set
ro_both:
    cmp  dl, 'I'                   ; the l / I / 1 family: context only
    jne  ro_case
    mov  ax, NU
    cmp  ax, NL
    ja   ro_I
    jb   ro_l
    mov  UNSUREF, 1
    cmp  CFIRST[si], 1
    je   ro_I
ro_l:
    mov  al, dh
    jmp  ro_set
ro_I:
    mov  al, dl
    jmp  ro_set
ro_case:
    test CFLAG[si], 2              ; descender below the baseline -> p / y
    jz   ro_nodesc
    cmp  dh, 'p'
    je   ro_lower
    cmp  dh, 'y'
    je   ro_lower
ro_nodesc:
    mov  REFUSED, 0
    call TallRef
    cmp  al, 2
    je   ro_fb
    mov  REFUSED, 1
    cmp  al, 0
    je   ro_lower
    jmp  ro_tall
ro_fb:
    test CFLAG[si], 1
    jz   ro_lower                  ; short -> lower case
    test CFLAG[si], 10h
    jnz  ro_upper                  ; absolute rule already decided
ro_tall:
    cmp  CFIRST[si], 1
    je   ro_upper
    mov  ax, NL
    cmp  ax, NU
    jbe  ro_upper
    mov  UNSUREF, 0                ; capital in the middle of a lower-case word: unlikely
    jmp  ro_lower
ro_upper:
    mov  al, dl
    cmp  REFUSED, 1
    jne  ro_u0
    cmp  REFBORD, 0
    je   ro_set
    mov  UNSUREF, 1
    jmp  ro_set
ro_u0:
    mov  bl, CRATIO[si]
    xor  bh, bh
    mov  cx, bx
    sub  cx, CASE_T
    jge  ro_u1
    neg  cx
ro_u1:
    cmp  cx, 6
    ja   ro_set
    test CFLAG[si], 10h
    jnz  ro_set
    mov  UNSUREF, 1
    jmp  ro_set
ro_lower:
    mov  al, dh
    cmp  REFUSED, 1
    jne  ro_l0
    cmp  REFBORD, 0
    je   ro_set
    mov  UNSUREF, 1
    jmp  ro_set
ro_l0:
    mov  bl, CRATIO[si]
    xor  bh, bh
    mov  cx, bx
    sub  cx, CASE_T
    jge  ro_l1
    neg  cx
ro_l1:
    cmp  cx, 6
    ja   ro_set
    test CFLAG[si], 10h
    jnz  ro_set
    mov  UNSUREF, 1
ro_set:
    mov  CCLS[si], al
    mov  CCONF[si], 1
    cmp  CMARG[si], 32
    jb   ro_uns
    cmp  UNSUREF, 0
    je   ro_ret
ro_uns:
    mov  CCONF[si], 0
ro_ret:
    pop  di
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ResolveOne endp

; ----------------------------------------------------------------------------
;  BuildOutput : OUTCH/OUTIDX text stream with spaces and line breaks
; ----------------------------------------------------------------------------
BuildOutput proc
    push ax
    push bx
    push si
    push di
    mov  NOUT, 0
    mov  NUNSURE, 0
    xor  si, si
    mov  di, 0FFFFh                ; previous output char
bo_lp:
    cmp  si, NCH
    jae  bo_done
    cmp  CCLS[si], CLS_NOISE
    je   bo_nx
    cmp  di, 0FFFFh
    je   bo_put
    mov  al, CLINE[si]
    cmp  al, CLINE[di]
    je   bo_sp
    mov  al, 0Ah                   ; new text line
    call OutPut
    jmp  bo_put
bo_sp:
    cmp  CFIRST[si], 1
    jne  bo_put
    mov  al, ' '
    call OutPut
bo_put:
    mov  al, CCLS[si]
    mov  bx, si
    mov  TMPI, bx
    call OutPutIdx
    cmp  CCONF[si], 0
    jne  bo_ok
    inc  NUNSURE
bo_ok:
    mov  di, si
bo_nx:
    inc  si
    jmp  bo_lp
bo_done:
    pop  di
    pop  si
    pop  bx
    pop  ax
    ret
BuildOutput endp

OutPut proc                        ; AL = separator (no glyph index)
    push bx
    mov  bx, NOUT
    mov  OUTCH[bx], al
    shl  bx, 1
    mov  OUTIDX[bx], 0FFFFh
    inc  NOUT
    pop  bx
    ret
OutPut endp

OutPutIdx proc                     ; AL = char, TMPI = glyph index
    push bx
    mov  bx, NOUT
    mov  OUTCH[bx], al
    shl  bx, 1
    mov  ax, TMPI
    mov  OUTIDX[bx], ax
    inc  NOUT
    pop  bx
    ret
OutPutIdx endp


; ============================================================================
;                    READ  /  REVIEW  /  TEACH  /  SAVE
; ============================================================================
SetCur proc                        ; DH row, DL col
    push ax
    push bx
    mov  ah, 2
    xor  bh, bh
    int  10h
    pop  bx
    pop  ax
    ret
SetCur endp

PrintCont proc                     ; print SI at cursor, colour TCOL
    push ax
    push bx
    push si
pc_n:
    lodsb
    cmp  al, 0
    je   pc_d
    mov  ah, 0Eh
    xor  bh, bh
    mov  bl, TCOL
    int  10h
    jmp  pc_n
pc_d:
    pop  si
    pop  bx
    pop  ax
    ret
PrintCont endp

; ----------------------------------------------------------------------------
DoRead proc
    push ax
    push si
    mov  ax, 2
    int  33h
    cmp  PTCOUNT, 0
    jne  dr_go
    mov  si, offset msgNoInk
    call SetStatus
    jmp  dr_end
dr_go:
    call Redraw                    ; clean ink only: boxes must not pollute reading
    call Recognize
    cmp  NCH, 0
    jne  dr_have
    mov  si, offset msgNoInk
    call SetStatus
    jmp  dr_end
dr_have:
    mov  STATE, 1
    mov  SELCH, 0FFFFh
    call DrawBoxes
    call ShowResults
    call WriteTextFile
    mov  TCOL, 14
    mov  si, offset msgRead1
    call SetStatus
dr_end:
    mov  ax, 1
    int  33h
    pop  si
    pop  ax
    ret
DoRead endp

ShowReview proc                    ; redraw boxes / highlight / prompt
    push ax
    mov  ax, 2
    int  33h
    call Redraw
    call DrawBoxes
    call ShowResults
    call ShowSelPrompt
    mov  ax, 1
    int  33h
    pop  ax
    ret
ShowReview endp

ShowSelPrompt proc
    push ax
    push bx
    push dx
    push si
    cmp  SELCH, 0FFFFh
    je   sp_none
    mov  TCOL, 11
    mov  dh, 26
    mov  dl, 1
    mov  si, offset msgSelA
    call PrintStr
    mov  ax, SELCH
    inc  ax
    call PrintNum
    mov  si, offset msgSelB
    call PrintCont
    mov  bx, SELCH
    mov  al, CCLS[bx]
    mov  bl, 15
    call PrintChar
    mov  TCOL, 7
    mov  si, offset msgSelC
    call PrintCont
sp_none:
    pop  si
    pop  dx
    pop  bx
    pop  ax
    ret
ShowSelPrompt endp
msgRead1 db 'Read done. Green = confident, red = unsure. Click a character to correct it.',0

ShowResults proc
    push ax
    push bx
    push cx
    push dx
    push si
    call ClearOutputPanel
    mov  TCOL, 15
    mov  dh, 21
    mov  dl, 1
    mov  si, offset msgRes
    call PrintStr
    mov  ax, NCH
    call PrintNum
    mov  si, offset msgChars
    call PrintCont
    mov  TCOL, 12
    mov  ax, NUNSURE
    call PrintNum
    mov  si, offset msgUnsure
    call PrintCont
    mov  dh, 22
    mov  dl, 1
    call SetCur
    mov  ROWN, 22
    mov  COLN, 1
    xor  si, si
sr_lp:
    cmp  si, NOUT
    jae  sr_done
    mov  bx, si
    mov  al, OUTCH[bx]
    shl  bx, 1
    mov  cx, OUTIDX[bx]
    cmp  cx, 0FFFFh
    jne  sr_glyph
    cmp  al, 0Ah
    jne  sr_space
    inc  ROWN
    mov  COLN, 1
    jmp  sr_cur
sr_space:
    mov  bl, 0
    call PrintChar
    inc  COLN
    jmp  sr_wrap
sr_glyph:
    mov  bl, COL_SURE
    mov  bx, cx
    cmp  CCONF[bx], 0
    mov  bl, COL_SURE
    jne  sr_c1
    mov  bl, COL_UNSURE
sr_c1:
    cmp  cx, SELCH
    jne  sr_pr
    mov  bl, COL_SEL
sr_pr:
    call PrintChar
    inc  COLN
sr_wrap:
    cmp  COLN, 78
    jb   sr_nx
    inc  ROWN
    mov  COLN, 1
sr_cur:
    cmp  ROWN, 25
    ja   sr_done
    mov  dh, ROWN
    mov  dl, COLN
    call SetCur
sr_nx:
    inc  si
    jmp  sr_lp
sr_done:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
ShowResults endp

DrawBoxes proc
    push ax
    push bx
    push si
    xor  si, si
db_lp:
    cmp  si, NCH
    jae  db_done
    mov  bx, si
    shl  bx, 1
    mov  ax, CX1[bx]
    sub  ax, 2
    jge  db_a
    xor  ax, ax
db_a:
    mov  RX1, ax
    mov  ax, CX2[bx]
    add  ax, 2
    cmp  ax, 639
    jbe  db_b
    mov  ax, 639
db_b:
    mov  RX2, ax
    mov  ax, CY1[bx]
    sub  ax, 2
    cmp  ax, CANV_Y1
    jge  db_c
    mov  ax, CANV_Y1
db_c:
    mov  RY1, ax
    mov  ax, CY2[bx]
    add  ax, 2
    cmp  ax, CANV_Y2
    jle  db_d
    mov  ax, CANV_Y2
db_d:
    mov  RY2, ax
    mov  RCOL, COL_SURE
    cmp  CCLS[si], CLS_NOISE
    jne  db_n
    mov  RCOL, 7
    jmp  db_draw
db_n:
    cmp  CCONF[si], 0
    jne  db_draw
    mov  RCOL, COL_UNSURE
db_draw:
    call DrawBox
    cmp  si, SELCH
    jne  db_nx
    mov  RCOL, 15                  ; selected: extra white frame
    sub  RX1, 2
    jge  db_s1
    mov  RX1, 0
db_s1:
    add  RX2, 2
    sub  RY1, 2
    add  RY2, 2
    call DrawBox
db_nx:
    inc  si
    jmp  db_lp
db_done:
    pop  si
    pop  bx
    pop  ax
    ret
DrawBoxes endp

WriteTextFile proc                 ; TEXT.OUT = recognised text (CR/LF lines)
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  di, offset FBUF
    xor  si, si
wt_lp:
    cmp  si, NOUT
    jae  wt_wr
    mov  al, OUTCH[si]
    cmp  al, 0Ah
    jne  wt_c
    mov  byte ptr [di], 13
    inc  di
wt_c:
    mov  [di], al
    inc  di
    inc  si
    jmp  wt_lp
wt_wr:
    mov  cx, di
    sub  cx, offset FBUF
    mov  TMPW, cx
    mov  ah, 3Ch
    xor  cx, cx
    mov  dx, offset fnText
    int  21h
    jc   wt_end
    mov  bx, ax
    mov  cx, TMPW
    mov  dx, offset FBUF
    mov  ah, 40h
    int  21h
    mov  ah, 3Eh
    int  21h
wt_end:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
WriteTextFile endp

; ============================================================================
;                                  TEACHING
; ============================================================================
TCLS  db 0
TOLD  db 0
TIDXC dw 0                         ; char being taught
GPTR  dw 0
KEY2  db 0
TT    db 0                         ; target class for TrainGrid
PMI   dw 0

; ---- add / update a learned-memory entry (BENT bytes) ----
GPTR57 dw 0
AddBank proc                       ; TIDXC = char, TCLS = class
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pop  es
    mov  bx, TIDXC
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    lea  dx, CGRID[bx]
    mov  GPTR, dx
    lea  dx, CG57[bx]
    mov  GPTR57, dx
    mov  si, offset BANK
    mov  TMPW, 0
ab_find:
    mov  ax, TMPW
    cmp  ax, NBANK
    jae  ab_new
    test byte ptr [si+16], 4
    jnz  ab_nx
    push si
    mov  di, GPTR
    mov  cx, 8
    cld
    repe cmpsb
    jne  ab_pop
    mov  di, GPTR57
    mov  cx, 7
    repe cmpsb
ab_pop:
    pop  si
    jne  ab_nx
    mov  bx, TIDXC
    mov  al, CFLAG[bx]
    and  al, 1
    cmp  al, [si+16]
    jne  ab_nx
    mov  al, CASP[bx]
    mov  ah, [si+17]
    sub  al, ah
    jnc  ab_a1
    neg  al
ab_a1:
    cmp  al, 8
    ja   ab_nx
    mov  al, TCLS
    mov  [si+15], al               ; same look already stored: update label
    jmp  ab_done
ab_nx:
    add  si, BENT
    inc  TMPW
    jmp  ab_find
ab_new:
    mov  ax, NBANK
    cmp  ax, BANKMAX
    jae  ab_ring
    inc  NBANK
    jmp  ab_slot
ab_ring:
    mov  ax, BANKNXT
    inc  BANKNXT
    cmp  BANKNXT, BANKMAX
    jb   ab_slot
    mov  BANKNXT, 0
    jmp  ab_slot
ab_slot:
    cmp  ax, NBANK
    jb   ab_s2
    mov  ax, NBANK
    dec  ax
ab_s2:
    mov  bx, BENT
    mul  bx
    mov  di, offset BANK
    add  di, ax
    mov  si, GPTR
    mov  cx, 8
    rep  movsb
    mov  si, GPTR57
    mov  cx, 7
    rep  movsb
    mov  al, TCLS
    mov  [di], al
    mov  bx, TIDXC
    mov  al, CFLAG[bx]
    and  al, 1
    mov  [di+1], al
    mov  al, CASP[bx]
    mov  [di+2], al
ab_done:
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
AddBank endp

AddBankTiny proc                   ; punctuation-like blobs: store geometry key
    push ax
    push bx
    push cx
    push si
    mov  bx, TIDXC
    mov  dl, CRATIO[bx]            ; key
    mov  KEY2, dl
    mov  si, offset BANK
    mov  cx, NBANK
    jcxz at_new
at_f:
    test byte ptr [si+16], 4
    jz   at_n
    mov  dl, KEY2
    cmp  [si], dl
    jne  at_n
    mov  al, TCLS
    mov  [si+15], al
    jmp  at_done
at_n:
    add  si, BENT
    loop at_f
at_new:
    mov  ax, NBANK
    cmp  ax, BANKMAX
    jae  at_ring
    inc  NBANK
    jmp  at_slot
at_ring:
    mov  ax, BANKNXT
    inc  BANKNXT
    cmp  BANKNXT, BANKMAX
    jb   at_slot
    mov  BANKNXT, 0
at_slot:
    cmp  ax, NBANK
    jb   at_s2
    mov  ax, NBANK
    dec  ax
at_s2:
    mov  bx, BENT
    mul  bx
    mov  si, offset BANK
    add  si, ax
    xor  al, al
    mov  cx, BENT
at_z:
    mov  [si], al
    inc  si
    loop at_z
    sub  si, BENT
    mov  al, KEY2
    mov  [si], al
    mov  al, TCLS
    mov  [si+15], al
    mov  byte ptr [si+16], 4
at_done:
    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
AddBankTiny endp

; ---- perceptron training on GRID8 toward TT ----
UpdW proc                          ; AX = class to raise(+) ; BX = class to lower
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov  PMI, bx
    mov  di, ax                    ; target
    mov  cx, NACT
    xor  si, si
uw_lp:
    cmp  si, cx
    jae  uw_b
    mov  al, ACT[si]
    xor  ah, ah
    mov  bx, di
    mov  dx, 6
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1                     ; class*64
    add  bx, ax
    mov  al, WTS[bx]
    cbw
    add  ax, 4
    cmp  ax, 127
    jle  uw_p1
    mov  ax, 127
uw_p1:
    mov  WTS[bx], al
    mov  bx, PMI
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    mov  al, ACT[si]
    xor  ah, ah
    add  bx, ax
    mov  al, WTS[bx]
    cbw
    sub  ax, 4
    cmp  ax, -127
    jge  uw_p2
    mov  ax, -127
uw_p2:
    mov  WTS[bx], al
    inc  si
    jmp  uw_lp
uw_b:
    mov  bx, di
    shl  bx, 1
    add  BIAS[bx], 8
    mov  bx, PMI
    shl  bx, 1
    sub  BIAS[bx], 8
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
UpdW endp

TrainGrid proc                     ; GRID8 set, TT = ASCII, CX = max iterations
    push ax
    push bx
    push cx
    push dx
    push si
    mov  bl, TT
    call ClsIdx
    cmp  ax, 0FFFFh
    je   tg_ret
    mov  TMPI, ax                  ; target class index
tg_it:
    push cx
    call ScorePerc
    xor  si, si                    ; argmax
    mov  bx, 0
    mov  dx, 8000h
tg_am:
    mov  ax, PSC[bx]
    cmp  ax, dx
    jle  tg_a1
    mov  dx, ax
    mov  si, bx
    shr  si, 1
tg_a1:
    add  bx, 2
    cmp  bx, 124
    jb   tg_am
    cmp  si, TMPI
    je   tg_ok
    mov  ax, si
    call IdxCls                    ; AL = ASCII of the wrongly winning class
    mov  bl, al
    xor  bh, bh
    mov  dl, GRP[bx]
    cmp  dl, 0FFh
    je   tg_upd
    mov  bl, TT
    xor  bh, bh
    cmp  GRP[bx], dl
    je   tg_ok                     ; same look-alike group: not a shape error
tg_upd:
    mov  ax, TMPI
    mov  bx, si
    call UpdW
    pop  cx
    dec  cx
    jnz  tg_it
    jmp  tg_ret
tg_ok:
    pop  cx
tg_ret:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
TrainGrid endp

CopyGridToGRID8 proc               ; AX = char index
    push ax
    push bx
    push cx
    push si
    push di
    push es
    push ds
    pop  es
    mov  bx, ax
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    lea  si, CGRID[bx]
    mov  di, offset GRID8
    mov  cx, 8
    cld
    rep  movsb
    pop  es
    pop  di
    pop  si
    pop  cx
    pop  bx
    pop  ax
    ret
CopyGridToGRID8 endp

AddProto proc                      ; learn the 5x7 look of this character
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pop  es
    mov  bx, TIDXC
    shl  bx, 1
    shl  bx, 1
    shl  bx, 1
    lea  dx, CG57[bx]
    mov  si, offset LPROT
    mov  TMPW, 0
ap_f:
    mov  ax, TMPW
    cmp  ax, NLPROT
    jae  ap_new
    mov  di, dx
    push si
    mov  cx, 7
    cld
    repe cmpsb
    pop  si
    jne  ap_n
    mov  al, TCLS
    mov  [si+7], al
    jmp  ap_done
ap_n:
    add  si, 8
    inc  TMPW
    jmp  ap_f
ap_new:
    mov  ax, NLPROT
    cmp  ax, LPROTMAX
    jae  ap_ring
    inc  NLPROT
    jmp  ap_slot
ap_ring:
    mov  ax, LPNXT
    inc  LPNXT
    cmp  LPNXT, LPROTMAX
    jb   ap_slot
    mov  LPNXT, 0
ap_slot:
    mov  cl, 3
    shl  ax, cl
    mov  di, offset LPROT
    add  di, ax
    mov  si, dx
    mov  cx, 7
    rep  movsb
    mov  al, TCLS
    mov  [di], al
ap_done:
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
AddProto endp

RetallChar proc
    push ax
    push bx
    push cx
    mov  bx, TIDXC
    and  CFLAG[bx], 0FEh
    mov  al, CRATIO[bx]
    xor  ah, ah
    mov  cx, ax
    test CFLAG[bx], 10h
    jz   rt_rel
    shl  bx, 1
    mov  cx, CY2[bx]
    sub  cx, CY1[bx]
    inc  cx
    cmp  cx, ABS_T
    jb   rt_ret
    jmp  rt_tall
rt_rel:
    cmp  cx, CASE_T
    jb   rt_ret
rt_tall:
    mov  bx, TIDXC
    or   CFLAG[bx], 1
rt_ret:
    pop  cx
    pop  bx
    pop  ax
    ret
RetallChar endp

AdaptCase proc                     ; learn the size threshold from a case fix
    push ax
    push bx
    push cx
    mov  al, TOLD
    mov  ah, TCLS
    mov  bl, al
    xor  bl, ah
    cmp  bl, 20h
    jne  ac_ret                    ; not a pure case change
    mov  bl, ah
    or   bl, 20h
    cmp  bl, 'a'
    jb   ac_ret
    cmp  bl, 'z'
    ja   ac_ret
    mov  bx, TIDXC
    mov  cl, CFLAG[bx]
    xor  ch, ch
    mov  al, CRATIO[bx]
    xor  ah, ah
    mov  dl, TCLS
    cmp  dl, 'Z'
    ja   ac_lower                  ; user says: lower case
    ; user says: tall (upper case)
    test cl, 10h
    jnz  ac_up_abs
    cmp  ax, CASE_T
    jae  ac_ret
    cmp  ax, 35
    jge  ac_u1
    mov  ax, 35
ac_u1:
    mov  CASE_T, ax
    jmp  ac_ret
ac_up_abs:
    mov  bx, TIDXC
    shl  bx, 1
    mov  ax, CY2[bx]
    sub  ax, CY1[bx]
    inc  ax
    cmp  ax, ABS_T
    jae  ac_ret
    cmp  ax, 16
    jge  ac_u2
    mov  ax, 16
ac_u2:
    mov  ABS_T, ax
    jmp  ac_ret
ac_lower:
    test cl, 10h
    jnz  ac_lo_abs
    cmp  ax, CASE_T
    jb   ac_ret
    inc  ax
    cmp  ax, 95
    jle  ac_l1
    mov  ax, 95
ac_l1:
    mov  CASE_T, ax
    jmp  ac_ret
ac_lo_abs:
    mov  bx, TIDXC
    shl  bx, 1
    mov  ax, CY2[bx]
    sub  ax, CY1[bx]
    inc  ax
    cmp  ax, ABS_T
    jb   ac_ret
    inc  ax
    cmp  ax, 120
    jle  ac_l2
    mov  ax, 120
ac_l2:
    mov  ABS_T, ax
ac_ret:
    pop  cx
    pop  bx
    pop  ax
    ret
AdaptCase endp

Consolidate proc                   ; re-check every taught sample against the
    push ax                        ; shape model so new training cannot break old
    push bx
    push cx
    push dx
    push si
    push di
    push es
    mov  dx, 2                     ; two sweeps
cs_sweep:
    push dx
    mov  si, offset BANK
    mov  TMPW, 0
cs_e:
    mov  ax, TMPW
    cmp  ax, NBANK
    jae  cs_next
    test byte ptr [si+16], 4
    jnz  cs_nx
    mov  al, [si+15]
    cmp  al, CLS_NOISE
    je   cs_nx
    mov  TT, al
    push si
    push ds
    pop  es
    mov  di, offset GRID8
    mov  cx, 8
    cld
    rep  movsb
    pop  si
    mov  cx, 3
    call TrainGrid
cs_nx:
    add  si, BENT
    inc  TMPW
    jmp  cs_e
cs_next:
    pop  dx
    dec  dx
    jnz  cs_sweep
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
Consolidate endp

; ----------------------------------------------------------------------------
;  TeachChar : AX = char index, DL = correct ASCII (CLS_NOISE = ignore blob)
;     remember -> train models -> re-read screen -> verify -> save
; ----------------------------------------------------------------------------
TeachChar proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    cmp  ax, NCH
    jb   tc_ok
    jmp  tc_out
tc_ok:
    mov  TIDXC, ax
    mov  TCLS, dl
    mov  bx, ax
    mov  al, CCLS[bx]
    mov  TOLD, al
    mov  ax, 2
    int  33h
    mov  bx, TIDXC
    test CFLAG[bx], 0Ch
    jz   tc_norm
    call AddBankTiny
    jmp  tc_verify
tc_norm:
    call AdaptCase                 ; learn size threshold first ...
    call RetallChar                ; ... then re-evaluate this glyph's size flag
    call AddBank
    cmp  TCLS, CLS_NOISE
    je   tc_verify
    mov  ax, TIDXC
    call CopyGridToGRID8
    mov  al, TCLS
    mov  TT, al
    mov  cx, 12
    call TrainGrid
    call AddProto
    call Consolidate
tc_verify:
    inc  NTAUGHT
    call Redraw                    ; re-read the SCREEN from scratch
    call Recognize
    call DrawBoxes
    call ShowResults
    call ShowSelPrompt
    call SaveLearn
    ; verification: does the fresh read now give the corrected answer?
    mov  FOUND, 0
    mov  ax, TIDXC
    cmp  ax, NCH
    jae  tc_say
    mov  bx, ax
    mov  al, CCLS[bx]
    cmp  al, TCLS
    jne  tc_say
    mov  FOUND, 1
tc_say:
    cmp  TCLS, CLS_NOISE
    jne  tc_msg
    mov  si, offset msgNoiseA
    call SetStatus
    jmp  tc_show
tc_msg:
    mov  si, offset msgLearnA
    call SetStatus
    mov  al, TOLD
    cmp  al, 0
    jne  tc_o
    mov  al, '?'
tc_o:
    mov  bl, 14
    call PrintChar
    mov  TCOL, 14
    mov  si, offset msgArrow
    call PrintCont
    mov  al, TCLS
    mov  bl, 11
    call PrintChar
    mov  TCOL, 10
    mov  si, offset msgVerOK
    cmp  FOUND, 1
    je   tc_vp
    mov  TCOL, 12
    mov  si, offset msgVerBad
tc_vp:
    call PrintCont
tc_show:
    call ShowTitle
    mov  ax, 1
    int  33h
tc_out:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
TeachChar endp
msgArrow db ' -> ',0

; ============================================================================
;                       MODEL RESET  /  FORGET  /  PERSISTENCE
; ============================================================================
ResetModel proc
    push ax
    push cx
    push si
    push di
    push ds
    push es
    mov  ax, @data
    mov  es, ax
    mov  ax, RODATA
    mov  ds, ax
    mov  si, offset ORIGW
    mov  di, offset WTS
    mov  cx, 62*32
    cld
    rep  movsw
    mov  si, offset ORIGB
    mov  di, offset BIAS
    mov  cx, 62
    rep  movsw
    pop  es
    pop  ds
    mov  NBANK, 0
    mov  BANKNXT, 0
    mov  NLPROT, 0
    mov  LPNXT, 0
    mov  CASE_T, 68
    mov  ABS_T, 42
    pop  di
    pop  si
    pop  cx
    pop  ax
    ret
ResetModel endp

DoForget proc
    push ax
    push dx
    push si
    mov  ax, 2
    int  33h
    mov  si, offset msgForget
    call SetStatus
    xor  ah, ah
    int  16h
    cmp  al, 'Y'
    je   df_yes
    cmp  al, 'y'
    je   df_yes
    mov  si, offset msgCancel
    call SetStatus
    jmp  df_end
df_yes:
    call ResetModel
    mov  ah, 41h
    mov  dx, offset fnLearn
    int  21h
    mov  si, offset msgForgot
    call SetStatus
    call ShowTitle
df_end:
    mov  ax, 1
    int  33h
    pop  si
    pop  dx
    pop  ax
    ret
DoForget endp

; ---- SaveLearn: whole model -> FBUF -> LEARN.DAT (with checksum) ----
SaveLearn proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pop  es
    cld
    mov  di, offset FBUF
    mov  si, offset magic
    mov  cx, 4
    rep  movsb
    mov  ax, YOFF
    stosw
    mov  ax, CASE_T
    stosw
    mov  ax, ABS_T
    stosw
    mov  ax, NBANK
    stosw
    mov  ax, NLPROT
    stosw
    mov  ax, BANKNXT
    stosw
    mov  ax, LPNXT
    stosw
    mov  si, offset BANK
    mov  ax, NBANK
    mov  bx, BENT
    mul  bx
    mov  cx, ax
    rep  movsb
    mov  si, offset LPROT
    mov  ax, NLPROT
    mov  cl, 3
    shl  ax, cl
    mov  cx, ax
    rep  movsb
    mov  si, offset WTS
    mov  cx, 62*64
    rep  movsb
    mov  si, offset BIAS
    mov  cx, 124
    rep  movsb
    mov  cx, di
    sub  cx, offset FBUF
    mov  TMPW, cx                  ; payload length
    mov  si, offset FBUF
    xor  ax, ax
    xor  bx, bx
sv_sum:
    mov  bl, [si]
    add  ax, bx
    inc  si
    loop sv_sum
    stosw
    mov  ah, 3Ch
    xor  cx, cx
    mov  dx, offset fnLearn
    int  21h
    jc   sv_fail
    mov  bx, ax
    mov  cx, TMPW
    add  cx, 2
    mov  dx, offset FBUF
    mov  ah, 40h
    int  21h
    pushf
    mov  ah, 3Eh
    int  21h
    popf
    jc   sv_fail
    mov  LOADOK, 3
    jmp  sv_end
sv_fail:
    mov  LOADOK, 4
sv_end:
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
SaveLearn endp

; ---- LoadLearn: LEARN.DAT -> model, only if every check passes ----
LoadLearn proc
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pop  es
    mov  LOADOK, 0
    mov  ax, 3D00h
    mov  dx, offset fnLearn
    int  21h
    jc   ll_end
    mov  bx, ax
    mov  ah, 3Fh
    mov  cx, FBUFSZ
    mov  dx, offset FBUF
    int  21h
    mov  TMPW, ax
    mov  ah, 3Eh
    int  21h
    mov  ax, TMPW
    cmp  ax, 18+4092+2
    jb   ll_bad
    cld
    mov  si, offset FBUF
    mov  di, offset magic
    mov  cx, 4
    repe cmpsb
    jne  ll_bad
    mov  ax, word ptr FBUF[10]     ; NBANK
    cmp  ax, BANKMAX
    ja   ll_bad
    mov  bx, BENT
    mul  bx
    mov  TMPI, ax
    mov  ax, word ptr FBUF[12]     ; NLPROT
    cmp  ax, LPROTMAX
    ja   ll_bad
    mov  cl, 3
    shl  ax, cl
    add  ax, TMPI
    add  ax, 18+4092
    mov  TMPI, ax                  ; expected payload length
    add  ax, 2
    cmp  ax, TMPW
    jne  ll_bad
    mov  si, offset FBUF           ; checksum
    mov  cx, TMPI
    xor  ax, ax
    xor  bx, bx
ll_sum:
    mov  bl, [si]
    add  ax, bx
    inc  si
    loop ll_sum
    cmp  ax, [si]
    jne  ll_bad
    ; ---- all good: install ----
    mov  ax, word ptr FBUF[4]
    cmp  ax, -40
    jl   ll_y1
    cmp  ax, 40
    jg   ll_y1
    mov  YOFF, ax
ll_y1:
    mov  ax, word ptr FBUF[6]
    mov  CASE_T, ax
    mov  ax, word ptr FBUF[8]
    mov  ABS_T, ax
    mov  ax, word ptr FBUF[10]
    mov  NBANK, ax
    mov  ax, word ptr FBUF[12]
    mov  NLPROT, ax
    mov  ax, word ptr FBUF[14]
    mov  BANKNXT, ax
    mov  ax, word ptr FBUF[16]
    mov  LPNXT, ax
    mov  si, offset FBUF+18
    mov  di, offset BANK
    mov  ax, NBANK
    mov  bx, BENT
    mul  bx
    mov  cx, ax
    rep  movsb
    mov  di, offset LPROT
    mov  ax, NLPROT
    mov  cl, 3
    shl  ax, cl
    mov  cx, ax
    rep  movsb
    mov  di, offset WTS
    mov  cx, 62*64
    rep  movsb
    mov  di, offset BIAS
    mov  cx, 124
    rep  movsb
    mov  LOADOK, 1
    jmp  ll_end
ll_bad:
    mov  LOADOK, 2
ll_end:
    pop  es
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret
LoadLearn endp


RODATA segment para public 'FAR_DATA'
ORIGW label byte
 db -23,-16,-4,-5,-3,-4,-4,-10,-22,-17,-12,-5,-1,6,-13,-13,-14,-8,-5,-5,2,2,-2,-10,-4,-1,3,5,6,6,14,6,-7,-2,6,10,5,27,25,7,1,15,-7,-7,2,13,9,-4,8,11,-34,-41,-15,-10,-1,-3,15,-16,-44,-17,-10,-12,-9,7
 db 5,8,8,11,6,7,4,-6,5,-9,-4,-6,-1,-5,-10,19,-14,-13,-4,-3,-9,0,14,1,-7,-5,7,5,11,20,-5,-39,-3,4,3,-6,5,6,3,-1,-12,11,-6,-24,-45,-13,4,25,11,0,1,6,4,2,-2,6,16,-3,2,7,7,4,-5,-25
 db -76,-31,-16,-12,-11,-6,-4,-17,-29,-13,-3,4,11,5,-1,0,-12,-6,-4,7,-1,-5,-4,4,9,7,-9,-31,-24,-7,-18,-47,19,12,-14,-43,-31,-31,-48,-45,15,6,3,-12,-18,-11,-12,-5,-3,-2,7,17,15,13,7,2,-40,-2,9,12,9,8,6,-9
 db 15,18,11,3,-2,-9,-20,-50,-5,-2,7,12,9,2,-12,-13,-17,-16,-13,-10,-1,0,4,11,-26,-15,-10,-20,-25,-17,5,18,-28,-6,7,-5,-30,-18,13,14,-14,-4,5,-2,-7,-6,-1,12,11,11,17,13,9,-5,-8,-2,15,12,11,3,1,-5,-14,-42
 db -7,-5,1,3,1,6,15,11,-4,0,2,3,5,7,4,1,-2,-2,-3,-12,-29,-41,-49,-43,-9,0,10,10,13,16,-10,-16,-8,13,13,2,6,-1,-21,-28,2,12,-12,-29,-30,-32,-27,-24,13,6,16,18,16,13,4,-1,7,8,7,7,9,3,-3,-1
 db -6,8,8,8,13,18,19,2,-3,3,0,5,7,5,2,7,-9,-7,0,-4,-23,-41,-23,-16,-4,2,16,15,3,0,-7,-4,-2,3,12,12,7,4,-2,-8,-5,0,4,0,-6,-6,-3,-11,-28,-31,-31,-31,-36,-47,-63,-72,-12,-26,-22,-16,-19,-19,-26,-47
 db -61,-27,-10,0,5,7,11,-3,-32,-19,-11,-7,5,4,-8,-1,-8,-7,-8,-14,-32,-31,-47,-71,11,5,-13,-3,-8,-10,-12,-11,14,-4,-28,10,13,17,18,13,27,-1,-25,0,18,19,11,8,3,1,-3,-4,3,-5,-5,-9,-14,4,12,12,8,2,6,-7
 db -10,-17,-23,-24,-23,-16,-19,11,1,-5,-13,-16,-29,-15,-7,-8,-5,1,-3,-13,-32,-3,14,-12,-5,9,18,2,2,14,17,7,2,14,14,0,10,27,17,7,-9,31,-10,-16,-1,4,2,-14,7,11,-22,-26,-7,-8,-4,-6,22,-10,-19,-12,-7,-7,-5,-1
 db -9,7,1,-2,-1,-4,-2,-5,-12,-1,7,1,-2,5,0,-15,-21,-15,-10,3,16,-4,-2,-14,-20,-11,-6,8,10,0,-6,-16,-17,-12,3,11,3,2,-14,-20,-17,-6,1,20,5,-5,-11,-25,-11,0,10,8,3,6,4,-7,-2,4,0,1,-1,4,1,-3
 db 0,14,9,3,-2,0,6,27,-4,10,18,16,13,8,3,-2,-15,-24,-27,-24,-7,-13,-22,-29,-89,-89,-71,-31,-25,-24,-14,-15,-26,-9,-46,-27,-12,-6,0,-9,2,-2,-18,-20,-9,-2,3,-5,9,17,13,11,-1,-12,-11,-1,-34,2,12,12,7,1,-6,-24
 db 6,-13,-17,-11,-21,-21,-29,0,5,-6,-18,-25,-23,-11,4,4,-7,-3,3,5,2,8,11,-1,-1,18,23,4,-5,-15,-34,-38,6,28,7,-1,-6,-27,-48,-60,-5,21,-9,7,4,3,1,-14,7,2,-30,-13,4,13,9,5,19,-14,-29,-28,-5,6,4,20
 db -22,-21,-26,-25,-23,-24,-26,-37,-25,-23,-34,-29,-26,-23,-31,-20,-17,-13,-10,-20,-21,-12,-14,-67,-18,-9,-12,-18,-16,-15,-68,-66,-9,3,-1,-12,-28,-50,-32,-28,-2,13,17,-1,-15,-3,-1,-18,16,37,25,20,19,21,19,6,13,21,9,7,3,7,17,7
 db 2,-14,-13,-17,-20,-21,-24,-5,16,1,6,-2,-9,-6,1,6,3,4,16,22,16,17,11,20,-2,3,5,4,18,4,10,12,3,10,-15,2,18,-11,11,7,9,9,-26,18,10,-18,4,7,10,-17,-42,-17,-15,-21,-11,13,12,-31,-36,-32,-28,-17,-22,-1
 db -21,-24,-29,-30,-27,-32,-20,5,-4,-11,-13,-23,-30,-35,1,3,4,5,12,7,-13,-18,16,0,5,10,17,16,-7,-21,4,9,-6,7,-2,1,4,-7,2,5,-2,26,-7,10,20,5,-1,4,24,7,-28,2,10,8,0,-1,20,-20,-41,-8,-11,-13,-11,-13
 db -44,-24,-7,-5,-7,-10,-9,-27,-19,-11,-2,5,16,15,1,-11,-15,-5,-3,7,17,13,10,7,7,4,-4,-11,-21,-12,14,12,14,14,-4,-27,-33,-3,9,12,10,1,-4,-6,-1,-5,-1,7,-3,-1,13,18,7,-6,-8,-10,-19,5,12,2,2,-6,-18,-88
 db 10,19,16,17,17,17,9,-4,15,10,5,-5,-4,-2,3,24,4,4,11,8,-8,-9,40,34,-3,2,12,13,-3,4,19,20,-8,-1,14,-1,-5,-3,6,5,-12,-1,4,-11,-20,-30,-42,-74,-21,-21,-36,-34,-51,-70,-92,-102,0,-31,-27,-25,-27,-31,-39,-29
 db -39,-17,2,4,9,4,3,-15,-21,-9,-6,6,11,8,-13,-10,-11,-8,-7,-5,-27,-9,-5,12,11,1,-11,-5,-11,-34,-3,17,27,-7,-34,4,14,1,1,-1,13,-4,-13,2,27,21,-8,-24,-5,-12,-5,3,11,7,12,-10,-24,-10,-12,-9,-4,4,9,29
 db -6,1,7,11,11,9,9,-13,2,-8,-6,-6,2,6,-11,9,-2,-4,-6,-5,-9,-7,16,11,-5,4,14,10,5,3,0,-9,-4,13,8,13,4,-14,-46,-55,2,22,-1,5,-3,-10,-11,-9,14,6,-32,-8,8,14,20,7,9,-17,-38,-34,-8,-3,4,20
 db -53,-20,-11,-5,3,8,12,-7,-15,-7,0,1,6,9,6,11,5,9,6,2,-15,-31,-37,-31,-9,-12,-4,2,-6,-11,-27,-53,-45,-40,-23,-10,2,6,6,5,-14,-18,-24,-23,-3,10,15,12,4,9,19,15,13,9,5,4,-12,4,9,8,10,6,-4,-31
 db 23,26,20,14,15,12,6,11,14,21,28,37,37,17,1,6,3,-3,6,17,14,-8,-15,-4,-9,-41,-10,-8,-14,-12,-42,-32,-38,-35,-13,-19,-12,-18,-31,-43,-56,-24,-18,-17,-16,-16,-34,-80,-25,-39,-34,-33,-39,-39,-46,-63,-42,-39,-40,-30,-35,-33,-32,-73
 db -17,-22,-26,-25,-38,-29,-25,-19,1,-2,-11,-18,-28,-15,-5,3,0,1,2,-14,-11,2,10,7,6,4,-2,-33,-5,-7,1,0,8,14,-19,-23,-2,4,-6,-12,15,10,-3,0,12,14,-6,-10,13,7,16,4,11,15,11,6,-11,6,2,-5,-3,2,8,-3
 db 5,-15,-29,-27,-54,-26,-4,1,14,4,-23,-28,-43,-9,17,6,16,28,12,-22,-8,5,5,2,3,21,12,-17,-9,-4,1,-4,-8,16,-2,-10,-3,-3,-11,-19,-4,8,9,13,3,-8,-18,-22,4,-7,1,2,-8,-13,-24,-36,-10,-5,-17,-12,-6,-10,-23,-55
 db 1,-28,-27,-33,-32,-25,-31,12,22,-17,-29,-27,-36,-47,-11,11,17,2,-13,4,-3,-52,5,4,5,16,-8,15,7,-32,-1,16,2,8,-4,12,6,-11,-6,8,10,1,9,17,10,-1,-11,-2,12,11,5,7,7,6,-9,-15,12,0,-14,-14,-5,-2,-13,-42
 db 7,-17,-11,-10,-25,-11,-9,5,9,16,-2,-17,-22,-5,19,-7,-3,2,19,14,8,21,-9,-7,-41,-16,2,13,1,-6,-45,-39,-42,-38,-4,5,12,0,-21,-42,-10,-14,21,5,20,21,-2,2,-1,27,-13,-16,-8,11,12,8,15,-9,-12,-17,-9,-2,-4,19
 db 11,6,-7,-15,-15,-30,-5,15,18,25,3,-1,-23,-12,27,1,2,14,17,18,11,14,6,-6,-18,-4,5,6,3,4,0,-14,-22,-20,-3,-2,-1,1,-1,-11,-39,-25,-15,-13,-13,-13,-19,-25,-21,-17,-22,-26,-31,-27,-28,-27,5,-4,-9,0,-4,-7,-7,-24
 db 22,21,16,9,9,9,0,-10,-6,6,17,11,10,4,-1,-3,-29,-38,-41,-28,-11,1,-6,-17,-40,-37,-20,-22,-7,-6,-6,-12,-11,-11,7,-2,-17,-27,-42,-38,-23,-5,13,-5,-15,-1,0,-3,9,15,15,12,14,14,15,19,16,14,9,2,-2,4,12,19
 db -28,-16,1,-4,-10,-8,-7,-26,-25,-10,6,19,11,1,-13,-10,-20,-15,-15,-3,-6,-7,-1,0,2,-4,-11,-1,-2,-1,0,-5,19,9,-16,-4,2,7,-7,-14,25,9,-3,6,12,11,-3,-4,5,6,7,1,9,15,24,9,-15,6,-6,-21,-8,4,10,-1
 db -2,-12,-22,-25,-24,-25,-22,-13,-12,-23,-35,-37,-40,-39,-42,-49,-15,-14,-8,-17,-17,-15,-38,-68,-17,-3,1,5,5,-4,-12,-7,-21,-1,14,5,7,3,17,12,-12,6,25,7,-9,6,33,15,14,30,16,3,5,12,12,10,17,18,15,24,19,16,3,-24
 db -73,-31,-10,-11,-10,-6,-10,-18,-29,-13,-4,8,14,9,-7,0,-13,-7,-4,6,3,-6,-5,-1,10,7,-12,-34,-17,-2,-22,-49,17,12,-16,-41,-31,-33,-49,-42,14,12,-1,-14,-21,-6,-5,-3,-5,0,13,22,17,17,11,4,-24,1,13,12,10,9,6,-4
 db -16,-26,-24,-24,-29,-26,-25,-2,-39,-33,-37,-37,-34,-39,-26,-22,-89,-82,-43,-27,-18,-9,-5,-19,-38,-4,-13,-5,2,14,2,-6,13,5,-4,2,19,14,-1,-15,23,29,-11,-3,16,14,3,-13,24,16,-1,3,10,17,25,15,-3,9,9,9,13,15,25,27
 db -39,-36,-13,-5,-4,-4,-7,-36,-20,-13,-1,5,12,6,-5,4,-1,6,8,8,1,0,11,16,17,16,20,17,7,6,-4,-19,23,11,-2,0,-4,-17,-43,-32,3,1,-12,-23,-36,-25,-13,1,-16,-13,6,16,16,11,7,7,-37,-5,2,3,4,5,6,-5
 db -38,0,3,10,16,23,16,2,-22,-3,-4,-4,-1,6,4,9,-16,-13,-2,-4,-17,-35,-18,-16,-3,-3,11,13,0,-5,-13,-8,1,-2,14,14,7,3,1,-4,0,-2,11,3,-2,-4,-2,-4,-38,-33,-23,-24,-30,-40,-52,-64,-16,-22,-17,-10,-11,-17,-27,-21
 db -65,-12,-1,7,14,16,8,-4,-12,-1,3,10,6,-3,0,3,8,13,6,1,6,15,13,0,8,-2,-5,-3,2,9,7,-7,-9,-18,-8,-2,-4,6,9,-8,-23,-21,-12,-10,-3,-1,4,-4,2,-11,-8,-16,-18,-17,-15,-6,1,0,0,0,2,-1,2,-2
 db 2,-10,-16,-18,-17,-15,-10,2,-15,-20,-31,-36,-39,-34,-38,-39,-20,-15,-13,-16,-18,-21,-38,-79,-14,-4,5,0,3,-4,-13,0,-20,0,11,4,0,3,17,9,-4,12,26,10,-2,13,25,-1,16,34,1,-22,-12,16,25,11,4,1,-19,-36,-4,12,25,16
 db -16,7,3,-2,0,0,3,-14,-17,-2,0,-3,-2,5,-1,-14,-33,-25,-21,-19,-16,-23,-17,-37,-23,-14,-6,0,1,2,-12,-17,-27,-10,11,10,13,6,-1,-20,-20,0,13,27,14,7,-2,-25,-17,2,16,9,5,5,7,-13,-6,13,4,5,4,12,8,-9
 db -30,0,-5,-12,-9,-8,1,3,-35,-8,-3,-11,-15,-13,-18,-26,-47,-52,-37,-34,-26,-23,-35,-44,-59,-46,-22,-17,-14,1,-2,-4,-15,-13,-29,-16,-2,8,7,0,-9,-5,-15,-17,4,17,15,-3,-3,11,21,12,11,6,9,3,-16,12,16,15,14,12,10,3
 db 11,-9,-15,-11,-13,-27,-33,-27,-9,-13,-23,-26,-31,-23,-15,-11,-10,-5,-5,-2,0,3,2,3,-13,7,15,6,2,0,-2,-1,-2,20,16,7,0,-14,-30,-36,0,29,5,9,5,-7,-16,-27,7,15,-18,-2,6,14,12,3,19,-3,-21,-23,1,5,11,17
 db -2,14,5,-5,-2,-5,1,-5,-16,-1,1,-6,-8,-1,2,-15,-17,-10,-3,6,13,10,0,-13,-14,-9,-2,4,14,6,-9,-13,-14,-12,2,16,9,0,-10,-14,-13,-9,14,13,5,-5,-10,-23,-13,4,4,-4,-5,0,-2,-13,0,4,-3,1,2,8,11,5
 db 4,-14,-8,-17,-22,-24,-22,-12,14,0,11,2,-7,-7,-1,6,8,7,20,26,21,15,9,17,3,6,9,7,17,3,6,12,6,11,-13,3,16,-13,6,10,6,6,-22,22,9,-23,3,5,7,-19,-37,-13,-16,-29,-10,12,12,-32,-30,-28,-32,-17,-16,4
 db -2,-8,-13,-12,-13,-18,-16,-22,18,7,7,7,2,3,-4,-1,-1,3,14,15,13,7,13,10,-7,-1,8,2,-12,-12,14,4,-3,4,6,-3,-33,0,12,-1,5,19,6,-8,-20,3,4,2,4,2,-20,-35,-12,-4,9,11,-6,-22,-28,-46,-16,-17,-10,-17
 db -65,-25,-6,-4,-6,-8,-12,-28,-25,-8,0,7,22,16,2,-11,-14,-4,-1,7,16,12,11,9,6,4,-7,-14,-23,-13,15,11,13,15,-5,-28,-34,-2,9,11,4,5,-9,-9,-3,-4,3,4,-8,2,13,18,7,-4,-9,-15,-9,8,13,6,5,1,-7,-52
 db 2,14,9,13,15,14,7,-10,12,10,4,2,5,6,4,17,4,6,6,7,-16,-9,36,33,-4,7,14,11,0,6,25,17,-6,4,17,3,-4,3,11,11,-14,6,8,-3,-8,-12,-23,-42,-27,-18,-32,-40,-52,-63,-78,-127,13,-14,-20,-18,-40,-40,-58,-32
 db -62,-14,1,12,16,18,8,-8,-9,3,3,11,0,-2,3,3,16,17,4,6,10,12,9,0,14,8,-6,6,11,5,-4,-10,2,-14,-8,4,6,2,-1,-12,-33,-23,-3,0,0,-3,-4,-7,-32,-28,-27,-16,-12,-15,-12,-12,6,-1,-7,-4,-5,-5,0,3
 db 14,6,-12,-11,-8,-2,-7,-31,19,14,5,2,3,11,-1,1,4,12,24,22,7,-1,14,13,3,17,18,2,-14,-15,10,17,-3,19,7,-6,-23,-35,-3,8,-10,5,13,-6,-22,-44,-73,-79,-4,-15,-21,-23,-25,-25,-43,-46,-22,-27,-32,-21,-33,-34,-31,-40
 db -51,-23,-12,-5,1,7,9,-11,-13,-5,-2,2,9,11,7,9,3,14,9,5,-13,-28,-38,-34,-4,-11,-1,2,-4,-7,-19,-40,-46,-40,-21,-11,1,7,6,5,-15,-18,-24,-24,-4,7,16,9,5,9,18,14,12,9,8,-2,-6,6,8,9,11,6,-2,-17
 db -46,-28,-21,-13,-13,-18,-26,-31,-20,-30,-16,-11,-12,-10,-23,-27,3,-2,8,13,14,10,-4,-1,7,-4,9,14,7,1,-3,0,-3,-8,2,-2,0,-1,-1,-4,-30,-20,1,-5,-18,-23,-30,-39,-29,-24,-12,-11,-10,-7,-15,-18,-15,-8,-4,7,4,0,-7,-25
 db -20,-19,-22,-28,-36,-27,-25,-27,1,-2,-12,-22,-29,-16,-2,1,0,1,2,-19,-8,0,10,7,5,9,-4,-25,-3,-5,1,-3,9,11,-15,-14,1,6,-5,-13,14,18,6,4,16,17,-1,-11,7,6,19,4,14,17,14,7,-8,7,3,-2,-3,8,13,4
 db -6,-12,-34,-35,-51,-17,-5,-8,13,5,-19,-41,-39,-9,17,9,18,27,12,-23,-6,6,9,3,6,27,15,-16,-8,-3,1,-1,-6,15,0,-4,-3,-2,-8,-15,-5,7,13,15,4,-5,-16,-19,0,-8,3,5,-2,-15,-20,-35,-14,-4,-15,-9,-5,-5,-14,-47
 db -7,-26,-29,-41,-39,-29,-34,0,11,-18,-28,-24,-39,-43,-6,14,13,5,-13,4,0,-35,13,13,7,19,-7,20,8,-26,-1,18,13,10,-2,17,11,-3,-5,8,17,4,14,27,18,10,-7,0,13,18,9,8,15,12,-7,-13,6,1,-16,-14,2,4,-8,-40
 db -5,-17,-19,-18,-25,-16,-12,-5,5,11,0,-19,-21,0,18,-2,0,7,23,18,11,16,-3,-9,-14,-14,5,13,8,-2,-40,-33,-36,-31,4,13,14,1,-16,-11,-6,-11,22,9,23,20,4,-3,-3,25,-9,-20,-11,13,3,3,7,-6,-12,-19,-12,-2,0,8
 db -1,2,-13,-16,-38,-22,-5,11,14,25,0,-12,-34,-8,22,0,10,18,17,15,2,16,7,-2,-4,1,7,9,8,10,2,-7,-10,-13,5,2,5,6,1,0,-30,-29,-12,-6,-3,-4,-7,-10,-23,-16,-19,-21,-20,-24,-27,-20,13,12,2,5,1,-2,-5,-14
 db 9,14,7,0,4,3,-2,-19,7,23,23,19,15,6,-2,-5,-7,-16,-11,-11,-7,0,-5,-19,-40,-48,-26,-18,-6,-6,-13,-8,-27,-14,10,1,-15,-27,-28,-21,-12,2,14,6,4,9,1,4,11,10,20,14,18,17,17,17,7,12,6,2,0,2,8,15
 db -35,-18,-5,0,-4,-5,-5,-16,-22,-12,-4,5,17,16,0,-9,-16,-9,-6,3,12,7,7,9,6,0,-7,-14,-27,-17,13,12,14,11,-5,-27,-34,-2,11,10,8,3,-10,-16,-5,-5,-2,5,-2,0,7,13,6,-7,-11,-15,-13,6,16,5,3,-6,-27,-60
 db -4,13,7,2,0,-4,8,1,-21,-4,-1,-4,-7,-1,0,-13,-19,-7,-3,4,15,13,-2,-15,-14,-8,-4,5,16,8,-9,-14,-13,-11,4,14,8,0,-10,-16,-16,-8,16,15,5,-4,-12,-23,-13,2,4,-3,-4,-2,0,-13,2,8,-2,1,3,7,8,-3
 db -8,10,11,7,2,1,-9,-32,1,8,11,10,6,-3,-18,-13,-3,-16,-17,-19,-15,-9,-5,-4,-70,-71,-53,-40,-25,-15,-7,-11,-42,-14,0,0,-3,-6,-15,-22,9,10,18,13,10,8,-4,-6,21,15,18,14,11,14,22,11,3,15,5,-5,-7,0,11,11
 db -4,9,11,16,14,10,2,-13,-5,4,9,11,15,6,5,13,-29,-38,-35,-20,2,12,10,-7,-26,-20,-2,7,16,16,-9,-38,-26,-34,-12,1,3,3,6,4,-12,-36,-48,-58,-31,-3,18,18,1,-3,7,7,4,-3,-2,2,-6,8,15,9,3,-4,-18,-42
 db -24,-9,-12,-17,-20,-16,-9,15,-18,-5,-7,-21,-25,-11,6,-10,7,14,15,-3,6,11,0,-11,16,30,19,0,5,9,2,2,8,11,4,1,12,15,8,6,-2,-16,0,5,3,2,-1,-7,-63,-45,-31,-30,-27,-29,-37,-35,-15,-15,-16,-14,-12,-9,-8,-15
 db -25,-2,3,3,5,4,17,24,-12,-2,1,6,8,13,10,0,-5,5,4,-1,-21,-32,-57,-65,7,3,14,2,-8,-6,-16,-39,-24,-21,-2,-14,-8,-2,0,-2,-16,-40,-31,-23,-8,-3,2,3,8,0,13,11,1,-6,-8,-8,-14,5,11,9,5,2,-14,-37
 db -31,-23,-21,-20,-10,-10,6,8,-34,-34,-32,-32,-28,-14,-23,-36,-24,-18,-13,-15,-19,-35,-75,-95,-1,3,-2,-8,-20,-17,-10,-2,8,13,2,-6,3,9,10,9,12,26,5,13,20,13,24,13,11,23,16,17,14,12,12,5,-6,9,19,27,18,10,-1,-25
 db 15,31,26,20,15,17,20,13,0,21,29,33,26,14,21,8,-3,3,0,-30,-10,20,21,0,-1,-16,-45,-27,-9,8,14,3,-21,-55,-15,-10,-6,0,8,-4,-79,-29,-8,-8,-10,-16,-22,-31,-29,-25,-23,-27,-31,-34,-41,-36,-17,-16,-23,-24,-28,-29,-28,-43
 db -29,1,5,10,13,9,2,1,5,8,7,9,1,-3,6,6,13,18,4,-7,-14,4,9,8,-7,-13,2,15,13,1,-12,-28,-45,-20,11,19,3,-8,-20,-20,0,7,2,-6,-9,-7,2,3,11,-10,-15,1,-4,-7,-6,-5,-10,4,14,7,3,-2,-10,-27
 db -47,0,12,18,34,38,15,-3,-3,6,9,13,4,-1,3,5,17,29,10,0,10,21,26,9,10,9,0,5,13,21,10,0,-5,-14,-6,-2,4,9,6,-6,-62,-49,-15,-6,-8,-7,-9,-18,-37,-29,-28,-31,-29,-32,-36,-24,3,-10,-19,-20,-26,-27,-17,-13
ORIGB label word
 dw -11,-54,40,-8,-55,74,-34,-37,-11,76,-7,67,-27,-10,-48,14
 dw -38,-54,23,123,15,11,-6,-61,49,-35,-24,-35,-15,4,-35,38
 dw -21,28,-29,59,-11,-12,-73,-5,-114,-60,-33,42,-36,153,-46,-23
 dw -88,-84,-18,-84,-6,-9,33,5,77,59,-12,59,-17,-13
BASEP label byte
 db 4,10,17,31,17,17,17,65   ; A
 db 14,17,17,31,17,17,17,65   ; A
 db 4,10,17,17,31,17,17,65   ; A
 db 30,17,17,30,17,17,30,66   ; B
 db 30,17,17,28,17,17,30,66   ; B
 db 14,17,16,16,16,17,14,67   ; C
 db 15,16,16,16,16,16,15,67   ; C
 db 30,17,17,17,17,17,30,68   ; D
 db 28,18,17,17,17,18,28,68   ; D
 db 31,16,16,30,16,16,31,69   ; E
 db 31,16,16,28,16,16,31,69   ; E
 db 31,16,16,30,16,16,16,70   ; F
 db 31,16,16,28,16,16,16,70   ; F
 db 14,17,16,23,17,17,15,71   ; G
 db 14,17,16,19,17,17,14,71   ; G
 db 17,17,17,31,17,17,17,72   ; H
 db 17,17,31,17,17,17,17,72   ; H
 db 14,4,4,4,4,4,14,73   ; I
 db 31,4,4,4,4,4,31,73   ; I
 db 4,4,4,4,4,4,4,73   ; I
 db 7,2,2,2,2,18,12,74   ; J
 db 2,2,2,2,2,18,12,74   ; J
 db 17,18,20,24,20,18,17,75   ; K
 db 18,20,24,28,20,18,17,75   ; K
 db 16,16,16,16,16,16,31,76   ; L
 db 16,16,16,16,16,16,15,76   ; L
 db 17,27,21,21,17,17,17,77   ; M
 db 17,27,21,17,17,17,17,77   ; M
 db 17,25,21,19,17,17,17,78   ; N
 db 17,25,21,21,19,17,17,78   ; N
 db 14,17,17,17,17,17,14,79   ; O
 db 4,10,17,17,17,10,4,79   ; O
 db 30,17,17,30,16,16,16,80   ; P
 db 28,18,18,28,16,16,16,80   ; P
 db 14,17,17,17,21,18,13,81   ; Q
 db 14,17,17,17,17,19,13,81   ; Q
 db 30,17,17,30,20,18,17,82   ; R
 db 30,17,17,30,18,18,17,82   ; R
 db 15,16,16,14,1,1,30,83   ; S
 db 14,17,16,14,1,17,14,83   ; S
 db 31,4,4,4,4,4,4,84   ; T
 db 14,4,4,4,4,4,4,84   ; T
 db 17,17,17,17,17,17,14,85   ; U
 db 17,17,17,17,17,17,31,85   ; U
 db 17,17,17,17,17,10,4,86   ; V
 db 17,17,17,10,10,4,4,86   ; V
 db 17,17,17,21,21,27,17,87   ; W
 db 17,17,21,21,21,10,10,87   ; W
 db 17,17,10,4,10,17,17,88   ; X
 db 17,10,4,4,4,10,17,88   ; X
 db 17,17,10,4,4,4,4,89   ; Y
 db 17,10,4,4,4,4,4,89   ; Y
 db 31,1,2,4,8,16,31,90   ; Z
 db 31,2,4,14,8,16,31,90   ; Z
 db 14,17,19,21,25,17,14,48   ; 0
 db 14,17,17,17,17,17,14,48   ; 0
 db 4,10,17,17,17,10,4,48   ; 0
 db 4,12,4,4,4,4,14,49   ; 1
 db 4,4,4,4,4,4,4,49   ; 1
 db 12,4,4,4,4,4,31,49   ; 1
 db 14,17,1,2,4,8,31,50   ; 2
 db 30,1,2,4,8,16,31,50   ; 2
 db 14,17,1,6,8,16,31,50   ; 2
 db 30,1,1,14,1,1,30,51   ; 3
 db 14,17,1,6,1,17,14,51   ; 3
 db 31,1,2,14,1,1,30,51   ; 3
 db 2,6,10,18,31,2,2,52   ; 4
 db 17,17,17,31,1,1,1,52   ; 4
 db 4,12,20,31,4,4,4,52   ; 4
 db 31,16,30,1,1,17,14,53   ; 5
 db 31,16,16,30,1,1,30,53   ; 5
 db 6,8,16,30,17,17,14,54   ; 6
 db 14,17,16,30,17,17,14,54   ; 6
 db 31,1,2,4,8,8,8,55   ; 7
 db 31,1,2,14,4,8,8,55   ; 7
 db 31,1,2,4,4,4,4,55   ; 7
 db 14,17,17,14,17,17,14,56   ; 8
 db 14,17,14,17,17,17,14,56   ; 8
 db 14,17,17,15,1,2,12,57   ; 9
 db 14,17,17,15,1,1,1,57   ; 9
 db 14,17,17,31,1,1,1,57   ; 9
 db 14,17,17,31,17,17,15,97   ; a
 db 7,9,17,15,17,17,15,97   ; a
 db 14,17,1,15,17,17,14,97   ; a
 db 16,16,22,25,17,17,30,98   ; b
 db 16,16,30,17,17,17,30,98   ; b
 db 14,17,16,16,16,17,14,99   ; c
 db 15,16,16,16,16,16,15,99   ; c
 db 1,1,13,19,17,17,15,100   ; d
 db 1,1,15,17,17,17,15,100   ; d
 db 14,17,17,31,16,17,14,101   ; e
 db 14,17,31,16,16,17,14,101   ; e
 db 6,9,8,30,8,8,8,102   ; f
 db 6,8,28,8,8,8,8,102   ; f
 db 14,17,17,15,1,17,14,103   ; g
 db 14,17,17,15,1,1,14,103   ; g
 db 16,16,22,25,17,17,17,104   ; h
 db 16,16,30,17,17,17,17,104   ; h
 db 4,0,12,4,4,4,14,105   ; i
 db 4,0,4,4,4,4,4,105   ; i
 db 2,0,6,2,2,18,12,106   ; j
 db 2,0,2,2,2,18,12,106   ; j
 db 16,16,18,20,24,20,18,107   ; k
 db 16,16,17,18,28,18,17,107   ; k
 db 12,4,4,4,4,4,14,108   ; l
 db 4,4,4,4,4,4,4,108   ; l
 db 26,21,21,21,21,21,21,109   ; m
 db 27,21,21,21,21,21,21,109   ; m
 db 22,25,17,17,17,17,17,110   ; n
 db 30,17,17,17,17,17,17,110   ; n
 db 14,17,17,17,17,17,14,111   ; o
 db 4,10,17,17,17,10,4,111   ; o
 db 30,17,17,30,16,16,16,112   ; p
 db 28,18,18,28,16,16,16,112   ; p
 db 15,17,17,15,1,1,1,113   ; q
 db 15,17,17,15,1,1,3,113   ; q
 db 22,25,16,16,16,16,16,114   ; r
 db 28,18,16,16,16,16,16,114   ; r
 db 15,16,14,1,1,17,14,115   ; s
 db 14,17,16,14,1,17,14,115   ; s
 db 8,8,30,8,8,9,6,116   ; t
 db 8,8,28,8,8,8,8,116   ; t
 db 17,17,17,17,17,17,15,117   ; u
 db 17,17,17,17,17,14,1,117   ; u
 db 17,17,17,10,10,10,4,118   ; v
 db 17,17,10,10,4,4,4,118   ; v
 db 17,17,17,21,21,27,17,119   ; w
 db 17,17,21,21,21,10,10,119   ; w
 db 17,10,4,4,4,10,17,120   ; x
 db 17,17,10,4,10,17,17,120   ; x
 db 17,17,17,15,1,17,14,121   ; y
 db 17,17,17,14,2,4,8,121   ; y
 db 31,1,2,4,8,16,31,122   ; z
 db 31,2,4,14,8,16,31,122   ; z
SEEDS label byte
 db 24,56,36,100,126,70,130,1,65
 db 48,56,104,76,116,222,130,1,65
 db 24,40,36,36,126,99,193,128,65
 db 254,129,129,254,131,129,129,254,66
 db 254,131,130,254,131,129,129,254,66
 db 127,193,195,254,129,129,131,252,66
 db 126,129,128,128,128,128,65,63,67
 db 63,65,128,128,128,128,131,126,67
 db 124,130,128,128,128,192,65,63,67
 db 254,131,129,129,129,129,130,252,68
 db 240,140,130,129,129,129,129,254,68
 db 254,129,129,129,129,130,142,240,68
 db 252,128,128,254,192,64,64,127,69
 db 124,67,192,248,134,128,192,62,69
 db 255,128,128,254,128,128,128,254,69
 db 255,128,128,224,223,192,64,64,70
 db 127,64,64,254,192,128,128,128,70
 db 127,64,64,124,192,128,128,128,70
 db 124,131,129,128,134,131,98,30,71
 db 127,193,128,128,135,129,65,63,71
 db 126,129,128,128,135,129,65,63,71
 db 129,129,129,255,131,129,129,131,72
 db 128,129,129,249,135,129,129,1,72
 db 1,129,129,255,129,129,129,128,72
 db 224,112,112,56,28,28,14,7,73
 db 28,28,28,28,28,60,60,60,73
 db 7,6,14,12,28,24,56,112,73
 db 3,3,2,6,6,4,12,248,74
 db 24,24,12,12,6,6,6,252,74
 db 64,207,176,224,144,136,4,2,75
 db 134,152,176,224,176,152,132,3,75
 db 131,140,176,224,176,136,132,3,75
 db 128,128,128,128,128,128,128,255,76
 db 64,64,64,192,192,128,128,255,76
 db 128,128,128,128,128,128,128,127,76
 db 3,197,165,165,157,153,129,128,77
 db 67,227,165,165,153,153,129,128,77
 db 195,163,167,165,153,153,129,129,77
 db 193,161,177,145,137,133,133,131,78
 db 195,161,177,145,137,141,135,131,78
 db 1,225,177,145,137,133,135,128,78
 db 124,130,129,129,129,129,65,62,79
 db 62,65,129,129,129,129,130,124,79
 db 254,129,129,131,254,192,192,64,80
 db 254,129,129,135,248,128,192,128,80
 db 254,129,129,131,248,128,128,128,80
 db 124,131,129,129,129,194,124,3,81
 db 124,194,129,129,129,195,124,3,81
 db 126,131,129,129,129,98,28,6,81
 db 248,132,132,136,248,132,130,131,82
 db 248,132,132,252,136,132,130,3,82
 db 248,140,132,136,248,132,130,195,82
 db 126,193,64,48,14,1,129,126,83
 db 31,64,128,126,1,1,3,252,83
 db 126,129,128,120,6,1,129,127,83
 db 255,8,8,8,8,8,8,8,84
 db 255,16,24,8,8,8,8,8,84
 db 248,31,16,16,16,16,16,16,84
 db 128,129,129,129,129,129,67,62,85
 db 193,129,129,129,131,130,130,124,85
 db 1,129,129,129,129,129,67,124,85
 db 1,130,66,68,100,36,40,24,86
 db 128,65,66,98,38,36,28,24,86
 db 1,131,194,66,34,52,20,12,86
 db 1,25,153,155,86,86,118,32,87
 db 1,153,154,154,234,106,102,100,87
 db 134,68,40,24,24,36,34,65,88
 db 194,100,40,24,24,36,98,67,88
 db 192,102,44,24,56,100,198,3,88
 db 128,65,38,60,24,16,16,16,89
 db 3,130,68,52,8,8,8,8,89
 db 195,70,36,24,16,16,16,16,89
 db 252,6,4,8,16,96,64,63,90
 db 254,6,4,8,16,32,64,255,90
 db 127,2,4,8,16,32,64,254,90
 db 124,130,3,63,65,193,195,124,97
 db 124,6,1,255,131,129,103,31,97
 db 124,6,1,255,129,129,103,63,97
 db 128,128,190,195,129,193,67,126,98
 db 64,64,94,97,65,193,195,190,98
 db 64,64,124,67,129,129,193,62,98
 db 62,96,128,128,128,128,67,62,99
 db 62,65,128,128,128,128,64,62,99
 db 62,96,192,128,128,128,195,126,99
 db 1,121,199,131,131,130,66,62,100
 db 1,1,125,195,129,129,193,127,100
 db 1,1,125,195,130,130,130,126,100
 db 62,66,129,255,128,128,193,126,101
 db 124,194,129,253,131,128,96,63,101
 db 62,65,129,255,128,128,193,126,101
 db 31,48,254,48,48,48,48,48,102
 db 31,48,254,32,32,32,32,32,102
 db 31,16,126,160,32,32,32,32,102
 db 63,65,129,129,135,123,2,252,103
 db 63,65,129,129,131,125,3,124,103
 db 63,193,129,129,195,125,3,126,103
 db 64,64,94,97,193,193,129,131,104
 db 128,128,190,193,129,129,129,129,104
 db 30,0,28,60,60,60,56,120,105
 db 240,0,60,60,28,30,15,7,105
 db 240,0,56,56,28,30,30,15,105
 db 12,0,14,14,6,6,6,252,106
 db 96,0,48,56,28,14,6,254,106
 db 6,0,6,7,3,3,3,254,106
 db 128,128,134,152,224,176,140,7,107
 db 128,128,135,152,224,176,136,135,107
 db 192,195,132,152,224,240,140,131,107
 db 14,28,56,56,120,112,224,224,108
 db 120,120,56,60,28,30,14,15,108
 db 30,28,56,56,120,112,224,224,108
 db 38,217,145,145,145,137,137,128,109
 db 7,121,209,145,153,137,136,128,109
 db 240,150,137,137,137,153,17,1,109
 db 92,99,193,193,129,131,131,2,110
 db 190,225,129,129,129,129,129,129,110
 db 124,194,129,129,129,129,67,62,111
 db 124,66,129,129,129,129,66,62,111
 db 124,194,129,129,129,193,67,62,111
 db 62,193,129,129,194,124,64,64,112
 db 252,130,129,129,193,190,128,128,112
 db 254,131,129,129,193,242,140,128,112
 db 62,66,131,131,131,197,121,1,113
 db 63,65,129,129,131,127,3,2,113
 db 125,131,129,129,65,63,1,1,113
 db 95,112,64,64,192,192,192,128,114
 db 31,176,192,192,192,64,64,96,114
 db 159,225,192,192,192,64,64,64,114
 db 127,65,64,120,6,1,129,254,115
 db 126,192,128,252,7,1,3,254,115
 db 127,128,128,124,7,1,129,254,115
 db 32,240,47,32,32,32,32,31,116
 db 16,31,127,16,48,48,48,31,116
 db 32,240,47,32,32,96,32,30,116
 db 130,131,129,129,193,65,67,61,117
 db 128,130,131,129,193,65,99,63,117
 db 2,131,131,129,129,193,71,124,117
 db 1,2,194,66,36,52,20,12,118
 db 1,130,66,68,100,44,40,24,118
 db 128,192,67,66,68,44,40,48,118
 db 1,1,153,155,86,86,114,32,119
 db 1,153,153,218,86,86,102,32,119
 db 128,153,153,89,86,102,38,2,119
 db 64,35,20,24,24,108,196,2,120
 db 64,35,54,24,56,68,132,3,120
 db 67,38,52,24,24,44,68,195,120
 db 3,194,68,40,56,16,32,224,121
 db 128,67,66,36,40,24,48,224,121
 db 64,33,51,18,30,12,8,56,121
 db 120,7,2,12,48,64,240,30,122
 db 254,6,4,8,16,48,96,127,122
 db 120,15,3,12,48,192,240,14,122
 db 62,65,193,129,129,129,130,124,48
 db 126,195,129,129,129,129,195,124,48
 db 124,130,129,129,129,129,65,62,48
 db 120,152,8,8,8,8,11,124,49
 db 248,8,8,8,8,8,8,127,49
 db 124,12,12,8,8,8,216,127,49
 db 126,129,1,2,4,24,96,255,50
 db 124,130,2,6,12,24,32,127,50
 db 252,2,2,2,12,16,32,127,50
 db 124,3,1,30,6,1,129,127,51
 db 254,2,2,30,3,1,1,254,51
 db 124,3,1,30,6,1,129,126,51
 db 28,52,36,68,132,255,4,4,52
 db 28,20,36,68,132,255,4,4,52
 db 63,64,64,126,1,1,3,252,53
 db 126,64,64,254,1,1,1,254,53
 db 252,128,224,254,1,1,1,254,53
 db 126,193,128,254,131,129,193,62,54
 db 63,64,128,190,193,129,195,126,54
 db 255,2,4,12,8,16,48,96,55
 db 15,226,6,4,12,8,16,48,55
 db 127,134,4,8,24,16,32,96,55
 db 126,195,65,62,194,129,193,62,56
 db 63,65,65,62,99,129,131,126,56
 db 126,131,65,62,194,129,193,126,56
 db 124,130,130,193,127,1,3,126,57
 db 124,130,129,129,127,1,3,252,57
 db 124,67,193,65,63,1,130,126,57
 db 126,126,126,126,127,8,0,31,33
 db 31,30,60,60,62,16,0,248,33
 db 6,14,12,28,24,16,0,96,33
 db 127,129,3,12,24,16,0,16,63
 db 254,1,1,6,8,16,0,16,63
 db 126,129,3,6,8,8,0,8,63
 db 24,56,40,36,60,126,66,199,65
 db 24,24,40,36,116,92,66,199,65
 db 48,56,40,76,124,66,71,192,65
 db 254,97,99,126,97,33,33,254,66
 db 254,99,99,62,35,33,33,255,66
 db 126,33,33,62,35,33,33,255,66
 db 124,131,129,128,128,128,65,62,67
 db 124,130,130,128,128,192,97,62,67
 db 248,70,65,65,65,65,65,254,68
 db 252,66,65,65,65,65,66,252,68
 db 120,38,33,33,97,65,65,254,68
 db 255,33,34,62,98,96,97,255,69
 db 127,33,34,62,34,32,96,254,69
 db 127,33,34,62,34,96,65,255,69
 db 252,35,33,58,38,34,32,248,70
 db 126,33,32,58,38,96,64,240,70
 db 31,224,98,62,32,32,32,120,70
 db 62,66,128,128,135,129,65,62,71
 db 126,193,128,128,135,129,65,63,71
 db 124,131,129,128,134,193,97,31,71
 db 231,66,66,126,66,66,66,231,72
 db 254,24,24,24,24,8,8,127,73
 db 127,24,24,24,24,24,24,254,73
 db 252,16,16,24,8,8,8,63,73
 db 127,4,4,6,2,2,3,254,74
 db 127,12,4,4,6,2,2,254,74
 db 31,4,4,4,4,12,136,248,74
 db 231,68,72,80,112,72,71,224,75
 db 238,76,88,112,80,72,100,115,75
 db 112,39,108,112,80,72,228,3,75
 db 112,32,32,32,32,32,33,255,76
 db 112,32,32,32,32,32,225,63,76
 db 240,96,32,32,32,33,35,124,76
 db 192,99,102,102,90,90,194,7,77
 db 195,102,102,102,90,90,82,198,77
 db 195,102,102,102,90,90,66,231,77
 db 192,103,114,82,74,78,230,2,78
 db 199,98,82,90,74,71,66,226,78
 db 126,33,33,33,62,32,32,240,80
 db 254,33,33,33,62,32,32,240,80
 db 63,225,33,46,48,32,32,120,80
 db 126,193,129,129,129,131,124,6,81
 db 126,195,129,129,129,195,126,6,81
 db 124,131,129,129,129,195,62,7,81
 db 252,98,98,124,100,68,66,227,82
 db 248,68,68,124,72,68,68,227,82
 db 252,70,68,124,68,68,67,224,82
 db 127,193,128,112,14,1,129,254,83
 db 63,65,64,112,14,1,131,254,83
 db 126,130,128,248,15,1,129,254,83
 db 31,217,136,8,8,8,8,28,84
 db 255,145,16,16,16,16,16,120,84
 db 255,153,8,8,8,8,8,28,84
 db 7,226,66,66,66,66,70,124,85
 db 39,226,66,66,66,66,68,120,85
 db 231,66,66,66,66,66,66,60,85
 db 227,66,34,36,36,20,24,24,86
 db 227,66,98,36,36,20,24,24,86
 db 226,67,34,34,18,20,12,12,86
 db 192,91,90,90,90,106,100,36,87
 db 192,75,89,90,122,106,108,4,87
 db 203,89,90,90,90,110,36,36,87
 db 238,100,40,24,24,36,38,103,88
 db 247,38,20,24,24,44,100,239,88
 db 238,36,40,24,24,44,36,103,88
 db 231,34,52,20,8,8,8,28,89
 db 231,98,36,24,16,16,16,56,89
 db 231,98,36,28,24,16,16,56,89
 db 127,66,4,8,16,32,64,254,90
 db 120,15,6,12,48,64,240,15,90
 db 254,132,8,24,16,32,97,255,90
 db 60,66,2,62,194,130,143,248,97
 db 248,132,6,254,130,134,126,19,97
 db 120,132,132,126,196,134,134,123,97
 db 224,96,62,33,33,33,33,254,98
 db 192,96,60,50,33,33,49,127,98
 db 224,32,62,33,33,33,51,124,98
 db 126,67,129,128,128,129,67,62,99
 db 63,97,192,128,128,131,130,124,99
 db 124,194,130,128,128,192,67,62,99
 db 12,4,52,76,132,134,135,120,100
 db 28,4,52,76,132,134,135,248,100
 db 6,2,122,134,130,130,198,127,100
 db 124,198,194,190,135,128,67,60,101
 db 60,66,130,255,128,131,198,124,101
 db 60,66,130,255,128,131,134,124,101
 db 31,48,60,224,32,32,32,248,102
 db 31,49,252,48,32,32,32,248,102
 db 31,32,124,160,32,48,48,124,102
 db 123,134,130,130,198,122,2,124,103
 db 123,134,130,130,134,122,2,124,103
 db 59,70,130,130,134,127,2,124,103
 db 96,32,40,54,98,98,226,7,104
 db 192,64,80,108,196,132,132,222,104
 db 224,32,124,98,66,66,66,231,104
 db 24,0,120,24,24,24,24,255,105
 db 8,0,120,8,24,24,24,255,105
 db 4,0,60,12,8,8,24,255,105
 db 60,6,2,2,3,1,255,0,106
 db 1,14,3,3,3,3,131,254,106
 db 1,14,1,1,3,3,131,254,106
 db 96,32,39,36,56,104,68,239,107
 db 192,64,78,68,104,56,36,119,107
 db 224,32,103,102,88,120,68,231,107
 db 240,16,24,24,24,24,8,127,108
 db 60,4,12,12,12,12,8,255,108
 db 248,24,24,24,24,24,8,127,108
 db 22,250,73,75,75,74,91,208,109
 db 190,90,82,90,74,74,74,219,109
 db 182,90,82,90,74,74,75,219,109
 db 220,102,66,66,66,66,66,231,110
 db 220,100,66,66,66,66,66,247,110
 db 28,230,66,66,66,66,71,224,110
 db 62,67,129,129,129,129,194,124,111
 db 60,66,129,129,129,129,194,124,111
 db 188,66,66,66,70,120,64,224,112
 db 126,49,33,33,33,62,96,240,112
 db 126,33,33,33,33,62,96,240,112
 db 118,140,132,132,196,126,2,15,113
 db 123,134,132,132,132,124,4,14,113
 db 246,140,132,132,68,60,6,7,113
 db 111,121,32,32,32,32,96,240,114
 db 238,57,33,32,32,96,32,248,114
 db 238,57,33,96,96,96,96,248,114
 db 126,67,65,56,14,130,194,126,115
 db 127,193,192,120,7,1,131,254,115
 db 63,65,64,124,7,1,130,252,115
 db 32,240,62,48,48,48,49,31,116
 db 48,62,240,32,32,32,33,62,116
 db 32,240,62,32,48,48,49,31,116
 db 6,194,66,66,66,70,79,56,117
 db 204,68,68,70,66,102,38,59,117
 db 192,70,66,66,66,66,110,19,117
 db 7,226,66,36,36,44,24,16,118
 db 224,71,98,36,36,40,56,16,118
 db 231,66,34,38,20,20,28,8,118
 db 3,201,90,90,86,118,52,32,119
 db 3,201,90,90,90,86,36,32,119
 db 3,9,218,90,86,54,50,32,119
 db 112,39,22,28,24,228,100,15,120
 db 247,34,20,24,24,60,100,239,120
 db 238,36,60,24,24,20,36,103,120
 db 7,226,36,52,24,8,16,112,121
 db 115,49,17,10,14,4,4,56,121
 db 231,66,36,36,24,16,16,224,121
 db 127,70,4,8,16,32,66,254,122
 db 127,66,4,8,16,32,66,254,122
 db 14,244,140,8,16,33,127,112,122
 db 124,194,129,129,129,193,65,62,48
 db 62,67,129,129,129,129,194,124,48
 db 124,194,129,129,129,129,67,62,48
 db 124,12,8,8,8,8,248,31,49
 db 60,108,12,8,8,8,24,255,49
 db 120,152,24,24,24,24,24,255,49
 db 252,130,2,2,4,24,97,255,50
 db 252,130,2,2,12,16,97,255,50
 db 62,67,2,6,12,17,99,252,50
 db 124,3,1,30,6,129,193,63,51
 db 63,65,3,30,3,1,130,252,51
 db 126,65,1,30,2,1,129,126,51
 db 12,28,52,36,69,254,4,30,52
 db 12,20,36,68,196,255,4,31,52
 db 4,12,20,36,68,255,4,30,52
 db 127,64,88,102,1,1,131,126,53
 db 126,192,192,255,1,1,131,252,53
 db 60,192,128,255,1,1,130,252,53
 db 63,65,128,254,131,129,130,126,54
 db 126,192,128,254,131,129,193,126,54
 db 126,130,128,254,129,193,65,62,54
 db 255,130,2,4,4,12,8,16,55
 db 31,227,130,4,4,8,24,16,55
 db 255,131,2,4,12,8,16,16,55
 db 126,130,130,126,195,129,129,126,56
 db 252,130,130,126,195,129,129,126,56
 db 124,130,130,124,99,129,193,126,56
 db 126,195,129,129,127,1,130,252,57
 db 62,195,129,131,125,1,2,124,57
 db 126,130,129,131,125,1,3,124,57
 db 126,28,28,24,28,28,0,14,33
 db 252,56,28,28,28,12,0,7,33
 db 252,24,24,24,24,28,0,7,33
 db 126,129,1,2,12,8,0,8,63
 db 126,131,1,2,28,16,0,16,63
 db 126,129,1,3,12,8,0,8,63
 db 48,40,104,68,100,222,130,3,65
 db 24,40,36,68,126,134,130,1,65
 db 24,20,36,36,66,126,130,129,65
 db 254,129,131,254,131,129,129,254,66
 db 252,134,130,254,198,65,65,127,66
 db 126,65,193,254,134,129,129,254,66
 db 63,64,128,128,128,128,193,126,67
 db 63,64,128,128,128,128,192,62,67
 db 63,64,128,128,128,128,193,127,67
 db 252,131,129,129,129,129,130,252,68
 db 252,130,129,129,129,129,131,252,68
 db 126,65,65,193,129,131,130,252,68
 db 255,192,192,254,128,128,128,126,69
 db 62,128,128,190,192,128,129,254,69
 db 127,128,128,254,192,128,128,254,69
 db 255,128,128,254,194,64,64,64,70
 db 127,64,64,112,79,64,64,64,70
 db 120,71,192,224,190,128,128,128,70
 db 63,96,64,128,134,130,130,126,71
 db 127,193,128,128,135,129,193,63,71
 db 63,64,128,128,135,129,129,126,71
 db 65,65,65,255,195,131,130,130,72
 db 64,193,129,253,131,131,130,2,72
 db 193,193,129,255,129,129,129,131,72
 db 127,8,24,24,24,24,24,254,73
 db 255,24,24,24,24,24,24,255,73
 db 254,16,16,24,24,8,8,127,73
 db 15,1,1,1,1,3,130,126,74
 db 62,2,3,3,1,1,129,127,74
 db 31,1,1,1,1,1,3,252,74
 db 3,132,152,160,208,136,132,131,75
 db 134,136,144,240,152,136,134,3,75
 db 6,136,144,176,240,140,198,65,75
 db 128,128,128,128,128,128,192,127,76
 db 192,192,192,128,128,128,192,63,76
 db 96,115,85,221,139,130,130,2,77
 db 227,163,181,153,153,129,129,129,77
 db 224,227,181,157,153,129,129,3,77
 db 193,161,145,145,137,141,133,131,78
 db 97,97,81,211,154,138,138,134,78
 db 2,194,162,147,201,197,67,64,78
 db 126,194,129,129,129,129,67,126,79
 db 124,195,129,129,129,129,195,126,79
 db 124,130,131,129,129,193,65,62,79
 db 126,65,65,70,252,192,128,128,80
 db 254,129,129,195,254,64,64,64,80
 db 254,129,129,195,252,64,64,64,80
 db 62,65,193,129,131,130,124,6,81
 db 62,195,129,129,129,130,70,63,81
 db 126,193,129,129,129,194,124,6,81
 db 126,66,66,204,252,132,130,131,82
 db 124,194,134,188,232,132,130,131,82
 db 124,194,194,140,248,132,130,131,82
 db 62,65,64,56,6,3,131,254,83
 db 62,65,64,56,12,2,130,126,83
 db 127,64,192,120,7,1,1,254,83
 db 248,31,24,16,16,16,16,16,84
 db 255,16,16,16,16,16,16,48,84
 db 255,16,16,16,16,16,16,16,84
 db 129,129,129,129,129,129,129,126,85
 db 128,129,129,129,129,129,131,126,85
 db 1,130,66,98,38,52,20,12,86
 db 129,66,66,68,36,44,40,56,86
 db 1,194,66,68,36,44,40,24,86
 db 128,129,195,90,90,126,102,4,87
 db 1,129,65,89,85,117,51,50,87
 db 128,128,129,154,170,234,78,4,87
 db 67,38,52,24,28,36,66,193,88
 db 2,196,44,24,28,38,67,192,88
 db 128,67,38,44,24,16,16,16,89
 db 1,130,70,52,24,8,8,12,89
 db 131,70,100,40,16,16,16,16,89
 db 254,4,12,24,16,32,64,255,90
 db 126,65,1,127,193,129,135,126,97
 db 126,129,1,63,193,129,135,124,97
 db 124,194,3,63,65,129,199,124,97
 db 64,64,124,194,129,129,193,62,98
 db 64,64,126,65,193,129,195,254,98
 db 64,64,124,195,193,129,193,62,98
 db 126,195,128,128,128,128,97,63,99
 db 62,65,128,128,128,128,65,62,99
 db 63,65,192,128,128,129,195,62,99
 db 1,1,125,131,129,129,65,63,100
 db 1,3,127,195,129,129,193,127,100
 db 1,1,125,195,131,131,131,126,100
 db 124,194,131,255,130,192,96,63,101
 db 62,67,129,255,128,128,65,63,101
 db 124,194,130,255,128,128,65,63,101
 db 15,16,255,16,24,24,24,24,102
 db 31,16,255,16,16,16,16,16,102
 db 15,16,254,16,16,48,48,32,102
 db 63,195,131,129,199,125,3,126,103
 db 63,195,129,129,135,125,3,252,103
 db 126,130,131,131,67,61,1,126,103
 db 64,64,94,65,193,193,129,3,104
 db 192,192,255,193,129,129,129,129,104
 db 4,0,56,8,8,8,24,255,105
 db 32,0,240,16,16,16,16,255,105
 db 16,0,240,16,16,16,24,255,105
 db 24,0,12,12,4,6,6,254,106
 db 1,30,2,2,2,6,4,252,106
 db 1,2,51,3,3,3,3,252,106
 db 128,128,134,152,240,152,132,131,107
 db 128,130,140,152,240,152,132,131,107
 db 128,134,136,144,240,136,134,131,107
 db 240,48,16,16,16,16,16,15,108
 db 224,48,16,16,16,16,8,15,108
 db 240,16,16,16,16,16,16,15,108
 db 55,249,137,137,137,153,153,128,109
 db 254,153,153,153,153,153,153,136,109
 db 254,147,145,153,153,153,153,153,109
 db 92,99,193,193,129,129,131,2,110
 db 188,194,131,129,129,129,193,129,110
 db 62,226,131,129,129,129,129,129,110
 db 124,67,193,129,129,129,66,60,111
 db 62,66,129,129,129,129,194,126,111
 db 124,194,131,129,129,193,67,62,111
 db 252,130,129,129,193,251,204,192,112
 db 126,67,193,193,193,242,140,128,112
 db 254,193,129,129,129,254,128,128,112
 db 127,193,131,131,130,126,2,2,113
 db 124,131,129,131,194,62,2,2,113
 db 126,131,131,131,195,127,1,1,113
 db 31,176,192,192,192,64,64,64,114
 db 191,225,128,128,128,128,128,128,114
 db 94,243,193,192,128,128,128,128,114
 db 62,65,64,56,6,3,195,126,115
 db 126,193,64,56,14,1,193,127,115
 db 62,97,64,56,6,2,130,126,115
 db 16,31,240,16,48,48,32,30,116
 db 16,30,254,16,16,16,16,15,116
 db 16,248,31,16,16,16,16,15,116
 db 129,129,129,129,129,129,195,63,117
 db 3,131,131,129,129,193,71,124,117
 db 129,131,131,129,193,65,67,63,117
 db 129,66,66,34,36,52,20,28,118
 db 129,66,66,34,38,20,20,12,118
 db 131,66,66,38,36,52,20,28,118
 db 129,129,67,90,90,86,54,36,119
 db 128,129,65,74,90,54,54,38,119
 db 1,1,130,218,90,94,116,32,119
 db 194,70,44,24,24,36,198,3,120
 db 65,34,20,24,24,36,198,3,120
 db 65,34,20,24,24,36,68,131,120
 db 3,194,98,36,28,8,8,48,121
 db 131,66,68,36,24,16,16,96,121
 db 128,67,66,36,40,24,16,224,121
 db 126,198,12,8,16,32,71,252,122
 db 14,246,4,8,16,32,111,112,122
 db 127,3,6,8,16,96,192,254,122
 db 62,65,129,129,129,129,130,124,48
 db 124,130,131,129,129,129,65,62,48
 db 248,8,8,8,8,8,24,255,49
 db 120,136,8,8,8,8,9,126,49
 db 120,136,8,8,8,8,24,127,49
 db 248,6,2,2,12,24,32,127,50
 db 124,130,2,6,12,16,32,127,50
 db 252,3,1,2,12,16,96,255,50
 db 124,2,3,30,6,1,129,127,51
 db 126,1,1,30,3,1,129,254,51
 db 252,2,2,30,6,1,129,127,51
 db 12,20,20,36,68,143,244,4,52
 db 14,26,50,102,196,255,4,4,52
 db 63,96,96,126,1,1,1,254,53
 db 126,64,64,126,1,1,3,254,53
 db 62,64,64,127,1,1,3,252,53
 db 63,64,192,254,195,131,194,124,54
 db 63,64,192,190,193,129,131,126,54
 db 31,96,192,191,193,129,130,124,54
 db 255,2,6,4,8,24,16,96,55
 db 63,194,6,4,8,24,16,48,55
 db 255,2,6,4,12,8,16,48,55
 db 126,195,130,126,99,129,131,254,56
 db 124,130,130,126,230,129,129,126,56
 db 126,194,130,254,99,129,131,252,56
 db 126,67,193,65,63,1,131,126,57
 db 126,195,129,131,253,3,6,248,57
 db 124,130,129,129,127,1,131,254,57
 db 15,30,30,60,60,16,0,124,33
 db 112,56,60,60,30,24,0,15,33
 db 6,14,28,56,56,48,0,96,33
 db 254,1,1,6,24,16,0,16,63
 db 254,129,3,6,24,16,0,16,63
 db 254,1,1,6,8,8,0,12,63
 db 24,40,44,36,126,66,193,128,65
 db 12,20,52,38,126,194,2,1,65
 db 48,40,40,68,124,98,131,128,65
 db 252,134,131,254,134,129,129,255,66
 db 254,131,130,254,129,129,131,254,66
 db 126,65,65,254,131,129,129,254,66
 db 124,194,129,128,128,128,65,62,67
 db 62,65,128,128,128,128,195,124,67
 db 62,65,128,128,128,128,195,126,67
 db 254,129,129,129,129,131,134,248,68
 db 248,134,129,129,129,129,131,254,68
 db 254,129,129,129,129,129,134,252,68
 db 127,64,192,190,224,128,128,254,69
 db 62,192,128,158,224,128,67,124,69
 db 62,192,128,158,224,128,135,252,69
 db 120,71,192,128,240,142,128,128,70
 db 255,128,128,128,254,128,128,128,70
 db 255,128,128,128,255,128,128,128,70
 db 124,130,128,128,135,129,65,63,71
 db 62,65,128,128,135,129,193,126,71
 db 124,130,129,128,134,129,65,63,71
 db 1,129,129,191,193,129,129,128,72
 db 1,129,129,159,225,129,129,128,72
 db 129,129,129,255,129,129,129,129,72
 db 240,112,120,56,28,30,31,15,73
 db 126,126,126,30,30,31,31,15,73
 db 14,28,28,28,56,48,112,112,73
 db 15,1,1,1,3,3,130,124,74
 db 30,3,3,3,1,1,193,63,74
 db 31,3,1,1,1,1,193,127,74
 db 134,136,144,224,144,140,134,3,75
 db 2,140,152,176,240,136,134,129,75
 db 130,140,144,224,144,140,132,3,75
 db 128,128,128,128,128,128,131,252,76
 db 192,192,192,128,128,128,128,255,76
 db 3,195,199,165,165,153,153,128,77
 db 131,195,197,165,165,153,153,137,77
 db 131,195,197,165,165,149,153,137,77
 db 193,225,161,145,137,141,133,131,78
 db 193,225,161,145,137,133,135,3,78
 db 192,225,161,145,137,133,133,3,78
 db 62,67,129,129,129,129,194,124,79
 db 124,194,129,129,129,129,67,62,79
 db 248,134,129,129,241,158,128,128,80
 db 252,130,129,129,255,192,192,64,80
 db 252,131,129,129,193,63,8,7,81
 db 62,193,129,129,129,198,60,7,81
 db 63,65,129,129,129,134,120,14,81
 db 126,65,193,142,252,132,130,131,82
 db 254,130,131,254,140,132,130,3,82
 db 248,134,129,251,140,132,2,3,82
 db 126,67,64,56,6,130,195,126,83
 db 124,131,192,120,6,1,193,63,83
 db 126,195,192,120,6,1,129,126,83
 db 252,27,16,16,16,16,16,16,84
 db 128,129,129,129,129,129,65,62,85
 db 128,129,129,129,129,131,194,126,85
 db 129,129,129,129,129,129,131,124,85
 db 129,194,66,68,36,40,40,16,86
 db 129,66,66,34,36,20,20,12,86
 db 1,130,70,68,76,104,56,48,86
 db 1,153,153,219,86,86,118,34,87
 db 129,153,154,154,234,106,108,100,87
 db 1,153,153,90,94,86,102,38,87
 db 67,38,52,24,24,36,66,131,88
 db 67,38,20,24,24,36,70,194,88
 db 2,196,104,24,24,38,67,192,88
 db 129,66,38,20,24,8,8,8,89
 db 131,66,36,40,16,16,16,16,89
 db 128,67,68,40,56,16,16,48,89
 db 254,4,12,8,16,32,64,255,90
 db 126,6,4,8,16,32,67,252,90
 db 60,7,2,12,48,96,240,14,90
 db 60,198,2,62,198,134,142,115,97
 db 60,68,132,60,68,134,139,240,97
 db 192,192,252,195,129,129,193,62,98
 db 64,64,95,97,193,193,194,252,98
 db 128,128,190,195,129,193,65,126,98
 db 60,67,128,128,128,130,132,120,99
 db 124,134,131,128,128,192,67,62,99
 db 124,198,131,128,128,128,67,62,99
 db 1,1,127,195,129,129,195,125,100
 db 1,1,63,67,130,130,134,122,100
 db 1,1,63,193,129,129,131,125,100
 db 124,194,129,255,128,128,195,62,101
 db 124,194,130,254,192,130,67,60,101
 db 124,194,131,253,135,192,99,62,101
 db 31,16,254,48,48,48,32,32,102
 db 30,48,255,24,24,24,24,24,102
 db 31,16,255,48,48,48,48,32,102
 db 126,134,131,129,199,125,33,126,103
 db 120,135,129,129,195,63,195,126,103
 db 125,67,131,130,198,62,194,124,103
 db 64,64,94,225,193,129,129,131,104
 db 128,132,191,193,193,193,193,64,104
 db 128,142,179,193,193,193,65,64,104
 db 14,0,28,56,56,48,112,96,105
 db 224,0,48,48,56,28,28,14,105
 db 224,0,48,56,56,28,28,14,105
 db 12,0,14,14,6,6,7,255,106
 db 112,0,56,24,28,12,14,254,106
 db 1,0,3,2,6,6,12,124,106
 db 128,128,134,152,240,88,68,3,107
 db 128,134,140,144,176,216,134,129,107
 db 128,130,140,152,176,216,132,131,107
 db 126,126,126,126,30,30,30,126,108
 db 224,112,112,56,28,28,14,7,108
 db 7,14,28,60,60,56,112,224,108
 db 6,249,145,145,137,137,137,128,109
 db 160,214,137,137,137,137,137,1,109
 db 246,221,137,137,153,153,153,145,109
 db 31,225,193,193,193,193,193,192,110
 db 128,254,129,129,129,129,129,1,110
 db 158,225,193,129,129,131,131,128,110
 db 124,130,129,129,129,193,65,62,111
 db 126,195,129,129,129,129,195,126,111
 db 62,193,129,129,195,252,192,64,112
 db 188,195,129,129,193,187,132,128,112
 db 126,65,193,193,195,190,128,128,112
 db 61,67,131,130,130,254,2,2,113
 db 125,195,131,129,131,125,1,1,113
 db 63,195,131,129,131,125,17,1,113
 db 207,248,96,64,64,64,64,64,114
 db 207,248,192,192,64,64,64,64,114
 db 207,112,64,192,192,192,192,192,114
 db 62,64,192,254,3,1,195,252,115
 db 126,195,192,124,7,1,193,126,115
 db 62,64,192,254,1,1,195,252,115
 db 48,60,240,48,48,16,16,31,116
 db 12,127,25,16,48,48,48,30,116
 db 24,255,50,48,32,32,32,62,116
 db 129,129,129,129,131,131,135,122,117
 db 129,129,129,129,129,129,135,125,117
 db 129,129,129,129,129,129,199,124,117
 db 128,67,66,98,36,36,28,24,118
 db 1,2,194,66,36,36,20,24,118
 db 1,3,130,66,38,36,20,12,118
 db 128,153,153,90,106,106,110,4,119
 db 1,25,153,218,86,86,118,32,119
 db 1,1,154,154,90,102,100,96,119
 db 130,68,44,24,24,36,98,193,120
 db 131,70,44,24,24,36,66,193,120
 db 64,35,54,24,24,100,198,3,120
 db 131,70,68,44,56,16,48,96,121
 db 131,66,34,20,28,8,8,48,121
 db 6,132,200,72,48,48,32,192,121
 db 62,228,12,24,48,32,95,240,122
 db 30,228,12,24,16,32,127,224,122
 db 126,2,4,8,16,32,64,255,122
 db 126,194,129,129,129,129,195,126,48
 db 126,195,129,129,129,129,194,126,48
 db 126,67,193,129,129,129,194,124,48
 db 60,68,12,12,8,8,72,255,49
 db 112,208,16,16,24,8,8,127,49
 db 62,65,1,3,12,48,64,255,50
 db 124,194,2,6,12,48,96,127,50
 db 62,97,1,3,12,48,64,254,50
 db 62,193,3,30,7,1,129,126,51
 db 126,67,1,30,6,1,193,126,51
 db 62,194,130,28,19,1,3,126,51
 db 4,28,20,36,68,255,228,4,52
 db 12,20,20,36,68,207,252,4,52
 db 12,20,20,36,68,207,254,2,52
 db 127,64,64,126,3,1,193,62,53
 db 63,64,64,126,1,1,131,126,53
 db 126,64,64,254,65,1,3,254,53
 db 62,65,192,190,194,130,130,124,54
 db 62,65,128,254,195,129,131,126,54
 db 62,97,192,190,194,130,130,124,54
 db 255,2,4,8,16,32,96,64,55
 db 255,3,6,4,8,8,8,8,55
 db 63,130,6,4,8,8,24,16,55
 db 126,67,65,127,194,129,193,63,56
 db 124,130,195,126,198,129,193,63,56
 db 62,65,65,62,67,129,129,126,56
 db 126,193,129,131,125,1,130,124,57
 db 63,65,65,67,125,3,6,252,57
 db 30,97,65,67,127,3,134,124,57
 db 124,120,28,30,30,30,0,3,33
 db 31,28,24,24,56,112,0,224,33
 db 252,240,56,60,28,28,0,31,33
 db 126,193,1,2,12,48,0,32,63
 db 63,65,129,6,12,16,0,16,63
 db 126,193,1,3,4,24,0,8,63
 db 16,40,40,36,124,68,71,228,65
 db 24,24,20,36,60,70,66,231,65
 db 24,24,40,36,60,68,66,231,65
 db 126,33,35,62,33,33,97,254,66
 db 254,35,35,62,33,33,33,254,66
 db 126,226,34,63,33,33,46,112,66
 db 31,65,128,128,128,129,129,126,67
 db 62,64,128,128,128,129,193,126,67
 db 63,65,128,128,128,129,129,126,67
 db 252,66,65,65,65,65,65,254,68
 db 62,193,65,33,33,34,60,112,68
 db 126,35,33,97,65,65,66,252,68
 db 254,34,36,60,36,32,33,127,69
 db 254,34,36,60,36,32,33,255,69
 db 254,98,36,60,36,33,33,127,69
 db 95,225,34,46,50,32,32,248,70
 db 255,33,32,34,62,34,32,120,70
 db 255,33,32,38,62,32,32,248,70
 db 126,130,128,128,133,130,66,62,71
 db 124,130,128,128,132,131,66,62,71
 db 62,66,128,128,135,130,194,124,71
 db 231,66,66,94,114,66,66,231,72
 db 112,103,66,114,78,66,230,14,72
 db 238,68,68,126,98,34,34,119,72
 db 63,8,8,8,24,16,16,252,73
 db 127,8,8,24,24,24,24,254,73
 db 252,16,24,24,24,8,8,127,73
 db 31,4,12,12,8,8,136,240,74
 db 63,12,12,4,4,4,132,248,74
 db 127,12,12,12,4,4,132,252,74
 db 119,36,40,120,104,68,68,227,75
 db 224,71,76,112,72,68,228,3,75
 db 230,76,72,80,104,76,68,243,75
 db 224,192,64,64,66,66,94,240,76
 db 120,32,32,32,32,32,225,31,76
 db 240,32,32,32,32,32,33,255,76
 db 195,70,102,110,90,90,90,231,77
 db 3,198,102,102,90,90,91,230,77
 db 3,198,102,102,122,90,83,212,77
 db 7,226,82,90,78,70,66,224,78
 db 135,226,82,90,78,70,66,224,78
 db 228,99,82,74,78,71,67,97,78
 db 124,130,131,129,129,129,65,62,79
 db 126,67,129,129,129,129,195,62,79
 db 126,49,33,33,62,32,32,248,80
 db 252,34,33,33,63,32,32,248,80
 db 255,33,33,35,60,32,32,120,80
 db 124,134,130,130,130,198,60,7,81
 db 120,132,130,130,130,102,28,7,81
 db 126,131,129,129,129,118,12,7,81
 db 252,68,68,92,120,68,67,240,82
 db 112,44,34,34,124,68,228,3,82
 db 252,70,70,68,120,68,70,227,82
 db 63,65,64,60,7,1,131,254,83
 db 126,193,97,56,6,129,193,63,83
 db 254,131,192,56,6,129,129,127,83
 db 255,145,16,16,16,16,16,60,84
 db 240,159,17,16,16,16,16,60,84
 db 255,153,8,8,8,8,8,60,84
 db 224,67,66,66,66,66,66,62,85
 db 231,66,66,66,66,66,70,60,85
 db 3,226,66,36,52,20,8,8,86
 db 39,226,34,34,20,28,12,8,86
 db 224,64,35,38,36,60,24,16,86
 db 195,201,74,90,54,54,54,48,87
 db 195,75,90,90,90,36,36,36,87
 db 3,3,202,90,86,54,36,32,87
 db 23,102,20,8,24,36,103,228,88
 db 14,228,40,16,24,39,70,224,88
 db 112,39,20,24,24,36,230,7,88
 db 39,226,36,28,24,16,16,60,89
 db 231,34,36,24,24,16,16,56,89
 db 7,98,228,52,24,8,8,28,89
 db 254,134,12,24,48,32,65,255,90
 db 127,70,12,8,16,32,65,255,90
 db 127,66,4,8,16,32,65,255,90
 db 248,140,4,124,196,132,132,255,97
 db 120,140,132,60,196,132,143,242,97
 db 124,68,6,126,230,134,142,255,97
 db 192,32,32,62,33,33,33,63,98
 db 224,32,44,55,33,33,33,62,98
 db 224,32,126,97,65,65,67,124,98
 db 62,98,128,128,128,128,195,126,99
 db 62,195,129,128,128,128,64,63,99
 db 124,194,130,128,128,64,96,31,99
 db 14,2,30,102,134,134,134,127,100
 db 28,4,60,196,132,132,132,127,100
 db 14,2,62,198,134,134,70,63,100
 db 126,195,193,255,130,128,192,63,101
 db 124,198,130,255,130,192,96,31,101
 db 62,67,193,255,128,128,192,127,101
 db 15,24,27,124,8,12,12,31,102
 db 15,24,22,120,16,48,48,252,102
 db 30,48,248,60,16,16,24,63,102
 db 127,70,70,124,112,222,131,126,103
 db 127,134,134,124,192,127,129,255,103
 db 31,34,66,124,64,126,130,252,103
 db 192,64,64,124,36,38,34,119,104
 db 192,64,92,102,98,34,34,119,104
 db 96,32,32,62,34,98,226,7,104
 db 16,0,240,24,24,24,24,255,105
 db 48,0,240,24,24,24,8,127,105
 db 1,14,3,3,6,6,132,252,106
 db 2,30,3,3,3,3,3,254,106
 db 2,31,3,3,3,3,3,254,106
 db 192,64,70,76,88,120,100,103,107
 db 96,32,35,38,44,52,35,115,107
 db 96,32,96,103,72,120,68,231,107
 db 248,24,24,24,24,24,24,127,108
 db 30,6,6,12,12,12,24,255,108
 db 120,12,12,12,8,24,24,255,108
 db 14,250,82,90,74,75,94,224,109
 db 62,250,82,82,82,82,95,208,109
 db 14,250,82,82,90,91,94,224,109
 db 220,114,98,98,98,98,71,224,110
 db 252,100,70,98,34,34,35,116,110
 db 252,102,66,66,98,98,103,240,110
 db 62,67,193,129,129,131,194,124,111
 db 62,67,193,193,129,129,66,124,111
 db 62,67,129,129,129,131,198,124,111
 db 252,99,33,33,33,62,32,120,112
 db 252,99,97,97,97,126,96,240,112
 db 126,33,33,33,35,126,96,240,112
 db 126,130,130,130,126,6,6,15,113
 db 124,132,132,132,100,28,6,15,113
 db 127,194,130,130,102,62,6,15,113
 db 103,63,48,48,32,32,32,248,114
 db 97,63,49,48,48,32,32,248,114
 db 97,63,49,48,48,48,32,248,114
 db 126,67,64,120,14,131,131,126,115
 db 63,97,96,56,6,131,131,254,115
 db 126,195,192,120,14,129,195,126,115
 db 24,31,240,48,48,48,48,31,116
 db 16,254,48,48,16,16,16,31,116
 db 16,62,240,48,48,16,16,31,116
 db 204,98,66,66,66,66,110,63,117
 db 14,194,66,98,66,98,103,56,117
 db 192,70,66,66,66,66,62,3,117
 db 7,242,98,38,52,20,12,8,118
 db 183,226,98,36,36,28,24,16,118
 db 224,116,39,34,36,20,24,16,118
 db 227,74,90,90,92,108,44,8,119
 db 3,194,74,90,92,108,36,32,119
 db 224,75,74,90,90,44,44,32,119
 db 254,36,56,24,24,44,100,239,120
 db 55,228,60,24,24,36,103,239,120
 db 6,244,40,24,24,36,79,224,120
 db 7,242,36,20,12,8,24,112,121
 db 231,98,36,20,24,16,16,224,121
 db 119,102,36,60,24,16,48,224,121
 db 127,196,12,24,16,33,97,255,122
 db 127,68,12,8,16,33,97,255,122
 db 62,228,136,24,49,33,127,240,122
 db 124,66,129,129,129,129,66,62,48
 db 62,67,193,129,129,131,194,124,48
 db 124,194,131,129,129,193,65,62,48
 db 14,60,12,12,8,8,8,255,49
 db 28,104,8,8,24,24,24,255,49
 db 24,240,16,24,24,24,24,127,49
 db 252,134,2,6,4,24,96,127,50
 db 126,130,2,6,12,48,99,254,50
 db 126,65,1,3,6,24,96,255,50
 db 63,65,3,30,3,1,131,252,51
 db 126,195,3,30,3,1,131,254,51
 db 126,3,3,30,6,1,129,126,51
 db 2,14,26,50,70,255,198,4,52
 db 4,12,20,36,68,255,230,4,52
 db 4,28,20,36,68,255,6,6,52
 db 252,128,128,254,3,1,129,254,53
 db 254,192,192,254,3,1,131,254,53
 db 126,192,128,252,131,129,65,62,54
 db 62,64,192,190,193,129,65,126,54
 db 63,64,192,190,193,129,195,126,54
 db 255,131,6,4,8,24,16,32,55
 db 248,131,6,12,8,16,32,64,55
 db 255,130,6,12,24,16,32,64,55
 db 124,130,134,124,99,193,195,126,56
 db 124,195,195,126,198,131,129,126,56
 db 252,130,130,126,198,129,193,127,56
 db 126,194,129,135,125,3,134,252,57
 db 62,97,65,67,127,2,134,248,57
 db 124,130,131,193,127,1,131,124,57
 db 255,28,28,30,30,14,0,6,33
 db 254,56,120,120,120,120,0,112,33
 db 127,28,60,56,120,112,0,240,33
 db 252,131,1,3,28,24,0,8,63
 db 254,131,3,6,60,32,0,32,63
 db 0,254,129,1,6,28,48,0,63
 db 28,20,20,36,62,98,67,128,65
 db 24,28,36,36,124,66,130,1,65
 db 24,20,52,36,62,98,67,128,65
 db 254,130,130,254,135,129,129,254,66
 db 254,131,130,252,135,129,129,254,66
 db 252,130,130,254,134,129,129,254,66
 db 124,134,129,128,128,128,67,62,67
 db 124,194,129,128,128,128,195,60,67
 db 60,67,128,128,128,128,130,124,67
 db 254,130,129,129,129,195,198,120,68
 db 248,134,131,129,129,193,195,254,68
 db 126,65,193,193,129,131,134,248,68
 db 255,128,128,254,128,128,128,255,69
 db 252,128,128,252,192,64,64,127,69
 db 62,192,128,158,240,128,131,252,69
 db 252,131,128,128,240,143,128,128,70
 db 127,64,64,192,254,128,128,128,70
 db 255,128,128,128,255,192,192,192,70
 db 60,67,128,128,142,130,194,126,71
 db 62,67,128,128,142,130,194,126,71
 db 62,195,128,134,141,129,195,126,71
 db 128,129,129,253,131,129,129,129,72
 db 2,130,131,159,225,65,65,64,72
 db 255,16,16,16,24,24,24,127,73
 db 254,24,24,24,24,24,24,127,73
 db 31,1,1,1,1,1,130,252,74
 db 31,1,1,3,3,3,130,124,74
 db 15,1,1,3,3,3,130,124,74
 db 6,140,152,144,240,136,132,131,75
 db 6,136,144,176,240,136,132,131,75
 db 6,132,152,176,240,136,132,131,75
 db 128,128,128,128,128,128,192,63,76
 db 195,167,165,157,153,129,129,129,77
 db 6,198,167,185,217,193,65,64,77
 db 3,197,165,189,153,129,129,128,77
 db 97,113,81,209,155,138,142,134,78
 db 65,225,241,211,219,139,135,134,78
 db 192,161,177,145,137,141,133,3,78
 db 62,65,193,129,129,131,130,124,79
 db 62,67,193,129,129,129,194,126,79
 db 124,195,193,193,254,128,128,128,80
 db 248,198,129,129,225,158,128,128,80
 db 127,129,129,134,248,192,64,64,80
 db 124,132,130,130,130,100,56,7,81
 db 124,130,130,130,130,68,56,15,81
 db 62,67,129,131,130,198,56,15,81
 db 248,134,130,254,136,140,134,3,82
 db 248,132,134,252,136,136,132,3,82
 db 252,130,132,188,200,140,135,128,82
 db 62,67,64,56,6,3,131,126,83
 db 126,195,192,124,3,1,193,126,83
 db 126,67,64,56,6,1,193,62,83
 db 255,16,16,16,16,24,24,24,84
 db 1,129,129,131,131,130,130,124,85
 db 129,129,129,129,129,129,193,126,85
 db 1,130,66,68,68,40,40,48,86
 db 128,67,66,98,36,36,20,24,86
 db 1,130,130,146,190,172,236,204,87
 db 1,1,129,203,91,87,118,48,87
 db 1,129,131,90,90,94,102,102,87
 db 6,196,104,24,28,38,97,192,88
 db 131,68,44,24,24,36,66,193,88
 db 198,68,40,24,24,36,34,65,88
 db 195,66,36,28,8,8,8,8,89
 db 193,66,36,20,8,8,8,8,89
 db 1,194,36,52,24,8,8,8,89
 db 127,2,6,8,16,96,192,255,90
 db 62,196,12,24,16,32,71,248,90
 db 127,2,4,8,16,96,64,254,90
 db 60,198,6,126,196,134,143,243,97
 db 124,132,6,126,134,134,222,51,97
 db 124,196,4,124,196,132,142,115,97
 db 128,128,190,195,129,129,195,190,98
 db 128,128,190,195,129,129,195,254,98
 db 128,128,190,195,129,129,131,254,98
 db 124,198,131,128,128,128,67,60,99
 db 124,194,131,128,128,128,67,62,99
 db 2,2,126,130,131,131,195,125,100
 db 2,2,254,131,131,131,195,125,100
 db 1,1,127,131,131,130,134,126,100
 db 62,66,131,255,224,129,194,124,101
 db 60,66,131,255,192,128,67,60,101
 db 60,66,130,159,224,129,194,124,101
 db 31,48,255,48,16,16,16,16,102
 db 31,32,255,48,48,16,16,16,102
 db 19,102,131,131,135,125,3,124,103
 db 59,70,130,130,134,122,4,248,103
 db 59,198,131,129,131,125,1,126,103
 db 192,128,191,193,129,129,129,129,104
 db 128,128,190,194,65,65,65,65,104
 db 128,128,188,195,129,129,129,129,104
 db 8,0,120,8,8,8,15,248,105
 db 8,64,56,24,24,24,216,127,105
 db 32,24,8,8,8,200,63,0,105
 db 1,30,3,2,2,2,2,252,106
 db 1,30,3,3,2,2,2,252,106
 db 2,62,3,3,1,1,1,255,106
 db 192,192,135,136,176,216,140,131,107
 db 128,128,131,156,240,152,132,3,107
 db 128,128,134,152,176,248,140,131,107
 db 248,24,24,16,16,48,48,31,108
 db 182,217,153,153,137,153,137,137,109
 db 183,217,201,137,137,153,153,128,109
 db 178,221,137,137,137,137,153,145,109
 db 94,97,193,193,193,131,131,130,110
 db 188,226,129,129,129,129,129,1,110
 db 156,230,129,129,129,129,129,1,110
 db 124,194,131,129,129,129,67,62,111
 db 62,97,193,129,129,131,198,124,111
 db 95,97,65,193,194,252,128,128,112
 db 126,65,65,193,195,190,128,128,112
 db 252,194,193,193,193,243,142,128,112
 db 127,131,129,129,131,125,1,1,113
 db 125,131,129,129,131,125,1,1,113
 db 124,131,131,131,195,63,2,2,113
 db 143,80,96,64,64,64,96,64,114
 db 15,216,112,64,64,96,96,96,114
 db 128,95,112,64,64,96,96,96,114
 db 254,131,128,120,14,1,129,126,115
 db 126,194,128,252,7,1,3,254,115
 db 62,67,64,124,6,3,130,124,115
 db 32,62,240,96,96,96,32,63,116
 db 48,126,224,96,96,96,96,63,116
 db 48,240,46,96,96,96,96,63,116
 db 1,131,131,131,131,131,135,121,117
 db 129,129,131,131,131,131,199,123,117
 db 129,131,131,131,131,131,207,57,117
 db 129,66,66,38,36,52,20,24,118
 db 129,67,66,34,36,36,28,24,118
 db 131,130,70,68,100,40,40,56,118
 db 1,131,130,218,90,106,110,100,119
 db 129,131,130,154,170,174,236,204,119
 db 1,129,131,90,90,86,102,96,119
 db 2,196,44,24,24,54,35,64,120
 db 193,98,36,24,24,36,70,131,120
 db 195,34,52,24,24,36,68,195,120
 db 129,66,98,36,20,8,8,48,121
 db 96,33,35,18,20,8,24,112,121
 db 131,66,68,36,40,16,48,224,121
 db 127,2,4,8,16,32,64,255,122
 db 126,194,4,8,16,32,71,254,122
 db 124,7,6,12,16,96,224,31,122
 db 62,194,129,129,129,129,195,124,48
 db 24,248,8,8,8,8,8,127,49
 db 24,232,8,8,8,8,8,255,49
 db 124,195,3,2,28,48,192,127,50
 db 126,195,3,2,12,48,64,255,50
 db 124,194,130,4,24,48,65,254,50
 db 124,130,3,30,6,129,65,63,51
 db 126,3,1,31,6,193,97,63,51
 db 124,130,2,30,6,1,65,63,51
 db 6,10,18,34,98,223,246,4,52
 db 4,12,20,36,68,207,244,4,52
 db 12,20,36,100,68,255,230,2,52
 db 126,128,128,254,193,1,195,126,53
 db 126,64,64,126,1,1,193,126,53
 db 254,128,128,252,3,1,193,62,53
 db 126,195,128,254,131,129,195,62,54
 db 62,65,192,190,195,129,195,126,54
 db 62,64,128,191,193,129,195,124,54
 db 255,3,6,12,8,16,16,48,55
 db 126,131,131,126,195,129,129,126,56
 db 126,194,134,254,65,129,131,252,56
 db 252,130,195,126,134,129,193,127,56
 db 62,195,129,131,253,1,194,124,57
 db 124,130,129,129,127,1,193,62,57
 db 62,65,129,131,125,3,198,124,57
 db 14,14,14,24,24,56,0,112,33
 db 31,30,31,30,126,126,0,126,33
 db 62,60,60,56,112,240,0,224,33
 db 62,193,129,6,28,48,0,32,63
 db 126,129,1,3,12,48,0,32,63
 db 127,193,129,6,12,16,0,16,63
 db 48,40,76,68,126,67,129,128,65
 db 28,20,36,38,126,194,130,1,65
 db 24,20,36,36,126,66,130,1,65
 db 120,70,193,241,142,129,193,127,66
 db 126,130,130,191,193,129,134,248,66
 db 252,130,130,254,131,129,193,126,66
 db 124,134,130,128,128,129,66,62,67
 db 62,66,128,128,128,131,194,124,67
 db 62,66,129,128,128,129,194,124,67
 db 126,129,129,129,129,131,130,252,68
 db 126,129,129,129,129,129,130,252,68
 db 252,130,129,129,129,129,67,124,68
 db 127,192,128,254,130,128,128,254,69
 db 62,192,128,142,224,128,195,124,69
 db 63,64,64,71,120,64,64,127,69
 db 255,128,128,192,254,128,128,128,70
 db 124,67,192,192,254,128,128,128,70
 db 124,130,128,128,143,129,65,63,71
 db 124,194,128,134,133,129,67,60,71
 db 62,67,128,135,129,129,195,124,71
 db 130,131,129,255,225,193,65,65,72
 db 192,129,129,241,143,129,131,2,72
 db 60,60,60,60,60,60,60,60,73
 db 14,28,60,60,56,56,112,112,73
 db 124,28,28,30,14,15,15,7,73
 db 1,1,1,3,3,131,130,126,74
 db 1,1,1,1,3,131,131,126,74
 db 1,3,3,2,2,130,134,124,74
 db 67,68,216,176,216,136,132,134,75
 db 67,196,152,240,152,136,132,6,75
 db 6,140,144,176,248,140,198,67,75
 db 64,64,192,192,128,128,192,63,76
 db 64,64,192,192,192,128,128,255,76
 db 64,225,163,167,165,157,153,1,77
 db 3,195,195,165,165,153,153,144,77
 db 3,133,197,229,165,157,152,128,77
 db 1,193,161,145,137,133,131,128,78
 db 65,97,241,145,137,141,135,130,78
 db 65,97,209,145,137,139,134,130,78
 db 60,195,129,129,129,129,194,124,79
 db 60,66,129,129,129,129,194,124,79
 db 255,129,129,158,240,128,128,128,80
 db 255,129,129,143,248,128,128,128,80
 db 126,65,65,65,254,128,128,128,80
 db 126,195,129,129,129,129,70,63,81
 db 62,97,129,129,129,131,134,126,81
 db 124,130,129,129,129,193,119,29,81
 db 252,130,130,140,246,130,130,129,82
 db 252,134,130,254,142,130,130,3,82
 db 126,193,129,142,242,130,130,129,82
 db 62,195,128,254,1,1,131,124,83
 db 62,195,128,124,3,1,131,126,83
 db 126,67,65,56,6,129,131,126,83
 db 255,24,16,16,16,16,16,16,84
 db 31,240,16,16,16,16,16,16,84
 db 252,23,16,16,16,16,16,16,84
 db 128,129,129,129,129,129,193,63,85
 db 1,129,129,129,129,129,129,126,85
 db 1,129,129,129,129,193,65,126,85
 db 129,194,66,68,36,44,56,24,86
 db 128,67,66,70,68,40,40,16,86
 db 1,130,66,66,36,36,20,24,86
 db 1,153,153,93,87,86,50,32,87
 db 128,144,153,187,170,106,78,4,87
 db 129,153,153,93,87,86,118,34,87
 db 194,68,44,24,24,36,66,195,88
 db 193,98,36,24,24,36,70,131,88
 db 64,35,52,24,24,108,196,2,88
 db 195,66,36,20,24,8,8,8,89
 db 3,194,68,44,24,16,16,16,89
 db 128,67,102,44,56,16,16,16,89
 db 127,3,4,8,16,32,64,254,90
 db 127,2,4,8,16,32,66,252,90
 db 255,2,4,8,16,32,65,254,90
 db 124,132,4,60,228,134,134,123,97
 db 124,6,2,126,130,130,126,3,97
 db 62,66,2,62,98,130,142,251,97
 db 128,156,227,193,193,65,66,124,98
 db 128,128,252,194,129,129,193,190,98
 db 128,136,246,193,193,193,194,252,98
 db 62,99,192,128,128,130,134,120,99
 db 62,99,65,128,128,130,198,124,99
 db 60,67,192,128,129,131,194,124,99
 db 1,57,197,131,131,129,67,63,100
 db 1,1,125,131,129,129,193,127,100
 db 1,49,79,131,129,129,67,63,100
 db 60,66,130,255,128,129,66,60,101
 db 124,198,130,255,134,192,67,62,101
 db 60,66,131,158,240,131,194,124,101
 db 30,16,255,16,16,16,16,16,102
 db 30,24,255,24,24,24,8,8,102
 db 31,24,255,16,16,16,48,48,102
 db 125,195,129,129,65,63,195,126,103
 db 63,67,193,193,67,63,194,126,103
 db 61,67,65,65,67,62,194,124,103
 db 128,128,254,129,129,129,129,129,104
 db 128,128,190,193,129,129,193,129,104
 db 64,64,255,225,193,129,129,131,104
 db 14,0,28,60,60,56,56,112,105
 db 224,0,56,24,28,14,14,7,105
 db 192,0,96,120,56,28,12,14,105
 db 6,2,6,6,7,7,3,254,106
 db 24,4,12,12,12,14,6,252,106
 db 6,0,12,12,8,24,16,240,106
 db 192,192,198,152,240,136,132,3,107
 db 128,128,134,152,240,136,196,3,107
 db 64,64,67,220,240,136,132,2,107
 db 240,112,56,56,28,30,15,15,108
 db 127,127,127,127,31,31,31,127,108
 db 30,30,30,30,30,30,30,126,108
 db 240,159,137,137,137,153,153,1,109
 db 38,249,145,145,153,137,137,128,109
 db 119,217,145,153,137,137,137,137,109
 db 188,227,129,129,129,129,129,129,110
 db 30,226,195,193,193,65,65,64,110
 db 190,227,129,129,129,129,129,1,110
 db 124,198,131,129,129,193,67,62,111
 db 124,194,131,129,129,193,99,62,111
 db 124,195,129,129,129,129,67,62,111
 db 254,193,129,129,195,188,128,128,112
 db 252,130,129,129,193,243,140,128,112
 db 190,195,129,193,195,126,64,64,112
 db 61,67,129,131,131,255,2,2,113
 db 126,194,131,131,131,125,17,1,113
 db 63,67,129,129,131,253,1,1,113
 db 7,124,96,64,64,64,192,192,114
 db 111,126,96,64,192,192,192,192,114
 db 79,120,96,64,192,192,192,192,114
 db 252,130,192,112,14,129,193,127,115
 db 126,67,64,56,14,131,195,126,115
 db 124,130,128,120,14,1,195,126,115
 db 48,240,30,16,16,24,24,15,116
 db 16,254,30,24,24,24,24,31,116
 db 24,31,252,48,48,48,96,124,116
 db 128,129,129,129,129,129,195,127,117
 db 3,131,131,129,129,193,195,124,117
 db 128,129,129,131,131,131,195,63,117
 db 129,66,66,38,36,36,28,24,118
 db 128,67,66,102,36,36,56,24,118
 db 1,130,66,70,36,36,28,24,118
 db 128,128,153,91,106,106,110,4,119
 db 128,128,153,91,106,106,76,4,119
 db 1,1,25,157,86,86,50,32,119
 db 65,98,52,24,24,60,102,192,120
 db 67,98,52,24,24,52,98,193,120
 db 64,35,22,24,24,44,196,2,120
 db 192,67,34,54,20,12,8,56,121
 db 65,66,38,36,40,16,48,224,121
 db 195,66,100,44,56,16,16,224,121
 db 126,196,12,24,16,32,79,252,122
 db 127,66,4,8,16,32,71,252,122
 db 254,4,12,24,16,32,64,255,122
 db 62,67,129,129,129,129,194,126,48
 db 62,66,129,129,129,129,67,124,48
 db 3,255,3,3,3,3,3,1,49
 db 3,254,2,3,3,3,3,3,49
 db 3,254,6,6,6,6,6,6,49
 db 124,130,2,2,28,96,64,255,50
 db 30,97,65,2,28,48,65,254,50
 db 124,194,2,14,3,1,65,62,51
 db 126,194,130,14,3,1,193,126,51
 db 62,66,130,14,1,1,67,126,51
 db 2,14,20,100,196,255,4,4,52
 db 2,14,22,36,196,255,4,4,52
 db 12,28,60,100,68,159,244,4,52
 db 30,96,64,126,65,1,130,124,53
 db 62,192,128,254,129,1,131,124,53
 db 254,192,216,254,3,1,193,62,53
 db 124,131,128,254,195,129,65,126,54
 db 60,67,128,252,130,131,130,124,54
 db 124,194,129,252,130,129,195,62,54
 db 255,2,4,8,16,16,32,96,55
 db 252,3,6,12,24,16,32,96,55
 db 127,194,4,12,8,16,16,48,55
 db 63,65,67,62,97,129,131,252,56
 db 126,193,194,126,193,129,131,126,56
 db 124,67,97,126,130,129,65,62,56
 db 62,65,65,65,63,3,130,124,57
 db 124,130,131,193,63,1,67,62,57
 db 124,67,193,65,63,129,66,62,57
 db 30,30,30,60,60,124,120,124,33
 db 15,14,28,56,56,112,96,224,33
 db 30,30,30,126,124,124,120,126,33
 db 126,193,1,6,12,8,0,8,63
 db 254,129,1,3,12,8,0,8,63
 db 126,193,129,6,24,16,0,32,63
 db 8,24,24,52,36,124,66,199,65
 db 8,24,24,52,52,124,66,199,65
 db 16,16,40,44,124,67,68,192,65
 db 240,46,33,49,46,35,225,31,66
 db 252,34,34,58,38,33,33,127,66
 db 255,33,35,63,33,33,46,248,66
 db 63,67,129,128,128,128,65,62,67
 db 31,33,64,128,128,128,131,124,67
 db 124,195,129,129,128,128,96,62,67
 db 248,70,67,97,33,33,33,126,68
 db 248,78,67,65,65,65,65,254,68
 db 120,38,33,33,33,97,67,254,68
 db 120,47,33,50,46,98,225,63,69
 db 254,66,98,62,34,32,33,126,69
 db 254,96,98,126,98,65,67,252,69
 db 255,33,32,63,33,32,48,120,70
 db 254,33,32,62,34,32,32,120,70
 db 255,32,34,62,32,32,32,120,70
 db 126,194,130,128,135,130,66,60,71
 db 62,66,130,135,130,130,194,124,71
 db 62,66,128,135,130,130,194,60,71
 db 240,71,66,122,78,198,228,14,72
 db 119,34,98,122,78,70,68,238,72
 db 232,70,68,126,78,98,98,23,72
 db 254,16,16,16,24,24,8,127,73
 db 48,15,8,24,16,16,208,126,73
 db 254,16,16,16,24,8,8,127,73
 db 255,24,24,24,8,8,8,120,74
 db 63,8,8,24,24,24,16,240,74
 db 127,24,24,24,24,24,24,240,74
 db 46,100,72,80,112,76,71,236,75
 db 255,68,72,112,112,72,68,239,75
 db 248,103,76,112,88,72,228,15,75
 db 240,64,32,32,32,32,33,127,76
 db 240,64,64,96,96,33,39,248,76
 db 240,64,64,64,64,65,71,248,76
 db 3,198,102,102,122,90,87,224,77
 db 3,70,102,110,122,90,86,212,77
 db 195,70,102,102,90,90,82,247,77
 db 64,103,83,82,74,78,230,2,78
 db 199,98,82,90,79,71,35,113,78
 db 103,98,82,82,74,78,68,226,78
 db 60,67,129,129,129,129,194,124,79
 db 62,97,193,129,129,129,130,124,79
 db 124,35,33,33,62,32,32,240,80
 db 254,33,33,35,60,32,32,248,80
 db 255,33,33,46,48,48,48,120,80
 db 60,66,130,130,130,134,120,15,81
 db 124,130,129,129,65,62,8,7,81
 db 120,132,130,130,194,126,24,7,81
 db 248,68,68,124,120,44,38,243,82
 db 252,68,68,120,72,76,71,224,82
 db 252,68,68,120,88,76,70,243,82
 db 31,33,64,48,6,2,130,252,83
 db 61,67,33,24,4,130,195,62,83
 db 127,67,97,56,6,131,193,126,83
 db 255,153,24,24,16,16,16,60,84
 db 63,217,136,8,8,8,8,62,84
 db 255,153,16,16,16,16,16,124,84
 db 231,66,66,66,66,68,68,120,85
 db 55,226,66,98,35,33,34,62,85
 db 224,71,66,66,66,66,34,30,85
 db 224,71,35,34,20,20,24,8,86
 db 231,34,34,52,20,12,8,8,86
 db 231,66,38,36,44,24,16,16,86
 db 251,90,74,90,58,52,36,36,87
 db 248,91,90,90,94,44,44,40,87
 db 240,91,90,90,90,44,44,40,87
 db 244,39,52,24,24,44,196,47,88
 db 240,39,20,24,24,108,228,15,88
 db 119,38,20,24,24,40,100,238,88
 db 231,34,52,28,8,8,8,30,89
 db 224,39,38,28,24,16,16,60,89
 db 7,226,36,28,24,24,24,60,89
 db 127,130,4,8,16,32,65,255,90
 db 255,132,12,24,16,32,65,255,90
 db 254,132,12,8,16,32,65,255,90
 db 60,68,6,62,100,132,140,247,97
 db 124,196,4,124,196,132,252,119,97
 db 120,68,4,124,196,132,124,7,97
 db 224,96,64,126,65,65,67,62,98
 db 224,96,108,54,33,33,33,62,98
 db 224,96,126,115,65,65,67,62,98
 db 28,98,64,128,128,129,198,124,99
 db 60,98,192,128,128,129,70,60,99
 db 60,66,192,128,128,129,198,124,99
 db 6,2,126,198,134,134,196,127,100
 db 28,4,116,132,132,132,196,63,100
 db 14,6,126,198,134,132,196,63,100
 db 120,196,246,252,128,193,67,62,101
 db 60,70,254,220,128,129,195,124,101
 db 124,196,254,252,128,129,67,60,101
 db 30,49,254,48,48,48,16,252,102
 db 15,16,124,48,48,32,32,248,102
 db 31,48,62,240,16,16,24,126,102
 db 127,68,196,120,64,127,131,252,103
 db 60,103,38,124,96,220,194,126,103
 db 60,103,38,124,96,220,130,126,103
 db 192,64,92,102,66,98,99,252,104
 db 192,64,88,100,102,98,34,247,104
 db 96,32,44,50,34,98,226,31,104
 db 12,0,126,8,24,24,24,255,105
 db 16,0,248,16,24,24,24,127,105
 db 12,0,60,12,8,8,24,255,105
 db 1,62,6,2,2,6,252,0,106
 db 0,15,3,3,3,3,126,0,106
 db 1,30,6,6,6,6,252,0,106
 db 224,96,111,72,112,88,76,255,107
 db 224,32,39,108,112,120,76,255,107
 db 96,32,39,40,48,40,100,255,107
 db 62,4,12,12,12,8,24,255,108
 db 224,32,32,48,48,48,22,124,108
 db 252,24,24,24,24,24,24,255,108
 db 240,126,74,74,74,74,250,15,109
 db 22,250,74,74,90,82,95,240,109
 db 116,218,82,82,82,66,90,255,109
 db 28,228,68,68,100,102,39,240,110
 db 60,244,100,102,102,38,39,253,110
 db 248,116,68,100,102,38,98,255,110
 db 124,198,131,129,129,193,99,62,111
 db 62,67,193,129,129,131,198,60,111
 db 126,97,97,97,118,104,32,248,112
 db 62,225,97,33,62,32,32,120,112
 db 124,50,33,33,33,62,32,240,112
 db 60,68,132,132,140,116,6,15,113
 db 63,66,130,130,206,54,6,31,113
 db 127,130,130,130,126,6,4,31,113
 db 31,248,48,48,48,48,60,248,114
 db 31,124,16,16,48,48,48,252,114
 db 119,255,48,16,16,16,24,126,114
 db 126,194,194,112,30,131,195,126,115
 db 126,194,194,120,30,131,195,126,115
 db 127,67,99,48,140,194,195,62,115
 db 8,248,62,48,48,48,48,31,116
 db 48,240,60,48,48,48,16,31,116
 db 16,116,252,48,16,16,16,15,116
 db 204,70,66,66,66,66,126,23,117
 db 204,66,66,66,66,66,111,52,117
 db 200,70,66,66,66,98,62,23,117
 db 240,39,34,54,20,20,8,8,118
 db 39,226,34,36,20,28,8,8,118
 db 7,226,38,36,52,24,24,8,118
 db 0,219,73,74,90,94,44,36,119
 db 27,217,74,90,122,52,36,36,119
 db 219,74,74,90,90,60,36,36,119
 db 254,36,24,16,24,44,68,239,120
 db 30,232,56,16,24,36,39,96,120
 db 248,38,56,24,56,44,228,15,120
 db 246,35,34,20,12,8,8,56,121
 db 231,34,54,20,12,8,8,48,121
 db 240,103,34,20,28,8,24,112,121
 db 124,71,4,24,16,96,227,62,122
 db 254,132,8,24,16,33,67,254,122
 db 254,132,8,24,16,32,33,127,122
 db 124,194,129,129,129,193,67,62,48
 db 62,67,129,129,129,131,194,124,48
 db 248,16,24,24,24,24,24,127,49
 db 62,12,12,8,8,24,24,255,49
 db 120,144,16,24,24,24,24,127,49
 db 124,194,134,4,8,16,103,248,50
 db 124,198,134,4,12,16,33,126,50
 db 124,134,6,4,12,24,33,255,50
 db 62,195,6,30,3,1,2,252,51
 db 124,130,6,28,3,1,3,126,51
 db 126,195,6,28,3,1,3,252,51
 db 12,28,52,100,196,255,4,4,52
 db 6,28,52,100,196,254,7,4,52
 db 6,30,54,68,196,62,7,4,52
 db 63,64,240,28,3,1,1,126,53
 db 63,64,112,12,6,2,134,124,53
 db 126,192,224,24,12,12,8,248,53
 db 7,16,96,124,130,130,132,120,54
 db 15,48,64,254,129,129,195,62,54
 db 31,48,64,254,131,129,65,62,54
 db 127,130,2,4,12,8,16,16,55
 db 127,130,6,4,8,24,16,32,55
 db 127,130,2,4,4,8,24,16,55
 db 126,131,134,124,110,193,129,126,56
 db 126,193,67,62,110,129,129,127,56
 db 126,131,194,60,110,131,129,127,56
 db 62,65,65,65,63,2,12,240,57
 db 126,195,129,195,127,2,12,240,57
 db 126,195,129,195,127,6,28,112,57
 db 15,30,60,60,56,112,0,224,33
 db 124,60,62,62,62,30,0,6,33
 db 30,60,60,60,120,120,0,112,33
 db 127,129,131,2,6,12,0,4,63
 db 126,195,1,6,12,24,16,16,63
 db 127,129,3,6,12,24,0,8,63
 db 112,40,44,36,126,67,71,224,65
 db 112,56,40,36,124,70,194,71,65
 db 120,24,40,36,60,78,66,231,65
 db 62,194,70,127,65,65,110,112,66
 db 126,195,66,127,65,65,78,248,66
 db 254,67,66,126,67,65,65,254,66
 db 30,98,128,128,128,129,195,124,67
 db 124,195,129,128,128,192,97,62,67
 db 126,194,128,128,128,192,97,62,67
 db 248,70,65,65,65,65,67,254,68
 db 126,65,65,65,65,65,66,252,68
 db 124,66,65,65,65,65,66,254,68
 db 127,33,97,124,72,64,65,255,69
 db 252,71,67,120,72,64,65,63,69
 db 127,97,65,124,72,64,65,255,69
 db 255,65,72,120,72,64,64,248,70
 db 255,65,64,124,100,32,32,120,70
 db 127,33,96,120,72,64,64,240,70
 db 124,194,128,128,132,199,97,63,71
 db 124,195,129,128,140,71,98,30,71
 db 124,130,128,128,143,195,97,31,71
 db 102,194,66,126,66,66,67,228,72
 db 96,71,66,122,70,66,226,7,72
 db 119,98,66,126,66,66,66,230,72
 db 254,16,16,16,24,24,24,255,73
 db 127,24,24,24,16,16,16,254,73
 db 126,11,24,24,24,16,144,126,73
 db 63,4,4,4,134,134,198,60,74
 db 63,4,4,6,134,134,198,124,74
 db 31,4,4,4,132,132,132,120,74
 db 224,70,72,112,72,68,230,35,75
 db 224,71,76,112,72,68,230,3,75
 db 115,68,72,112,72,68,68,227,75
 db 248,32,32,32,33,33,33,254,76
 db 120,32,32,32,33,33,39,252,76
 db 240,32,32,32,32,33,33,127,76
 db 3,199,101,125,217,193,199,224,77
 db 96,99,103,87,90,66,226,6,77
 db 192,227,230,214,218,194,226,7,77
 db 192,103,114,82,74,74,198,6,78
 db 7,226,115,89,77,71,99,112,78
 db 198,99,83,89,73,101,99,115,78
 db 62,99,193,129,129,129,194,60,79
 db 62,99,65,129,129,129,66,124,79
 db 60,67,129,129,129,129,66,60,79
 db 124,34,33,97,126,64,64,240,80
 db 63,193,65,102,56,32,36,120,80
 db 126,33,33,99,124,64,64,248,80
 db 62,67,129,129,129,70,61,62,81
 db 62,66,129,129,130,196,63,56,81
 db 62,67,129,129,129,66,60,63,81
 db 252,70,66,76,120,68,66,227,82
 db 252,66,66,92,124,70,67,224,82
 db 124,98,98,126,124,68,66,227,82
 db 63,65,192,124,7,129,129,254,83
 db 60,67,65,56,6,129,193,62,83
 db 63,65,64,120,7,129,129,254,83
 db 224,158,17,17,16,16,112,28,84
 db 255,153,17,24,16,16,16,62,84
 db 31,249,152,24,8,8,10,62,84
 db 7,98,195,67,65,65,66,60,85
 db 231,66,67,65,65,65,33,30,85
 db 228,71,66,66,66,66,98,30,85
 db 226,67,66,38,36,36,24,24,86
 db 7,226,66,68,36,40,56,16,86
 db 7,226,66,70,36,36,24,24,86
 db 7,195,219,91,87,87,118,34,87
 db 231,131,154,218,90,102,102,102,87
 db 231,194,154,218,170,238,100,68,87
 db 99,98,52,24,24,36,66,231,88
 db 196,70,44,24,24,36,70,103,88
 db 199,70,44,24,24,36,66,231,88
 db 231,70,36,56,16,16,16,60,89
 db 227,70,36,56,16,16,16,124,89
 db 71,198,36,56,16,16,16,60,89
 db 254,130,4,24,48,65,193,127,90
 db 254,134,140,24,48,65,129,255,90
 db 254,134,140,24,48,97,193,255,90
 db 60,98,2,62,66,135,139,240,97
 db 124,66,2,126,66,134,143,248,97
 db 60,196,6,62,194,134,143,240,97
 db 192,64,94,97,65,65,97,222,98
 db 192,64,94,99,65,65,97,254,98
 db 96,32,32,118,65,65,225,30,98
 db 60,71,129,128,128,192,97,62,99
 db 31,99,192,128,128,129,198,124,99
 db 62,98,192,128,128,129,194,124,99
 db 6,6,62,70,130,130,135,120,100
 db 3,3,62,198,130,130,134,127,100
 db 3,3,62,66,130,130,134,123,100
 db 124,198,131,255,135,192,97,31,101
 db 62,67,129,255,128,128,67,62,101
 db 124,198,131,255,135,128,97,63,101
 db 63,32,254,32,32,32,32,254,102
 db 31,32,62,224,32,48,48,254,102
 db 31,16,62,96,32,32,32,252,102
 db 120,135,130,130,102,26,2,60,103
 db 123,198,130,130,70,58,6,60,103
 db 120,135,130,130,126,20,4,124,103
 db 96,32,126,98,67,66,66,231,104
 db 192,64,120,70,66,66,194,7,104
 db 192,64,92,98,66,66,66,231,104
 db 16,0,112,24,24,24,31,252,105
 db 32,0,224,16,16,16,16,255,105
 db 16,0,112,16,16,16,152,127,105
 db 2,0,63,1,3,3,2,254,106
 db 4,0,255,3,3,3,1,127,106
 db 4,0,255,3,1,1,1,126,106
 db 192,70,72,88,112,44,39,96,107
 db 96,32,96,111,112,72,196,7,107
 db 96,96,102,76,112,88,68,199,107
 db 120,24,24,24,24,24,31,252,108
 db 240,16,16,16,16,16,24,255,108
 db 56,8,8,8,8,24,216,63,108
 db 14,122,210,82,82,89,72,96,109
 db 224,222,82,82,90,91,201,9,109
 db 246,90,82,82,82,83,83,201,109
 db 220,98,66,66,66,66,66,227,110
 db 222,98,67,67,67,67,226,7,110
 db 188,98,66,66,66,66,66,227,110
 db 124,198,131,129,129,65,99,30,111
 db 62,99,193,129,129,130,198,120,111
 db 120,198,131,129,129,65,97,30,111
 db 30,225,65,67,126,64,64,240,112
 db 220,98,65,65,97,94,64,240,112
 db 92,114,65,65,97,94,64,240,112
 db 123,135,130,130,126,2,2,15,113
 db 63,70,130,130,142,122,2,14,113
 db 63,70,130,130,198,122,2,7,113
 db 198,63,48,32,32,32,112,126,114
 db 111,57,48,32,32,32,32,252,114
 db 7,104,48,32,32,32,44,248,114
 db 62,67,65,60,7,129,193,254,115
 db 63,97,64,126,1,1,135,252,115
 db 31,97,64,126,3,1,134,252,115
 db 32,96,254,96,96,96,97,62,116
 db 32,96,254,96,96,64,96,63,116
 db 64,64,252,64,96,32,32,31,116
 db 192,71,67,67,67,66,110,27,117
 db 198,67,67,67,67,67,70,59,117
 db 192,70,66,66,66,66,102,59,117
 db 231,66,70,100,36,40,56,16,118
 db 224,71,66,38,36,36,56,24,118
 db 224,68,71,98,36,36,56,24,118
 db 192,195,66,90,122,110,108,76,119
 db 3,66,194,90,90,86,118,32,119
 db 192,131,66,90,90,54,54,38,119
 db 230,103,36,24,56,100,226,39,120
 db 231,34,52,24,56,100,194,103,120
 db 231,34,52,24,24,100,66,231,120
 db 99,66,36,52,24,16,16,240,121
 db 227,66,38,36,24,24,16,240,121
 db 96,99,35,54,28,24,144,112,121
 db 255,135,6,24,48,96,241,127,122
 db 30,254,140,8,16,33,79,248,122
 db 255,130,12,24,48,96,193,255,122
 db 62,67,131,129,129,131,194,124,48
 db 60,66,131,129,129,131,66,126,48
 db 56,88,24,24,24,24,152,127,49
 db 24,120,24,24,24,24,24,255,49
 db 62,65,1,2,12,48,224,255,50
 db 62,67,1,3,28,96,224,30,50
 db 124,194,130,4,24,48,97,126,50
 db 60,3,1,15,6,1,193,62,51
 db 126,3,1,30,6,1,129,126,51
 db 126,3,3,30,3,1,3,254,51
 db 14,18,38,198,230,31,6,15,52
 db 28,52,100,196,134,255,2,15,52
 db 28,52,100,68,132,255,6,15,52
 db 252,128,208,126,3,1,193,126,53
 db 126,64,88,126,1,1,129,126,53
 db 252,128,192,126,3,1,129,126,53
 db 30,48,64,158,227,193,195,62,54
 db 14,48,64,158,227,193,195,126,54
 db 15,48,64,188,226,130,130,124,54
 db 255,131,2,4,12,8,24,16,55
 db 254,1,3,6,4,12,24,16,55
 db 254,1,3,2,4,12,8,16,55
 db 63,65,195,126,99,129,131,124,56
 db 126,195,130,124,99,193,131,126,56
 db 62,65,65,62,198,131,130,126,56
 db 62,195,129,199,121,2,12,248,57
 db 124,194,129,195,61,3,6,252,57
 db 62,195,131,135,121,2,12,120,57
 db 7,14,28,28,60,0,0,248,33
 db 7,14,30,28,60,0,0,248,33
 db 7,15,14,30,60,0,0,248,33
 db 126,129,1,7,28,8,0,24,63
 db 252,131,1,3,28,16,0,48,63
 db 62,193,129,6,24,16,0,24,63
 db 48,40,104,68,100,190,130,1,65
 db 16,40,44,36,68,126,130,129,65
 db 24,40,44,68,70,126,131,128,65
 db 254,130,130,190,195,193,67,124,66
 db 248,134,131,246,142,129,129,255,66
 db 248,134,129,243,142,131,129,127,66
 db 124,194,131,128,128,128,67,60,67
 db 62,65,128,128,128,129,130,124,67
 db 60,66,129,128,128,129,66,60,67
 db 126,129,129,129,129,131,134,248,68
 db 126,131,129,129,129,130,140,240,68
 db 254,128,128,254,252,192,192,127,69
 db 254,128,128,240,78,64,64,127,69
 db 254,128,128,134,252,128,128,255,69
 db 255,192,192,252,140,128,128,128,70
 db 127,64,64,192,252,128,128,128,70
 db 127,64,64,252,224,192,128,128,70
 db 62,67,128,135,137,129,130,124,71
 db 60,195,128,131,143,129,67,62,71
 db 60,66,129,128,143,129,65,62,71
 db 129,129,129,159,241,129,129,129,72
 db 128,129,129,249,143,129,129,129,72
 db 128,129,129,249,143,129,129,1,72
 db 15,30,28,28,56,112,112,240,73
 db 30,30,30,60,60,120,120,120,73
 db 240,240,120,60,62,30,15,15,73
 db 1,3,1,1,1,1,131,126,74
 db 1,1,3,3,2,2,134,124,74
 db 1,1,3,3,3,2,194,124,74
 db 131,140,144,224,176,152,132,2,75
 db 3,140,152,160,224,152,140,131,75
 db 67,76,216,224,176,152,140,6,75
 db 96,64,64,192,192,128,128,127,76
 db 128,128,192,192,192,64,67,126,76
 db 64,64,64,192,192,192,192,255,76
 db 129,193,195,167,165,157,153,17,77
 db 65,195,163,165,165,185,153,145,77
 db 128,193,195,167,165,157,153,17,77
 db 1,193,225,145,137,135,131,128,78
 db 1,129,225,145,141,135,129,128,78
 db 1,129,225,145,137,135,129,128,78
 db 30,97,65,129,129,131,134,124,79
 db 62,97,193,129,129,129,134,124,79
 db 120,70,65,193,241,142,128,128,80
 db 126,65,65,195,252,128,128,128,80
 db 120,70,65,65,243,142,128,128,80
 db 124,130,129,129,65,62,6,3,81
 db 124,134,130,131,194,62,4,3,81
 db 124,134,130,130,194,118,28,3,81
 db 127,65,65,66,120,204,134,131,82
 db 126,65,65,198,248,140,132,131,82
 db 252,130,130,198,248,136,132,3,82
 db 126,67,64,112,12,2,130,126,83
 db 126,131,128,120,14,1,193,126,83
 db 124,130,128,120,14,1,65,62,83
 db 252,19,16,16,16,48,48,32,84
 db 31,248,24,24,24,24,24,16,84
 db 255,24,24,24,24,24,24,24,84
 db 129,129,129,129,129,65,65,62,85
 db 129,129,129,129,129,193,65,62,85
 db 129,129,129,129,129,129,65,62,85
 db 1,130,66,68,68,40,40,16,86
 db 129,67,66,34,38,20,20,8,86
 db 1,155,154,186,170,110,108,68,87
 db 1,17,155,218,86,86,102,32,87
 db 129,145,154,170,170,174,108,76,87
 db 2,196,44,24,24,52,35,64,88
 db 2,196,108,24,24,36,35,64,88
 db 193,66,36,36,24,24,24,24,89
 db 3,130,68,36,24,24,8,8,89
 db 62,194,4,8,16,32,67,252,90
 db 254,4,12,8,16,32,96,127,90
 db 61,99,193,129,129,129,199,124,97
 db 120,199,131,129,129,65,99,29,97
 db 124,199,131,129,129,129,103,61,97
 db 128,128,190,193,129,129,193,190,98
 db 64,68,254,193,129,129,194,188,98
 db 128,128,184,198,129,129,193,62,98
 db 30,99,64,128,128,131,198,124,99
 db 60,67,128,128,128,131,198,124,99
 db 1,1,125,195,131,130,130,126,100
 db 1,1,125,131,129,129,67,63,100
 db 1,1,29,99,129,129,131,124,100
 db 62,65,129,255,192,129,194,124,101
 db 124,130,131,249,143,128,65,62,101
 db 62,67,129,191,240,129,66,124,101
 db 15,16,254,48,48,32,96,96,102
 db 31,48,255,48,48,48,48,48,102
 db 15,16,255,48,16,16,16,24,102
 db 61,195,129,129,199,57,1,126,103
 db 29,99,129,129,199,121,3,124,103
 db 127,195,129,129,103,17,2,124,103
 db 128,156,227,193,129,193,193,64,104
 db 128,158,163,193,193,193,193,64,104
 db 128,128,252,195,129,129,129,1,104
 db 240,0,48,56,24,28,30,15,105
 db 7,0,14,30,28,60,56,120,105
 db 124,0,30,30,30,30,30,30,105
 db 112,0,24,28,12,6,7,255,106
 db 6,0,12,12,12,12,12,248,106
 db 1,0,2,6,4,12,8,248,106
 db 128,128,142,152,224,176,140,7,107
 db 64,64,71,216,224,176,136,6,107
 db 64,67,196,216,224,240,136,134,107
 db 30,30,30,30,30,28,28,124,108
 db 6,14,28,28,56,48,112,96,108
 db 7,7,14,12,28,60,56,120,108
 db 39,217,153,145,153,153,137,128,109
 db 224,148,155,153,153,145,17,1,109
 db 7,249,153,145,145,145,144,128,109
 db 94,99,193,193,129,129,129,129,110
 db 254,227,129,129,129,129,129,1,110
 db 188,198,131,129,129,129,129,1,110
 db 124,198,131,129,129,193,98,62,111
 db 62,66,129,129,129,129,66,124,111
 db 252,195,129,129,225,190,128,128,112
 db 126,97,65,193,230,152,128,128,112
 db 124,98,193,193,225,190,128,128,112
 db 63,65,129,129,135,121,1,1,113
 db 125,131,129,129,119,9,1,1,113
 db 58,70,130,131,135,125,1,1,113
 db 71,126,192,192,192,192,192,192,114
 db 207,252,192,192,192,192,192,192,114
 db 71,252,224,192,192,192,192,192,114
 db 62,97,64,120,14,2,130,124,115
 db 124,66,65,48,12,130,66,62,115
 db 124,130,193,112,30,131,65,62,115
 db 48,255,32,32,32,96,96,62,116
 db 32,254,240,48,48,48,48,31,116
 db 48,240,63,32,96,96,96,60,116
 db 1,129,129,129,131,131,134,120,117
 db 129,129,129,129,129,129,131,125,117
 db 129,129,129,131,131,130,134,122,117
 db 128,193,66,66,36,36,40,24,118
 db 1,194,66,98,36,52,20,28,118
 db 128,67,66,66,36,36,28,24,118
 db 1,145,154,154,170,108,108,68,119
 db 1,1,154,154,234,110,100,96,119
 db 1,145,154,90,90,110,100,100,119
 db 64,35,52,24,56,108,196,2,120
 db 130,68,44,24,24,36,34,65,120
 db 2,196,108,56,24,52,35,64,120
 db 128,67,70,36,40,16,32,96,121
 db 193,66,38,36,24,16,16,32,121
 db 193,66,100,36,56,16,32,96,121
 db 127,2,4,8,16,32,64,254,122
 db 255,2,4,24,16,32,96,255,122
 db 254,6,4,8,16,32,96,255,122
 db 62,65,129,129,129,129,194,124,48
 db 62,67,129,129,129,129,66,124,48
 db 255,6,6,14,12,12,28,24,49
 db 255,7,7,7,6,6,6,6,49
 db 252,14,6,6,6,3,3,3,49
 db 63,65,65,2,4,24,48,255,50
 db 62,67,131,2,4,24,32,254,50
 db 124,194,130,6,4,24,49,126,50
 db 63,65,3,30,3,1,129,126,51
 db 126,193,1,30,6,129,195,126,51
 db 126,195,2,30,3,1,65,62,51
 db 12,20,36,100,70,255,6,2,52
 db 6,26,18,34,66,255,6,4,52
 db 6,10,50,98,66,254,7,4,52
 db 254,128,128,254,3,129,193,62,53
 db 252,131,128,254,3,129,193,62,53
 db 254,128,128,254,3,1,193,126,53
 db 62,65,128,191,193,129,131,126,54
 db 62,65,192,190,195,131,130,124,54
 db 124,194,128,190,193,129,65,126,54
 db 252,3,2,6,4,8,16,32,55
 db 255,3,6,4,12,24,16,32,55
 db 15,243,2,4,4,8,24,16,55
 db 126,194,130,254,99,193,195,126,56
 db 63,65,65,126,67,129,131,126,56
 db 252,130,131,126,198,129,193,63,56
 db 126,130,129,131,125,1,67,62,57
 db 62,193,129,131,125,1,130,124,57
 db 126,195,129,131,125,1,65,126,57
 db 112,56,24,28,30,30,0,3,33
 db 224,112,112,112,56,28,0,7,33
 db 112,48,56,24,28,12,0,3,33
 db 126,131,1,3,62,32,0,32,63
 db 126,131,1,1,62,32,0,64,63
 db 126,131,1,3,30,16,0,16,63
 db 8,24,28,36,52,94,194,7,65
 db 16,48,40,44,124,99,70,192,65
 db 8,24,24,36,52,94,194,71,65
 db 254,66,66,126,65,97,99,254,66
 db 252,66,66,124,71,65,65,254,66
 db 254,66,66,124,67,65,65,254,66
 db 126,194,130,128,128,128,65,62,67
 db 30,99,64,128,128,128,131,126,67
 db 60,67,129,128,128,128,64,62,67
 db 126,33,65,65,65,66,68,248,68
 db 248,70,67,65,65,97,33,126,68
 db 126,193,65,65,65,66,92,240,68
 db 254,66,64,124,68,96,33,127,69
 db 127,97,96,124,68,64,65,255,69
 db 254,66,64,124,68,64,65,255,69
 db 127,33,32,62,36,96,96,240,70
 db 254,65,96,50,46,34,32,120,70
 db 255,97,96,58,34,32,32,120,70
 db 62,66,128,129,134,130,194,124,71
 db 62,98,194,129,134,130,130,124,71
 db 62,97,65,64,67,65,33,31,71
 db 7,194,66,94,98,66,71,224,72
 db 103,66,66,126,70,66,66,198,72
 db 99,66,66,126,66,66,66,198,72
 db 254,16,16,24,24,24,24,127,73
 db 127,24,24,24,24,16,16,254,73
 db 63,8,8,24,24,24,16,254,73
 db 30,5,12,8,8,8,152,240,74
 db 127,8,8,12,12,12,12,248,74
 db 127,8,12,12,12,12,12,248,74
 db 100,103,72,112,72,76,196,3,75
 db 119,38,40,120,88,72,68,227,75
 db 238,72,88,112,88,76,38,97,75
 db 112,32,32,32,32,97,65,255,76
 db 240,64,64,64,64,65,67,252,76
 db 224,64,64,96,32,32,33,127,76
 db 3,194,102,102,110,90,91,192,77
 db 65,98,102,102,118,90,218,211,77
 db 192,99,98,102,86,218,218,3,77
 db 194,99,114,82,74,78,198,2,78
 db 67,99,114,82,74,78,198,194,78
 db 67,98,82,82,74,78,70,194,78
 db 60,66,129,129,129,129,67,126,79
 db 124,130,129,129,129,129,67,62,79
 db 127,33,33,34,60,96,64,240,80
 db 248,70,65,65,123,68,64,240,80
 db 63,193,65,102,120,32,32,112,80
 db 60,66,130,130,130,134,124,7,81
 db 124,198,130,130,130,196,60,3,81
 db 62,65,129,129,131,198,60,3,81
 db 252,66,66,76,120,76,70,227,82
 db 252,66,66,76,120,76,70,225,82
 db 120,38,98,118,72,68,228,3,82
 db 126,130,128,112,14,129,129,254,83
 db 63,65,65,56,6,129,129,254,83
 db 254,130,194,48,14,129,129,255,83
 db 255,153,144,16,16,16,16,56,84
 db 252,159,17,17,16,16,16,56,84
 db 127,145,144,16,16,16,16,56,84
 db 227,67,65,65,65,97,33,30,85
 db 3,226,66,66,66,66,66,60,85
 db 227,66,66,67,65,65,34,62,85
 db 231,66,68,100,44,56,24,16,86
 db 35,194,68,100,44,40,24,16,86
 db 192,211,91,122,110,108,76,8,87
 db 195,90,90,90,90,38,36,36,87
 db 3,83,218,90,94,118,36,32,87
 db 6,228,104,56,24,54,39,96,88
 db 7,230,108,56,24,38,103,224,88
 db 231,68,36,24,24,36,68,199,88
 db 231,98,36,28,24,8,8,60,89
 db 224,67,38,20,24,8,8,60,89
 db 35,194,36,60,24,8,8,28,89
 db 126,132,132,8,16,33,97,126,90
 db 255,130,4,8,16,32,65,255,90
 db 124,67,6,8,16,96,194,62,90
 db 120,132,4,28,118,134,142,251,97
 db 248,140,4,60,228,134,134,127,97
 db 120,132,132,28,102,134,143,240,97
 db 224,64,72,102,65,97,97,94,98
 db 224,64,64,118,65,65,193,62,98
 db 224,64,94,99,65,65,67,126,98
 db 62,97,193,128,128,192,97,62,99
 db 62,98,192,128,128,128,195,126,99
 db 62,99,192,128,128,128,195,60,99
 db 7,3,30,98,130,130,130,127,100
 db 12,4,60,196,132,134,134,127,100
 db 12,4,124,132,132,134,70,63,100
 db 30,99,207,252,128,128,195,124,101
 db 120,198,194,254,128,192,65,62,101
 db 124,194,241,159,128,192,96,63,101
 db 31,48,126,176,16,16,24,124,102
 db 31,16,252,48,48,32,32,248,102
 db 15,16,62,112,48,32,32,240,102
 db 63,68,132,124,128,126,129,254,103
 db 27,100,68,124,192,254,130,252,103
 db 126,140,132,124,128,126,129,127,103
 db 96,32,44,50,98,66,66,231,104
 db 224,96,72,118,66,66,66,231,104
 db 192,64,92,98,98,34,35,112,104
 db 16,0,248,24,24,24,8,127,105
 db 0,126,12,12,12,4,63,0,105
 db 8,0,124,12,28,28,28,255,105
 db 126,12,12,4,6,6,252,0,106
 db 31,6,6,6,6,4,252,0,106
 db 62,12,12,12,12,12,248,0,106
 db 224,64,64,71,120,120,68,227,107
 db 192,64,64,70,120,56,36,115,107
 db 192,64,64,70,120,88,100,99,107
 db 240,32,48,48,16,24,24,126,108
 db 248,24,24,24,8,12,12,127,108
 db 126,12,12,24,24,24,24,252,108
 db 240,94,82,89,89,89,217,3,109
 db 126,218,73,73,73,73,91,216,109
 db 254,90,82,82,74,75,73,219,109
 db 30,242,98,98,66,66,71,224,110
 db 28,226,66,66,66,66,103,224,110
 db 28,226,66,66,66,67,103,224,110
 db 124,198,130,129,129,193,98,62,111
 db 62,98,193,129,129,131,198,124,111
 db 126,33,33,33,102,88,64,224,112
 db 254,65,65,67,126,112,64,224,112
 db 254,99,65,65,99,126,64,224,112
 db 60,68,132,132,134,122,2,7,113
 db 60,196,132,134,134,122,2,7,113
 db 124,131,130,194,126,2,6,14,113
 db 255,56,32,32,32,48,48,248,114
 db 55,248,32,32,32,32,32,240,114
 db 255,56,48,48,48,16,16,124,114
 db 125,67,67,48,14,131,195,254,115
 db 63,99,97,48,12,130,130,252,115
 db 63,99,97,56,12,130,194,254,115
 db 24,48,255,32,32,32,32,62,116
 db 32,240,44,32,32,48,16,15,116
 db 32,60,224,32,32,48,17,30,116
 db 198,70,66,66,66,98,34,63,117
 db 2,198,194,66,66,66,71,56,117
 db 2,78,194,66,66,66,103,56,117
 db 231,66,68,100,44,40,24,16,118
 db 231,67,102,36,36,60,24,16,118
 db 3,98,194,68,36,52,24,24,118
 db 195,202,90,90,90,54,36,36,119
 db 3,202,90,90,82,54,36,32,119
 db 3,202,90,90,90,36,36,36,119
 db 247,102,44,24,24,44,68,231,120
 db 6,228,40,24,24,36,71,224,120
 db 112,39,54,24,56,108,196,6,120
 db 227,98,38,20,28,8,24,112,121
 db 3,226,38,20,12,8,8,48,121
 db 227,70,36,56,24,16,32,224,121
 db 63,102,68,8,17,34,70,252,122
 db 127,130,132,8,16,33,65,255,122
 db 127,134,140,24,16,33,65,254,122
 db 62,67,129,129,129,129,130,124,48
 db 124,66,129,129,129,129,67,62,48
 db 30,116,4,12,12,12,8,255,49
 db 24,216,24,24,8,8,8,63,49
 db 60,200,8,8,8,8,8,127,49
 db 120,132,4,4,24,48,65,127,50
 db 124,130,2,6,24,96,128,255,50
 db 124,130,6,4,24,32,193,254,50
 db 62,65,3,30,7,1,131,254,51
 db 126,65,1,30,6,1,129,126,51
 db 124,130,2,28,3,1,131,252,51
 db 4,28,60,100,196,255,4,15,52
 db 4,28,52,36,68,255,4,15,52
 db 2,6,28,52,100,255,4,30,52
 db 2,254,128,252,3,1,1,126,53
 db 2,124,128,156,227,1,3,126,53
 db 1,254,128,252,3,1,131,254,53
 db 62,64,192,190,193,129,131,126,54
 db 62,65,128,252,131,129,193,62,54
 db 63,97,192,190,193,129,131,126,54
 db 63,131,6,4,12,8,24,16,55
 db 255,129,2,2,4,4,4,8,55
 db 255,131,2,6,4,4,12,8,55
 db 62,65,65,62,102,131,129,126,56
 db 62,65,67,62,102,195,131,254,56
 db 126,195,195,62,102,131,129,127,56
 db 126,195,129,131,125,3,134,252,57
 db 62,65,129,131,125,2,6,248,57
 db 62,195,129,131,125,3,2,124,57
 db 15,14,28,60,56,120,0,224,33
 db 120,56,60,60,60,60,0,30,33
 db 120,56,60,60,28,60,0,14,33
 db 0,126,193,3,6,24,56,0,63
 db 0,126,129,3,6,56,56,0,63
 db 126,131,1,3,28,28,0,4,63
 db 24,56,36,36,126,98,65,128,65
 db 48,40,44,100,126,99,64,128,65
 db 48,40,40,68,116,94,130,1,65
 db 252,131,129,243,158,129,129,255,66
 db 248,134,130,246,222,65,65,127,66
 db 252,134,130,254,206,65,65,127,66
 db 62,64,192,128,128,128,193,126,67
 db 126,192,128,128,128,128,64,63,67
 db 62,193,128,128,128,192,96,63,67
 db 248,132,130,129,129,129,129,126,68
 db 254,131,129,129,129,131,134,248,68
 db 252,130,129,129,129,129,131,254,68
 db 127,64,192,204,248,128,128,254,69
 db 127,64,192,252,204,128,128,254,69
 db 126,128,128,140,240,192,64,127,69
 db 255,192,192,128,254,128,128,128,70
 db 127,64,64,198,248,128,128,128,70
 db 127,64,64,192,252,192,192,128,70
 db 63,96,192,128,135,131,130,124,71
 db 126,195,128,128,134,193,97,63,71
 db 62,193,128,128,135,129,65,63,71
 db 65,193,193,255,129,131,131,130,72
 db 2,131,131,159,225,129,193,192,72
 db 1,129,129,159,241,129,129,128,72
 db 126,30,30,30,30,31,31,31,73
 db 7,14,14,30,28,28,56,112,73
 db 112,120,56,60,28,30,14,15,73
 db 6,6,6,3,3,3,7,252,74
 db 3,3,3,3,3,3,6,248,74
 db 3,3,3,3,3,3,7,252,74
 db 67,68,200,240,144,136,132,134,75
 db 67,196,136,240,144,136,132,131,75
 db 4,8,152,144,240,140,199,64,75
 db 128,128,128,192,192,192,192,127,76
 db 128,128,128,192,192,192,67,126,76
 db 192,192,192,192,192,192,128,255,76
 db 128,193,163,165,181,153,129,1,77
 db 3,131,197,165,189,153,129,128,77
 db 129,195,197,165,181,153,137,129,77
 db 3,131,225,145,137,135,193,192,78
 db 192,225,161,145,137,143,135,2,78
 db 65,97,241,209,137,143,134,130,78
 db 62,66,129,129,129,129,66,124,79
 db 124,194,129,129,129,129,194,126,79
 db 252,130,129,129,255,192,64,64,80
 db 252,131,129,131,254,128,128,128,80
 db 254,129,129,131,252,192,64,64,80
 db 120,132,134,130,134,196,124,3,81
 db 124,130,130,130,130,124,6,3,81
 db 60,68,130,130,130,132,140,115,81
 db 124,66,67,254,200,140,4,3,82
 db 252,134,134,140,240,136,132,131,82
 db 124,70,194,254,152,140,132,3,82
 db 62,65,96,56,14,2,195,126,83
 db 62,192,128,252,3,1,3,124,83
 db 31,96,64,120,6,2,2,252,83
 db 255,24,24,16,16,16,16,16,84
 db 255,8,8,8,8,8,12,12,84
 db 255,16,16,16,16,16,48,48,84
 db 129,129,129,129,129,129,193,62,85
 db 1,129,129,129,129,129,195,124,85
 db 128,129,129,129,129,129,195,62,85
 db 1,2,130,66,102,36,20,28,86
 db 1,130,66,70,36,36,28,24,86
 db 1,130,66,68,100,40,40,24,86
 db 1,145,155,218,86,102,102,32,87
 db 129,153,153,90,106,102,102,100,87
 db 1,17,155,154,86,118,102,32,87
 db 67,102,36,24,24,36,68,130,88
 db 65,34,36,24,56,44,68,130,88
 db 2,196,40,24,24,36,35,64,88
 db 1,130,66,52,28,8,8,8,89
 db 129,66,100,44,24,16,16,16,89
 db 1,194,102,52,28,8,8,8,89
 db 63,2,4,8,16,32,64,254,90
 db 30,228,12,8,16,48,47,120,90
 db 124,6,3,127,199,129,247,57,97
 db 62,3,1,7,127,195,135,127,97
 db 126,194,3,31,113,129,135,248,97
 db 96,64,92,115,65,193,195,254,98
 db 192,192,222,225,193,193,130,252,98
 db 64,64,88,246,193,193,195,190,98
 db 62,64,128,128,128,192,97,62,99
 db 126,194,128,128,128,192,97,63,99
 db 62,97,192,128,128,128,65,62,99
 db 3,3,31,103,129,129,131,125,100
 db 2,2,58,198,131,131,195,127,100
 db 1,1,27,103,130,130,134,250,100
 db 62,99,195,254,128,192,67,62,101
 db 62,99,65,255,128,128,194,62,101
 db 30,97,193,255,192,128,195,126,101
 db 31,48,254,38,32,32,96,64,102
 db 31,48,55,248,16,24,24,24,102
 db 127,198,198,120,72,127,131,254,103
 db 124,71,70,124,112,220,134,124,103
 db 62,196,132,248,70,121,67,124,103
 db 192,192,222,225,193,193,131,128,104
 db 64,64,76,115,193,129,129,131,104
 db 64,192,222,227,193,193,195,131,104
 db 14,0,31,31,31,30,30,126,105
 db 120,0,30,30,30,14,15,15,105
 db 6,0,15,30,30,30,30,124,105
 db 2,0,6,6,4,12,12,248,106
 db 4,0,6,6,6,6,6,252,106
 db 2,0,4,4,12,12,8,240,106
 db 128,128,131,140,240,152,140,131,107
 db 128,128,131,140,240,152,196,3,107
 db 128,130,132,136,240,216,134,131,107
 db 15,30,30,60,60,120,120,240,108
 db 124,124,28,30,30,15,15,7,108
 db 14,14,28,24,56,48,112,96,108
 db 240,223,137,137,137,137,153,1,109
 db 246,221,137,137,137,153,145,17,109
 db 240,159,153,137,137,137,137,1,109
 db 190,227,131,129,129,129,129,129,110
 db 190,227,129,129,129,129,129,129,110
 db 30,243,193,129,129,129,129,128,110
 db 62,67,193,129,129,129,194,124,111
 db 62,99,193,129,129,131,198,124,111
 db 190,225,193,193,195,126,64,64,112
 db 94,97,65,193,194,252,128,128,112
 db 95,97,65,195,194,252,128,128,112
 db 124,131,131,131,66,62,2,2,113
 db 124,195,131,131,195,127,2,2,113
 db 63,67,195,131,195,111,57,1,113
 db 79,120,64,192,192,192,192,128,114
 db 15,216,112,96,96,96,96,32,114
 db 159,248,224,192,96,96,96,96,114
 db 126,195,192,120,14,3,131,126,115
 db 63,192,192,120,30,3,3,254,115
 db 63,192,192,120,14,3,131,254,115
 db 24,16,255,48,32,32,96,62,116
 db 32,32,252,48,48,16,16,31,116
 db 16,17,255,48,48,48,50,63,116
 db 193,193,129,131,131,131,199,127,117
 db 129,129,129,129,129,131,199,125,117
 db 130,131,131,131,131,195,199,124,117
 db 192,67,66,102,36,44,56,24,118
 db 1,194,66,102,36,52,28,24,118
 db 129,66,66,38,36,20,28,8,118
 db 129,153,153,90,94,86,102,38,119
 db 129,137,89,91,86,86,54,34,119
 db 1,1,154,154,90,106,108,96,119
 db 3,98,36,24,24,36,70,195,120
 db 192,102,36,56,56,108,196,3,120
 db 192,99,36,24,56,68,134,3,120
 db 193,66,34,52,28,8,8,16,121
 db 128,65,66,36,40,56,32,96,121
 db 128,67,70,36,40,16,48,96,121
 db 14,254,12,24,16,32,127,240,122
 db 255,2,12,8,16,32,96,255,122
 db 127,2,12,8,16,32,64,254,122
 db 60,66,129,129,129,129,67,62,48
 db 62,99,193,129,129,130,194,124,48
 db 12,124,12,8,8,24,24,255,49
 db 12,124,76,8,8,8,24,255,49
 db 6,60,68,12,8,8,8,255,49
 db 62,65,1,3,14,24,96,255,50
 db 124,194,2,6,12,16,32,255,50
 db 62,67,1,3,14,56,224,63,50
 db 62,97,1,14,3,1,131,126,51
 db 62,66,130,14,3,1,3,126,51
 db 126,193,1,14,7,1,193,126,51
 db 6,30,52,100,196,255,4,4,52
 db 6,30,54,70,196,127,4,4,52
 db 8,28,52,100,68,159,244,6,52
 db 63,96,64,126,2,3,2,252,53
 db 63,32,96,124,2,2,6,252,53
 db 63,96,64,126,3,1,2,252,53
 db 6,8,16,126,193,129,131,124,54
 db 6,24,48,126,131,129,193,126,54
 db 14,24,96,254,131,129,193,62,54
 db 127,130,6,4,8,16,32,96,55
 db 255,2,6,12,24,16,32,96,55
 db 255,3,2,4,12,8,24,48,55
 db 62,65,65,126,98,129,131,126,56
 db 126,67,193,126,230,129,129,126,56
 db 62,65,65,62,198,129,129,126,56
 db 62,193,129,206,118,12,24,48,57
 db 62,193,129,206,126,8,16,96,57
 db 14,14,28,56,56,96,0,96,33
 db 112,120,56,56,60,56,0,3,33
 db 30,28,28,120,124,96,0,56,33
 db 0,254,3,3,30,48,0,0,63
 db 0,254,1,3,12,16,0,0,63
 db 0,254,3,3,14,24,16,0,63
 db 8,24,20,36,60,34,71,224,65
 db 16,24,40,40,60,68,194,39,65
 db 16,24,28,36,60,34,71,224,65
 db 127,49,33,62,33,33,35,252,66
 db 254,34,34,62,35,33,33,126,66
 db 254,35,34,62,33,33,35,252,66
 db 126,194,128,128,128,128,67,126,67
 db 62,66,128,128,128,128,195,124,67
 db 62,66,128,128,128,128,193,126,67
 db 254,97,97,33,33,35,46,240,68
 db 224,92,70,66,66,66,194,252,68
 db 254,99,33,33,33,33,38,120,68
 db 255,33,34,62,34,33,33,255,69
 db 126,17,49,50,46,32,33,255,69
 db 127,49,50,62,34,33,33,254,69
 db 254,33,33,34,62,50,48,120,70
 db 120,39,33,34,62,34,32,240,70
 db 255,33,34,62,50,32,32,120,70
 db 126,195,129,128,134,129,67,62,71
 db 126,193,128,128,135,129,65,127,71
 db 62,66,128,130,135,129,65,126,71
 db 112,39,34,122,78,68,228,14,72
 db 7,226,66,94,114,66,71,224,72
 db 119,34,34,126,100,68,68,238,72
 db 254,24,24,24,24,24,24,255,73
 db 63,8,8,8,24,24,16,252,73
 db 63,12,8,8,24,24,16,224,74
 db 63,12,8,8,24,24,16,240,74
 db 119,38,44,56,56,104,68,230,75
 db 119,36,40,56,40,44,100,243,75
 db 46,196,72,112,120,44,39,240,75
 db 240,32,32,32,32,33,35,124,76
 db 224,64,64,64,64,66,110,240,76
 db 248,32,32,32,32,33,33,254,76
 db 3,194,102,102,106,90,91,228,77
 db 3,198,102,102,122,90,95,224,77
 db 195,66,102,102,102,90,90,231,77
 db 192,103,114,82,74,78,198,34,78
 db 96,39,114,82,74,78,196,36,78
 db 199,98,82,82,74,78,70,226,78
 db 126,195,129,129,129,129,195,126,79
 db 62,97,65,129,129,131,130,124,79
 db 120,54,33,33,63,32,32,240,80
 db 124,51,33,33,62,32,32,240,80
 db 124,19,49,33,62,32,32,240,80
 db 62,195,129,129,129,130,124,7,81
 db 126,193,129,129,131,198,120,6,81
 db 126,131,129,129,129,66,60,7,81
 db 124,34,34,54,60,36,36,243,82
 db 120,46,34,62,36,36,246,3,82
 db 120,38,34,52,40,100,100,243,82
 db 126,193,64,56,6,129,129,126,83
 db 62,67,192,124,3,1,131,252,83
 db 126,130,192,56,6,131,129,126,83
 db 252,139,25,16,16,16,16,120,84
 db 255,137,8,8,8,8,8,60,84
 db 231,66,66,66,66,66,68,60,85
 db 224,71,66,66,66,66,66,60,85
 db 231,66,66,66,34,34,34,30,85
 db 228,67,98,36,52,20,24,8,86
 db 247,66,34,36,20,20,12,8,86
 db 224,71,66,36,36,40,24,16,86
 db 3,91,218,90,94,118,36,32,87
 db 192,75,91,90,118,54,38,34,87
 db 224,72,91,90,90,106,38,4,87
 db 46,228,40,24,24,36,39,244,88
 db 119,36,20,24,24,36,36,239,88
 db 119,38,52,24,24,36,36,239,88
 db 7,226,36,52,24,8,8,30,89
 db 239,66,36,24,24,8,8,60,89
 db 47,198,36,56,16,16,16,60,89
 db 254,130,4,8,16,32,65,255,90
 db 62,196,136,24,16,33,79,240,90
 db 126,66,4,8,16,33,65,254,90
 db 124,196,134,62,102,132,143,240,97
 db 124,70,2,126,134,134,252,7,97
 db 120,140,132,60,100,132,143,240,97
 db 192,96,46,51,33,33,33,63,98
 db 224,96,62,49,33,33,33,62,98
 db 192,64,126,33,33,33,35,60,98
 db 124,194,130,128,128,192,96,63,99
 db 30,99,64,192,128,128,194,124,99
 db 30,98,192,128,128,128,199,124,99
 db 12,4,60,68,132,134,134,123,100
 db 28,4,60,196,132,132,134,123,100
 db 7,2,126,130,130,130,198,59,100
 db 60,66,130,252,128,128,67,124,101
 db 124,198,130,254,128,192,64,63,101
 db 126,195,129,255,128,192,192,63,101
 db 31,49,252,20,16,16,16,126,102
 db 31,17,60,248,48,48,48,252,102
 db 63,49,252,16,16,24,8,63,102
 db 2,124,134,140,112,127,65,126,103
 db 57,70,194,126,96,254,131,126,103
 db 121,70,66,62,96,254,130,126,103
 db 192,64,120,100,70,66,226,15,104
 db 96,32,56,102,98,66,226,15,104
 db 224,32,124,98,66,66,66,255,104
 db 32,0,240,16,16,24,24,127,105
 db 48,0,248,24,24,24,24,127,105
 db 16,0,248,24,24,24,24,127,105
 db 32,240,24,24,12,6,6,254,106
 db 4,20,38,6,7,3,3,255,106
 db 2,30,19,3,7,3,3,254,106
 db 192,64,102,40,56,40,36,115,107
 db 192,96,103,108,56,40,36,247,107
 db 96,32,32,47,56,104,76,246,107
 db 31,3,6,6,12,12,12,255,108
 db 240,16,24,24,8,12,12,63,108
 db 240,24,24,24,8,12,12,63,108
 db 246,74,74,74,74,74,202,91,109
 db 224,92,74,73,73,203,26,3,109
 db 240,78,73,73,73,203,218,7,109
 db 220,98,66,66,66,66,66,239,110
 db 124,50,34,34,98,66,66,255,110
 db 220,102,98,66,66,66,226,7,110
 db 124,194,129,129,129,193,97,62,111
 db 31,225,33,97,38,120,32,240,112
 db 108,51,33,33,33,127,96,240,112
 db 252,99,97,97,65,126,64,240,112
 db 127,195,130,130,206,54,4,31,113
 db 62,66,130,134,142,118,4,15,113
 db 239,49,48,48,48,48,48,124,114
 db 238,57,48,48,16,16,16,124,114
 db 230,63,33,32,32,32,32,248,114
 db 126,67,99,56,14,131,195,62,115
 db 126,194,196,120,14,131,131,254,115
 db 126,198,128,252,15,1,131,252,115
 db 16,62,240,48,16,16,16,31,116
 db 24,255,16,48,48,48,32,30,116
 db 24,254,16,16,16,16,16,31,116
 db 12,196,102,98,34,34,39,56,117
 db 14,6,198,98,34,34,39,56,117
 db 204,100,38,38,34,34,38,31,117
 db 7,226,68,100,44,40,56,16,118
 db 231,66,38,36,36,24,24,16,118
 db 224,103,34,38,36,52,24,24,118
 db 3,2,202,218,90,86,52,32,119
 db 195,74,90,90,90,108,108,32,119
 db 3,202,74,90,122,54,54,36,119
 db 240,39,36,28,24,44,228,15,120
 db 255,36,60,24,24,60,38,239,120
 db 238,36,44,24,24,52,36,119,120
 db 231,100,36,40,24,16,16,224,121
 db 7,230,36,52,24,8,24,112,121
 db 240,71,36,44,56,16,144,224,121
 db 124,199,6,8,16,96,195,62,122
 db 30,244,140,24,16,35,111,248,122
 db 126,67,129,129,129,129,194,126,48
 db 124,194,129,129,129,129,66,124,48
 db 240,16,16,24,24,8,8,127,49
 db 112,208,16,24,24,8,15,112,49
 db 248,24,24,24,24,24,24,255,49
 db 62,99,1,3,6,56,224,31,50
 db 124,66,2,2,4,24,96,255,50
 db 62,66,66,6,12,24,96,255,50
 db 252,194,2,60,6,1,129,126,51
 db 126,65,3,30,6,1,129,126,51
 db 63,97,35,28,2,3,130,252,51
 db 4,8,18,38,68,255,132,4,52
 db 12,24,50,102,196,255,4,4,52
 db 24,48,32,68,132,255,5,4,52
 db 254,128,128,254,3,1,131,254,53
 db 127,192,192,254,3,1,131,254,53
 db 127,64,64,126,2,2,130,252,53
 db 15,48,96,220,227,129,131,126,54
 db 15,48,64,252,198,131,195,126,54
 db 255,131,130,4,12,8,24,8,55
 db 252,135,3,12,24,48,96,96,55
 db 255,131,6,12,16,48,96,96,55
 db 62,67,67,62,70,129,129,126,56
 db 126,195,194,124,71,129,129,126,56
 db 62,65,97,62,198,129,131,126,56
 db 126,195,129,207,49,2,12,48,57
 db 126,193,129,207,51,6,24,112,57
 db 126,195,129,71,59,2,12,112,57
 db 124,30,30,31,30,14,0,1,33
 db 60,60,60,60,60,60,0,4,33
 db 7,7,30,28,112,112,0,192,33
 db 127,193,7,28,48,96,0,32,63
 db 254,195,3,14,48,32,0,16,63
 db 0,127,195,3,12,48,32,0,63
 db 12,20,20,38,34,126,66,129,65
 db 56,40,40,68,124,134,130,1,65
 db 126,193,193,254,134,129,129,254,66
 db 254,131,130,254,195,129,131,252,66
 db 252,130,129,243,142,129,129,127,66
 db 120,130,130,128,128,128,65,62,67
 db 124,130,129,128,128,129,67,62,67
 db 120,134,130,128,128,128,65,62,67
 db 126,65,193,129,129,130,134,248,68
 db 120,198,131,129,129,129,131,254,68
 db 254,128,128,248,142,192,192,127,69
 db 127,64,192,254,224,128,128,254,69
 db 252,128,128,252,196,64,64,127,69
 db 255,128,128,134,248,128,128,128,70
 db 127,128,128,134,240,128,128,128,70
 db 120,71,64,64,248,134,128,128,70
 db 62,65,128,129,133,129,130,124,71
 db 126,67,129,128,135,129,194,124,71
 db 124,195,129,128,135,129,65,62,71
 db 128,131,129,249,135,129,193,1,72
 db 28,60,60,60,60,56,120,120,73
 db 224,224,112,112,56,60,60,30,73
 db 15,14,14,28,28,56,56,120,73
 db 3,3,1,1,1,1,193,126,74
 db 1,1,3,3,3,2,130,124,74
 db 2,2,3,3,1,129,193,126,74
 db 3,132,152,176,240,136,132,131,75
 db 7,140,152,144,240,136,134,131,75
 db 3,196,136,144,240,136,132,130,75
 db 64,64,64,192,192,128,128,127,76
 db 64,64,64,192,128,128,224,31,76
 db 195,195,199,165,165,153,153,153,77
 db 192,195,163,165,165,153,153,1,77
 db 195,195,197,165,165,157,153,9,77
 db 194,227,161,145,137,141,135,195,78
 db 129,193,161,145,137,133,131,129,78
 db 192,225,161,145,137,141,133,3,78
 db 62,65,129,129,129,131,130,124,79
 db 124,67,65,65,243,156,128,128,80
 db 254,129,129,129,254,128,128,128,80
 db 254,129,129,131,252,128,128,128,80
 db 124,130,129,129,129,203,126,3,81
 db 124,194,129,129,129,155,110,27,81
 db 124,130,129,129,129,207,126,3,81
 db 252,130,130,194,188,132,134,3,82
 db 127,65,65,194,252,132,130,131,82
 db 252,130,130,134,248,132,134,131,82
 db 60,67,65,48,14,131,65,62,83
 db 126,193,192,112,6,1,193,126,83
 db 62,65,64,120,6,3,130,124,83
 db 127,144,16,16,16,16,16,16,84
 db 15,248,8,8,8,8,8,8,84
 db 252,27,8,8,8,8,8,8,84
 db 1,1,129,129,129,129,130,124,85
 db 128,65,66,66,36,36,60,24,86
 db 129,66,66,98,36,36,20,24,86
 db 1,2,194,66,38,36,20,28,86
 db 129,153,153,91,86,102,102,38,87
 db 1,25,153,154,86,118,102,96,87
 db 128,153,153,89,122,102,102,38,87
 db 65,34,20,24,24,36,68,131,88
 db 67,98,36,24,24,36,66,193,88
 db 67,38,52,24,24,36,70,192,88
 db 192,67,38,44,24,16,16,16,89
 db 129,66,36,28,24,8,8,8,89
 db 128,67,36,44,24,16,16,16,89
 db 127,3,4,8,16,32,64,255,90
 db 62,193,1,63,97,129,135,124,97
 db 62,194,1,31,97,65,67,124,97
 db 62,193,1,31,97,129,135,124,97
 db 128,158,227,193,193,65,102,88,98
 db 128,128,188,194,129,193,97,94,98
 db 128,128,190,193,129,129,195,188,98
 db 62,67,128,128,128,130,194,124,99
 db 124,198,129,128,128,192,99,62,99
 db 124,198,131,128,128,192,98,62,99
 db 1,57,199,131,129,129,67,61,100
 db 2,2,62,67,129,129,131,124,100
 db 1,1,127,193,129,129,195,125,100
 db 62,67,129,255,128,131,195,124,101
 db 124,194,129,253,135,128,99,62,101
 db 124,194,130,255,128,130,67,62,101
 db 15,16,252,48,48,32,32,96,102
 db 31,16,254,16,16,16,16,16,102
 db 15,16,254,16,24,24,24,24,102
 db 125,131,129,129,99,29,65,63,103
 db 62,194,131,129,199,57,1,126,103
 db 125,131,129,129,67,61,65,127,103
 db 64,64,126,65,193,129,131,131,104
 db 192,196,251,193,129,129,129,129,104
 db 128,128,252,131,129,129,129,1,104
 db 248,0,120,120,60,60,30,30,105
 db 248,0,56,60,60,28,14,7,105
 db 14,0,56,120,112,112,224,192,105
 db 6,0,12,12,8,24,24,248,106
 db 1,3,3,3,3,3,3,126,106
 db 3,2,6,6,6,14,12,252,106
 db 128,130,140,152,240,216,140,131,107
 db 128,128,134,152,240,152,140,3,107
 db 128,128,134,152,240,200,68,3,107
 db 7,14,14,14,28,56,56,112,108
 db 124,124,124,30,30,15,15,15,108
 db 6,14,28,60,60,56,112,96,108
 db 7,121,209,145,137,137,136,128,109
 db 224,214,139,137,153,145,17,1,109
 db 126,217,145,145,153,137,137,137,109
 db 188,194,129,129,129,129,129,1,110
 db 188,194,129,129,129,129,129,129,110
 db 124,198,131,129,129,129,99,62,111
 db 124,194,129,129,129,129,66,62,111
 db 254,195,129,129,195,190,128,128,112
 db 254,195,129,129,195,254,192,192,112
 db 190,193,129,129,194,188,128,128,112
 db 126,134,130,131,67,61,1,1,113
 db 124,131,129,131,67,62,2,2,113
 db 29,99,129,129,131,255,3,2,113
 db 111,120,64,64,192,192,192,128,114
 db 15,240,192,192,192,192,192,192,114
 db 79,240,192,192,192,192,128,128,114
 db 62,195,128,252,7,1,195,124,115
 db 124,131,192,120,14,67,193,63,115
 db 60,66,67,48,12,195,67,62,115
 db 32,252,48,48,48,48,16,15,116
 db 16,254,176,48,48,48,48,31,116
 db 16,254,48,48,48,48,56,15,116
 db 1,129,129,129,129,129,199,124,117
 db 129,129,129,129,129,129,195,125,117
 db 130,131,131,131,193,193,67,61,117
 db 1,194,66,100,36,36,28,24,118
 db 131,66,70,68,68,40,40,48,118
 db 129,194,66,98,36,52,20,24,118
 db 1,153,153,90,86,86,54,32,119
 db 128,153,89,90,90,102,102,4,119
 db 129,153,154,90,90,102,102,36,119
 db 198,68,40,24,24,44,38,67,120
 db 6,196,104,56,24,38,35,64,120
 db 198,68,40,24,24,52,38,67,120
 db 131,66,68,44,40,16,48,224,121
 db 129,66,70,36,40,24,16,224,121
 db 131,66,38,52,20,8,8,48,121
 db 63,66,4,8,16,32,71,252,122
 db 126,196,12,24,16,32,103,252,122
 db 255,2,4,8,16,32,64,255,122
 db 62,97,65,129,129,131,130,124,48
 db 60,66,129,129,129,129,66,124,48
 db 31,115,195,3,3,3,3,3,49
 db 63,195,3,3,3,3,3,3,49
 db 31,227,3,3,3,3,3,3,49
 db 124,131,1,2,12,48,192,63,50
 db 126,67,1,3,12,48,224,63,50
 db 62,65,1,2,4,24,32,255,50
 db 126,130,2,30,7,1,129,126,51
 db 126,65,1,15,6,1,193,127,51
 db 63,65,1,14,7,1,129,126,51
 db 12,28,20,36,100,71,254,132,52
 db 6,10,18,38,70,255,254,4,52
 db 12,20,52,100,68,254,7,6,52
 db 126,64,64,254,3,1,193,62,53
 db 127,64,64,254,3,3,130,124,53
 db 126,192,192,252,3,1,193,63,53
 db 124,194,129,252,130,130,194,124,54
 db 62,65,128,190,193,129,194,124,54
 db 127,2,4,8,24,48,96,192,55
 db 248,7,2,6,8,16,32,192,55
 db 255,2,6,4,8,16,32,96,55
 db 126,193,65,62,198,129,193,126,56
 db 62,195,130,254,99,129,131,252,56
 db 124,130,130,126,198,129,129,126,56
 db 126,131,129,195,63,1,194,124,57
 db 124,195,129,131,125,1,67,124,57
 db 112,120,120,120,120,32,0,124,33
 db 112,112,56,56,60,48,0,30,33
 db 28,28,28,28,60,16,0,124,33
 db 126,195,1,3,12,8,0,8,63
 db 0,62,193,3,6,24,16,0,63
 db 126,193,1,6,24,16,0,16,63
 db 16,48,40,40,124,76,196,7,65
 db 16,48,40,40,124,92,198,39,65
 db 16,16,40,40,36,124,68,231,65
 db 126,33,33,62,35,33,33,254,66
 db 252,34,33,62,34,33,33,127,66
 db 254,33,33,62,35,33,33,254,66
 db 9,55,65,128,129,129,130,124,67
 db 125,131,129,129,128,129,97,30,67
 db 29,99,129,128,128,129,130,124,67
 db 124,38,33,33,33,97,65,254,68
 db 254,67,97,33,33,33,34,124,68
 db 126,33,33,33,33,34,70,248,68
 db 126,33,37,60,60,101,65,254,69
 db 248,70,67,125,92,101,225,127,69
 db 252,66,106,56,44,37,33,127,69
 db 112,46,33,37,60,36,224,112,70
 db 255,33,36,60,36,32,32,248,70
 db 254,33,37,36,60,36,32,240,70
 db 26,54,66,128,135,130,134,124,71
 db 61,66,130,128,133,130,194,126,71
 db 126,134,130,130,128,135,66,62,71
 db 239,66,66,126,98,66,98,247,72
 db 47,198,66,126,98,66,67,252,72
 db 238,68,68,126,66,98,34,127,72
 db 124,144,16,24,24,8,11,56,73
 db 254,16,24,24,24,24,8,127,73
 db 252,16,16,16,24,24,8,127,73
 db 31,100,4,4,6,2,6,252,74
 db 63,4,4,4,4,4,132,248,74
 db 63,4,4,4,4,4,140,248,74
 db 231,68,72,88,104,68,68,247,75
 db 115,36,40,120,104,68,68,231,75
 db 38,228,72,88,120,36,39,112,75
 db 120,32,32,32,33,33,35,252,76
 db 124,32,32,32,33,33,35,254,76
 db 3,198,102,102,106,90,95,192,77
 db 224,99,102,102,90,218,210,7,77
 db 192,96,103,102,90,218,82,7,77
 db 199,98,82,82,74,70,70,226,78
 db 192,103,82,82,74,70,230,2,78
 db 71,98,82,90,74,70,68,224,78
 db 62,67,129,129,129,131,130,124,79
 db 124,134,131,129,129,129,67,62,79
 db 255,33,33,62,32,32,32,240,80
 db 254,35,33,33,62,32,32,240,80
 db 254,33,33,35,60,32,32,120,80
 db 60,66,130,130,130,154,221,63,81
 db 60,66,131,129,130,154,125,7,81
 db 248,132,130,130,194,122,60,7,81
 db 124,34,34,60,100,68,68,243,82
 db 252,102,66,124,76,68,196,179,82
 db 252,68,68,124,76,68,69,243,82
 db 126,134,130,120,6,129,193,190,83
 db 63,195,129,252,3,129,198,184,83
 db 62,194,130,252,3,129,195,252,83
 db 15,241,144,152,8,8,14,56,84
 db 31,241,152,136,8,8,14,56,84
 db 127,145,145,16,24,24,8,60,84
 db 247,66,66,66,66,66,34,60,85
 db 224,100,67,66,66,70,68,60,85
 db 240,71,66,66,66,66,98,60,85
 db 227,98,34,38,20,20,8,8,86
 db 224,67,34,38,52,28,24,16,86
 db 227,66,34,36,20,28,24,8,86
 db 208,91,90,90,122,108,108,8,87
 db 216,75,90,90,90,108,44,36,87
 db 3,25,202,90,86,54,52,32,87
 db 112,39,20,24,24,36,228,7,88
 db 231,36,24,24,24,36,103,228,88
 db 99,226,36,24,24,16,16,56,89
 db 227,34,36,20,8,8,8,28,89
 db 3,226,38,20,12,8,8,28,89
 db 252,130,4,8,48,97,193,126,90
 db 126,67,4,8,16,97,194,126,90
 db 254,132,140,8,16,33,97,127,90
 db 112,200,4,124,132,132,125,23,97
 db 120,136,140,60,101,133,143,112,97
 db 120,76,4,124,196,133,205,119,97
 db 224,96,64,126,65,65,195,190,98
 db 224,96,72,118,65,65,67,190,98
 db 224,96,44,54,33,33,33,62,98
 db 126,66,128,128,128,193,99,30,99
 db 62,67,129,128,128,192,97,62,99
 db 62,98,192,128,128,129,195,124,99
 db 12,4,52,206,132,132,198,127,100
 db 14,6,22,78,134,132,132,127,100
 db 28,4,52,204,132,132,134,127,100
 db 60,66,195,255,128,192,97,62,101
 db 60,66,195,255,128,193,99,62,101
 db 60,70,194,254,128,193,99,62,101
 db 31,48,48,254,48,48,48,252,102
 db 15,16,16,126,48,48,48,252,102
 db 31,48,48,254,16,24,24,127,102
 db 126,136,140,248,128,127,129,126,103
 db 127,68,68,120,120,142,130,126,103
 db 63,68,68,120,64,254,130,252,103
 db 192,64,80,104,196,196,196,254,104
 db 96,32,32,60,34,98,226,47,104
 db 96,96,104,118,66,66,66,255,104
 db 12,0,120,8,8,24,24,255,105
 db 24,0,248,24,24,24,24,255,105
 db 16,0,240,24,24,24,24,127,105
 db 1,12,3,3,6,6,4,252,106
 db 6,24,15,3,3,3,3,255,106
 db 2,0,19,3,3,3,3,254,106
 db 192,96,46,40,56,36,39,112,107
 db 192,96,32,38,40,56,36,119,107
 db 192,96,96,102,92,120,228,55,107
 db 60,12,12,12,24,24,24,255,108
 db 240,16,16,24,24,8,8,63,108
 db 240,24,24,24,24,24,8,127,108
 db 6,58,218,90,75,78,112,192,109
 db 240,126,74,73,75,202,26,3,109
 db 244,90,90,82,82,82,210,255,109
 db 110,50,34,34,34,98,98,255,110
 db 216,100,68,70,66,98,242,15,110
 db 108,50,34,34,98,98,226,63,110
 db 60,67,193,129,129,129,66,60,111
 db 60,194,129,129,129,131,194,60,111
 db 254,97,33,33,51,44,32,120,112
 db 252,34,33,33,49,62,32,112,112
 db 254,33,33,33,35,60,32,112,112
 db 125,135,130,130,126,6,6,15,113
 db 122,134,130,130,70,62,6,15,113
 db 58,198,130,130,134,126,2,15,113
 db 119,121,16,16,48,48,48,252,114
 db 231,57,48,48,48,48,48,252,114
 db 7,232,48,48,48,48,60,252,114
 db 124,199,67,56,134,195,225,63,115
 db 126,67,67,56,142,195,194,62,115
 db 126,195,131,124,135,129,195,254,115
 db 16,48,254,48,48,49,17,31,116
 db 16,16,254,48,48,49,17,30,116
 db 24,24,255,48,48,33,35,30,116
 db 224,78,66,66,66,98,62,3,117
 db 224,78,66,66,66,66,46,27,117
 db 204,68,68,68,70,102,38,59,117
 db 247,98,34,36,44,56,24,16,118
 db 55,226,34,36,20,20,24,8,118
 db 240,103,34,36,36,24,24,16,118
 db 248,75,74,122,58,54,36,4,119
 db 248,75,74,90,58,54,36,4,119
 db 27,217,74,90,54,54,54,16,119
 db 7,228,40,24,24,36,39,224,120
 db 96,52,23,28,56,236,36,7,120
 db 116,55,20,24,24,52,228,47,120
 db 231,38,36,56,24,16,32,224,121
 db 119,230,36,56,24,16,32,224,121
 db 247,38,36,56,24,16,32,224,121
 db 254,132,140,24,16,33,97,255,122
 db 127,198,132,8,17,33,97,255,122
 db 127,66,68,8,25,49,97,254,122
 db 62,67,193,129,129,129,194,126,48
 db 124,131,129,129,129,129,195,62,48
 db 24,248,24,24,24,24,25,254,49
 db 124,12,12,12,8,8,216,63,49
 db 48,208,16,24,24,24,15,124,49
 db 124,134,130,4,8,17,111,112,50
 db 126,67,67,2,6,24,97,254,50
 db 124,134,130,4,8,17,62,112,50
 db 63,33,3,28,3,1,130,252,51
 db 126,130,6,60,3,1,131,254,51
 db 62,33,1,30,6,195,195,126,51
 db 6,12,52,100,196,127,4,30,52
 db 6,28,52,196,196,63,12,30,52
 db 4,12,20,36,68,255,4,31,52
 db 96,95,64,124,2,131,194,126,53
 db 7,60,96,126,2,2,134,248,53
 db 113,94,64,124,2,131,194,126,53
 db 63,97,204,231,129,193,193,62,54
 db 63,194,152,230,129,129,193,62,54
 db 31,97,192,254,195,131,130,124,54
 db 143,242,134,12,8,8,8,8,55
 db 192,255,134,12,8,16,16,16,55
 db 192,255,134,12,24,16,16,16,55
 db 126,130,198,124,102,129,129,126,56
 db 126,195,198,60,102,129,131,124,56
 db 252,134,66,60,204,131,193,63,56
 db 124,194,129,193,127,25,66,124,57
 db 62,65,193,193,127,19,134,248,57
 db 126,194,131,131,237,17,2,124,57
 db 120,56,60,60,30,14,0,3,33
 db 31,31,31,31,127,31,0,30,33
 db 124,126,126,30,30,14,0,7,33
 db 0,254,129,3,12,16,16,0,63
 db 254,195,3,14,16,48,0,32,63
 db 126,129,2,12,8,8,0,8,63
 db 24,20,36,36,62,114,67,129,65
 db 48,40,40,68,124,98,195,128,65
 db 24,24,36,36,116,94,130,129,65
 db 126,195,129,254,134,129,129,254,66
 db 248,134,129,243,142,131,129,255,66
 db 252,130,130,252,134,193,65,126,66
 db 63,96,192,128,128,128,193,62,67
 db 62,64,128,128,128,128,65,63,67
 db 62,65,128,128,128,128,96,63,67
 db 252,134,131,129,129,129,131,252,68
 db 254,131,129,129,129,130,134,248,68
 db 248,134,130,129,129,129,130,252,68
 db 255,128,128,190,224,128,128,255,69
 db 254,128,128,254,128,128,128,255,69
 db 30,224,128,142,240,128,195,124,69
 db 63,192,128,134,248,128,192,192,70
 db 124,71,64,192,248,134,128,128,70
 db 255,128,128,192,254,192,64,64,70
 db 62,65,128,128,128,134,66,62,71
 db 31,96,192,128,135,129,193,126,71
 db 30,96,192,128,135,129,65,62,71
 db 130,130,130,255,131,129,193,65,72
 db 14,28,28,60,60,56,112,112,73
 db 7,14,28,28,56,48,112,224,73
 db 240,112,120,60,28,30,15,7,73
 db 1,1,1,1,1,1,3,254,74
 db 1,3,3,3,3,3,130,254,74
 db 2,2,2,3,3,1,1,254,74
 db 131,140,152,176,200,140,134,131,75
 db 2,4,136,144,184,198,131,192,75
 db 3,140,152,176,216,140,134,131,75
 db 192,192,128,128,128,128,128,127,76
 db 128,128,128,128,192,192,79,120,76
 db 128,128,128,128,128,128,129,254,76
 db 193,195,227,165,165,157,153,1,77
 db 192,193,163,167,165,153,25,1,77
 db 67,195,167,165,165,169,153,145,77
 db 193,161,161,145,137,133,133,131,78
 db 194,162,179,145,137,197,71,67,78
 db 193,225,177,145,137,133,133,131,78
 db 124,194,131,129,129,129,67,62,79
 db 124,198,129,129,129,129,65,62,79
 db 60,66,129,129,129,129,67,62,79
 db 252,195,193,193,254,128,128,128,80
 db 126,193,193,129,254,128,128,128,80
 db 254,131,129,131,252,192,64,64,80
 db 62,65,129,129,129,154,108,19,81
 db 124,195,129,129,145,106,28,2,81
 db 60,66,131,129,131,154,206,123,81
 db 126,65,194,254,232,132,134,131,82
 db 126,65,195,156,236,132,130,129,82
 db 252,132,132,184,200,196,195,64,82
 db 31,96,64,120,6,3,2,252,83
 db 62,65,96,24,4,2,194,62,83
 db 62,64,128,254,1,1,3,252,83
 db 240,31,16,16,16,16,16,16,84
 db 7,248,8,8,8,8,8,8,84
 db 129,129,129,129,129,129,65,126,85
 db 128,129,129,129,129,131,195,62,85
 db 128,67,66,98,36,36,24,24,86
 db 128,193,66,70,68,40,40,48,86
 db 1,130,194,68,68,40,40,24,86
 db 128,153,153,89,126,102,102,6,87
 db 1,25,153,154,94,102,102,96,87
 db 1,153,155,154,170,110,100,64,87
 db 130,68,40,24,24,36,67,192,88
 db 2,132,104,56,28,39,97,64,88
 db 3,130,68,40,56,16,16,16,89
 db 1,130,68,36,24,8,8,8,89
 db 128,65,98,36,24,16,16,16,89
 db 254,4,12,8,16,32,64,127,90
 db 14,244,12,8,16,32,111,112,90
 db 126,195,1,15,125,193,135,253,97
 db 252,131,3,29,255,129,193,127,97
 db 126,195,1,31,125,193,135,125,97
 db 128,128,158,227,65,65,66,124,98
 db 64,64,64,126,65,193,131,254,98
 db 64,192,204,243,193,193,131,254,98
 db 126,194,128,128,128,192,97,62,99
 db 62,96,192,128,128,129,195,124,99
 db 62,96,192,128,128,193,67,62,99
 db 1,1,25,111,129,129,193,127,100
 db 1,1,127,134,130,130,66,62,100
 db 1,1,17,127,129,129,193,127,100
 db 60,66,195,255,131,128,65,62,101
 db 124,70,195,255,195,64,97,63,101
 db 124,198,195,191,131,192,96,62,101
 db 31,48,32,252,48,48,16,16,102
 db 31,48,224,60,32,32,96,96,102
 db 31,48,32,252,32,32,32,32,102
 db 127,68,68,248,224,254,130,126,103
 db 127,68,68,120,64,254,130,126,103
 db 63,34,34,60,48,78,65,63,103
 db 192,192,196,243,193,193,193,129,104
 db 128,128,192,254,66,67,65,65,104
 db 128,128,200,254,67,65,65,65,104
 db 56,0,28,60,60,60,28,28,105
 db 14,0,12,24,56,120,112,112,105
 db 120,0,24,56,60,60,28,30,105
 db 0,3,3,3,3,2,254,0,106
 db 0,6,2,3,3,3,254,0,106
 db 2,0,2,3,3,3,3,255,106
 db 64,64,64,71,216,248,132,6,107
 db 64,192,193,198,216,248,132,130,107
 db 128,128,134,136,144,236,135,128,107
 db 240,240,112,56,28,28,30,15,108
 db 14,12,28,24,56,48,112,96,108
 db 240,112,120,60,60,30,30,15,108
 db 23,253,201,137,137,153,145,128,109
 db 240,223,137,137,137,153,17,1,109
 db 7,249,145,153,137,137,136,128,109
 db 62,226,195,195,195,193,193,192,110
 db 94,225,193,193,193,193,193,128,110
 db 30,227,195,193,193,193,193,64,110
 db 60,66,193,129,129,131,66,60,111
 db 124,198,131,129,129,193,99,30,111
 db 127,65,65,65,70,248,128,128,112
 db 126,67,65,65,195,254,128,128,112
 db 254,131,129,193,195,254,192,192,112
 db 62,66,130,131,131,127,1,1,113
 db 125,131,129,131,99,63,2,2,113
 db 63,195,131,131,198,62,2,2,113
 db 71,220,240,192,192,192,192,192,114
 db 103,126,96,64,192,192,192,192,114
 db 3,222,240,192,192,192,192,64,114
 db 126,67,96,56,14,131,225,62,115
 db 124,199,64,56,14,131,225,63,115
 db 60,71,97,56,12,130,99,30,115
 db 48,62,248,48,48,48,49,31,116
 db 32,112,254,48,48,48,16,31,116
 db 16,240,63,48,48,48,48,31,116
 db 129,129,129,129,129,193,195,125,117
 db 128,129,129,129,129,193,99,63,117
 db 3,129,129,129,129,129,199,120,117
 db 129,194,66,102,36,52,28,24,118
 db 128,195,66,68,76,104,56,48,118
 db 128,193,66,70,68,104,40,48,118
 db 1,17,154,154,90,102,100,96,119
 db 128,144,153,91,106,106,102,4,119
 db 1,145,154,154,122,102,102,100,119
 db 195,102,60,24,24,36,70,131,120
 db 2,196,40,24,24,36,99,64,120
 db 131,70,60,24,24,36,66,193,120
 db 131,66,38,52,28,8,24,112,121
 db 131,66,36,52,28,8,24,112,121
 db 64,67,38,36,24,24,16,224,121
 db 31,246,4,24,16,32,127,240,122
 db 255,6,4,24,16,32,64,255,122
 db 127,70,4,8,16,32,70,254,122
 db 12,124,12,8,8,8,24,255,49
 db 16,240,16,16,24,8,8,127,49
 db 62,4,12,12,12,8,8,255,49
 db 124,130,3,2,4,24,96,127,50
 db 124,195,1,3,6,24,96,255,50
 db 124,130,131,3,6,24,96,255,50
 db 62,67,3,28,3,1,1,254,51
 db 126,1,1,30,6,131,195,62,51
 db 252,130,2,60,6,1,129,126,51
 db 12,20,52,36,68,127,132,4,52
 db 14,30,54,100,196,127,4,4,52
 db 24,28,60,36,68,79,244,4,52
 db 126,64,64,126,2,1,195,126,53
 db 63,96,96,126,2,3,130,252,53
 db 127,64,64,126,1,1,131,126,53
 db 62,192,156,230,129,129,67,62,54
 db 31,96,204,243,129,129,195,124,54
 db 30,96,204,243,129,129,131,126,54
 db 254,4,8,24,48,32,96,96,55
 db 255,3,4,24,48,32,96,64,55
 db 127,131,4,8,24,16,48,32,55
 db 126,131,195,126,198,129,193,126,56
 db 126,195,131,126,99,129,131,126,56
 db 62,65,195,126,99,131,195,124,56
 db 124,131,129,129,199,57,2,252,57
 db 126,195,129,129,71,59,2,252,57
 db 124,194,129,129,67,63,130,252,57
 db 30,56,56,56,112,224,0,192,33
 db 120,56,56,28,28,14,0,15,33
 db 120,56,56,60,60,28,0,30,33
 db 254,1,3,14,24,16,0,16,63
 db 254,129,3,6,8,8,0,4,63
 db 254,1,1,6,8,8,0,8,63
 db 24,40,40,68,124,66,130,131,65
 db 24,20,36,36,124,66,194,129,65
 db 24,60,36,100,126,130,130,1,65
 db 252,130,131,250,142,129,129,255,66
 db 252,131,129,251,134,129,129,255,66
 db 126,193,129,254,130,129,129,254,66
 db 60,194,128,128,128,129,66,60,67
 db 60,66,129,128,128,130,194,124,67
 db 62,66,129,128,128,131,130,124,67
 db 252,134,129,129,129,129,129,254,68
 db 126,193,129,129,129,129,130,252,68
 db 252,130,129,129,129,129,65,126,68
 db 254,128,128,252,134,128,128,255,69
 db 254,128,128,248,134,128,128,127,69
 db 254,128,128,240,134,128,128,255,69
 db 31,192,128,142,240,192,64,64,70
 db 15,240,128,142,240,192,64,64,70
 db 127,192,192,252,156,128,128,128,70
 db 124,134,131,128,143,193,99,31,71
 db 124,194,129,128,143,129,67,61,71
 db 124,130,129,128,143,129,65,63,71
 db 1,129,129,143,225,129,129,128,72
 db 192,129,129,241,135,129,129,2,72
 db 120,120,126,126,30,30,31,31,73
 db 15,14,28,28,56,112,112,224,73
 db 6,14,28,28,56,48,112,96,73
 db 1,1,1,1,1,129,131,126,74
 db 2,2,2,3,3,129,193,126,74
 db 3,3,3,1,1,129,129,126,74
 db 131,132,152,240,136,140,132,2,75
 db 135,140,144,176,216,140,132,3,75
 db 64,199,152,240,152,136,4,2,75
 db 64,64,192,128,128,128,128,255,76
 db 192,128,128,128,128,128,128,255,76
 db 128,128,128,128,128,192,192,255,76
 db 192,225,163,167,181,153,25,1,77
 db 3,133,197,165,165,157,152,128,77
 db 65,227,163,165,165,189,153,145,77
 db 65,225,177,145,137,133,135,128,78
 db 2,193,161,145,137,133,195,64,78
 db 124,194,129,129,129,129,65,62,79
 db 252,131,129,129,255,128,192,64,80
 db 254,129,129,193,254,64,64,64,80
 db 124,130,129,129,129,79,62,1,81
 db 124,194,129,129,129,69,62,1,81
 db 124,130,129,129,129,69,62,1,81
 db 254,131,130,254,246,130,130,131,82
 db 252,130,130,254,142,130,130,3,82
 db 254,130,130,158,246,130,130,131,82
 db 62,65,64,120,7,129,129,126,83
 db 124,130,193,48,14,129,65,63,83
 db 124,67,65,56,142,131,65,62,83
 db 129,129,129,129,129,129,130,124,85
 db 128,129,129,129,129,129,65,63,85
 db 129,66,66,100,36,36,24,24,86
 db 128,67,66,70,36,44,40,24,86
 db 131,66,66,102,36,52,20,24,86
 db 1,153,154,154,106,110,102,68,87
 db 129,153,89,89,86,118,38,34,87
 db 128,153,217,89,87,118,38,34,87
 db 6,196,104,24,24,36,35,64,88
 db 2,132,104,56,28,38,97,64,88
 db 194,100,44,24,24,36,66,195,88
 db 193,66,38,20,24,8,8,8,89
 db 3,194,102,52,24,8,8,8,89
 db 254,2,4,8,48,96,192,127,90
 db 254,2,4,8,16,32,64,255,90
 db 124,198,130,62,114,130,134,123,97
 db 124,196,132,62,98,194,71,121,97
 db 126,66,130,30,114,130,134,251,97
 db 128,128,188,194,129,129,193,254,98
 db 128,128,188,194,129,129,193,190,98
 db 64,64,94,99,65,193,195,190,98
 db 60,194,129,128,128,129,194,124,99
 db 124,194,131,128,128,128,195,62,99
 db 124,194,131,128,128,129,66,62,99
 db 3,1,61,195,129,129,131,125,100
 db 1,1,61,195,129,129,195,125,100
 db 1,49,205,131,129,129,97,63,100
 db 62,99,129,191,240,131,134,124,101
 db 62,67,129,255,128,129,194,124,101
 db 120,134,130,254,130,193,67,62,101
 db 30,24,127,12,12,6,6,6,102
 db 30,16,255,24,24,12,12,12,102
 db 30,48,252,48,48,48,32,32,102
 db 127,131,131,129,67,61,193,62,103
 db 126,130,130,131,67,61,65,63,103
 db 63,65,193,129,67,61,131,126,103
 db 128,128,190,195,129,129,129,129,104
 db 128,128,188,194,67,65,65,65,104
 db 224,0,112,56,56,60,30,30,105
 db 192,0,112,120,56,56,28,14,105
 db 240,0,56,28,28,14,14,7,105
 db 3,3,6,6,6,6,6,252,106
 db 1,1,3,3,6,6,6,124,106
 db 12,6,14,6,7,7,3,254,106
 db 128,134,136,144,240,200,196,195,107
 db 132,140,136,144,248,68,67,64,107
 db 64,64,71,220,248,136,132,3,107
 db 7,7,14,14,12,28,56,120,108
 db 126,30,30,31,31,31,31,31,108
 db 224,112,56,60,28,12,14,7,108
 db 246,217,145,153,137,137,137,137,109
 db 242,159,153,153,153,153,153,1,109
 db 247,217,137,137,137,137,137,129,109
 db 190,195,129,129,129,193,193,129,110
 db 190,227,193,193,193,193,193,65,110
 db 124,198,131,129,129,193,65,62,111
 db 62,97,193,129,129,131,134,124,111
 db 126,193,193,129,194,188,128,128,112
 db 62,193,129,129,198,248,192,192,112
 db 188,194,193,193,65,126,64,64,112
 db 125,131,129,129,99,29,1,1,113
 db 58,70,130,130,130,207,49,1,113
 db 207,248,192,192,192,192,192,192,114
 db 207,248,192,64,96,96,96,96,114
 db 99,127,96,96,64,64,192,192,114
 db 124,130,128,112,30,1,193,126,115
 db 252,134,195,112,14,131,65,63,115
 db 126,195,192,124,15,1,195,126,115
 db 32,52,252,48,16,24,24,15,116
 db 24,31,248,48,48,48,32,62,116
 db 24,255,254,48,48,48,32,62,116
 db 64,193,129,131,131,130,198,122,117
 db 129,131,129,129,193,193,195,63,117
 db 1,129,129,129,129,131,135,252,117
 db 129,194,66,68,36,36,56,24,118
 db 3,130,70,68,36,44,56,24,118
 db 129,194,66,68,76,40,56,48,118
 db 1,145,154,90,90,86,102,32,119
 db 128,145,153,90,106,102,38,4,119
 db 128,145,154,218,106,106,108,4,119
 db 192,35,52,24,24,108,196,3,120
 db 194,68,40,24,24,60,38,67,120
 db 195,38,36,24,24,36,100,195,120
 db 131,66,100,36,56,16,48,224,121
 db 96,33,17,27,10,4,4,56,121
 db 3,194,68,36,24,16,16,96,121
 db 254,132,12,8,16,32,99,254,122
 db 120,15,6,12,48,96,240,15,122
 db 126,2,6,8,16,32,64,255,122
 db 62,65,129,129,129,129,130,126,48
 db 124,195,129,129,129,129,195,62,48
 db 126,195,129,129,129,129,194,124,48
 db 3,126,198,6,6,6,6,6,49
 db 3,30,230,2,3,3,3,3,49
 db 62,65,1,3,28,96,64,255,50
 db 126,130,130,4,24,32,79,240,50
 db 126,193,129,6,28,32,64,255,50
 db 62,65,131,30,1,1,131,124,51
 db 124,194,3,30,2,129,193,62,51
 db 63,65,129,14,3,1,131,254,51
 db 4,28,52,68,132,255,4,4,52
 db 4,28,52,100,196,255,4,4,52
 db 2,14,54,68,132,127,4,4,52
 db 63,96,64,127,1,1,195,126,53
 db 126,64,72,126,1,1,193,126,53
 db 63,96,72,126,1,129,193,126,53
 db 126,195,128,254,131,131,194,124,54
 db 124,194,129,252,130,130,194,62,54
 db 62,195,128,190,193,129,195,126,54
 db 255,2,4,24,16,32,96,192,55
 db 255,2,4,8,16,48,32,96,55
 db 62,67,130,126,97,129,131,252,56
 db 124,130,130,252,67,129,131,126,56
 db 126,195,129,193,127,1,195,126,57
 db 126,131,129,193,127,1,195,126,57
 db 124,130,129,131,125,1,67,126,57
 db 30,30,30,126,30,126,12,30,33
 db 7,14,28,60,56,112,32,224,33
 db 30,30,28,124,56,120,16,112,33
 db 0,63,65,129,6,8,24,0,63
 db 0,124,131,1,3,12,24,0,63
 db 8,24,60,36,92,194,34,7,65
 db 16,16,40,44,124,66,71,224,65
 db 8,12,20,20,60,98,67,229,65
 db 254,34,34,63,33,33,34,124,66
 db 254,33,33,62,35,97,65,254,66
 db 254,33,35,62,99,97,65,254,66
 db 126,129,128,128,128,128,96,31,67
 db 63,65,128,128,128,128,65,62,67
 db 126,195,129,128,128,192,96,30,67
 db 126,193,65,65,65,66,76,112,68
 db 224,60,98,65,65,65,193,62,68
 db 254,67,65,65,97,33,34,124,68
 db 254,34,32,58,62,32,33,127,69
 db 112,47,33,50,46,34,224,30,69
 db 255,33,34,62,34,33,35,252,69
 db 127,33,32,46,58,32,32,248,70
 db 255,33,32,49,63,49,16,120,70
 db 127,33,32,62,34,32,32,240,70
 db 30,98,128,128,135,129,195,126,71
 db 126,129,129,128,128,135,98,62,71
 db 63,65,128,128,135,130,194,126,71
 db 224,71,66,122,70,66,226,7,72
 db 230,66,66,126,66,66,66,247,72
 db 127,8,24,24,24,24,24,255,73
 db 127,8,24,24,24,16,16,254,73
 db 31,4,4,12,12,8,8,112,74
 db 255,24,8,8,8,12,12,120,74
 db 115,36,40,48,48,72,68,227,75
 db 112,35,44,48,112,72,228,3,75
 db 6,228,72,80,112,108,35,240,75
 db 112,160,32,32,33,33,46,112,76
 db 120,32,32,32,32,96,65,254,76
 db 112,160,32,32,32,33,39,120,76
 db 195,98,102,102,106,90,90,215,77
 db 2,198,102,102,106,90,91,98,77
 db 3,194,102,102,106,90,87,192,77
 db 67,98,114,82,74,78,70,192,78
 db 64,99,82,82,74,74,198,6,78
 db 62,65,129,129,129,129,194,124,79
 db 252,35,33,33,46,32,32,248,80
 db 255,33,33,46,32,16,16,120,80
 db 255,33,33,46,32,32,32,120,80
 db 62,65,129,129,129,130,124,63,81
 db 126,195,129,129,129,98,60,15,81
 db 124,130,130,130,130,194,124,31,81
 db 248,68,68,124,72,76,228,19,82
 db 248,68,68,124,40,44,36,243,82
 db 126,34,34,60,40,36,38,243,82
 db 63,65,192,252,3,1,130,252,83
 db 63,65,64,124,7,1,130,252,83
 db 124,130,128,112,14,129,193,126,83
 db 252,147,17,16,16,16,16,60,84
 db 255,137,8,8,8,8,8,30,84
 db 231,66,66,66,66,66,34,62,85
 db 231,66,99,33,33,33,33,30,85
 db 7,226,66,36,36,20,24,8,86
 db 224,70,35,34,36,28,24,16,86
 db 230,67,34,34,20,20,12,8,86
 db 203,73,91,90,86,102,38,36,87
 db 203,75,90,90,106,108,76,68,87
 db 203,75,90,90,126,102,100,36,87
 db 67,34,20,24,24,36,102,195,88
 db 224,35,22,24,56,100,132,3,88
 db 193,38,20,24,24,36,198,3,88
 db 1,66,226,20,8,8,8,28,89
 db 193,34,36,20,8,8,8,60,89
 db 193,34,36,28,24,16,16,60,89
 db 127,66,4,8,16,32,67,254,90
 db 14,244,136,24,16,33,79,240,90
 db 127,67,4,8,16,32,193,255,90
 db 60,196,134,62,68,132,157,247,97
 db 120,132,6,254,132,196,124,7,97
 db 124,198,6,126,198,134,252,103,97
 db 224,32,36,59,33,33,34,124,98
 db 224,32,32,126,97,65,65,126,98
 db 224,32,32,62,33,33,33,126,98
 db 126,193,129,128,128,64,96,31,99
 db 31,97,192,128,128,128,67,62,99
 db 62,67,129,128,128,192,96,63,99
 db 28,4,4,124,132,132,134,123,100
 db 12,4,4,124,132,132,134,123,100
 db 60,66,131,254,224,128,193,62,101
 db 30,99,193,158,240,128,195,126,101
 db 60,198,130,254,128,128,193,62,101
 db 7,8,16,126,16,48,48,248,102
 db 15,24,16,126,16,16,48,248,102
 db 127,196,76,112,124,194,130,124,103
 db 127,132,196,120,124,194,131,126,103
 db 120,135,68,120,124,194,130,126,103
 db 192,64,64,124,66,66,226,19,104
 db 192,64,76,118,66,66,98,241,104
 db 224,96,72,124,66,66,66,243,104
 db 0,60,12,12,8,24,255,0,105
 db 4,0,124,8,8,24,24,255,105
 db 16,0,240,16,16,24,24,127,105
 db 2,63,6,6,4,4,12,248,106
 db 8,62,134,6,3,3,3,62,106
 db 62,12,8,8,24,16,224,0,106
 db 112,48,32,39,40,56,36,243,107
 db 192,64,64,78,112,112,200,230,107
 db 96,32,32,39,40,56,44,243,107
 db 124,8,8,8,24,24,24,255,108
 db 120,8,8,8,12,12,4,63,108
 db 31,6,4,4,12,8,8,255,108
 db 240,126,74,74,74,74,218,251,109
 db 126,250,90,90,74,74,91,248,109
 db 118,250,74,74,74,74,90,251,109
 db 60,244,98,66,66,66,66,243,110
 db 224,124,70,66,66,66,242,3,110
 db 232,124,66,66,66,66,242,3,110
 db 60,67,129,129,129,129,66,60,111
 db 60,99,129,129,129,129,194,60,111
 db 62,99,193,129,129,131,194,124,111
 db 126,49,33,35,60,32,32,240,112
 db 252,35,33,33,62,32,32,120,112
 db 127,225,33,35,60,32,32,112,112
 db 60,68,132,132,252,4,4,15,113
 db 127,194,130,134,124,4,4,30,113
 db 126,132,132,132,124,4,4,15,113
 db 247,57,48,48,16,16,16,126,114
 db 240,63,49,48,48,48,240,28,114
 db 112,31,49,48,48,48,240,28,114
 db 126,194,192,126,3,129,131,252,115
 db 63,97,64,124,7,129,131,252,115
 db 126,195,193,56,14,129,193,126,115
 db 16,16,127,208,16,16,16,31,116
 db 8,16,255,22,48,48,32,60,116
 db 24,16,255,16,48,48,48,30,116
 db 102,206,66,66,66,66,38,59,117
 db 2,206,66,66,66,66,102,59,117
 db 6,204,68,68,102,34,38,59,117
 db 55,226,100,36,36,40,24,16,118
 db 247,98,34,38,20,20,12,8,118
 db 3,6,226,102,36,20,28,8,118
 db 11,202,90,90,90,36,36,32,119
 db 232,75,90,90,106,108,108,4,119
 db 192,64,74,91,106,106,76,4,119
 db 2,228,40,24,24,36,99,192,120
 db 3,230,52,24,24,36,99,192,120
 db 192,38,60,24,24,44,198,3,120
 db 247,38,36,56,24,16,48,224,121
 db 247,34,36,28,24,16,32,224,121
 db 119,38,36,56,16,16,32,192,121
 db 127,67,4,8,16,32,225,191,122
 db 62,228,140,8,16,33,111,248,122
 db 127,66,4,8,24,48,33,255,122
 db 126,194,131,129,129,193,67,62,48
 db 126,195,129,129,129,131,130,124,48
 db 24,248,8,8,8,8,8,63,49
 db 56,216,24,8,8,8,8,63,49
 db 120,144,24,8,8,8,8,63,49
 db 252,134,2,6,12,16,96,255,50
 db 124,134,134,4,8,16,39,112,50
 db 62,66,2,30,1,1,130,252,51
 db 124,194,2,28,3,129,131,126,51
 db 62,65,3,30,1,1,130,124,51
 db 12,24,44,108,196,254,4,63,52
 db 8,24,40,108,76,254,4,31,52
 db 2,14,20,36,68,254,4,63,52
 db 254,192,192,126,1,1,131,126,53
 db 126,64,64,126,1,1,131,126,53
 db 126,192,192,127,1,1,131,252,53
 db 15,48,64,254,193,129,195,126,54
 db 30,96,192,254,131,129,67,62,54
 db 14,48,64,254,227,129,193,126,54
 db 127,130,132,8,16,48,96,192,55
 db 255,130,4,8,16,32,64,192,55
 db 15,242,132,12,24,16,32,64,55
 db 126,194,134,124,99,129,131,252,56
 db 62,65,99,62,198,131,130,124,56
 db 126,130,198,124,70,129,131,126,56
 db 126,195,129,135,127,2,12,112,57
 db 124,130,129,195,61,3,6,120,57
 db 126,193,129,135,122,6,24,224,57
 db 63,24,56,48,48,112,0,192,33
 db 124,56,24,28,28,12,0,2,33
 db 254,112,112,224,224,192,0,192,33
 db 126,193,3,6,24,16,0,16,63
 db 254,131,1,6,24,48,0,16,63
 db 126,131,1,6,56,48,0,32,63
 db 14,10,18,50,62,66,66,129,65
 db 6,14,10,19,63,99,65,129,65
 db 6,14,10,18,62,35,65,129,65
 db 31,33,33,62,66,66,70,248,66
 db 63,97,65,127,67,65,193,254,66
 db 31,33,35,62,66,66,76,240,66
 db 30,97,64,128,128,130,132,120,67
 db 30,97,64,128,128,131,134,124,67
 db 60,67,129,128,128,128,194,124,67
 db 60,34,33,65,65,65,195,126,68
 db 62,33,33,97,65,67,66,252,68
 db 63,33,33,65,67,66,220,240,68
 db 63,32,96,126,64,64,64,254,69
 db 63,64,64,126,96,64,130,252,69
 db 62,35,96,112,78,64,192,60,69
 db 61,35,32,96,92,64,192,128,70
 db 7,120,64,78,112,64,192,128,70
 db 15,56,96,78,112,64,192,128,70
 db 62,97,192,135,137,131,134,120,71
 db 62,97,64,135,137,131,134,120,71
 db 30,65,64,128,142,130,134,126,71
 db 1,97,67,78,114,66,194,128,72
 db 96,65,65,123,78,194,130,130,72
 db 1,65,67,78,114,66,130,128,72
 db 7,12,12,24,16,48,32,224,73
 db 3,6,12,24,16,48,96,192,73
 db 3,4,12,24,16,48,96,192,73
 db 1,2,2,2,4,196,140,248,74
 db 3,2,2,6,4,132,132,248,74
 db 1,2,2,4,4,4,136,240,74
 db 3,70,72,80,120,200,132,130,75
 db 35,38,104,80,120,72,136,132,75
 db 35,68,72,112,120,72,196,132,75
 db 32,96,64,64,64,65,94,224,76
 db 16,16,32,32,96,64,64,255,76
 db 8,24,16,48,32,96,64,255,76
 db 1,3,103,103,106,154,144,128,77
 db 1,99,103,102,106,250,146,128,77
 db 97,99,99,102,238,170,154,2,77
 db 1,33,50,82,74,78,132,128,78
 db 32,49,83,82,74,202,140,4,78
 db 1,97,83,82,74,74,134,128,78
 db 31,33,65,129,129,130,132,248,79
 db 60,35,33,97,127,64,64,128,80
 db 63,33,97,126,120,64,64,128,80
 db 62,33,97,65,126,64,64,128,80
 db 62,65,129,129,129,129,198,122,81
 db 31,33,65,129,129,130,140,248,81
 db 30,97,65,129,129,130,140,124,81
 db 62,33,97,123,70,66,130,2,82
 db 63,33,97,127,70,66,194,130,82
 db 63,33,65,94,98,66,195,128,82
 db 63,97,64,56,6,130,130,252,83
 db 62,65,65,56,14,130,130,126,83
 db 31,97,64,120,6,2,130,252,83
 db 248,23,16,16,32,32,32,64,84
 db 255,16,16,16,16,48,32,32,84
 db 127,216,16,16,16,16,16,48,84
 db 65,67,194,130,130,130,132,248,85
 db 1,67,66,130,130,134,132,248,85
 db 1,66,66,66,132,132,140,248,85
 db 3,130,132,140,200,80,112,96,86
 db 131,130,132,136,144,144,160,192,86
 db 3,130,132,196,72,88,80,96,86
 db 128,145,185,186,202,204,140,8,87
 db 145,147,186,170,172,204,204,136,87
 db 1,147,154,170,174,236,204,192,87
 db 67,102,36,24,24,44,68,130,88
 db 32,35,20,24,56,104,196,4,88
 db 99,34,52,24,24,40,68,130,88
 db 131,70,76,104,48,32,32,32,89
 db 131,198,76,88,48,32,32,64,89
 db 131,70,68,40,48,16,32,32,89
 db 7,58,4,8,16,32,94,224,90
 db 63,2,4,8,16,32,64,252,90
 db 31,50,4,8,16,32,76,248,90
 db 31,49,97,31,98,130,143,242,97
 db 62,67,3,126,130,130,206,115,97
 db 62,99,2,62,98,130,134,251,97
 db 32,100,123,97,65,67,238,144,98
 db 96,64,94,97,65,65,194,188,98
 db 96,64,94,97,65,65,195,188,98
 db 30,97,64,128,129,130,134,120,99
 db 62,97,192,128,128,131,134,124,99
 db 62,99,192,128,128,131,198,124,99
 db 1,3,58,70,130,130,132,124,100
 db 1,2,26,102,198,132,132,252,100
 db 1,3,122,134,130,134,132,124,100
 db 62,97,65,253,135,128,130,124,101
 db 60,66,193,185,135,128,66,60,101
 db 30,97,65,190,225,130,134,120,101
 db 7,8,62,16,48,32,64,192,102
 db 7,8,126,16,48,32,96,192,102
 db 29,98,66,66,68,124,12,248,103
 db 61,66,130,130,134,126,4,252,103
 db 29,98,66,194,198,124,4,248,103
 db 16,16,63,49,97,66,66,132,104
 db 48,32,63,33,65,67,66,128,104
 db 24,16,63,49,97,67,66,134,104
 db 3,4,14,24,16,48,96,192,105
 db 7,0,14,24,16,48,96,192,105
 db 7,4,12,24,16,48,32,192,105
 db 3,0,4,12,8,16,48,224,106
 db 6,0,8,24,16,48,32,192,106
 db 32,96,67,76,120,200,132,134,107
 db 32,32,99,76,120,72,196,130,107
 db 16,16,35,44,120,72,72,132,107
 db 7,12,8,24,48,96,64,192,108
 db 15,28,24,24,48,112,96,192,108
 db 7,12,24,16,48,96,64,192,108
 db 7,125,73,201,137,137,144,128,109
 db 7,125,73,137,137,153,144,128,109
 db 3,125,73,73,201,153,146,128,109
 db 46,59,97,65,65,67,130,2,110
 db 48,63,33,65,65,194,130,6,110
 db 60,63,33,65,65,66,130,6,110
 db 30,33,65,193,130,130,132,120,111
 db 30,97,65,193,131,130,132,120,111
 db 28,30,33,33,97,98,94,128,112
 db 63,97,65,67,110,208,128,128,112
 db 62,49,33,33,97,126,192,128,112
 db 63,66,134,132,140,120,8,24,113
 db 127,194,130,130,140,116,4,12,113
 db 61,66,130,132,140,120,8,24,113
 db 3,60,48,32,96,64,64,192,114
 db 25,30,48,32,32,64,64,192,114
 db 39,124,96,64,64,64,192,192,114
 db 63,97,64,120,6,3,130,252,115
 db 31,33,64,124,6,3,134,252,115
 db 63,97,64,124,7,1,131,252,115
 db 3,4,63,24,48,32,96,120,116
 db 28,25,254,48,48,32,32,60,116
 db 12,24,255,48,32,96,64,120,116
 db 33,66,66,194,132,132,140,248,117
 db 65,66,194,194,130,134,132,124,117
 db 1,66,66,194,132,132,140,240,117
 db 3,194,68,76,72,80,96,96,118
 db 131,66,68,76,72,80,112,96,118
 db 3,194,70,68,108,40,56,48,118
 db 128,145,154,178,180,212,216,24,119
 db 1,130,154,186,172,108,108,64,119
 db 128,128,153,170,170,236,76,8,119
 db 3,102,52,24,24,44,70,192,120
 db 32,19,22,24,56,104,136,4,120
 db 65,34,20,24,24,44,196,2,120
 db 35,34,36,40,48,32,32,192,121
 db 32,35,38,36,40,48,32,192,121
 db 65,66,36,44,56,48,32,192,121
 db 60,3,6,12,48,64,192,60,122
 db 31,50,4,8,16,32,66,252,122
 db 31,50,4,8,16,32,68,252,122
 db 62,97,65,129,129,130,134,124,48
 db 31,49,65,65,130,130,132,248,48
 db 63,97,193,129,129,131,134,248,48
 db 3,6,252,8,24,16,48,32,49
 db 3,14,252,8,24,16,48,32,49
 db 3,254,132,12,12,8,24,24,49
 db 31,33,1,3,28,96,64,254,50
 db 31,49,33,6,28,48,78,248,50
 db 62,33,65,1,14,48,64,255,50
 db 62,65,1,30,3,129,129,126,51
 db 31,33,67,14,2,2,132,248,51
 db 62,97,1,31,2,130,130,124,51
 db 3,6,10,54,68,255,4,12,52
 db 1,6,10,20,100,127,136,8,52
 db 1,6,26,34,68,255,4,8,52
 db 63,32,112,124,6,2,132,124,53
 db 31,32,32,124,6,4,132,248,53
 db 31,48,32,124,70,4,12,248,53
 db 62,65,192,254,131,129,195,126,54
 db 31,33,64,124,194,130,132,120,54
 db 31,97,64,254,195,131,130,124,54
 db 14,252,8,16,32,64,128,128,55
 db 127,6,12,24,16,32,64,128,55
 db 31,98,12,24,16,32,64,128,55
 db 63,65,67,62,67,129,131,126,56
 db 31,33,97,62,194,130,134,124,56
 db 31,33,67,126,99,195,134,252,56
 db 62,97,65,65,63,130,134,124,57
 db 31,33,65,67,127,2,132,248,57
 db 62,97,65,65,127,2,134,120,57
 db 15,12,28,24,56,48,0,240,33
 db 7,4,12,24,16,48,0,224,33
 db 7,4,12,24,16,32,32,192,33
 db 63,65,131,14,24,48,0,32,63
 db 63,65,195,12,24,48,0,32,63
 db 63,65,130,12,48,96,0,192,63
 db 24,40,36,36,122,67,129,128,65
 db 48,40,104,68,126,66,129,128,65
 db 24,20,52,36,126,66,193,128,65
 db 252,130,130,254,193,193,67,124,66
 db 252,195,193,243,142,129,129,255,66
 db 62,97,192,128,128,129,130,124,67
 db 124,130,129,128,128,192,97,62,67
 db 124,195,128,128,128,128,67,62,67
 db 252,131,129,129,129,129,198,120,68
 db 252,130,129,129,129,129,134,252,68
 db 127,64,192,240,142,128,128,254,69
 db 127,64,64,240,252,128,128,254,69
 db 255,128,128,254,240,128,128,254,69
 db 255,128,128,130,254,128,128,128,70
 db 127,128,192,199,240,64,64,64,70
 db 255,128,128,240,190,128,192,128,70
 db 62,96,192,131,157,131,134,124,71
 db 62,97,192,129,159,131,134,124,71
 db 124,134,129,128,159,195,65,62,71
 db 130,131,129,255,129,129,65,65,72
 db 64,65,65,249,135,130,130,2,72
 db 120,120,60,60,30,30,15,15,73
 db 14,28,60,56,112,96,224,192,73
 db 14,28,28,28,56,112,112,112,73
 db 1,1,1,1,1,1,195,126,74
 db 1,1,3,3,2,130,194,60,74
 db 1,1,1,1,1,129,67,62,74
 db 65,198,136,176,208,136,132,2,75
 db 67,70,216,176,208,136,140,6,75
 db 3,132,136,144,240,216,132,131,75
 db 64,64,64,64,192,128,128,255,76
 db 128,128,128,192,192,192,64,127,76
 db 131,195,199,165,165,153,153,136,77
 db 192,195,227,165,165,153,153,1,77
 db 192,195,227,165,165,157,153,1,77
 db 1,225,177,153,141,133,131,128,78
 db 192,161,145,145,137,133,135,2,78
 db 1,193,161,145,141,135,129,128,78
 db 124,194,129,129,129,129,67,60,79
 db 62,97,65,129,129,129,134,124,79
 db 254,129,129,129,254,64,64,64,80
 db 254,193,129,131,252,128,128,128,80
 db 60,66,129,129,129,255,199,125,81
 db 62,97,193,129,129,255,135,124,81
 db 62,65,129,129,129,249,198,127,81
 db 252,130,130,130,156,136,196,3,82
 db 124,67,65,193,158,136,132,2,82
 db 252,130,130,130,158,136,132,3,82
 db 62,65,64,60,3,1,193,126,83
 db 62,65,64,60,3,1,195,126,83
 db 124,134,128,120,6,1,193,62,83
 db 127,8,8,8,8,8,12,8,84
 db 255,24,24,8,8,8,8,8,84
 db 1,129,129,129,129,129,130,124,85
 db 131,131,129,129,193,65,65,62,85
 db 128,65,66,66,36,36,24,24,86
 db 1,130,66,68,36,44,24,24,86
 db 1,130,130,68,100,44,56,24,86
 db 128,144,153,155,234,106,108,12,87
 db 1,153,153,154,90,118,102,100,87
 db 128,145,153,217,122,106,102,4,87
 db 130,70,44,24,24,36,70,131,88
 db 2,132,104,56,24,38,97,64,88
 db 198,68,40,24,24,36,102,67,88
 db 128,65,98,36,56,16,16,16,89
 db 1,194,68,44,56,16,16,16,89
 db 1,130,70,36,28,8,8,8,89
 db 255,2,4,8,16,96,192,255,90
 db 255,2,4,8,16,32,64,255,90
 db 60,67,129,129,129,129,67,61,97
 db 61,67,129,129,129,129,195,61,97
 db 124,195,129,129,129,129,99,61,97
 db 128,140,178,193,129,129,194,188,98
 db 128,190,225,129,129,131,198,184,98
 db 64,76,115,193,129,129,194,188,98
 db 62,99,192,128,128,129,198,124,99
 db 60,67,129,128,128,129,66,60,99
 db 60,66,129,128,128,128,67,60,99
 db 1,121,135,131,129,131,102,26,100
 db 3,3,63,65,129,129,131,124,100
 db 1,1,125,131,129,129,193,63,100
 db 124,194,131,253,143,129,67,60,101
 db 62,97,65,191,225,131,198,124,101
 db 124,198,130,255,130,193,98,62,101
 db 31,48,255,48,48,16,16,16,102
 db 15,16,255,16,16,16,16,24,102
 db 15,16,254,32,96,96,64,64,102
 db 124,131,129,129,65,191,66,62,103
 db 124,131,129,129,65,191,65,62,103
 db 64,64,255,193,129,129,129,129,104
 db 128,190,225,129,129,193,65,64,104
 db 128,140,243,129,129,129,129,128,104
 db 6,4,28,28,56,48,112,112,105
 db 224,0,112,112,56,60,60,30,105
 db 224,0,56,56,60,28,14,7,105
 db 6,0,6,6,6,6,14,248,106
 db 12,6,6,6,7,3,3,254,106
 db 128,128,132,136,208,120,68,67,107
 db 192,192,131,140,176,216,132,3,107
 db 130,132,136,144,144,236,67,64,107
 db 120,60,60,60,30,30,14,15,108
 db 31,30,30,30,28,60,60,124,108
 db 246,155,137,137,137,137,137,1,109
 db 110,217,145,145,153,137,137,128,109
 db 224,158,153,137,137,137,9,1,109
 db 252,198,130,131,129,193,193,1,110
 db 124,66,193,193,129,129,129,1,110
 db 252,130,130,129,129,129,193,1,110
 db 124,130,129,129,129,193,97,62,111
 db 62,99,193,129,129,129,194,124,111
 db 124,194,129,129,129,193,99,62,111
 db 62,193,129,129,194,188,128,128,112
 db 62,193,129,129,134,248,128,128,112
 db 124,131,129,129,67,63,1,3,113
 db 61,67,129,129,129,103,25,1,113
 db 7,124,96,64,192,192,192,192,114
 db 103,124,96,64,64,192,192,192,114
 db 126,131,192,120,7,129,195,126,115
 db 124,194,128,252,7,3,131,126,115
 db 62,97,64,124,6,2,134,252,115
 db 24,24,255,16,48,48,32,96,116
 db 24,24,255,24,16,16,16,16,116
 db 24,24,255,24,24,24,24,16,116
 db 128,131,129,129,129,65,67,63,117
 db 129,129,129,129,129,129,67,61,117
 db 128,65,66,70,36,36,56,24,118
 db 128,192,67,70,68,40,40,48,118
 db 128,195,66,70,100,40,40,16,118
 db 128,128,89,89,90,90,38,4,119
 db 128,128,209,89,90,122,46,4,119
 db 128,128,145,154,106,106,108,12,119
 db 192,98,52,24,24,36,66,3,120
 db 67,38,52,24,24,40,68,198,120
 db 65,34,52,24,24,40,68,130,120
 db 129,66,68,44,40,48,32,96,121
 db 129,66,68,104,56,48,32,64,121
 db 131,66,68,40,40,16,32,32,121
 db 254,4,12,24,16,32,64,127,122
 db 124,3,6,8,48,96,224,63,122
 db 126,196,12,24,16,32,103,124,122
 db 126,129,129,129,129,129,193,126,48
 db 126,131,129,129,129,129,193,126,48
 db 255,3,7,7,6,6,6,6,49
 db 255,3,3,3,3,3,3,3,49
 db 254,6,6,2,3,3,3,3,49
 db 124,130,130,2,4,24,32,127,50
 db 62,67,131,2,12,16,33,126,50
 db 124,66,130,2,4,24,96,127,50
 db 62,66,2,30,1,1,131,252,51
 db 62,65,3,14,3,129,129,126,51
 db 124,130,2,28,3,129,129,126,51
 db 2,6,10,27,17,33,127,97,52
 db 4,12,22,54,98,66,255,2,52
 db 4,14,30,18,34,67,94,226,52
 db 63,32,112,70,1,129,193,62,53
 db 63,32,120,102,1,129,193,62,53
 db 124,64,112,206,3,129,65,62,53
 db 24,48,56,86,129,129,193,62,54
 db 6,24,48,127,129,129,131,124,54
 db 4,24,48,63,65,129,131,124,54
 db 255,3,6,4,8,16,32,96,55
 db 255,3,6,12,24,48,96,192,55
 db 254,3,2,4,8,16,32,64,55
 db 62,65,67,62,195,129,131,124,56
 db 126,66,67,126,131,129,193,62,56
 db 124,66,66,126,195,129,193,126,56
 db 126,129,129,129,126,4,8,48,57
 db 124,131,129,129,99,30,12,16,57
 db 62,193,129,129,126,4,24,48,57
 db 14,14,30,28,24,56,16,112,33
 db 30,28,28,24,56,112,16,112,33
 db 30,60,60,56,120,112,0,240,33
 db 126,131,1,3,12,16,0,16,63
 db 124,131,1,3,4,8,0,8,63
 db 62,193,129,6,8,16,0,16,63
 db 16,48,56,40,124,116,71,196,65
 db 8,24,24,44,36,124,66,199,65
 db 8,24,24,36,60,68,194,7,65
 db 254,33,35,62,35,33,33,254,66
 db 240,46,33,49,46,33,161,127,66
 db 248,38,35,59,46,33,33,255,66
 db 124,130,129,128,128,192,96,31,67
 db 15,49,65,128,128,128,131,124,67
 db 124,131,129,129,128,128,96,62,67
 db 240,76,66,97,33,33,33,126,68
 db 254,65,65,65,65,67,108,240,68
 db 240,76,66,65,65,65,65,254,68
 db 254,66,96,62,38,32,33,255,69
 db 254,33,34,62,34,32,33,255,69
 db 240,110,98,50,46,34,225,31,69
 db 255,33,34,62,32,32,32,120,70
 db 254,33,32,58,46,32,32,248,70
 db 112,39,33,34,62,34,32,240,70
 db 126,130,130,128,135,130,66,62,71
 db 124,198,130,128,135,130,66,60,71
 db 30,98,128,135,130,130,130,124,71
 db 239,66,66,126,70,66,66,231,72
 db 247,34,34,126,70,68,68,238,72
 db 15,230,70,78,114,98,103,240,72
 db 118,9,24,24,16,16,144,126,73
 db 63,8,8,8,24,24,16,240,74
 db 255,24,24,8,8,12,8,248,74
 db 14,232,72,80,112,76,39,112,75
 db 46,232,88,80,120,44,39,112,75
 db 255,36,104,112,112,72,68,255,75
 db 240,32,32,32,32,32,33,254,76
 db 240,32,32,32,32,97,99,252,76
 db 240,96,32,32,32,32,33,127,76
 db 192,67,102,102,122,90,210,7,77
 db 3,134,70,106,106,90,87,224,77
 db 192,71,102,102,122,90,210,7,77
 db 199,98,82,82,74,70,66,226,78
 db 71,98,82,82,74,70,68,228,78
 db 192,103,114,82,74,70,198,34,78
 db 255,33,33,46,48,32,32,120,80
 db 254,33,33,34,60,32,32,248,80
 db 254,35,33,33,62,32,32,120,80
 db 124,130,129,129,131,110,24,7,81
 db 124,194,130,130,130,196,120,15,81
 db 124,134,130,130,130,108,24,15,81
 db 240,76,68,108,88,72,228,19,82
 db 248,68,68,120,104,36,39,112,82
 db 248,68,68,124,88,72,68,51,82
 db 126,195,65,48,14,129,193,127,83
 db 62,195,128,120,6,1,131,126,83
 db 127,65,97,24,6,131,193,62,83
 db 63,209,152,8,8,8,8,30,84
 db 252,155,25,24,8,8,8,60,84
 db 254,153,9,8,8,8,8,60,84
 db 39,194,66,98,35,33,34,30,85
 db 7,226,66,66,66,34,34,60,85
 db 167,66,66,66,66,66,98,60,85
 db 231,66,36,36,36,24,24,16,86
 db 231,66,102,36,44,24,16,16,86
 db 228,67,34,36,36,24,24,16,86
 db 251,82,74,90,58,52,36,36,87
 db 11,250,74,74,54,54,20,16,87
 db 224,90,83,90,122,44,44,12,87
 db 112,54,23,24,56,200,108,14,88
 db 119,36,28,24,24,44,100,238,88
 db 246,36,56,24,24,36,38,231,88
 db 7,226,36,60,24,24,24,60,89
 db 7,226,36,20,8,8,12,30,89
 db 7,226,36,20,8,8,8,28,89
 db 63,98,68,8,16,33,66,252,90
 db 254,132,8,24,16,32,65,255,90
 db 112,136,12,60,196,132,220,119,97
 db 120,204,12,124,204,140,252,39,97
 db 120,204,140,60,76,140,159,240,97
 db 224,96,96,126,97,65,65,126,98
 db 224,32,96,62,33,97,33,62,98
 db 224,96,96,126,97,97,97,62,98
 db 60,98,64,128,128,131,198,124,99
 db 124,198,128,128,128,193,99,62,99
 db 62,98,192,128,128,129,67,62,99
 db 28,12,36,252,132,132,134,127,100
 db 28,12,4,124,132,132,135,126,100
 db 14,6,6,126,198,134,135,124,100
 db 124,198,254,224,128,129,70,60,101
 db 124,70,254,144,128,193,67,62,101
 db 124,198,254,140,128,129,67,62,101
 db 31,48,254,16,16,16,16,126,102
 db 31,16,124,48,48,48,48,252,102
 db 60,71,102,60,64,254,131,126,103
 db 60,71,102,124,96,220,130,126,103
 db 126,196,196,124,64,127,129,254,103
 db 224,64,88,116,68,70,102,127,104
 db 112,32,40,54,34,98,242,15,104
 db 224,64,64,124,70,66,226,63,104
 db 4,0,126,8,8,24,24,255,105
 db 8,0,124,8,24,24,24,255,105
 db 32,0,240,32,48,48,48,254,105
 db 2,31,6,6,6,6,4,252,106
 db 2,31,6,6,6,6,6,252,106
 db 7,38,6,6,2,6,254,0,106
 db 96,192,78,72,112,120,103,240,107
 db 96,32,39,44,48,56,100,247,107
 db 112,32,39,36,56,56,104,255,107
 db 124,8,8,24,24,24,24,255,108
 db 126,12,12,12,8,8,24,255,108
 db 14,250,82,82,74,75,94,224,109
 db 22,234,74,74,74,74,91,252,109
 db 22,250,74,74,90,90,95,240,109
 db 60,228,68,102,98,98,47,240,110
 db 124,62,34,34,34,98,246,15,110
 db 236,118,66,66,66,66,66,255,110
 db 60,66,129,129,129,131,194,124,111
 db 124,194,131,129,129,193,98,62,111
 db 60,66,129,129,129,195,66,60,111
 db 254,97,33,33,62,32,48,124,112
 db 126,49,33,33,54,60,96,240,112
 db 126,49,33,33,51,62,32,240,112
 db 63,194,130,130,222,34,6,31,113
 db 126,194,130,130,222,6,6,31,113
 db 31,252,48,48,48,48,48,254,114
 db 120,31,16,48,48,48,240,124,114
 db 27,255,48,48,48,16,16,254,114
 db 63,99,65,56,14,131,194,252,115
 db 126,198,194,112,14,131,195,126,115
 db 126,198,194,56,14,131,195,254,115
 db 12,126,254,48,48,48,32,63,116
 db 16,52,252,48,48,48,17,30,116
 db 24,48,254,48,48,48,48,31,116
 db 204,70,66,66,66,70,110,31,117
 db 192,110,66,66,70,70,126,23,117
 db 12,196,68,100,102,38,47,60,117
 db 244,99,38,36,52,24,24,16,118
 db 7,242,34,38,20,28,8,8,118
 db 55,226,34,54,20,12,8,8,118
 db 208,75,73,74,54,54,36,4,119
 db 219,73,73,74,54,54,36,4,119
 db 15,249,74,90,90,124,36,32,119
 db 112,55,28,24,56,108,228,15,120
 db 30,228,56,16,24,36,71,224,120
 db 30,232,56,16,24,36,47,96,120
 db 247,34,50,20,12,8,8,56,121
 db 247,34,36,20,24,24,16,96,121
 db 247,98,36,60,24,16,48,224,121
 db 255,134,12,24,16,33,65,255,122
 db 127,198,140,24,16,33,99,254,122
 db 127,70,68,8,16,33,67,254,122
 db 124,130,131,129,129,193,67,62,48
 db 62,67,129,129,129,129,66,60,48
 db 62,4,12,12,8,24,24,255,49
 db 62,12,12,12,8,8,24,255,49
 db 60,72,8,8,24,24,24,255,49
 db 124,134,132,4,8,17,39,248,50
 db 124,194,2,4,8,16,97,254,50
 db 60,66,2,6,12,16,97,254,50
 db 126,194,6,62,3,1,3,252,51
 db 63,65,2,30,1,1,2,252,51
 db 126,194,6,62,1,1,3,252,51
 db 4,12,20,36,68,255,132,4,52
 db 3,14,26,50,98,127,3,2,52
 db 2,14,30,52,68,255,132,4,52
 db 63,96,112,12,4,6,132,248,53
 db 127,192,240,12,3,1,3,254,53
 db 63,64,120,12,2,2,134,124,53
 db 7,24,96,252,130,130,134,248,54
 db 30,32,192,254,131,193,65,62,54
 db 31,32,192,254,131,129,194,62,54
 db 31,114,130,6,4,4,8,8,55
 db 255,3,2,6,4,8,24,16,55
 db 127,130,6,4,12,8,16,16,55
 db 126,65,99,60,108,131,195,126,56
 db 252,130,194,60,108,131,193,126,56
 db 126,194,134,124,110,193,131,124,56
 db 124,130,131,193,127,3,6,120,57
 db 124,130,129,129,127,3,12,120,57
 db 60,67,65,65,63,31,6,248,57
 db 31,30,30,62,60,124,0,32,33
 db 30,60,60,56,112,224,0,128,33
 db 62,60,56,120,112,240,0,128,33
 db 254,131,1,7,12,16,0,16,63
 db 127,193,131,2,4,8,0,8,63
 db 254,131,3,6,12,16,0,32,63
 db 8,24,56,36,124,68,226,7,65
 db 24,24,56,36,60,66,71,224,65
 db 16,48,56,40,124,100,67,228,65
 db 127,225,34,63,33,33,46,240,66
 db 126,33,33,51,38,33,33,255,66
 db 127,33,33,62,33,33,33,254,66
 db 63,65,193,128,128,129,194,124,67
 db 63,65,129,128,128,129,65,62,67
 db 60,67,129,129,128,129,67,62,67
 db 254,33,97,97,65,65,66,254,68
 db 254,97,97,65,65,65,66,252,68
 db 126,35,33,33,97,65,67,254,68
 db 254,67,104,56,37,33,35,124,69
 db 254,99,105,56,36,37,33,127,69
 db 254,98,33,60,44,37,33,127,69
 db 63,225,36,60,36,32,32,120,70
 db 127,33,33,52,44,36,32,240,70
 db 255,97,37,60,36,36,32,248,70
 db 62,66,130,128,143,130,134,122,71
 db 120,198,130,130,143,130,70,58,71
 db 30,102,194,129,142,130,134,120,71
 db 119,98,98,126,102,68,70,238,72
 db 247,66,66,126,66,66,66,231,72
 db 254,16,16,24,24,24,24,255,73
 db 127,8,24,24,16,16,16,254,73
 db 31,4,4,4,4,4,200,248,74
 db 31,4,4,4,4,196,132,120,74
 db 15,4,4,4,4,200,136,120,74
 db 247,68,72,88,104,68,68,239,75
 db 232,78,72,80,104,68,244,7,75
 db 239,68,72,88,104,68,68,247,75
 db 240,32,32,32,33,33,39,120,76
 db 240,64,32,32,32,33,33,126,76
 db 120,32,32,32,32,33,97,254,76
 db 96,103,102,126,90,90,214,14,77
 db 192,103,102,110,90,90,242,23,77
 db 3,230,102,106,90,90,87,244,77
 db 71,98,82,82,74,70,70,226,78
 db 7,194,114,82,74,70,66,224,78
 db 255,33,33,46,48,32,32,248,80
 db 127,33,33,39,56,32,32,240,80
 db 124,35,33,33,63,32,32,240,80
 db 124,194,130,130,186,166,125,7,81
 db 62,65,129,129,187,238,125,7,81
 db 124,134,130,130,186,238,60,7,81
 db 252,98,66,124,76,68,69,243,82
 db 252,68,68,124,108,36,39,114,82
 db 124,196,68,120,36,37,35,112,82
 db 122,134,130,112,6,129,193,191,83
 db 63,65,65,56,6,131,194,254,83
 db 63,67,129,124,3,129,131,252,83
 db 254,145,153,8,8,8,8,30,84
 db 63,241,153,136,8,8,8,28,84
 db 63,241,145,152,8,8,10,30,84
 db 39,194,66,66,70,68,68,120,85
 db 228,67,66,66,66,98,34,62,85
 db 231,66,68,36,40,40,24,16,86
 db 7,226,70,36,36,24,24,16,86
 db 11,251,74,90,118,54,52,48,87
 db 248,75,74,90,62,54,38,36,87
 db 251,75,90,90,54,54,54,52,87
 db 238,100,40,24,24,44,36,119,88
 db 119,100,52,24,24,36,100,239,88
 db 23,228,60,24,24,36,103,236,88
 db 247,102,36,28,24,16,16,60,89
 db 247,98,36,20,24,8,8,60,89
 db 244,99,36,20,24,16,16,60,89
 db 254,132,140,24,16,33,65,255,90
 db 254,132,136,24,16,33,65,255,90
 db 254,132,140,24,16,33,97,127,90
 db 120,136,140,60,100,132,143,240,97
 db 120,140,132,60,100,132,140,251,97
 db 60,68,68,60,100,132,143,240,97
 db 224,96,62,49,33,33,50,76,98
 db 224,96,78,115,65,65,98,156,98
 db 224,64,76,118,65,65,65,254,98
 db 62,99,192,192,128,193,195,62,99
 db 62,98,192,192,128,129,194,124,99
 db 62,66,192,128,128,193,99,62,99
 db 14,2,2,110,130,130,134,127,100
 db 14,4,4,124,132,132,132,123,100
 db 14,2,114,142,134,132,76,55,100
 db 60,70,130,190,224,129,198,124,101
 db 60,198,130,255,240,129,195,60,101
 db 120,196,134,254,140,192,65,62,101
 db 31,49,240,60,48,16,16,126,102
 db 15,16,48,124,32,32,32,248,102
 db 15,17,48,124,32,32,32,248,102
 db 127,132,132,248,128,126,131,254,103
 db 127,196,70,252,192,254,131,126,103
 db 63,196,132,252,192,255,193,254,103
 db 96,32,32,62,34,98,66,247,104
 db 192,64,64,60,38,34,34,119,104
 db 96,32,44,50,34,98,66,231,104
 db 8,0,120,8,8,24,24,255,105
 db 0,120,12,12,12,4,63,0,105
 db 4,126,6,3,3,3,3,254,106
 db 1,30,1,1,1,1,3,126,106
 db 8,252,4,6,6,3,3,254,106
 db 192,66,78,72,120,100,111,240,107
 db 96,32,32,47,104,120,68,239,107
 db 192,64,72,78,88,120,68,255,107
 db 240,24,24,24,24,24,24,127,108
 db 240,16,16,24,24,24,8,127,108
 db 248,24,24,24,24,24,24,255,108
 db 22,250,74,74,74,91,92,224,109
 db 240,94,90,82,82,210,250,3,109
 db 6,58,210,82,90,75,88,224,109
 db 28,228,98,66,66,99,52,192,110
 db 220,100,68,70,66,66,98,255,110
 db 124,54,98,98,66,66,226,15,110
 db 62,67,193,129,129,131,66,60,111
 db 60,66,195,129,129,195,66,60,111
 db 222,35,33,33,51,46,32,120,112
 db 110,49,33,33,50,44,96,240,112
 db 111,49,33,33,50,44,96,240,112
 db 124,135,130,130,110,22,4,31,113
 db 124,135,130,130,126,6,4,31,113
 db 122,134,132,132,204,116,4,15,113
 db 231,60,56,48,32,32,32,252,114
 db 96,63,56,48,32,32,224,120,114
 db 7,232,56,32,32,32,56,224,114
 db 120,135,195,112,142,131,225,31,115
 db 124,67,97,56,142,195,225,30,115
 db 254,134,130,120,142,129,225,190,115
 db 24,16,254,32,32,32,35,62,116
 db 16,48,254,32,32,33,33,62,116
 db 16,16,254,32,32,33,35,62,116
 db 228,102,66,66,66,66,126,51,117
 db 230,98,66,66,66,66,78,59,117
 db 238,66,66,66,66,66,102,59,117
 db 224,116,35,38,36,28,24,16,118
 db 224,116,99,38,36,40,24,16,118
 db 27,202,74,90,54,54,36,36,119
 db 219,74,90,90,90,108,36,36,119
 db 219,75,90,90,58,54,36,4,119
 db 14,228,44,24,24,37,46,96,120
 db 244,39,20,24,24,36,228,15,120
 db 240,39,52,24,24,44,228,47,120
 db 55,226,36,20,24,8,16,96,121
 db 247,34,36,28,24,16,48,192,121
 db 55,226,36,28,24,16,16,224,121
 db 124,71,196,8,16,32,193,62,122
 db 127,66,76,8,16,33,67,254,122
 db 125,71,68,8,16,33,225,63,122
 db 124,134,130,129,129,193,97,62,48
 db 124,194,131,129,129,193,67,62,48
 db 16,240,16,16,24,24,11,124,49
 db 124,134,66,2,12,48,65,255,50
 db 124,66,66,2,12,16,97,255,50
 db 124,130,194,6,8,49,65,254,50
 db 63,97,3,30,3,1,130,252,51
 db 252,130,3,62,6,129,129,127,51
 db 62,65,3,30,3,1,131,254,51
 db 8,24,56,44,68,255,4,15,52
 db 4,12,28,36,68,255,196,15,52
 db 135,248,192,254,129,1,195,254,53
 db 230,248,192,254,3,1,65,127,53
 db 99,92,64,124,2,2,130,124,53
 db 31,33,64,191,225,129,194,124,54
 db 126,194,128,190,195,193,67,62,54
 db 63,97,192,190,193,129,195,124,54
 db 127,130,134,4,12,8,8,8,55
 db 15,250,134,132,8,8,24,16,55
 db 255,130,134,4,8,8,24,16,55
 db 62,65,65,62,230,129,129,126,56
 db 126,67,97,63,198,129,193,63,56
 db 126,130,134,252,99,129,131,252,56
 db 124,130,131,195,125,1,66,124,57
 db 124,130,129,193,127,1,195,126,57
 db 124,194,129,131,125,1,66,124,57
 db 6,14,12,24,56,112,0,64,33
 db 7,7,14,12,28,60,0,112,33
 db 7,14,14,28,28,56,0,96,33
 db 0,254,131,3,6,24,32,0,63
 db 0,252,131,1,3,28,32,0,63
 db 254,131,1,6,24,32,0,64,63
 db 48,40,40,44,124,68,226,7,65
 db 24,24,20,36,60,66,71,224,65
 db 254,33,35,126,97,97,67,252,66
 db 252,66,67,126,99,33,33,255,66
 db 248,70,65,114,38,33,33,127,66
 db 63,65,129,128,128,128,195,60,67
 db 124,195,129,129,128,128,65,62,67
 db 62,67,129,128,128,128,67,62,67
 db 126,33,33,97,97,65,70,252,68
 db 252,66,65,65,65,65,35,254,68
 db 62,193,65,65,65,98,60,96,68
 db 254,65,72,120,72,65,66,252,69
 db 254,65,72,120,72,65,102,248,69
 db 126,65,72,120,73,65,78,240,69
 db 63,225,68,124,36,32,48,112,70
 db 254,65,100,60,36,32,32,112,70
 db 62,193,72,120,76,64,64,240,70
 db 62,66,130,129,135,130,134,122,71
 db 120,134,130,128,135,130,66,62,71
 db 120,134,130,128,135,194,98,62,71
 db 7,226,66,94,98,66,71,224,72
 db 7,226,66,126,98,66,71,224,72
 db 228,71,66,126,66,66,226,7,72
 db 252,16,16,24,24,8,8,63,73
 db 15,6,4,4,4,132,132,248,74
 db 15,4,6,6,6,6,132,248,74
 db 15,6,6,2,2,2,132,248,74
 db 119,36,40,56,108,68,68,231,75
 db 119,38,44,56,108,68,68,231,75
 db 174,204,72,88,108,68,103,244,75
 db 112,32,32,32,32,32,97,254,76
 db 240,32,32,32,32,33,35,254,76
 db 224,64,96,32,33,35,46,112,76
 db 96,99,102,102,90,90,210,7,77
 db 96,96,103,118,90,218,82,7,77
 db 195,102,102,102,90,90,82,231,77
 db 231,98,82,90,74,70,70,226,78
 db 231,98,82,82,74,70,70,226,78
 db 7,226,115,89,69,67,96,112,78
 db 124,130,129,129,129,129,97,62,79
 db 124,194,129,129,129,129,66,62,79
 db 255,97,33,46,48,32,32,112,80
 db 124,131,129,129,129,127,93,127,81
 db 126,195,129,129,129,127,29,126,81
 db 126,131,129,129,129,127,93,126,81
 db 252,66,66,124,104,68,66,225,82
 db 254,98,66,124,76,68,66,225,82
 db 252,98,66,118,92,68,70,227,82
 db 63,97,64,62,1,129,130,252,83
 db 126,66,65,56,6,129,193,62,83
 db 126,66,65,56,7,129,65,126,83
 db 254,153,17,16,16,16,16,120,84
 db 127,137,152,16,16,16,16,120,84
 db 127,217,152,16,16,16,16,56,84
 db 231,66,66,66,66,66,68,124,85
 db 224,71,66,66,66,66,98,62,85
 db 7,226,194,66,66,66,66,60,85
 db 7,34,194,38,36,20,28,8,86
 db 231,66,34,36,36,24,24,16,86
 db 7,38,226,102,36,20,28,8,86
 db 3,26,202,90,90,124,52,32,87
 db 219,74,74,90,122,54,52,36,87
 db 11,218,82,90,92,124,108,32,87
 db 14,228,40,24,24,36,39,224,88
 db 112,39,22,28,56,228,38,7,88
 db 238,36,60,24,24,44,196,47,88
 db 231,98,36,28,24,24,24,60,89
 db 7,226,36,52,24,8,8,28,89
 db 231,66,36,28,24,16,16,60,89
 db 126,130,4,24,48,96,193,126,90
 db 127,66,4,8,16,33,65,254,90
 db 63,70,12,8,16,33,70,248,90
 db 120,68,4,60,100,132,143,114,97
 db 56,68,132,28,100,132,143,242,97
 db 120,136,4,60,100,132,140,115,97
 db 224,64,76,118,65,65,65,126,98
 db 224,64,126,33,33,33,34,124,98
 db 224,100,63,33,33,33,34,60,98
 db 60,66,192,128,128,129,194,60,99
 db 60,66,128,128,128,129,67,62,99
 db 60,66,128,128,128,129,67,60,99
 db 28,4,124,132,132,132,110,27,100
 db 14,6,62,70,134,134,134,123,100
 db 28,4,116,132,132,132,198,127,100
 db 120,132,254,156,128,192,99,62,101
 db 120,132,254,142,128,128,65,62,101
 db 120,196,254,143,128,192,99,62,101
 db 31,48,252,48,48,48,48,254,102
 db 15,16,124,48,16,48,48,252,102
 db 15,24,60,16,16,48,32,248,102
 db 63,66,98,124,96,158,195,62,103
 db 22,108,66,124,192,127,129,254,103
 db 30,100,70,124,64,126,129,255,103
 db 96,32,44,50,34,98,66,255,104
 db 192,64,92,102,98,98,39,244,104
 db 192,64,92,102,66,66,66,247,104
 db 4,96,60,12,8,8,248,15,105
 db 0,248,16,24,24,8,127,0,105
 db 0,124,8,8,24,24,255,0,105
 db 124,12,6,6,6,6,252,0,106
 db 62,6,6,3,3,3,254,0,106
 db 15,2,2,2,2,6,252,0,106
 db 192,64,72,78,88,104,68,255,107
 db 96,32,32,39,56,108,244,15,107
 db 192,64,78,72,120,36,39,244,107
 db 248,16,24,24,24,24,24,127,108
 db 248,16,24,24,24,24,24,255,108
 db 224,112,78,74,74,250,26,7,109
 db 240,78,74,74,74,74,250,15,109
 db 246,106,74,74,74,74,82,255,109
 db 220,100,68,98,34,34,34,119,110
 db 108,50,34,34,34,34,226,63,110
 db 252,98,66,66,66,66,66,255,110
 db 120,198,130,129,129,193,99,62,111
 db 62,99,193,129,129,129,198,124,111
 db 108,50,33,33,33,62,32,240,112
 db 31,241,33,35,62,32,40,112,112
 db 254,33,33,33,51,44,32,120,112
 db 124,132,132,132,140,116,4,15,113
 db 126,198,134,134,204,52,4,15,113
 db 122,132,132,132,124,4,4,15,113
 db 247,24,48,48,48,48,32,248,114
 db 247,248,48,48,16,48,16,252,114
 db 255,56,16,16,16,16,16,126,114
 db 126,70,66,124,7,129,97,126,115
 db 126,66,65,56,7,129,65,126,115
 db 60,71,97,24,134,195,225,30,115
 db 48,48,124,160,48,48,17,31,116
 db 16,16,254,48,48,48,32,31,116
 db 16,16,254,48,48,48,48,31,116
 db 230,66,66,66,66,66,78,59,117
 db 228,70,66,66,66,66,46,51,117
 db 204,70,66,98,34,34,46,27,117
 db 7,242,102,36,36,44,24,24,118
 db 224,100,35,34,36,20,20,24,118
 db 224,100,35,34,36,20,24,24,118
 db 11,218,74,74,90,54,52,32,119
 db 3,26,202,74,90,86,52,32,119
 db 27,218,74,90,90,54,54,32,119
 db 112,55,20,24,56,228,44,3,120
 db 7,116,44,24,28,39,46,224,120
 db 238,36,40,16,24,36,100,239,120
 db 224,103,34,36,24,24,16,224,121
 db 231,34,36,40,24,16,32,224,121
 db 231,34,36,20,28,8,8,48,121
 db 126,196,136,24,16,33,99,126,122
 db 127,198,140,24,16,33,67,254,122
 db 126,196,136,24,48,33,67,254,122
 db 124,194,131,129,129,129,67,62,48
 db 60,67,129,129,129,129,66,60,48
 db 60,66,129,129,129,129,66,60,48
 db 112,144,16,24,8,8,15,56,49
 db 248,24,24,24,24,24,24,127,49
 db 124,66,2,2,4,24,97,254,50
 db 62,66,66,6,12,17,98,252,50
 db 62,66,66,2,4,24,97,254,50
 db 252,130,2,60,3,1,129,126,51
 db 126,130,2,60,3,1,131,254,51
 db 62,65,1,30,2,129,129,126,51
 db 24,56,40,72,141,255,4,30,52
 db 24,56,104,200,252,15,4,30,52
 db 24,24,40,72,79,252,6,24,52
 db 127,192,192,254,3,1,130,252,53
 db 254,128,128,254,1,1,65,126,53
 db 3,252,128,254,129,1,131,126,53
 db 62,65,128,254,131,129,65,62,54
 db 62,64,128,190,193,129,65,126,54
 db 62,64,128,190,193,129,131,124,54
 db 127,131,6,8,8,16,16,32,55
 db 254,129,2,4,8,24,16,48,55
 db 31,194,134,12,8,16,16,48,55
 db 62,65,67,124,103,129,131,254,56
 db 124,67,97,127,134,129,193,62,56
 db 124,67,97,126,134,131,193,62,56
 db 62,65,129,131,125,3,130,252,57
 db 62,65,129,131,125,3,130,124,57
 db 62,193,129,131,125,1,130,252,57
 db 112,56,28,30,30,15,2,1,33
 db 124,56,60,60,30,30,4,2,33
 db 126,131,1,3,30,48,0,32,63
 db 0,62,193,129,6,8,24,0,63
 db 62,193,129,6,12,16,0,16,63
 db 24,40,36,36,68,126,130,129,65
 db 24,40,36,100,68,126,130,129,65
 db 48,40,104,68,116,158,130,3,65
 db 126,130,134,190,193,193,71,120,66
 db 254,130,130,254,129,193,195,124,66
 db 254,130,134,254,193,65,67,124,66
 db 126,193,128,128,128,128,65,63,67
 db 62,64,128,128,128,128,65,62,67
 db 126,129,128,128,128,192,96,31,67
 db 126,193,129,129,129,131,134,248,68
 db 252,134,129,129,129,129,131,254,68
 db 254,129,129,129,129,129,134,248,68
 db 126,128,128,254,192,64,65,126,69
 db 127,192,128,254,128,128,128,254,69
 db 127,64,64,126,192,128,128,254,69
 db 255,128,128,254,128,128,128,128,70
 db 255,128,192,255,64,64,64,64,70
 db 255,192,192,127,64,64,96,96,70
 db 63,64,128,130,133,129,129,126,71
 db 192,129,129,249,131,129,129,1,72
 db 30,28,60,60,56,120,112,112,73
 db 28,60,60,56,56,120,120,112,73
 db 3,3,2,6,6,6,4,248,74
 db 3,3,2,6,6,6,4,252,74
 db 3,2,2,6,4,4,12,248,74
 db 195,140,176,224,176,152,132,3,75
 db 7,140,144,160,224,144,140,135,75
 db 195,204,144,224,176,152,140,3,75
 db 128,128,128,128,128,128,192,255,76
 db 195,199,229,165,185,153,129,128,77
 db 3,197,229,165,185,153,129,128,77
 db 194,197,165,165,153,153,129,129,77
 db 193,161,177,145,137,141,133,131,78
 db 193,161,177,145,137,137,133,135,78
 db 60,67,129,129,129,129,67,62,79
 db 62,67,129,129,129,129,130,124,79
 db 126,67,65,65,126,192,128,128,80
 db 126,131,129,129,129,67,60,6,81
 db 124,195,129,129,129,98,28,6,81
 db 62,65,129,129,129,130,124,6,81
 db 248,140,132,248,136,132,130,3,82
 db 252,132,132,152,232,132,130,131,82
 db 252,134,132,252,136,132,130,131,82
 db 127,192,192,120,6,1,129,254,83
 db 63,65,64,56,6,3,131,254,83
 db 126,193,64,120,6,1,129,126,83
 db 255,16,16,16,16,16,48,32,84
 db 248,23,16,16,16,16,48,32,84
 db 255,16,16,24,24,8,8,8,84
 db 128,129,129,129,129,129,195,126,85
 db 1,194,66,98,36,52,20,8,86
 db 64,97,33,34,18,20,20,8,86
 db 129,66,66,102,36,36,24,24,86
 db 128,153,153,154,106,106,102,100,87
 db 128,152,153,219,106,106,110,4,87
 db 129,153,153,90,122,110,102,100,87
 db 12,136,80,32,48,72,70,128,88
 db 130,68,40,24,24,36,66,193,88
 db 64,35,20,24,56,100,198,2,88
 db 193,66,36,28,24,24,8,8,89
 db 195,66,36,24,24,24,8,8,89
 db 129,66,36,24,8,8,8,8,89
 db 62,230,12,8,16,32,71,248,90
 db 124,7,6,12,48,96,224,31,90
 db 126,131,1,127,193,129,135,125,97
 db 126,130,3,63,65,129,199,124,97
 db 124,3,1,127,193,129,195,125,97
 db 128,140,178,193,129,193,195,124,98
 db 64,64,252,195,193,129,193,190,98
 db 192,192,252,194,129,129,193,190,98
 db 63,64,128,128,128,128,193,126,99
 db 126,195,128,128,128,128,64,63,99
 db 62,66,128,128,128,192,65,63,99
 db 1,1,125,131,129,131,194,126,100
 db 1,1,61,195,129,131,131,127,100
 db 1,17,239,131,131,130,194,126,100
 db 124,198,130,254,128,192,65,63,101
 db 124,198,130,255,134,192,97,31,101
 db 124,134,130,255,130,192,96,31,101
 db 31,48,254,32,32,96,96,96,102
 db 30,48,255,16,24,24,8,8,102
 db 31,48,254,48,48,48,48,32,102
 db 63,65,129,131,134,122,6,248,103
 db 63,195,129,129,199,125,3,126,103
 db 62,195,129,129,195,125,3,126,103
 db 128,128,191,193,129,129,129,129,104
 db 64,64,254,227,193,193,129,131,104
 db 64,64,95,97,193,193,131,130,104
 db 30,0,30,30,28,28,28,124,105
 db 224,0,56,60,60,28,14,7,105
 db 120,0,28,28,30,14,15,15,105
 db 96,0,56,24,28,12,14,254,106
 db 3,0,6,6,6,4,12,248,106
 db 6,0,7,7,3,3,3,127,106
 db 32,32,32,110,112,72,70,1,107
 db 128,128,134,152,224,144,140,3,107
 db 128,128,134,152,224,80,76,3,107
 db 126,126,126,30,30,31,31,31,108
 db 14,30,28,28,56,48,112,96,108
 db 15,15,30,30,28,60,60,120,108
 db 240,214,137,137,137,137,17,1,109
 db 246,221,137,137,137,145,145,17,109
 db 94,97,65,193,129,129,129,129,110
 db 126,227,193,193,129,129,129,3,110
 db 94,225,193,193,193,129,129,129,110
 db 62,67,193,129,129,131,134,124,111
 db 254,195,129,129,193,190,128,128,112
 db 190,195,129,129,195,188,128,128,112
 db 125,195,129,129,195,62,2,2,113
 db 125,131,129,129,195,63,3,3,113
 db 95,112,64,64,192,192,192,192,114
 db 76,255,192,192,192,192,128,128,114
 db 223,225,192,192,192,192,192,192,114
 db 63,64,128,252,3,1,3,252,115
 db 63,97,64,56,6,2,134,252,115
 db 63,96,64,124,6,3,130,252,115
 db 48,248,255,96,96,96,64,60,116
 db 48,240,127,96,96,96,64,62,116
 db 64,96,252,32,32,48,48,31,116
 db 131,131,131,129,129,129,195,125,117
 db 131,131,131,131,129,129,67,61,117
 db 3,131,131,129,129,193,199,124,117
 db 129,67,66,34,36,52,20,24,118
 db 129,194,66,98,36,36,28,24,118
 db 128,67,66,70,100,44,40,48,118
 db 1,153,217,90,86,86,54,32,119
 db 128,153,154,186,234,106,108,68,119
 db 1,153,217,91,86,86,54,32,119
 db 3,196,44,24,24,36,67,192,120
 db 64,35,20,24,24,44,196,2,120
 db 192,102,60,24,56,36,198,3,120
 db 131,66,68,44,56,16,48,224,121
 db 192,67,98,36,60,24,16,96,121
 db 1,194,70,36,56,24,16,96,121
 db 126,3,6,12,16,96,192,254,122
 db 62,228,12,8,16,32,111,112,122
 db 62,228,4,8,16,32,111,112,122
 db 126,195,129,129,129,129,195,126,48
 db 248,8,8,8,24,24,24,127,49
 db 248,8,8,8,8,24,24,255,49
 db 126,1,1,2,4,24,96,254,50
 db 126,130,2,4,8,16,33,126,50
 db 126,1,1,30,2,3,2,252,51
 db 252,3,3,30,6,1,129,127,51
 db 62,3,1,31,6,3,131,126,51
 db 6,10,18,34,70,191,196,4,52
 db 14,26,22,38,68,255,4,4,52
 db 252,192,192,254,3,1,1,254,53
 db 126,64,64,126,1,1,129,254,53
 db 124,128,192,254,131,1,3,252,53
 db 126,193,128,254,131,129,65,62,54
 db 63,65,144,254,130,131,194,124,54
 db 31,96,192,190,193,129,131,124,54
 db 255,2,6,4,12,8,8,16,55
 db 255,2,6,4,4,8,8,16,55
 db 255,2,6,4,12,8,24,48,55
 db 126,195,65,126,198,129,131,126,56
 db 126,67,65,62,198,129,195,126,56
 db 62,195,130,126,99,193,131,126,56
 db 126,194,129,131,125,1,2,124,57
 db 126,130,131,129,127,1,3,126,57
 db 31,30,28,28,56,112,0,240,33
 db 28,28,60,60,60,48,0,56,33
 db 15,14,28,60,60,48,0,240,33
 db 127,129,3,6,8,24,0,8,63
 db 127,193,3,6,12,8,0,4,63
 db 254,3,3,6,8,8,0,8,63
RODATA ends

end main
