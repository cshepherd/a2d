;;; ============================================================
;;; DSH - Desk Accessory
;;;
;;; Desktop Shell - A simple shell interface with redraw support.
;;; ============================================================

        .include "../config.inc"

        .include "apple2.inc"
        .include "../inc/apple2.inc"
        .include "../inc/macros.inc"
        .include "../inc/prodos.inc"
        .include "../mgtk/mgtk.inc"
        .include "../toolkits/letk.inc"
        .include "../common.inc"
        .include "../desktop/desktop.inc"

;;; ============================================================

        DA_HEADER
        DA_START_AUX_SEGMENT

;;; ============================================================

        .include "../lib/event_params.s"

;;; ============================================================
;;; Monaco monospaced font

monaco_font:
        .incbin .concat("../../out/Monaco.", kBuildLang, ".font")

;;; ============================================================

.params trackgoaway_params
goaway:         .byte   0
.endparams

kDALeft    = 10
kDATop     = 28
kDAWidth   = 512
kDAHeight  = 150

kDAWindowId = $80

kLineHeight = 10
kLeftMargin = 3
kTopMargin = 10

;;; External command constants (shared between aux and main segments)
kCommandBank    = 2             ; Use bank 2 for external commands
kCommandStart   = $0800         ; Start address in RamWorks bank
kCommandEnd     = $BFFF         ; End of usable bank-switched memory
kMaxCommandSize = kCommandEnd - kCommandStart + 1  ; $B400 = 46,080 bytes

.params winfo
window_id:      .byte   kDAWindowId
options:        .byte   MGTK::Option::go_away_box
title:          .addr   title_string
hscroll:        .byte   MGTK::Scroll::option_none
vscroll:        .byte   MGTK::Scroll::option_normal
hthumbmax:      .byte   0
hthumbpos:      .byte   0
vthumbmax:      .byte   32
vthumbpos:      .byte   0
status:         .byte   0
reserved:       .byte   0
mincontwidth:   .word   200
mincontheight:  .word   51
maxcontwidth:   .word   kDAWidth
maxcontheight:  .word   kDAHeight
port:
        DEFINE_POINT viewloc, kDALeft, kDATop
mapbits:        .addr   MGTK::screen_mapbits
mapwidth:       .byte   MGTK::screen_mapwidth
reserved2:      .byte   0
        DEFINE_RECT maprect, 0, 0, kDAWidth, kDAHeight
pattern:        .res    8, $FF
colormasks:     .byte   MGTK::colormask_and, MGTK::colormask_or
        DEFINE_POINT penloc, 0, 0
penwidth:       .byte   1
penheight:      .byte   1
penmode:        .byte   MGTK::pencopy
textback:       .byte   MGTK::textbg_white
textfont:       .addr   DEFAULT_FONT
nextwinfo:      .addr   0
        REF_WINFO_MEMBERS
.endparams

title_string:
        PASCAL_STRING "dsh"

welcome_prefix:
        PASCAL_STRING "Welcome to dsh - "
welcome_string:
        .res    36, 0           ; Built dynamically with RamWorks bank count
ramworks_suffix:
        PASCAL_STRING " RamWorks banks"
str_from_int:
        PASCAL_STRING "000"     ; Filled in by IntToString

prompt_string:
        PASCAL_STRING "dsh% "

.params cursor_pos
xcoord: .word   kLeftMargin
ycoord: .word   kTopMargin
.endparams

kInputBufferSize = 80
input_buffer:   .res    kInputBufferSize, 0
input_pos:      .byte   0

.params welcome_params
textptr:        .addr   welcome_string+1
textlen:        .byte   .strlen("Welcome to dsh.")
.endparams

.params prompt_params
textptr:        .addr   prompt_string+1
textlen:        .byte   .strlen("dsh% ")
.endparams

char_buf:       .byte   0
.params char_params
textptr:        .addr   char_buf
textlen:        .byte   1
.endparams

space_char:     .byte   ' '
.params space_params
textptr:        .addr   space_char
textlen:        .byte   1
.endparams

;;; LineEdit control for input
kPromptWidth = 35
kInputLeft = kLeftMargin + kPromptWidth
kInputTop = kTopMargin  ; Position rect so text baseline (at rect.top+10) aligns with prompt at y=20
kInputWidth = kDAWidth - kInputLeft - kLeftMargin

        DEFINE_LINE_EDIT line_edit_rec, kDAWindowId, input_buffer, kInputLeft, kInputTop, kInputWidth, kInputBufferSize-1
        DEFINE_LINE_EDIT_PARAMS le_params, line_edit_rec

;;; ============================================================
;;; Line history and scrolling

kMaxHistoryLines = 3            ; Maximum number of lines to keep in history
kMaxLineLength = 80             ; Maximum length of each line
kMaxVisibleLines = kDAHeight / kLineHeight ; ~14 lines
kLineRecordSize = kMaxLineLength + 1 ; Pascal string: length + data

;;; Line history buffer in aux memory (16 × 81 = 1296 bytes)
line_history:   .res    kMaxHistoryLines * kLineRecordSize, 0

;;; Current number of lines in history
total_lines:    .word   0

;;; Index of the first line visible at the top of the window
top_line_index: .word   0

;;; Zero page pointers for string operations
zp_src_ptr      := $06
zp_dst_ptr      := $08

;;; ============================================================

.proc Init
        MGTK_CALL MGTK::OpenWindow, winfo
        MGTK_CALL MGTK::SetPort, winfo::port

        ;; Set monospaced font
        MGTK_CALL MGTK::SetFont, monaco_font

        ;; Initialize history
        copy16  #0, total_lines
        copy16  #0, top_line_index

        ;; Detect RamWorks banks
        jsr     DetectRamWorks

        ;; Add welcome message to history
        ldax    #welcome_string
        jsr     AddLineToHistory

        ;; Redraw all lines (draws all except the last line)
        jsr     RedrawAllLines

        ;; Initialize input buffer
        copy8   #0, input_buffer

        ;; Position line edit at last line
        jsr     PositionLineEditAtBottom

        ;; Draw the prompt at the line edit position
        jsr     DrawPrompt

        ;; Initialize and activate line edit control
        LETK_CALL LETK::Init, le_params
        LETK_CALL LETK::Activate, le_params

        MGTK_CALL MGTK::FlushEvents
        jmp     InputLoop
.endproc ; Init

;;; ============================================================
;;; Add a Pascal string to the line history
;;; Input: A/X = address of Pascal string to add
;;; Trashes: A, X, Y

.proc AddLineToHistory
        ;; Save the new line pointer
        stax    new_line_ptr

        ;; Check if we've hit max lines
        lda     total_lines+1
        bne     at_max
        lda     total_lines
        cmp     #kMaxHistoryLines
        bcs     at_max
        jmp     has_space

at_max:
        ;; At max - shift all lines up by one to make room
        ;; Copy line 1 to line 0, line 2 to line 1, etc.
        ;; We'll use GetLineAddress to calculate addresses

        ;; Start with line 0 (destination)
        copy16  #0, current_line

