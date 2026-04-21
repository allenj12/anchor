;;; reader.ss — Anchor tokenizer and parser
;;;
;;; AST uses native Chez types:
;;;   symbols   → stx objects with source location (file line col)
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
;; Tokenizer — returns list of (string line col) triples
;; ---------------------------------------------------------------------------

(define (anchor-tokenize src)
  (let ([len    (string-length src)]
        [tokens '()]
        [line   1]
        [col    1])

    (define (push! str l c)
      (set! tokens (cons (list str l c) tokens)))

    ;; Update line/col by scanning src[i..j).  Used after multi-char reads.
    (define (advance-pos! i j)
      (let scan ([k i])
        (when (fx< k j)
          (if (char=? (string-ref src k) #\newline)
              (begin (set! line (fx+ line 1)) (set! col 1))
              (set! col (fx+ col 1)))
          (scan (fx+ k 1)))))

    (let loop ([i 0])
      (if (fx>= i len)
          (reverse tokens)
          (let ([c   (string-ref src i)]
                [tl  line]
                [tc  col])
            (cond
              ;; Whitespace
              [(char-whitespace? c)
               (if (char=? c #\newline)
                   (begin (set! line (fx+ line 1)) (set! col 1))
                   (set! col (fx+ col 1)))
               (loop (fx+ i 1))]

              ;; Line comment — skip to end of line
              [(char=? c #\;)
               (let skip ([j i])
                 (if (or (fx>= j len) (char=? (string-ref src j) #\newline))
                     (loop j)
                     (skip (fx+ j 1))))]

              ;; ,@ must come before ,
              [(and (char=? c #\,)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\@))
               (push! ",@" tl tc) (set! col (fx+ col 2)) (loop (fx+ i 2))]

              ;; #,@ must come before #, and #'
              [(and (char=? c #\#)
                    (fx< (fx+ i 2) len)
                    (char=? (string-ref src (fx+ i 1)) #\,)
                    (char=? (string-ref src (fx+ i 2)) #\@))
               (push! "#,@" tl tc) (set! col (fx+ col 3)) (loop (fx+ i 3))]

              ;; #,
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\,))
               (push! "#," tl tc) (set! col (fx+ col 2)) (loop (fx+ i 2))]

              ;; #'
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\'))
               (push! "#'" tl tc) (set! col (fx+ col 2)) (loop (fx+ i 2))]

              ;; #`
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\`))
               (push! "#`" tl tc) (set! col (fx+ col 2)) (loop (fx+ i 2))]

              ;; Single-char tokens: ( ) [ ] ` ' ,
              [(memv c '(#\( #\) #\[ #\] #\` #\' #\,))
               (push! (string c) tl tc) (set! col (fx+ col 1)) (loop (fx+ i 1))]

              ;; String literal
              [(char=? c #\")
               (let-values ([(tok j) (read-string src i len)])
                 (push! tok tl tc)
                 (advance-pos! i j)
                 (loop j))]

              ;; #\<char> or #\<name>
              [(and (char=? c #\#)
                    (fx< (fx+ i 1) len)
                    (char=? (string-ref src (fx+ i 1)) #\\))
               (let-values ([(tok j) (read-hash-char-literal src i len)])
                 (push! tok tl tc)
                 (set! col (fx+ col (fx- j i)))
                 (loop j))]

              ;; Char literal: \x... or \<single>
              [(and (char=? c #\\)
                    (fx< (fx+ i 1) len)
                    (not (char-whitespace? (string-ref src (fx+ i 1))))
                    (not (memv (string-ref src (fx+ i 1)) '(#\( #\) #\[ #\] #\" #\; #\` #\' #\,))))
               (let-values ([(tok j) (read-char-literal src i len)])
                 (push! tok tl tc)
                 (set! col (fx+ col (fx- j i)))
                 (loop j))]

              ;; Atom (symbol or number)
              [else
               (let-values ([(tok j) (read-atom src i len)])
                 (push! tok tl tc)
                 (set! col (fx+ col (fx- j i)))
                 (loop j))]))))))

(define (read-string src start len)
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

(define (read-hash-char-literal src start len)
  (let ([ci (fx+ start 2)])
    (when (fx>= ci len)
      (anchor-error "truncated #\\ char literal"))
    (let ([c (string-ref src ci)])
      (if (char-alphabetic? c)
          (let loop ([i ci] [chars '()])
            (if (or (fx>= i len)
                    (let ([ch (string-ref src i)])
                      (or (char-whitespace? ch)
                          (memv ch '(#\( #\) #\[ #\] #\; #\" #\, #\` #\')))))
                (values (string-append "#\\" (list->string (reverse chars))) i)
                (loop (fx+ i 1) (cons (string-ref src i) chars))))
          (values (string-append "#\\" (string c)) (fx+ ci 1))))))

(define (read-char-literal src start len)
  (let ([next (string-ref src (fx+ start 1))])
    (if (and (char=? next #\x)
             (fx< (fx+ start 2) len)
             (hex-digit? (string-ref src (fx+ start 2))))
        (let loop ([i (fx+ start 2)] [chars '(#\x #\\)])
          (if (and (fx< i len) (hex-digit? (string-ref src i)))
              (loop (fx+ i 1) (cons (string-ref src i) chars))
              (values (list->string (reverse chars)) i)))
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

(define (anchor-parse src . rest)
  (let* ([filename (if (null? rest) "<input>" (car rest))]
         [tokens   (anchor-tokenize src)]
         [tv       (list->vector tokens)]
         [pos      (list 0)])
    (let loop ([exprs '()])
      (if (fx>= (car pos) (vector-length tv))
          (reverse exprs)
          (loop (cons (parse-one tv pos filename) exprs))))))

(define (anchor-parse-file path)
  (anchor-parse (read-file path) path))

(define (parse-one tv pos filename)
  (when (fx>= (car pos) (vector-length tv))
    (anchor-error "unexpected end of input"))
  (let* ([entry (vector-ref tv (car pos))]
         [tok   (car entry)]
         [tl    (cadr entry)]
         [tc    (caddr entry)])
    (set-car! pos (fx+ (car pos) 1))
    (cond
      ;; Reader macros
      [(assoc tok *reader-macros*)
       => (lambda (pair)
            (list (cdr pair) (parse-one tv pos filename)))]
      ;; Open paren / bracket — parse list
      [(or (string=? tok "(") (string=? tok "["))
       (let ([close (if (string=? tok "(") ")" "]")])
         (let loop ([items '()])
           (when (fx>= (car pos) (vector-length tv))
             (anchor-error (string-append filename ":" (number->string tl) ":" (number->string tc)
                                          ": unexpected end of input inside list")))
           (let ([next (car (vector-ref tv (car pos)))])
             (if (string=? next close)
                 (begin (set-car! pos (fx+ (car pos) 1))
                        (reverse items))
                 (loop (cons (parse-one tv pos filename) items))))))]
      ;; Close paren/bracket without open
      [(or (string=? tok ")") (string=? tok "]"))
       (anchor-error (string-append filename ":" (number->string tl) ":" (number->string tc)
                                    ": unexpected") tok)]
      ;; String literal
      [(and (string? tok) (fx> (string-length tok) 0) (char=? (string-ref tok 0) #\"))
       (parse-string-token tok)]
      ;; Char literal
      [(and (string? tok) (fx> (string-length tok) 0) (char=? (string-ref tok 0) #\\))
       (parse-char-token tok)]
      ;; Number or symbol
      [else
       (parse-atom tok filename tl tc)])))

(define (parse-string-token tok)
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
                     (let ([hi (fx+ i 2)] [lo (fx+ i 3)])
                       (when (or (fx>= hi (string-length s)) (fx>= lo (string-length s)))
                         (anchor-error "truncated \\x escape in string"))
                       (write-char (integer->char
                                     (string->number
                                       (substring s hi (fx+ lo 1)) 16)) out)
                       (loop (fx+ i 4)))]
                    [(char<=? #\0 nc #\7)
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

(define (parse-atom tok filename line col)
  (cond
    [(string=? tok "#t") #t]
    [(string=? tok "#f") #f]
    ;; #\<name> or #\<char> — delegate to Chez reader
    [(and (fx>= (string-length tok) 3)
          (char=? (string-ref tok 0) #\#)
          (char=? (string-ref tok 1) #\\))
     (let ([c (guard (exn [#t (anchor-error "unknown char literal" tok)])
                (read (open-input-string tok)))])
       (if (char? c)
           (char->integer c)
           (anchor-error "unknown char literal" tok)))]
    ;; 0x hex literals
    [(and (fx> (string-length tok) 2)
          (char=? (string-ref tok 0) #\0)
          (or (char=? (string-ref tok 1) #\x)
              (char=? (string-ref tok 1) #\X)))
     (or (string->number (substring tok 2 (string-length tok)) 16)
         (make-stx (string->symbol tok) '() (list filename line col)))]
    [else
     (let ([n (string->number tok)])
       (if n n (make-stx (string->symbol tok) '() (list filename line col))))]))
