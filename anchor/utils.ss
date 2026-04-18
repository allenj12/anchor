;;; utils.ss — shared helpers for the Anchor compiler

(define *gensym-counter* 0)

(define (anchor-gensym base)
  (set! *gensym-counter* (fx+ *gensym-counter* 1))
  (string->symbol
    (string-append (symbol->string base) "_G"
                   (number->string *gensym-counter*))))

(define (anchor-error msg . irritants)
  (apply error "anchorc" msg irritants))

;; ---------------------------------------------------------------------------
;; Syntax objects — KFFD hygiene marks
;; ---------------------------------------------------------------------------

;; A syntax object pairs an identifier with its mark set.
;; Marks track which macro application introduced the identifier.
;; Naming the type 'stx' gives us make-stx / stx? / stx-sym / stx-marks for free.
(define-record-type stx
  (fields
    (immutable sym   stx-sym)
    (immutable marks stx-marks)))

(define *mark-clock* 0)
(define (fresh-mark)
  (set! *mark-clock* (fx+ *mark-clock* 1))
  *mark-clock*)

;; Toggle mark m (XOR): present → remove, absent → add.
(define (mark-flip marks m)
  (if (memv m marks)
      (filter (lambda (x) (not (fx= x m))) marks)
      (cons m marks)))

;; Strip any stx wrapper; return the base symbol.
(define (id-sym x) (if (stx? x) (stx-sym x) x))

;; Add mark m to every identifier in form.
;; XOR property: (add-mark (add-mark form m) m) = form, so applying the same
;; mark twice cancels — user-provided identifiers come back clean.
(define (add-mark form m)
  (cond
    [(symbol? form) (make-stx form (list m))]
    [(stx? form)    (make-stx (stx-sym form) (mark-flip (stx-marks form) m))]
    [(pair? form)   (cons (add-mark (car form) m) (add-mark (cdr form) m))]
    [else form]))

;;; Read entire file into a string
(define (read-file path)
  (call-with-port (open-input-file path)
    (lambda (p)
      (let loop ([chars '()])
        (let ([c (read-char p)])
          (if (eof-object? c)
              (list->string (reverse chars))
              (loop (cons c chars))))))))