shift_loop:
        ;; Calculate source line index (current_line + 1)
        add16   current_line, #1, source_line

        ;; Check if we've copied all lines (source_line == kMaxHistoryLines)
        lda     source_line
        cmp     #kMaxHistoryLines
        bne     continue_shift
        lda     source_line+1
        beq     done_shift
continue_shift:
        ;; Get source address
        copy16  source_line, temp_idx
        jsr     CalcLineAddress ; Returns address in zp_dst_ptr
        copy16  zp_dst_ptr, saved_src

        ;; Get destination address
        copy16  current_line, temp_idx
        jsr     CalcLineAddress ; Returns address in zp_dst_ptr

        ;; Restore source address
        copy16  saved_src, zp_src_ptr
        ldy     #kLineRecordSize-1
copy_byte:
        lda     (zp_src_ptr),y
        sta     (zp_dst_ptr),y
        dey
        bpl     copy_byte

        ;; Move to next line
        inc16   current_line
        jmp     shift_loop

done_shift:
        ;; Now use the last slot (decrement total so it will be re-incremented)
        dec16   total_lines

        ;; Adjust scroll position
        lda     top_line_index
        bne     :+
        lda     top_line_index+1
        beq     has_space
:       dec16   top_line_index

has_space:
        ;; Restore the new line pointer
        ldax    new_line_ptr
        stax    zp_src_ptr
        ;; Calculate destination address: line_history + (total_lines * (kMaxLineLength+1))
        lda     total_lines
        sta     line_num
        lda     total_lines+1
        sta     line_num+1

        ;; Multiply by 81 (kMaxLineLength+1)
        ;; 81 = 64 + 16 + 1
        copy16  line_num, zp_dst_ptr
        lda     #0
        sta     zp_dst_ptr+1

        ;; * 64
        ldx     #6
:       asl16   zp_dst_ptr
        dex
        bne     :-

        ;; + (line_num * 16)
        copy16  line_num, temp
        ldx     #4
:       asl16   temp
        dex
        bne     :-
        add16   zp_dst_ptr, temp, zp_dst_ptr

        ;; + line_num
        add16   zp_dst_ptr, line_num, zp_dst_ptr

        ;; Add base address
        add16   zp_dst_ptr, #line_history, zp_dst_ptr

        ;; Copy the string (length + data)
        ldy     #0
        lda     (zp_src_ptr),y
        sta     (zp_dst_ptr),y  ; Copy length byte
        tay
:       lda     (zp_src_ptr),y
        sta     (zp_dst_ptr),y
        dey
        bne     :-

        ;; Increment total_lines
        inc16   total_lines

        rts

;;; Helper: Calculate line address from line index
;;; Input: temp_idx = line index
;;; Output: zp_dst_ptr = address
;;; Trashes: A, X
CalcLineAddress:
        copy16  temp_idx, zp_dst_ptr
        lda     #0
        sta     zp_dst_ptr+1

        ;; Multiply by 81 (kMaxLineLength+1)
        ;; 81 = 64 + 16 + 1

        ;; * 64
        ldx     #6
:       asl16   zp_dst_ptr
        dex
        bne     :-

        ;; Save * 64
        copy16  zp_dst_ptr, temp_64

        ;; Calculate * 16
        copy16  temp_idx, temp_offset
        lda     #0
        sta     temp_offset+1
        ldx     #4
:       asl16   temp_offset
        dex
        bne     :-

        ;; Add: *64 + *16 + original
        add16   zp_dst_ptr, temp_offset, zp_dst_ptr
        add16   zp_dst_ptr, temp_idx, zp_dst_ptr

        ;; Add base address
        add16   zp_dst_ptr, #line_history, zp_dst_ptr
        rts

line_num:       .word   0
temp:           .word   0
new_line_ptr:   .addr   0
current_line:   .word   0
source_line:    .word   0
temp_idx:       .word   0
temp_offset:    .word   0
temp_64:        .word   0
saved_src:      .word   0
.endproc ; AddLineToHistory

;;; ============================================================
;;; Redraw all visible lines from history
;;; Trashes: A, X, Y

.proc RedrawAllLines
        ;; Calculate how many lines to draw
        ;; min(total_lines - top_line_index, kMaxVisibleLines - 1)
        ;; (Leave room for the active prompt line at the bottom)
        sub16   total_lines, top_line_index, lines_to_draw
        lda     lines_to_draw+1
        bne     use_max         ; If > 255, use max
        lda     lines_to_draw
        cmp     #kMaxVisibleLines-1
        bcs     use_max
        jmp     start_draw
use_max:
        lda     #kMaxVisibleLines-1
        sta     lines_to_draw
        lda     #0
        sta     lines_to_draw+1

start_draw:
        ;; Start at top of window
        copy16  #kLeftMargin, cursor_pos::xcoord
        copy16  #kTopMargin, cursor_pos::ycoord

        ;; Start with top_line_index
        copy16  top_line_index, current_line

loop:
        ;; Check if done
        lda     lines_to_draw
        ora     lines_to_draw+1
        beq     done

        ;; Get line address
        jsr     GetLineAddress  ; Returns address in zp_src_ptr

        ;; Draw the line
        MGTK_CALL MGTK::MoveTo, cursor_pos
        ldy     #0
        lda     (zp_src_ptr),y  ; Get length
        beq     next_line       ; Skip empty lines
        sta     draw_params::textlen
        inc16   zp_src_ptr
        copy16  zp_src_ptr, draw_params::textptr
        MGTK_CALL MGTK::DrawText, draw_params

next_line:
        ;; Move to next line
        add16_8 cursor_pos::ycoord, #kLineHeight
        inc16   current_line
        dec16   lines_to_draw
        jmp     loop

done:   rts

lines_to_draw: .word 0
current_line: .word 0

.params draw_params
textptr: .addr  0
textlen: .byte  0
.endparams
.endproc ; RedrawAllLines

;;; ============================================================
;;; Get address of a line in history
;;; Input: current_line (from RedrawAllLines)
;;; Output: zp_src_ptr
;;; Trashes: A, X

.proc GetLineAddress
        ;; Calculate address: line_history + (current_line * 81)
        copy16  RedrawAllLines::current_line, line_num

        ;; Multiply by 81 (64 + 16 + 1)
        copy16  line_num, addr
        lda     #0
        sta     addr+1

        ;; * 64
        ldx     #6
:       asl16   addr
        dex
        bne     :-

        ;; + (line_num * 16)
        copy16  line_num, temp
        ldx     #4
:       asl16   temp
        dex
        bne     :-
        add16   addr, temp, addr

        ;; + line_num
        add16   addr, line_num, addr

        ;; Add base
        add16   addr, #line_history, addr
        copy16  addr, zp_src_ptr

        rts

line_num: .word 0
addr:   .addr   0
temp:   .word   0
.endproc ; GetLineAddress

