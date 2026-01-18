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

welcome_string:
        PASCAL_STRING "Welcome to dsh."

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

kMaxHistoryLines = 16           ; Maximum number of lines to keep in history
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

;;; ============================================================

        DA_END_AUX_SEGMENT

;;; ============================================================

        DA_START_MAIN_SEGMENT
        jmp     Start

;;; ============================================================

.proc Start
        JSR_TO_AUX aux::Init
        rts
.endproc ; Start

        DA_END_MAIN_SEGMENT

;;; ============================================================
