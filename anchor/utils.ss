;;; utils.ss — shared helpers for the Anchor compiler

(define *gensym-counter* 0)

(define (anchor-gensym base)
  (set! *gensym-counter* (fx+ *gensym-counter* 1))
  (string->symbol
    (string-append (symbol->string base) "_G"
                   (number->string *gensym-counter*))))

;; ---------------------------------------------------------------------------
;; Source locations
;; ---------------------------------------------------------------------------

(define (format-src src)
  (if src
      (string-append (car src) ":" (number->string (cadr src)) ":" (number->string (caddr src)) ": ")
      ""))

(define (anchor-error msg . irritants)
  (apply error "anchorc" msg irritants))

(define (anchor-error/loc form msg . irritants)
  (let ([src (stx-loc form)])
    (apply error "anchorc" (string-append (format-src src) msg) irritants)))

;; ---------------------------------------------------------------------------
;; Syntax objects — KFFD hygiene marks
;; ---------------------------------------------------------------------------

;; A syntax object pairs an identifier with its mark set and source location.
;; src is (file line col) or #f.
(define-record-type stx
  (fields
    (immutable sym   stx-sym)
    (immutable marks stx-marks)
    (immutable src   stx-src)))

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

;; Find the src of the first stx in form.
(define (stx-loc form)
  (cond
    [(stx? form)  (stx-src form)]
    [(pair? form) (or (stx-loc (car form)) (stx-loc (cdr form)))]
    [else         #f]))

;; Add mark m to every identifier in form, preserving src.
;; XOR property: (add-mark (add-mark form m) m) = form.
(define (add-mark form m)
  (cond
    [(symbol? form) (make-stx form (list m) #f)]
    [(stx? form)    (make-stx (stx-sym form) (mark-flip (stx-marks form) m) (stx-src form))]
    [(pair? form)   (cons (add-mark (car form) m) (add-mark (cdr form) m))]
    [else form]))

;; ---------------------------------------------------------------------------
;; local-expand — let macro-case transformers expand subforms on demand
;; ---------------------------------------------------------------------------

(define *current-expand* (make-parameter #f))

(define (local-expand form)
  (let ([exp (*current-expand*)])
    (unless exp
      (anchor-error "local-expand: called outside macro expansion"))
    (exp form)))

;;; Read entire file into a string
(define (read-file path)
  (call-with-port (open-input-file path)
    (lambda (p)
      (let loop ([chars '()])
        (let ([c (read-char p)])
          (if (eof-object? c)
              (list->string (reverse chars))
              (loop (cons c chars))))))))
