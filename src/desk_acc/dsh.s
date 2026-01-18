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
vscroll:        .byte   MGTK::Scroll::option_none
hthumbmax:      .byte   0
hthumbpos:      .byte   0
vthumbmax:      .byte   0
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

.proc Init
        MGTK_CALL MGTK::OpenWindow, winfo
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

        ;; Initialize input buffer
        copy8   #0, input_buffer

        ;; Initialize and activate line edit control
        LETK_CALL LETK::Init, le_params
        LETK_CALL LETK::Activate, le_params

        MGTK_CALL MGTK::FlushEvents
        jmp     InputLoop
.endproc ; Init

;;; ============================================================

.proc InputLoop
        LETK_CALL LETK::Idle, le_params
        JSR_TO_MAIN JUMP_TABLE_SYSTEM_TASK
        jsr     GetNextEvent
        lda     event_params
        cmp     #MGTK::EventKind::key_down
        beq     OnKeyDown
        cmp     #MGTK::EventKind::button_down
        beq     OnButtonDown
        cmp     #kEventKindMouseMoved
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
        ;; Content click - convert to window coords and pass to LETK
        copy8   #kDAWindowId, screentowindow_params::window_id
        MGTK_CALL MGTK::ScreenToWindow, screentowindow_params
        COPY_STRUCT screentowindow_params::window, le_params::coords
        LETK_CALL LETK::Click, le_params
        jmp     InputLoop
.endproc ; OnButtonDown

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

        ;; Move to next line
        add16_8 cursor_pos::ycoord, #kLineHeight
        copy16  #kLeftMargin, cursor_pos::xcoord

        ;; Check if we're past the bottom of the window
        lda     cursor_pos::ycoord+1
        bne     wrap_to_top         ; High byte set, definitely too far
        lda     cursor_pos::ycoord
        cmp     #(kDAHeight - kLineHeight)
        bcc     draw_prompt

wrap_to_top:
        ;; Wrap back to top
        copy16  #kTopMargin, cursor_pos::ycoord

draw_prompt:
        ;; Update line edit rect y1 and y2 to new line position
        ;; LineEditRecord layout: window_id(1), a_buf(2), rect(8 bytes: x1,y1,x2,y2)
        ;; rect.y1 is at offset 5, rect.y2 is at offset 9
        ;; cursor_pos::ycoord is the text baseline, rect.y1 should be kLineHeight above it
        sub16   cursor_pos::ycoord, #kLineHeight, line_edit_rec+5  ; rect.y1
        add16   line_edit_rec+5, #kTextBoxHeight, line_edit_rec+9  ; rect.y2

        ;; Draw prompt
        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, prompt_params

        ;; Clear input buffer
        copy8   #0, input_buffer

        ;; Reactivate line edit (moves caret to end, which is the beginning since buffer is empty)
        LETK_CALL LETK::Activate, le_params
        rts
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
