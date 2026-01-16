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

;;; Simple redraw flag - just redraw welcome + prompt for now
needs_redraw:   .byte   0

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

;;; Cursor drawing params
.params cursor_line
xdelta: .word   0
ydelta: .word   AS_WORD(-kLineHeight)
.endparams

.params penXOR
penmode:        .byte   MGTK::pencopy|MGTK::notpencopy  ; XOR mode
.endparams

.params penCopy
penmode:        .byte   MGTK::pencopy
.endparams

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

        add16_8 cursor_pos::xcoord, #35
        copy8   #0, input_pos

        ;; Draw initial cursor
        jsr     DrawCursor

        MGTK_CALL MGTK::FlushEvents
        jmp     InputLoop
.endproc ; Init

;;; ============================================================

.proc InputLoop
        JSR_TO_MAIN JUMP_TABLE_SYSTEM_TASK
        MGTK_CALL MGTK::GetEvent, event_params
        lda     event_params
        cmp     #MGTK::EventKind::key_down
        beq     OnKeyDown
        cmp     #MGTK::EventKind::button_down
        bne     InputLoop

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
        jmp     InputLoop

title:  jsr     OnTitleBarClick
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

        jmp     InputLoop

no_mod:
        lda     event_params::key

        cmp     #CHAR_ESCAPE
        jeq     DoClose

        cmp     #CHAR_RETURN
        beq     HandleReturn

        cmp     #CHAR_DELETE
        beq     HandleBackspace

        cmp     #CHAR_LEFT
        beq     HandleBackspace

        cmp     #' '
        bcc     InputLoop
        cmp     #$7F
        bcs     InputLoop

        jsr     HandleChar
        jmp     InputLoop

HandleReturn:
        jsr     HandleEnter
        jmp     InputLoop

HandleBackspace:
        jsr     HandleDelete
        jmp     InputLoop
.endproc ; OnKeyDown

;;; ============================================================

.proc HandleChar
        lda     input_pos
        cmp     #kInputBufferSize-1
        bcs     done

        ;; Erase cursor at current position
        jsr     DrawCursor

        tax
        lda     event_params::key
        sta     input_buffer,x
        inc     input_pos

        sta     char_buf

        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, char_params

        add16_8 cursor_pos::xcoord, #7

        ;; Draw cursor at new position
        jsr     DrawCursor

done:   rts
.endproc ; HandleChar

;;; ============================================================

.proc HandleEnter
        ;; Erase cursor at current position
        jsr     DrawCursor

        add16_8 cursor_pos::ycoord, #kLineHeight
        copy16  #kLeftMargin, cursor_pos::xcoord

        lda     cursor_pos::ycoord+1
        bne     reset
        lda     cursor_pos::ycoord
        cmp     #(kDAHeight - kLineHeight)
        bcc     draw_prompt

reset:  copy16  #kTopMargin, cursor_pos::ycoord

draw_prompt:
        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, prompt_params

        add16_8 cursor_pos::xcoord, #35

        copy8   #0, input_pos

        ;; Draw cursor at new position
        jsr     DrawCursor
        rts
.endproc ; HandleEnter

;;; ============================================================

.proc HandleDelete
        lda     input_pos
        beq     done

        ;; Erase cursor at current position
        jsr     DrawCursor

        dec     input_pos

        sub16_8 cursor_pos::xcoord, #7

        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::DrawText, space_params

        ;; Draw cursor at new position
        jsr     DrawCursor

done:   rts
.endproc ; HandleDelete

;;; ============================================================

.proc OnCloseClick
        MGTK_CALL MGTK::TrackGoAway, trackgoaway_params
        lda     trackgoaway_params::goaway
        bne     DoClose
        jmp     InputLoop
.endproc ; OnCloseClick

.proc DoClose
        MGTK_CALL MGTK::CloseWindow, winfo
        JSR_TO_MAIN JUMP_TABLE_CLEAR_UPDATES
        rts
.endproc ; DoClose

;;; ============================================================
;;; Draw text cursor at current position

.proc DrawCursor
        MGTK_CALL MGTK::MoveTo, cursor_pos
        MGTK_CALL MGTK::SetPenMode, penXOR
        MGTK_CALL MGTK::Line, cursor_line
        MGTK_CALL MGTK::SetPenMode, penCopy
        rts
.endproc ; DrawCursor

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

        add16_8 cursor_pos::xcoord, #35
        copy8   #0, input_pos

        ;; Redraw cursor after window move
        jsr     DrawCursor
    END_IF
        rts
.endproc ; OnTitleBarClick

;;; ============================================================

        .include "../lib/uppercase.s"

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