;;; ============================================================
;;; Position line edit control at the bottom visible line

.proc PositionLineEditAtBottom
        ;; Calculate number of visible history lines
        ;; min(total_lines - top_line_index, kMaxVisibleLines - 1)
        sub16   total_lines, top_line_index, visible_lines
        lda     visible_lines+1
        bne     use_max
        lda     visible_lines
        cmp     #kMaxVisibleLines-1
        bcs     use_max
        jmp     calc_pos
use_max:
        lda     #kMaxVisibleLines-1
        sta     visible_lines
        lda     #0
        sta     visible_lines+1

        ;; Calculate line edit rect.y1 position
        ;; The prompt line comes after visible_lines history lines
        ;; Text baseline for prompt should be at: kTopMargin + visible_lines * kLineHeight
        ;; But rect.y1 is kTextBoxTextVOffset pixels above the baseline
        ;; So: rect.y1 = kTopMargin + visible_lines * kLineHeight - kTextBoxTextVOffset
        ;;            = kTopMargin + visible_lines * kLineHeight - kTopMargin  (since both = 10)
        ;;            = visible_lines * kLineHeight
calc_pos:
        copy16  visible_lines, temp
        lda     #0
        sta     temp+1

        ;; Multiply by 10 (kLineHeight)
        ldx     #3              ; * 8
:       asl16   temp
        dex
        bne     :-
        add16   temp, visible_lines, temp ; * 8 + visible_lines = * 9
        add16   temp, visible_lines, temp ; * 9 + visible_lines = * 10

        ;; temp now has visible_lines * kLineHeight, which is the rect.y1 position

        ;; Update line edit rect y positions
        copy16  temp, line_edit_rec+5    ; rect.y1
        add16   temp, #kTextBoxHeight, line_edit_rec+9  ; rect.y2

        rts

visible_lines: .word 0
temp:   .word   0
.endproc ; PositionLineEditAtBottom

;;; ============================================================
;;; Draw the prompt at the current line edit position
;;; This should be called after PositionLineEditAtBottom

.proc DrawPrompt
        ;; Calculate the text baseline position
        ;; The line edit rect.y1 is 10 pixels above the text baseline
        ;; So baseline_y = rect.y1 + kTextBoxTextVOffset
        copy16  line_edit_rec+5, prompt_pos+MGTK::Point::ycoord  ; Start with rect.y1
        add16_8 prompt_pos+MGTK::Point::ycoord, #kTextBoxTextVOffset ; Add offset to baseline
        copy16  #kLeftMargin, prompt_pos+MGTK::Point::xcoord

        MGTK_CALL MGTK::MoveTo, prompt_pos
        MGTK_CALL MGTK::DrawText, prompt_text_params
        rts

        DEFINE_POINT prompt_pos, 0, 0

.params prompt_text_params
textptr:        .addr   prompt_string+1
textlen:        .byte   5               ; "dsh% " is 5 characters
.endparams
.endproc ; DrawPrompt

;;; ============================================================
;;; Update scrollbar position and activation state

.proc UpdateScrollBar
        ;; Check if scrolling is needed
        ;; If total_lines <= kMaxVisibleLines, deactivate scrollbar
        lda     total_lines+1
        bne     needs_scroll
        lda     total_lines
        cmp     #kMaxVisibleLines+1
        bcs     needs_scroll

        ;; Deactivate scrollbar
        MGTK_CALL MGTK::ActivateCtl, deactivate_params
        rts

needs_scroll:
        ;; Activate scrollbar
        MGTK_CALL MGTK::ActivateCtl, activate_params

        ;; Calculate thumb size: vthumbmax = min(32, (kMaxVisibleLines * 32) / total_lines)
        ;; Simple approximation: vthumbmax = 32 * 13 / total_lines
        lda     total_lines
        cmp     #kMaxVisibleLines-1
        bcs     calc_size
        lda     #32             ; If total <= visible, full size
        sta     winfo::vthumbmax
        jmp     calc_thumbpos

calc_size:
        ;; vthumbmax ≈ (13 * 32) / total_lines = 416 / total_lines
        ;; Use table lookup for common sizes
        lda     total_lines
        cmp     #16
        bcc     size_16
        cmp     #26
        bcc     size_26
        cmp     #52
        bcc     size_52
        lda     #4              ; For very large histories
        sta     winfo::vthumbmax
        jmp     calc_thumbpos

size_16:
        lda     #26             ; 416/16 = 26
        sta     winfo::vthumbmax
        jmp     calc_thumbpos
size_26:
        lda     #16             ; 416/26 = 16
        sta     winfo::vthumbmax
        jmp     calc_thumbpos
size_52:
        lda     #8              ; 416/52 = 8
        sta     winfo::vthumbmax

calc_thumbpos:
        ;; Calculate thumb position: top_line_index * 32 / (total_lines - (kMaxVisibleLines-1))
        sub16   total_lines, #kMaxVisibleLines-1, max_scroll
        lda     max_scroll+1
        bne     :+
        lda     max_scroll
        beq     at_bottom       ; Exactly at capacity

:       ;; Calculate: top_line_index * 32 / max_scroll
        copy16  top_line_index, temp
        lda     #0
        sta     temp+1
        ldx     #5              ; * 32
:       asl16   temp
        dex
        bne     :-

        ;; Divide by max_scroll (simplified - just clamp to 32)
        lda     temp+1
        bne     at_bottom
        lda     temp
        cmp     #32
        bcc     :+
at_bottom:
        lda     #32
:       sta     winfo::vthumbpos
        MGTK_CALL MGTK::UpdateThumb, updatethumb_params
        rts

max_scroll:     .word   0
temp:           .word   0

.params activate_params
which_ctl:      .byte   MGTK::Ctl::vertical_scroll_bar
activate:       .byte   MGTK::activatectl_activate
.endparams

.params deactivate_params
which_ctl:      .byte   MGTK::Ctl::vertical_scroll_bar
activate:       .byte   MGTK::activatectl_deactivate
.endparams

.params updatethumb_params
which_ctl:      .byte   MGTK::Ctl::vertical_scroll_bar
thumbpos:       .byte   0
.endparams
.endproc ; UpdateScrollBar

;;; ============================================================

.proc InputLoop
        LETK_CALL LETK::Idle, le_params
        JSR_TO_MAIN JUMP_TABLE_SYSTEM_TASK
        jsr     GetNextEvent
        lda     event_params
        cmp     #MGTK::EventKind::key_down
        bne     :+
        jmp     OnKeyDown
:       cmp     #MGTK::EventKind::button_down
        bne     :+
        jmp     OnButtonDown
:       cmp     #kEventKindMouseMoved
        bne     :+
        jmp     OnMouseMove
:       jmp     InputLoop

OnButtonDown:
        FALL_THROUGH_TO OnButtonDown
.endproc ; InputLoop

;;; ============================================================

