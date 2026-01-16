;;; ============================================================
;;; DSH - Desk Accessory
;;;
;;; Desktop Shell - A simple shell interface.
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
;;; Memory map
;;;
;;;              Main           Aux
;;;          :           : :           :
;;;          |           | |           |
;;;          | DHR       | | DHR       |
;;;  $2000   +-----------+ +-----------+
;;;          |           | |           |
;;;          |           | |           |
;;;          |           | |           |
;;;          |           | | UI code & |
;;;          |           | | resources |
;;;   $800   +-----------+ +-----------+
;;;          :           : :           :

;;; ============================================================

        DA_HEADER
        DA_START_AUX_SEGMENT

;;; ============================================================

        .include "../lib/event_params.s"

.params trackgoaway_params      ; queried after close clicked to see if aborted/finished
goaway:         .byte   0       ; 0 = aborted, 1 = clicked
.endparams

kDALeft    = 10
kDATop     = 28
kDAWidth   = 512
kDAHeight  = 150

kDAWindowId = $80

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

.params welcome_pos
xcoord: .word   10
ycoord: .word   20
.endparams

.params welcome_params
textptr:        .addr   welcome_string+1
textlen:        .byte   .strlen("Welcome to dsh.")
.endparams

;;; ============================================================
;;; Create the DA window and display welcome message

.proc Init
        ;; Create window
        MGTK_CALL MGTK::OpenWindow, winfo
        MGTK_CALL MGTK::SetPort, winfo::port

        ;; Draw welcome message
        MGTK_CALL MGTK::MoveTo, welcome_pos
        MGTK_CALL MGTK::DrawText, welcome_params

        MGTK_CALL MGTK::FlushEvents
        FALL_THROUGH_TO InputLoop
.endproc ; Init

;;; ============================================================
;;; Main Input Loop

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

        ;; Which part of the window?
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
;;; Key handling

.proc OnKeyDown
        ldx     event_params::modifiers
        beq     no_mod

        ;; Modifiers
        lda     event_params::key
        jsr     ToUpperCase

        cmp     #kShortcutCloseWindow
        jeq     DoClose

        jmp     InputLoop

        ;; No modifiers
no_mod:
        lda     event_params::key

        cmp     #CHAR_ESCAPE
        jeq     DoClose

        jmp     InputLoop
.endproc ; OnKeyDown

;;; ============================================================
;;; Click on Close Button

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
;;; Click on Title Bar

.proc OnTitleBarClick
        copy8   #kDAWindowId, dragwindow_params::window_id
        MGTK_CALL MGTK::DragWindow, dragwindow_params
        bit     dragwindow_params::moved
    IF NS
        JSR_TO_MAIN JUMP_TABLE_CLEAR_UPDATES
    END_IF
        rts
.endproc ; OnTitleBarClick

;;; ============================================================

        .include "../lib/uppercase.s"

;;; ============================================================

        DA_END_AUX_SEGMENT

;;; ============================================================
;;; Main Segment
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
