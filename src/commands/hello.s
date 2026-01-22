;;; ============================================================
;;; HELLO - External command for dsh
;;;
;;; Prints "hello" and returns to dsh
;;; ============================================================

        .include "../config.inc"
        .include "../inc/apple2.inc"
        .include "../inc/macros.inc"

;;; ============================================================
;;; Command Interface Convention:
;;;
;;; Entry: Command starts at $0800
;;; Exit:  RTS to return to dsh
;;; Output: Write Pascal strings to output_buffer ($0200-$02FF)
;;;         Set output_count to number of lines (max 10)
;;;
;;; Memory Map in RamWorks Bank 2:
;;;   $0200-$02FF: output_buffer (up to 10 lines, Pascal strings)
;;;   $0300:       output_count (number of lines to print)
;;;   $0800-$BFFF: Command code and data
;;; ============================================================

;;; Command entry point at $0800
        .org $0800

.proc HelloCommand
        ;; Write "hello" to output_buffer at $0200
        lda     #5                      ; Length of "hello"
        sta     $0200                   ; output_buffer

        lda     #'h'
        sta     $0201
        lda     #'e'
        sta     $0202
        lda     #'l'
        sta     $0203
        lda     #'l'
        sta     $0204
        lda     #'o'
        sta     $0205

        ;; Set output_count at $0300 to 1 line
        lda     #1
        sta     $0300

        rts
.endproc

;;; ============================================================