.proc OnButtonDown
        MGTK_CALL MGTK::FindWindow, event_params::coords
        lda     findwindow_params::window_id
        cmp     #kDAWindowId
        bne     InputLoop

        lda     findwindow_params::which_area
        cmp     #MGTK::Area::close_box
        jeq     OnCloseClick

        cmp     #MGTK::Area::dragbar
        beq     title

        cmp     #MGTK::Area::content
        beq     content
        jmp     InputLoop

title:  jsr     OnTitleBarClick
        jmp     InputLoop

content:
        ;; Check if click is on a scrollbar
        MGTK_CALL MGTK::FindControl, findcontrol_params
        lda     findcontrol_params::which_ctl
        cmp     #MGTK::Ctl::vertical_scroll_bar
        beq     vscroll

        ;; Content click - convert to window coords and pass to LETK
        copy8   #kDAWindowId, screentowindow_params::window_id
        MGTK_CALL MGTK::ScreenToWindow, screentowindow_params
        COPY_STRUCT screentowindow_params::window, le_params::coords
        LETK_CALL LETK::Click, le_params
        jmp     InputLoop

vscroll:
        jmp     OnVScroll
.endproc ; OnButtonDown

;;; ============================================================

.proc OnVScroll
        ;; Find which part of the scrollbar was clicked
        MGTK_CALL MGTK::FindControl, findcontrol_params
        lda     findcontrol_params::which_part
        cmp     #MGTK::Part::thumb
        bne     :+
        jmp     OnThumb
:       cmp     #MGTK::Part::page_down
        bne     :+
        jmp     OnPageDown
:       cmp     #MGTK::Part::page_up
        bne     :+
        jmp     OnPageUp
:       cmp     #MGTK::Part::up_arrow
        bne     :+
        jmp     OnLineUp
:       cmp     #MGTK::Part::down_arrow
        bne     :+
        jmp     OnLineDown
:       jmp     InputLoop

OnThumb:
        ;; Track thumb dragging
        copy8   #MGTK::Ctl::vertical_scroll_bar, trackthumb_params::which_ctl
        MGTK_CALL MGTK::TrackThumb, trackthumb_params
        lda     trackthumb_params::thumbmoved
        bne     :+
        jmp     done
:
        ;; Calculate new top_line_index from thumb position
        ;; top_line_index = thumbpos * max_scroll / 32
        ;; where max_scroll = total_lines - (kMaxVisibleLines - 1)
        sub16   total_lines, #kMaxVisibleLines-1, max_scroll
        lda     max_scroll+1
        bmi     thumb_done      ; No scrolling needed
        bne     :+
        lda     max_scroll
        bne     :+
thumb_done:
        jmp     done
:
        ;; Multiply thumbpos by max_scroll
        lda     trackthumb_params::thumbpos
        sta     muldiv_num
        lda     #0
        sta     muldiv_num+1
        copy16  max_scroll, muldiv_mult
        jsr     Multiply16      ; Result in muldiv_result

        ;; Divide by 32
        lda     muldiv_result+1
        lsr     a
        lsr     a
        lsr     a
        sta     top_line_index+1
        lda     muldiv_result
        lsr     a
        lsr     a
        lsr     a
        ora     top_line_index+1
        sta     top_line_index
        lda     muldiv_result+1
        and     #$07
        sta     top_line_index+1

        jsr     RedrawContent
        jmp     InputLoop

OnPageDown:
        ;; Scroll down by visible page
        add16   top_line_index, #kMaxVisibleLines-1, top_line_index
        sub16   total_lines, #kMaxVisibleLines-1, max_scroll
        cmp16   top_line_index, max_scroll
        bcc     :+
        copy16  max_scroll, top_line_index
:       jsr     RedrawContent
        jmp     InputLoop

OnPageUp:
        ;; Scroll up by visible page
        sub16   top_line_index, #kMaxVisibleLines-1, top_line_index
        lda     top_line_index+1
        bpl     :+
        copy16  #0, top_line_index
:       jsr     RedrawContent
        jmp     InputLoop

OnLineDown:
        ;; Scroll down by one line
        inc16   top_line_index
        sub16   total_lines, #kMaxVisibleLines-1, max_scroll
        cmp16   top_line_index, max_scroll
        bcc     :+
        copy16  max_scroll, top_line_index
:       jsr     RedrawContent
        jmp     InputLoop

OnLineUp:
        ;; Scroll up by one line
        lda     top_line_index
        bne     :+
        lda     top_line_index+1
        beq     done
:       dec16   top_line_index
        jsr     RedrawContent
        jmp     InputLoop

done:   jmp     InputLoop

max_scroll:     .word   0
muldiv_num:     .word   0
muldiv_mult:    .word   0
muldiv_result:  .word   0
.endproc ; OnVScroll

;;; ============================================================
;;; Multiply 16-bit numbers
;;; Input: muldiv_num, muldiv_mult
;;; Output: muldiv_result

.proc Multiply16
        copy16  #0, OnVScroll::muldiv_result
        ldx     #16
loop:   lsr     OnVScroll::muldiv_mult+1
        ror     OnVScroll::muldiv_mult
        bcc     :+
        add16   OnVScroll::muldiv_result, OnVScroll::muldiv_num, OnVScroll::muldiv_result
:       asl     OnVScroll::muldiv_num
        rol     OnVScroll::muldiv_num+1
        dex
        bne     loop
        rts
.endproc ; Multiply16

;;; ============================================================
;;; Redraw the window content after scrolling

.proc RedrawContent
        MGTK_CALL MGTK::SetPort, winfo::port
        MGTK_CALL MGTK::PaintRect, winfo::maprect
        MGTK_CALL MGTK::SetFont, monaco_font
        jsr     RedrawAllLines
        jsr     PositionLineEditAtBottom
        jsr     DrawPrompt
        jsr     UpdateScrollBar
        LETK_CALL LETK::Update, le_params
        rts
.endproc ; RedrawContent

;;; ============================================================

.proc OnKeyDown
        ldx     event_params::modifiers
        beq     no_mod

        lda     event_params::key
        jsr     ToUpperCase

        cmp     #kShortcutCloseWindow
        jeq     DoClose

        ;; Pass modified keys to LETK
        jmp     pass_to_letk

no_mod:
        lda     event_params::key

        cmp     #CHAR_ESCAPE
        jeq     DoClose

        cmp     #CHAR_RETURN
        beq     HandleReturn

        ;; Fall through to pass key to LETK

pass_to_letk:
        lda     event_params::key
        ldx     event_params::modifiers
        sta     le_params::key
        stx     le_params::modifiers
        LETK_CALL LETK::Key, le_params
        jmp     InputLoop

HandleReturn:
        jsr     HandleEnter
        jmp     InputLoop
.endproc ; OnKeyDown

;;; ============================================================

.proc HandleEnter
        ;; Deactivate line edit
        LETK_CALL LETK::Deactivate, le_params

        ;; Create a line with prompt + input text and add to history
        ;; Format: "dsh% [user input]"
        ldy     #0
        ldx     prompt_string   ; Get prompt length
