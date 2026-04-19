;;; reader.ss — Anchor tokenizer and parser
;;;
;;; AST uses native Chez types:
;;;   symbols   → Chez symbols
;;;   integers  → Chez exact integers
;;;   floats    → Chez inexact reals
;;;   strings   → Chez strings
;;;   lists     → Chez proper lists
;;;   char literals → exact integers (Unicode codepoint)
;;;
;;; Reader macros expand inline:
;;;   'x  → (quote x)
;;;   `x  → (quasiquote x)
;;;   ,x  → (unquote x)
;;;   ,@x → (unquote-splicing x)

;; ---------------------------------------------------------------------------
;; Tokenizer
;; ---------------------------------------------------------------------------

(define (anchor-tokenize src)
  (let ([len (string-length src)]
        [tokens '()])
    (let loop ([i 0])
      (if (fx>= i len)
          (reverse tokens)
          (let ([c (string-ref src i)])
            (cond
              ;; Whitespace — skip
              [(char-whitespace? c)
               (loop (fx+ i 1))]
              ;; Line comment — skip to end of line
              [(char=? c #\;)
               (let skip ([j i])
                 (if (or (fx>= j len) (char=? (string-ref src j) #\newline))
                     (loop j)
                     (skip (fx+ j 1))))]
              ;; ,@ must come before , check
              [(and (char=? c #\,)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\@))
               (set! tokens (cons ",@" tokens))
               (loop (fx+ i 2))]
              ;; #,@ must come before #, and #'
              [(and (char=? c #\#)
                    (fx< (fx+ i 2) len)
                    (char=? (string-ref src (fx+ i 1)) #\,)
                    (char=? (string-ref src (fx+ i 2)) #\@))
               (set! tokens (cons "#,@" tokens))
               (loop (fx+ i 3))]
              ;; #, unsyntax: #,x → (unsyntax x)
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\,))
               (set! tokens (cons "#," tokens))
               (loop (fx+ i 2))]
              ;; #' syntax shorthand: #'x → (syntax x)
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\'))
               (set! tokens (cons "#'" tokens))
               (loop (fx+ i 2))]
              ;; #` quasisyntax: #`x → (quasisyntax x)
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\`))
               (set! tokens (cons "#`" tokens))
               (loop (fx+ i 2))]
              ;; Single-char tokens: ( ) [ ] ` ' ,
              [(memv c '(#\( #\) #\[ #\] #\` #\' #\,))
               (set! tokens (cons (string c) tokens))
               (loop (fx+ i 1))]
              ;; String literal
              [(char=? c #\")
               (let-values ([(tok j) (read-string src i len)])
                 (set! tokens (cons tok tokens))
                 (loop j))]
              ;; Char literal: \x... or \<single>
              [(and (char=? c #\\)
                    (fx< (fx+ i 1) len)
                    (not (char-whitespace? (string-ref src (fx+ i 1))))
                    (not (memv (string-ref src (fx+ i 1)) '(#\( #\) #\[ #\] #\" #\; #\`  #\' #\,))))
               (let-values ([(tok j) (read-char-literal src i len)])
                 (set! tokens (cons tok tokens))
                 (loop j))]
              ;; Atom (symbol or number)
              [else
               (let-values ([(tok j) (read-atom src i len)])
                 (set! tokens (cons tok tokens))
                 (loop j))]))))))

(define (read-string src start len)
  ;; Returns (raw-token-string end-index) where raw token includes surrounding quotes
  (let loop ([i (fx+ start 1)] [chars (list #\")])
    (when (fx>= i len)
      (anchor-error "unterminated string literal"))
    (let ([c (string-ref src i)])
      (cond
        [(char=? c #\")
         (values (list->string (reverse (cons #\" chars))) (fx+ i 1))]
        [(char=? c #\\)
         (when (fx>= (fx+ i 1) len)
           (anchor-error "truncated escape in string"))
         (loop (fx+ i 2) (cons (string-ref src (fx+ i 1)) (cons #\\ chars)))]
        [else
         (loop (fx+ i 1) (cons c chars))]))))

(define (read-char-literal src start len)
  ;; \xHH...  or  \<single-non-whitespace-char>
  ;; Returns (raw-token-string end-index)
  (let ([next (string-ref src (fx+ start 1))])
    (if (and (char=? next #\x)
             (fx< (fx+ start 2) len)
             (hex-digit? (string-ref src (fx+ start 2))))
        ;; \xHH+ hex char literal — consume all hex digits
        (let loop ([i (fx+ start 2)] [chars '(#\x #\\)])
          (if (and (fx< i len) (hex-digit? (string-ref src i)))
              (loop (fx+ i 1) (cons (string-ref src i) chars))
              (values (list->string (reverse chars)) i)))
        ;; \<char> single char literal
        (values (string #\\ next) (fx+ start 2)))))

(define (read-atom src start len)
  (let loop ([i start] [chars '()])
    (if (or (fx>= i len)
            (let ([c (string-ref src i)])
              (or (char-whitespace? c)
                  (memv c '(#\( #\) #\[ #\] #\" #\; #\` #\' #\,)))))
        (values (list->string (reverse chars)) i)
        (loop (fx+ i 1) (cons (string-ref src i) chars)))))

(define (hex-digit? c)
  (or (char<=? #\0 c #\9)
      (char<=? #\a c #\f)
      (char<=? #\A c #\F)))

;; ---------------------------------------------------------------------------
;; Parser — tokens → AST
;; ---------------------------------------------------------------------------

(define *reader-macros*
  '(("'"  . quote)
    ("`"  . quasiquote)
    (","  . unquote)
    (",@" . unquote-splicing)
    ("#'" . syntax)
    ("#`" . quasisyntax)
    ("#," . unsyntax)
    ("#,@" . unsyntax-splicing)))