:       lda     prompt_string,y
        sta     temp_line,y
        iny
        dex
        bpl     :-

        ;; Now append the input buffer
        ldy     temp_line       ; Current length (destination index)
        ldx     #1              ; Start at first char of input (after length byte)
        lda     input_buffer    ; Get input length
        beq     done_append     ; Skip if empty
        sta     temp_len        ; Save it
append_loop:
        lda     input_buffer,x  ; Copy from input buffer
        sta     temp_line+1,y   ; Store in temp_line
        iny
        inx
        cpx     temp_len
        bcc     append_loop
        beq     append_loop
done_append:
        sty     temp_line       ; Update total length

        ;; Add the complete line to history
        ldax    #temp_line
        jsr     AddLineToHistory

        ;; Parse and execute the command
        lda     input_buffer    ; Check if input is empty
        beq     no_command
        jsr     ParseCommand

no_command:
        ;; Adjust scroll position to ensure the new line is visible
        ;; We can show kMaxVisibleLines - 1 history lines (leaving room for prompt)
        ;; So: top_line_index = max(0, total_lines - (kMaxVisibleLines - 1))
        sub16   total_lines, #kMaxVisibleLines-1, temp_scroll
        ;; If temp_scroll < 0, keep top_line_index at 0
        lda     temp_scroll+1
        bmi     no_scroll_adjust
        ;; Otherwise, set top_line_index = max(top_line_index, temp_scroll)
        cmp16   temp_scroll, top_line_index
        bcc     no_scroll_adjust        ; temp_scroll < top_line_index, no change needed
        copy16  temp_scroll, top_line_index

no_scroll_adjust:
        ;; Clear the window and redraw all lines
        MGTK_CALL MGTK::SetPort, winfo::port
        MGTK_CALL MGTK::PaintRect, winfo::maprect

        ;; Set font again after clearing
        MGTK_CALL MGTK::SetFont, monaco_font

        ;; Redraw all visible lines (all except the last)
        jsr     RedrawAllLines

        ;; Position line edit at bottom
        jsr     PositionLineEditAtBottom

        ;; Draw the prompt at the line edit position
        jsr     DrawPrompt

        ;; Update scrollbar
        jsr     UpdateScrollBar

        ;; Clear input buffer
        copy8   #0, input_buffer

        ;; Reactivate line edit
        LETK_CALL LETK::Activate, le_params
        rts

temp_scroll:    .word   0
temp_line:      .res    90, 0  ; Prompt + input (80 + 10 for prompt)
temp_len:       .byte   0
.endproc ; HandleEnter

;;; ============================================================
;;; Parse and execute a command
;;; Input: input_buffer contains the command

.proc ParseCommand
        lda     input_buffer
        bne     :+
        jmp     done
:

        ;; Check first 2 characters for "cd" with argument
        cmp     #4
        bcs     check_cd

        ;; Check exact lengths for other commands
        cmp     #7
        beq     check_version
        jmp     try_external_command

check_cd:
        ;; Check if command starts with "cd "
        lda     input_buffer+1
        jsr     ToUpperCase
        cmp     #'C'
        bne     check_other
        lda     input_buffer+2
        jsr     ToUpperCase
        cmp     #'D'
        bne     check_other
        lda     input_buffer+3
        cmp     #' '
        bne     check_other
        jmp     cmd_cd

check_other:
        lda     input_buffer
        cmp     #7
        beq     check_version
        jmp     try_external_command

check_version:
        ;; Check if command is "version"
        ldx     #0
:       lda     input_buffer+1,x
        jsr     ToUpperCase
        cmp     version_cmd,x
        bne     try_external_command
        inx
        cpx     #7
        bne     :-
        jmp     cmd_version

try_external_command:
        ;; Build command path: /A2.DESKTOP/COMMANDS/<command>
        jsr     BuildCommandPath
        jsr     CopyPathToMain

        ;; Open command file
        JSR_TO_MAIN DoOpenFile
        bcc     open_ok
        jmp     open_failed

open_ok:
        ;; Store ref_num (returned in A)
        sta     read_params_aux + 1
        sta     close_params_aux + 1

        ;; Also store in main params
        sta     RAMRDOFF
        sta     RAMWRTOFF
        sta     read_params_cmd + 1
        sta     close_params_cmd + 1
        sta     RAMRDON
        sta     RAMWRTON

        ;; Read command file to buffer in main memory
        JSR_TO_MAIN DoReadFile
        bcc     read_ok
        jmp     read_failed