(define (anchor-parse src)
  (let* ([tokens (anchor-tokenize src)]
         [tv     (list->vector tokens)]
         [pos    (list 0)])
    (let loop ([exprs '()])
      (if (fx>= (car pos) (vector-length tv))
          (reverse exprs)
          (loop (cons (parse-one tv pos) exprs))))))

(define (anchor-parse-file path)
  (anchor-parse (read-file path)))

(define (parse-one tv pos)
  (when (fx>= (car pos) (vector-length tv))
    (anchor-error "unexpected end of input"))
  (let ([tok (vector-ref tv (car pos))])
    (set-car! pos (fx+ (car pos) 1))
    (cond
      ;; Reader macros
      [(assoc tok *reader-macros*)
       => (lambda (pair)
            (list (cdr pair) (parse-one tv pos)))]
      ;; Open paren / bracket — parse list
      [(or (string=? tok "(") (string=? tok "["))
       (let ([close (if (string=? tok "(") ")" "]")])
         (let loop ([items '()])
           (when (fx>= (car pos) (vector-length tv))
             (anchor-error "unexpected end of input inside list"))
           (let ([next (vector-ref tv (car pos))])
             (if (string=? next close)
                 (begin (set-car! pos (fx+ (car pos) 1))
                        (reverse items))
                 (loop (cons (parse-one tv pos) items))))))]
      ;; Close paren/bracket without open
      [(or (string=? tok ")") (string=? tok "]"))
       (anchor-error "unexpected" tok)]
      ;; String literal
      [(and (string? tok) (fx> (string-length tok) 0) (char=? (string-ref tok 0) #\"))
       (parse-string-token tok)]
      ;; Char literal: \xHH or \<c>
      [(and (string? tok) (fx> (string-length tok) 0) (char=? (string-ref tok 0) #\\))
       (parse-char-token tok)]
      ;; Number or symbol
      [else
       (parse-atom tok)])))

(define (parse-string-token tok)
  ;; tok is the raw token including surrounding quotes; process escapes
  (let ([s   (substring tok 1 (fx- (string-length tok) 1))]
        [out (open-output-string)])
    (let loop ([i 0])
      (if (fx>= i (string-length s))
          (get-output-string out)
          (let ([c (string-ref s i)])
            (if (and (char=? c #\\) (fx< (fx+ i 1) (string-length s)))
                (let ([nc (string-ref s (fx+ i 1))])
                  (cond
                    [(char=? nc #\n)  (write-char #\newline out) (loop (fx+ i 2))]
                    [(char=? nc #\t)  (write-char #\tab out)     (loop (fx+ i 2))]
                    [(char=? nc #\r)  (write-char #\return out)  (loop (fx+ i 2))]
                    [(char=? nc #\\)  (write-char #\\ out)       (loop (fx+ i 2))]
                    [(char=? nc #\")  (write-char #\" out)       (loop (fx+ i 2))]
                    [(char=? nc #\e)  (write-char (integer->char 27) out) (loop (fx+ i 2))]
                    [(char=? nc #\x)
                     ;; \xHH hex escape (2 hex digits)
                     (let ([hi (fx+ i 2)] [lo (fx+ i 3)])
                       (when (or (fx>= hi (string-length s)) (fx>= lo (string-length s)))
                         (anchor-error "truncated \\x escape in string"))
                       (write-char (integer->char
                                     (string->number
                                       (substring s hi (fx+ lo 1)) 16)) out)
                       (loop (fx+ i 4)))]
                    [(char<=? #\0 nc #\7)
                     ;; \NNN octal escape
                     (let loop2 ([j (fx+ i 1)] [end (fxmin (fx+ i 5) (string-length s))])
                       (if (and (fx< j end) (char<=? #\0 (string-ref s j) #\7))
                           (loop2 (fx+ j 1) end)
                           (begin
                             (write-char (integer->char
                                           (string->number (substring s (fx+ i 1) j) 8)) out)
                             (loop j))))]
                    [else (write-char c out) (loop (fx+ i 1))]))
                (begin (write-char c out) (loop (fx+ i 1)))))))))

(define (parse-char-token tok)
  ;; \xHH+ → codepoint integer;  \<c> → codepoint integer
  (if (and (fx>= (string-length tok) 2) (char=? (string-ref tok 1) #\x))
      (let ([n (string->number (substring tok 2 (string-length tok)) 16)])
        (or n (anchor-error "bad hex char literal" tok)))
      (let ([c (string-ref tok 1)])
        (cond
          [(char=? c #\n) 10]
          [(char=? c #\t)  9]
          [(char=? c #\r) 13]
          [(char=? c #\0)  0]
          [(char=? c #\e) 27]
          [(char=? c #\a)  7]
          [(char=? c #\b)  8]
          [else (char->integer c)]))))

(define (parse-atom tok)
  (cond
    [(string=? tok "#t") #t]
    [(string=? tok "#f") #f]
    [(and (fx> (string-length tok) 2)
          (char=? (string-ref tok 0) #\0)
          (or (char=? (string-ref tok 1) #\x)
              (char=? (string-ref tok 1) #\X)))
     (or (string->number (substring tok 2 (string-length tok)) 16)
         (string->symbol tok))]
    [else
     (or (string->number tok)
         (string->symbol tok))]))