read_ok:
        ;; Close the file (we're done with it)
        JSR_TO_MAIN DoCloseFile

        ;; Copy command from $1700 to $0800 in main memory
        JSR_TO_MAIN CopyCommandTo0800

        ;; Execute command at $0800 in main memory
        JSR_TO_MAIN ExecuteCommandInMainMemory

        ;; Restore aux memory
        sta     RAMRDON
        sta     RAMWRTON

        ;; Command wrote output to $0200/$0300 in AUX memory
        ;; Check line count
        lda     kCmdOutputCount
        beq     no_output

        ;; Display the output
        ldax    #kCmdOutputBuffer
        jsr     AddLineToHistory

no_output:
        rts

open_failed:
        ldax    #msg_open_failed
        jsr     AddLineToHistory
        rts

read_failed:
        ldax    #msg_read_failed
        jsr     AddLineToHistory
        rts

external_cmd_error:
        ldax    #err_load_failed
        jsr     AddLineToHistory
        rts

msg_opened: PASCAL_STRING "opened"
msg_read: PASCAL_STRING "read ok"
msg_closed: PASCAL_STRING "closed"
msg_open_failed: PASCAL_STRING "open failed"
msg_read_failed: PASCAL_STRING "read failed"
msg_success: PASCAL_STRING "success"
err_load_failed: PASCAL_STRING "load failed"

done:   rts

;;; ============================================================
;;; Trampoline to execute command in current RamWorks bank
;;;
;;; Called from main memory with bank already switched
;;; This code runs in AUX bank 0, jumps to $0800 in whatever
;;; bank is currently selected
;;; ============================================================

;;; NO LONGER NEEDED - removed bank switching approach

;;; --------------------------------------------------
;;; Execute "version" command

cmd_version:
        ldax    #version_output
        jsr     AddLineToHistory
        rts


;;; --------------------------------------------------
;;; Execute "cd" command - change directory

cmd_cd:
        ;; Extract the path argument (starts at input_buffer+4)
        ;; Copy to cd_path_buffer in aux, then copy to main for ProDOS
        lda     input_buffer    ; Total length
        sec
        sbc     #3              ; Subtract "cd " (3 chars)
        sta     cd_path_buffer  ; Store path length

        ;; Copy path characters
        tax
        beq     cd_done         ; Empty path?
:       lda     input_buffer+3,x ; +3 to skip "cd "
        sta     cd_path_buffer,x
        dex
        bne     :-

cd_done:
        ;; Copy from aux to main using AUXMOVE
        copy16  #cd_path_buffer, STARTLO
        lda     cd_path_buffer
        clc
        adc     #<cd_path_buffer
        sta     ENDLO
        lda     #>cd_path_buffer
        adc     #0
        sta     ENDLO+1
        inc16   ENDLO                   ; Make it end+1
        copy16  #cd_path_main, DESTINATIONLO

        clc                             ; Carry clear = aux to main
        jsr     AUXMOVE

        ;; Call SET_PREFIX in main memory
        JSR_TO_MAIN SetPrefixMain
        bcs     cd_error
        rts

cd_error:
        ldax    #cd_error_msg
        jsr     AddLineToHistory
        rts

cd_error_msg:
        PASCAL_STRING "Error changing directory"
cd_path_buffer: .res    65, 0           ; Aux buffer for cd path

;;; --------------------------------------------------
;;; Data

version_cmd:
        .byte   "VERSION"
version_output:
        PASCAL_STRING "dsh v0.1 alpha release"
.endproc ; ParseCommand

;;; ============================================================

.proc OnMouseMove
        copy8   #kDAWindowId, screentowindow_params::window_id
        MGTK_CALL MGTK::ScreenToWindow, screentowindow_params
        MGTK_CALL MGTK::MoveTo, screentowindow_params::window
        MGTK_CALL MGTK::InRect, line_edit_rec::rect
    IF ZERO
        MGTK_CALL MGTK::SetCursor, MGTK::SystemCursor::pointer
    ELSE
        MGTK_CALL MGTK::SetCursor, MGTK::SystemCursor::ibeam
    END_IF
        jmp     InputLoop
.endproc ; OnMouseMove

;;; ============================================================

.proc OnCloseClick
        MGTK_CALL MGTK::TrackGoAway, trackgoaway_params
        lda     trackgoaway_params::goaway
        beq     :+
        MGTK_CALL MGTK::CloseWindow, winfo
        JSR_TO_MAIN JUMP_TABLE_CLEAR_UPDATES
        rts                     ; Exit the DA
:       jmp     InputLoop
.endproc ; OnCloseClick

.proc DoClose
        MGTK_CALL MGTK::CloseWindow, winfo
        JSR_TO_MAIN JUMP_TABLE_CLEAR_UPDATES
        rts
.endproc ; DoClose

;;; ============================================================

.proc OnTitleBarClick
        copy8   #kDAWindowId, dragwindow_params::window_id
        MGTK_CALL MGTK::DragWindow, dragwindow_params
        bit     dragwindow_params::moved
    IF NS
        JSR_TO_MAIN JUMP_TABLE_CLEAR_UPDATES

        ;; Redraw after move
        MGTK_CALL MGTK::SetPort, winfo::port

        ;; Set monospaced font
        MGTK_CALL MGTK::SetFont, monaco_font

        ;; Draw welcome
        copy16  #kLeftMargin, cursor_pos::xcoord
        copy16  #kTopMargin, cursor_pos::ycoord
        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, welcome_params

        ;; Draw prompt on next line
        add16_8 cursor_pos::ycoord, #kLineHeight
        copy16  #kLeftMargin, cursor_pos::xcoord
        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, prompt_params

        ;; Redraw line edit after window move
        LETK_CALL LETK::Update, le_params
    END_IF
        rts
.endproc ; OnTitleBarClick

;;; ============================================================

        .include "../lib/uppercase.s"
        .include "../lib/get_next_event.s"
        .include "../lib/inttostring.s"

;;; ============================================================
;;; External Command Execution
;;; ============================================================

;;; Helper procs for external command execution


;;; ============================================================
;;; Copy path from aux to main

.proc CopyPathToMain
        ldy     #43
:       lda     command_path_aux,y  ; Read from aux (normal)
        sta     RAMWRTOFF       ; Enable write to main
        sta     command_path_main,y ; Write to main
        sta     RAMWRTON        ; Restore write to aux
        dey
        bpl     :-
        rts
.endproc

;;; ============================================================
;;; Build Command Path
;;; Builds path: /A2.DESKTOP/COMMANDS/<commandname>
;;; Input: input_buffer contains command name
;;; Output: command_path_aux contains full path

.proc BuildCommandPath
        COPY_STRING base_command_path, command_path_aux
        ldy     command_path_aux
        ldx     #0
:       inx
        cpy     #64
        bcs     done
        cpx     input_buffer
        beq     last_char
        bcs     done
        iny
        lda     input_buffer,x
        cmp     #' '
        beq     done
        sta     command_path_aux,y
        jmp     :-
last_char:
        iny
        lda     input_buffer,x
        sta     command_path_aux,y
done:   sty     command_path_aux
        rts

base_command_path:
        PASCAL_STRING "/A2.DESKTOP/COMMANDS/"
.endproc

;;; ============================================================
;;; Command output interface in aux memory
;;; ============================================================

kCmdOutputBuffer = $0200        ; Output buffer location
kCmdOutputCount  = $0300        ; Output line count location

;;; ============================================================
;;; RamWorks Detection

.proc DetectRamWorks
        ;; Call detection routine in main memory
        JSR_TO_MAIN CheckRamWorksMain
        ;; Y register contains bank count (0 = 256)
        sty     ramworks_banks

        ;; Build welcome message with bank count
        ;; Convert bank count to string
        lda     ramworks_banks
        beq     is_256          ; 0 means 256 banks
        ldx     #0              ; High byte = 0
        jsr     IntToString     ; A = low byte, X = high byte
        jmp     copy_str

is_256: ldax    #256
        jsr     IntToString

copy_str:
        ;; Copy "Welcome to dsh - "
        COPY_STRING welcome_prefix, welcome_string

        ;; Append bank count from str_from_int
        ldy     welcome_string          ; Get current length
        ldx     #0                      ; Start at index 0 (will increment to 1)
:       inx
        iny
        lda     str_from_int,x          ; Copy character
        sta     welcome_string,y
        cpx     str_from_int            ; Compare with length byte
        bne     :-                      ; Continue until we've copied all chars
        sty     welcome_string          ; Update length

        ;; Append " RamWorks banks"
        ldy     welcome_string          ; Get current length
        ldx     #0                      ; Start at index 0 (will increment to 1)
:       inx
        iny
        lda     ramworks_suffix,x       ; Copy character
        sta     welcome_string,y
        cpx     ramworks_suffix         ; Compare with length byte
        bne     :-                      ; Continue until we've copied all chars
        sty     welcome_string          ; Update length

        rts
.endproc ; DetectRamWorks

;;; ============================================================
;;; Aux buffers

prefix_buffer_aux:   .res    45, 0
ramworks_banks:      .byte   0
command_path_aux:    .res    44, 0

;;; ============================================================
;;; MLI parameter blocks in aux memory (keep in sync with main copy!)

        DEFINE_OPEN_PARAMS open_params_aux, command_path_main, DA_IO_BUFFER
        DEFINE_READWRITE_PARAMS read_params_aux, read_buffer_main, 1024
        DEFINE_CLOSE_PARAMS close_params_aux

;;; ============================================================

        DA_END_AUX_SEGMENT

;;; ============================================================

        DA_START_MAIN_SEGMENT
        jmp     Start

;;; ============================================================

        MLIEntry := MLI

;;; ============================================================
;;; External command constants (repeated for main segment)

kCommandBank    = 2             ; Use bank 2 for external commands
kCommandStart   = $0800         ; Start address in RamWorks bank
kCommandEnd     = $BFFF         ; End of usable bank-switched memory
kMaxCommandSize = kCommandEnd - kCommandStart + 1  ; $B400 = 46,080 bytes

;;; Command output interface (same addresses as in aux segment)
kCmdOutputBuffer = $0200        ; Output buffer location
kCmdOutputCount  = $0300        ; Output line count location

;;; ============================================================

.proc Start
        JSR_TO_AUX aux::Init
        rts
.endproc ; Start

;;; ============================================================
;;; ProDOS GET_PREFIX helper (must be in main memory)

prefix_buffer_main:  .res    65, 0      ; ProDOS prefix buffer (max 64 chars + length)
cd_path_main:        .res    65, 0      ; Main memory buffer for cd path

DEFINE_GET_PREFIX_PARAMS getprefix_params_main, prefix_buffer_main
DEFINE_SET_PREFIX_PARAMS setprefix_params_main, cd_path_main

;;; Call ProDOS GET_PREFIX - result left in prefix_buffer_main
;;; Output: C set on error
.proc GetPrefixMain
        JUMP_TABLE_MLI_CALL GET_PREFIX, getprefix_params_main
        rts
.endproc

;;; Test procedure right after GetPrefixMain
.proc TestOpenFile
        ;; Just test if OPEN works from here
        ;; params will be defined later, so just use addresses
        jsr     JUMP_TABLE_MLI_CALL
        .byte   OPEN
        .addr   $0000  ; dummy for now
        rts
.endproc

;;; Call ProDOS SET_PREFIX - uses cd_path_main as source
;;; Output: C set on error
.proc SetPrefixMain
        JUMP_TABLE_MLI_CALL SET_PREFIX, setprefix_params_main
        rts
.endproc

;;; ============================================================
;;; Detect RamWorks banks (based on this.apple.s CheckRamworksMemory)
;;; Output: Y = number of banks (0 = 256 banks)
;;; Note: Must be called from main memory with interrupts enabled

.proc CheckRamWorksMain
        sigb0   := $00
        sigb1   := $01

        ;; DAs are loaded with $1C00 as the io_buffer, so
        ;; $1C00-$1FFF MAIN is free.
        buf0    := DA_IO_BUFFER
        buf1    := DA_IO_BUFFER + $100

        php
        sei     ; don't let interrupts happen while memory map is munged

        ldy     #0              ; populated bank count

        ;; Mark pass: iterate downwards, saving bytes and marking each bank
        ldx     #255
mark_loop:
        stx     RAMWORKS_BANK
        copy8   sigb0, buf0,x   ; preserve bytes
        copy8   sigb1, buf1,x
        txa                     ; bank num as first signature
        sta     sigb0
        eor     #$FF            ; complement as second signature
        sta     sigb1
        dex
        cpx     #$FF
        bne     mark_loop

        ;; Count pass: iterate upwards, tallying valid banks
        ldx     #0
count_loop:
        stx     RAMWORKS_BANK
        txa
        cmp     sigb0           ; verify first signature
        bne     :+
        eor     #$FF
        cmp     sigb1           ; verify second signature
        bne     :+
        iny                     ; match - count it
:       inx
        bne     count_loop

        ;; Restore pass: iterate upwards, restoring valid banks
        ldx     #0
restore_loop:
        stx     RAMWORKS_BANK
        txa
        cmp     sigb0           ; verify first signature
        bne     :+
        eor     #$FF
        cmp     sigb1           ; verify second signature
        bne     :+
        copy8   buf0,x, sigb0   ; match - restore it
        copy8   buf1,x, sigb1
:       inx
        bne     restore_loop

        ;; Switch back to bank 0 (normal aux memory)
        copy8   #0, RAMWORKS_BANK

        plp                     ; restore interrupt state
        rts
.endproc ; CheckRamWorksMain

;;; ============================================================
;;; Load Command File to RamWorks Bank 2
;;; Input: command_path_aux (in aux memory) contains path
;;; Output: Carry set on error
;;; Note: Must be called from main memory


;;; ============================================================
;;; Main segment buffers

command_path_main:      .res    44, 0
file_ref:               .byte   0

;;; ============================================================
;;; Load Command File to Main Buffer (main segment)

;;; Parameter blocks and buffers
bytes_loaded:
        .word   0

test_hardcoded_path:
        PASCAL_STRING "/A2.DESKTOP/READ.ME"

DEFINE_OPEN_PARAMS test_open_params, test_hardcoded_path, DA_IO_BUFFER
DEFINE_READWRITE_PARAMS test_read_params, DA_IO_BUFFER, 1024
DEFINE_CLOSE_PARAMS test_close_params

;;; Keep in sync with aux copy!
mli_params_main:
        DEFINE_OPEN_PARAMS open_params_cmd, command_path_main, DA_IO_BUFFER
        DEFINE_READWRITE_PARAMS read_params_cmd, read_buffer_main, 1024
        DEFINE_CLOSE_PARAMS close_params_cmd
sizeof_mli_params_main = * - mli_params_main

;;; Read buffer in main memory (can't use DA_IO_BUFFER as MLI uses it)
read_buffer_main := $1700
        .assert read_buffer_main + 1024 <= DA_IO_BUFFER, error, "buffer overlap"

;; Just OPEN - minimal code
.proc DoOpenFile
        jsr     CopyParamsAuxToMain
        sta     ALTZPOFF        ; Switch to main ZP
        MLI_CALL OPEN, open_params_cmd
        sta     ALTZPON         ; Switch back to aux ZP
        php                     ; Save status
        lda     open_params_cmd::ref_num  ; Get ref_num
        tax                     ; Save in X
        plp                     ; Restore status
        jsr     CopyParamsMainToAux  ; Preserves A and P
        txa                     ; Return ref_num in A
        rts
.endproc

;; Just READ - minimal code
.proc DoReadFile
        ;; Don't call CopyParamsAuxToMain - we already set ref_num in main params
        sta     ALTZPOFF        ; Switch to main ZP
        MLI_CALL READ, read_params_cmd
        php                     ; Save status (includes carry)
        ;; Read trans_count and store to bytes_loaded while still in main memory mode
        lda     read_params_cmd::trans_count
        sta     bytes_loaded
        lda     read_params_cmd::trans_count+1
        sta     bytes_loaded+1
        plp                     ; Restore status (including carry)
        sta     ALTZPON         ; Switch back to aux ZP (doesn't affect carry)
        rts
.endproc

;; Just CLOSE - minimal code
.proc DoCloseFile
        jsr     CopyParamsAuxToMain
        sta     ALTZPOFF        ; Switch to main ZP
        MLI_CALL CLOSE, close_params_cmd
        sta     ALTZPON         ; Switch back to aux ZP
        jmp     CopyParamsMainToAux  ; Preserves A and P, returns
.endproc

;;; ============================================================
;;; Copy parameter blocks between aux and main memory

;;; Copies param blocks from Aux to Main
.proc CopyParamsAuxToMain
        copy16  #aux::open_params_aux, STARTLO
        copy16  #aux::close_params_aux + 1, ENDLO  ; end of close_params
        copy16  #mli_params_main, DESTINATIONLO
        TAIL_CALL AUXMOVE, C=0  ; aux>main
.endproc ; CopyParamsAuxToMain

;;; Copies param blocks from Main to Aux
;;; Preserves A and P
.proc CopyParamsMainToAux
        php
        pha

        copy16  #mli_params_main, STARTLO
        copy16  #mli_params_main + sizeof_mli_params_main - 1, ENDLO
        copy16  #aux::open_params_aux, DESTINATIONLO
        CALL    AUXMOVE, C=1    ; main>aux

        pla
        plp
        rts
.endproc ; CopyParamsMainToAux

;;; ============================================================

;; Read file and execute - called via JSR from DoOpenAndChain
.proc DoReadAndExecute
        JUMP_TABLE_MLI_CALL READ, read_params_cmd
        php             ; Save read status

        ;; Store bytes read
        lda     read_params_cmd::trans_count
        sta     bytes_loaded
        lda     read_params_cmd::trans_count+1
        sta     bytes_loaded+1

        ;; Close the file
        JUMP_TABLE_MLI_CALL CLOSE, close_params_cmd

        plp             ; Restore read status
        bcs     error

        ;; Check we got some bytes
        lda     bytes_loaded
        ora     bytes_loaded+1
        beq     error

        ;; Copy from DA_IO_BUFFER (main) to $0800 (aux)
        ldx     bytes_loaded
        lda     bytes_loaded+1
        bne     cap_256
        cpx     #0
        beq     error
        jmp     do_copy
cap_256:
        ldx     #0

do_copy:
        ldy     #0
loop:   lda     DA_IO_BUFFER,y
        sta     RAMWRTOFF
        sta     kCommandStart,y
        sta     RAMWRTON
        iny
        dex
        bne     loop

        ;; Execute in aux
        sta     RAMRDOFF
        sta     RAMWRTOFF
        jsr     kCommandStart
        sta     RAMRDON
        sta     RAMWRTON

        clc
        rts

error:  sec
        rts
.endproc

;;; ============================================================
;;; RamWorks Trampoline - Execute Command in Bank 2
;;;
;;; This code runs in MAIN memory and is not affected by RamWorks
;;; bank switching. It switches to bank 2, executes the command,
;;; and switches back to bank 0.
;;;
;;; Called from aux memory via JSR_TO_MAIN
;;; ============================================================

.proc CopyCommandTo0800
        ;; Copy from $1700 to $0800 in main memory
        ldy     bytes_loaded
        beq     done
:       lda     read_buffer_main-1,y
        sta     $0800-1,y
        dey
        bne     :-
done:   rts
.endproc

.proc ExecuteCommandInMainMemory
        ;; Command is now at $0800 in main memory (its expected location)
        ;; Set up: write to aux (for output buffer), but read from main
        sta     RAMRDOFF        ; Read from main
        sta     RAMWRTON        ; Write to aux

        ;; Call command at $0800
        jsr     $0800

        ;; DON'T restore memory here - caller will do it
        rts
.endproc

;;; ============================================================
;;; Copy Command to Bank 2
;;;
;;; Copies command from read_buffer_main to bank 2 aux $0800
;;; Input: bytes_loaded = number of bytes to copy
;;; ============================================================

.proc CopyCommandToBank2
        ;; Get byte count
        lda     bytes_loaded
        sta     copy_count
        lda     bytes_loaded+1
        sta     copy_count+1

        ;; Check for zero bytes
        ora     copy_count
        beq     done

        ;; Switch to RamWorks bank 2
        lda     #kCommandBank
        sta     RAMWORKS_BANK

        ;; Set up memory: read main, write aux
        sta     RAMRDOFF
        sta     RAMWRTON

        ;; Copy first page (up to 256 bytes)
        ldy     #0
        ldx     copy_count      ; Low byte of count
        beq     check_high      ; If low byte is 0, only copy high byte pages

copy_first:
        lda     read_buffer_main,y
        sta     kCommandStart,y
        iny
        dex
        bne     copy_first

check_high:
        ;; Check if we have more pages to copy
        dec     copy_count+1
        bmi     copy_done       ; If high byte was 0, we're done

        ;; Copy additional 256-byte pages
        ldx     copy_count+1    ; Number of additional pages
copy_page:
        lda     read_buffer_main,y
        sta     kCommandStart,y
        iny
        bne     copy_page
        dex
        bne     copy_page

copy_done:
        ;; Switch back to bank 0
        lda     #0
        sta     RAMWORKS_BANK

        ;; DON'T restore aux memory yet - we're still executing in main!
        ;; The caller (aux code) will restore memory state after return

done:   rts

copy_count:
        .word   0
.endproc

;;; ============================================================
;;; Read Output from Bank 2
;;;
;;; Reads command output from bank 2 and copies to bank 0
;;; Output: A = line count (0 if no output)
;;; ============================================================

.proc ReadOutputFromBank2
        ;; Switch to RamWorks bank 2
        lda     #kCommandBank
        sta     RAMWORKS_BANK

        ;; Set up memory: read aux, write aux
        sta     RAMRDON
        sta     RAMWRTON

        ;; Read line count from $0300 in bank 2
        lda     kCmdOutputCount
        pha                     ; Save for return value

        ;; Check if there's output to copy
        beq     no_output

        ;; Copy output buffer from bank 2 to bank 0
        ;; We'll copy up to 256 bytes (plenty for output buffer)
        ldy     #0
copy_loop:
        lda     kCmdOutputBuffer,y
        pha                     ; Save byte

        ;; Switch to bank 0 to write
        lda     #0
        sta     RAMWORKS_BANK

        pla                     ; Restore byte
        sta     kCmdOutputBuffer,y

        ;; Switch back to bank 2 to read next byte
        lda     #kCommandBank
        sta     RAMWORKS_BANK

        iny
        cpy     #$FF            ; Copy up to 255 bytes
        bne     copy_loop

no_output:
        ;; Switch back to bank 0
        lda     #0
        sta     RAMWORKS_BANK

        ;; Restore read/write to aux
        sta     RAMRDON
        sta     RAMWRTON

        pla                     ; Return line count in A
        rts
.endproc

;;; ============================================================

        DA_END_MAIN_SEGMENT

;;; ============================================================
