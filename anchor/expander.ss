;;; expander.ss — syntax-rules macro expander for Anchor
;;;
;;; Uses native Chez types (symbols, numbers, strings, lists) as the AST.
;;;
;;; Pattern language:
;;;   _          wildcard — matches anything, not bound
;;;   symbol     pattern variable — matches anything, bound to matched form
;;;   (p ...)    ellipsis — matches zero or more of p
;;;   literal    exact symbol match (from the literals list)
;;;
;;; Template language:
;;;   symbol     substituted if pattern var, else kept as-is
;;;   (t ...)    ellipsis — expanded per capture

;; ---------------------------------------------------------------------------
;; Special forms — never treated as macro calls
;; ---------------------------------------------------------------------------

(define *special-forms*
  '(do block let set! if while return fn ffi include
    cast alloc ref deref with-arena struct
    global global-set! extern-global const global-arena arena-reset! with-parent-arena
    sizeof break continue fn-ptr call-ptr call-ptr-c fn-c
    define-syntax syntax-rules macro-case syntax with-syntax quasisyntax unsyntax unsyntax-splicing quote quasiquote unquote unquote-splicing
    embed-bytes embed-string
    cons car cdr set-car! set-cdr! nil null?
    unpacked-struct union enum
    + - * / % f+ f- f* f/ u+ u- u* u/ u%
    == != < > <= >= f== f!= f< f> f<= f>= u< u> u<= u>=
    && || !
    band bor bxor bnot lshift rshift))

;; ---------------------------------------------------------------------------
;; Pattern variable helpers
;; ---------------------------------------------------------------------------

(define (pattern-vars pattern literals)
  ;; All pattern variable symbols in pattern (excluding wildcards/ellipsis/literals)
  (cond
    [(symbol? pattern)
     (if (or (eq? pattern '_) (eq? pattern '...) (memv pattern literals))
         '()
         (list pattern))]
    [(pair? pattern)
     (append (pattern-vars (car pattern) literals)
             (pattern-vars (cdr pattern) literals))]
    [else '()]))

(define (ellipsis-bound-vars pattern literals)
  ;; Returns alist of (symbol . depth) for vars under ellipsis.
  ;; Depth 1 = one ..., depth 2 = nested ... ..., etc.
  (define (ebv pat depth)
    (cond
      [(pair? pat)
       (let loop ([items pat] [acc '()])
         (cond
           [(null? items) acc]
           [(and (pair? (cdr items)) (eq? (cadr items) '...))
            (loop (cddr items)
                  (append (map (lambda (v)
                                 (let ([existing (assq v acc)])
                                   (if existing
                                       ;; already seen at a deeper level, keep higher depth
                                       (cons v (max (cdr existing) (fx+ depth 1)))
                                       (cons v (fx+ depth 1)))))
                               (pattern-vars (car items) literals))
                          (ebv (car items) (fx+ depth 1))
                          acc))]
           [else
            (loop (cdr items)
                  (append (ebv (car items) depth) acc))]))]
      [else '()]))
  ;; Deduplicate, keeping highest depth for each variable
  (let ([raw (ebv pattern 0)])
    (let loop ([rest raw] [acc '()])
      (if (null? rest) acc
          (let* ([entry (car rest)]
                 [existing (assq (car entry) acc)])
            (if existing
                (if (fx> (cdr entry) (cdr existing))
                    (loop (cdr rest)
                          (cons entry (filter (lambda (e) (not (eq? (car e) (car entry)))) acc)))
                    (loop (cdr rest) acc))
                (loop (cdr rest) (cons entry acc))))))))

(define (evar-depth sym evars)
  ;; Returns the ellipsis depth of sym in evars, or 0 if not an evar.
  (let ([entry (assq sym evars)])
    (if entry (cdr entry) 0)))

(define (evar? sym evars)
  ;; Is sym an ellipsis-bound variable?
  (and (assq sym evars) #t))

;; ---------------------------------------------------------------------------
;; Pattern matching
;; ---------------------------------------------------------------------------

(define (match-pattern pattern form literals bindings)
  ;; Returns updated bindings (alist) on success, #f on failure.
  ;; Ellipsis vars are stored as lists in bindings.
  (cond
    [(symbol? pattern)
     (cond
       [(eq? pattern '...) bindings]
       [(eq? pattern '_)   bindings]
       [(memv pattern literals)
        (and (eq? (id-sym form) pattern) bindings)]
       [else (cons (cons pattern form) bindings)])]
    [(number? pattern)
     (and (number? form) (= pattern form) bindings)]
    [(string? pattern)
     (and (string? form) (string=? pattern form) bindings)]
    [(null? pattern)
     (and (null? form) bindings)]
    [(pair? pattern)
     (and (list? form)
          (match-list (list->vector pattern)
                      (list->vector form)
                      literals bindings))]
    [else #f]))

;; Minimum number of form elements required by pattern positions [start..plen).
;; Ellipsis groups (pat ...) count as 0 minimum; fixed patterns count as 1.
(define (min-forms pv start)
  (let loop ([i start] [count 0])
    (if (fx>= i (vector-length pv))
        count
        (if (eq? (vector-ref pv i) '...)
            (loop (fx+ i 1) count)
            (if (and (fx< (fx+ i 1) (vector-length pv))
                     (eq? (vector-ref pv (fx+ i 1)) '...))
                (loop (fx+ i 2) count)
                (loop (fx+ i 1) (fx+ count 1)))))))

(define (match-list pv fv literals bindings)
  (let ([plen (vector-length pv)]
        [flen (vector-length fv)])
    (let loop ([pi 0] [fi 0] [b bindings])
      (cond
        [(and (fx= pi plen) (fx= fi flen)) b]
        [(fx>= pi plen) #f]
        [else
         (let ([pat (vector-ref pv pi)])
           (if (and (fx< (fx+ pi 1) plen)
                    (eq? (vector-ref pv (fx+ pi 1)) '...))
               ;; Ellipsis pattern: greedily match as many consecutive elements as
               ;; possible, up to the maximum that leaves enough for remaining patterns.
               ;; Stops on the first element that doesn't match pat.
               (let* ([min-after  (min-forms pv (fx+ pi 2))]
                      [max-avail  (fx- (fx- flen fi) min-after)])
                 (if (fx< max-avail 0)
                     #f
                     (let* ([evars (pattern-vars pat literals)]
                            [b2    (fold-right
                                     (lambda (v acc)
                                       (if (assq v acc) acc (cons (cons v '()) acc)))
                                     b evars)])
                       (let cap ([k 0] [b3 b2])
                         (if (or (fx= k max-avail)
                                 (fx>= (fx+ fi k) flen))
                             (loop (fx+ pi 2) (fx+ fi k) b3)
                             (let ([sub (match-pattern pat (vector-ref fv (fx+ fi k))
                                                       literals '())])
                               (if sub
                                   (cap (fx+ k 1)
                                        (map (lambda (entry)
                                               (if (memv (car entry) evars)
                                                   (let ([cur (assq (car entry) b3)])
                                                     (cons (car entry)
                                                           (append (cdr cur)
                                                                   (list (cdr (assq (car entry) sub))))))
                                                   entry))
                                             b3))
                                   ;; element doesn't match pat — stop greedy here
                                   (loop (fx+ pi 2) (fx+ fi k) b3))))))))
               ;; Normal pattern item
               (and (fx< fi flen)
                    (let ([b2 (match-pattern pat (vector-ref fv fi) literals b)])
                      (and b2 (loop (fx+ pi 1) (fx+ fi 1) b2))))))]))))

;; ---------------------------------------------------------------------------
;; Template instantiation
;; ---------------------------------------------------------------------------

(define (ellipsis-escape? template)
  ;; (... subtemplate) — one-argument escape form
  (and (pair? template)
       (eq? (car template) '...)
       (pair? (cdr template))
       (null? (cddr template))))

(define (ellipsis-vars-in template evars)
  ;; Which evars actually appear in template?
  ;; Don't look inside (... subtemplate) — ellipsis is escaped there.
  (cond
    [(symbol? template)
     (if (evar? template evars) (list template) '())]
    [(ellipsis-escape? template) '()]
    [(pair? template)
     (append (ellipsis-vars-in (car template) evars)
             (ellipsis-vars-in (cdr template) evars))]
    [else '()]))

(define (instantiate template bindings evars)
  (cond
    [(symbol? template)
     (let ([b (assq template bindings)])
       (if (and b (not (evar? template evars)))
           (cdr b)
           template))]
    [(ellipsis-escape? template)
     ;; (... subtemplate) — process subtemplate with ... as literal
     (instantiate-escaped (cadr template) bindings evars)]
    [(pair? template)
     (instantiate-list template bindings evars)]
    [else template]))

;; Instantiate with ... treated as a literal symbol.
;; (... subtemplate) inside escaped context pops back to normal mode.
(define (instantiate-escaped template bindings evars)
  (cond
    [(eq? template '...) '...]
    [(symbol? template)
     (let ([b (assq template bindings)])
       (if (and b (not (evar? template evars)))
           (cdr b)
           template))]
    [(ellipsis-escape? template)
     ;; nested (... subtemplate) — pop back to normal instantiation
     (instantiate (cadr template) bindings evars)]
    [(pair? template)
     (instantiate-list-escaped template bindings evars)]
    [else template]))

(define (instantiate-list-escaped items bindings evars)
  (let loop ([rest items] [result '()])
    (if (null? rest)
        (reverse result)
        (loop (cdr rest)
              (cons (instantiate-escaped (car rest) bindings evars) result)))))

(define (instantiate-list items bindings evars)
  (let loop ([rest items] [result '()])
    (cond
      [(null? rest)
       (reverse result)]
      [(and (pair? (cdr rest)) (eq? (cadr rest) '...))
       (let* ([item    (car rest)]
              [used-ev (ellipsis-vars-in item evars)])
         (if (null? used-ev)
             ;; No ellipsis vars — pass through literally (supports nested templates
             ;; where the inner ... belongs to an inner pattern, not the outer one).
             (loop (cddr rest)
                   (cons '... (cons (instantiate item bindings evars) result)))
         (let* ([evar  (car used-ev)]
                [count (length (cdr (assq evar bindings)))])
           (for-each (lambda (v)
                       (unless (fx= (length (cdr (assq v bindings))) count)
                         (anchor-error "mismatched ellipsis lengths")))
                     used-ev)
           (let expand ([k 0] [r result])
             (if (fx= k count)
                 (loop (cddr rest) r)
                 (let* ([sub-b  (map (lambda (e)
                                       (if (memv (car e) used-ev)
                                           (cons (car e) (list-ref (cdr e) k))
                                           e))
                                     bindings)]
                        ;; Decrement depth for used evars; remove if now depth 0
                        [sub-ev (let loop ([ev evars] [acc '()])
                                  (if (null? ev) acc
                                      (let ([e (car ev)])
                                        (if (memv (car e) used-ev)
                                            (if (fx> (cdr e) 1)
                                                (loop (cdr ev) (cons (cons (car e) (fx- (cdr e) 1)) acc))
                                                (loop (cdr ev) acc))
                                            (loop (cdr ev) (cons e acc))))))]
                        [expanded (instantiate item sub-b sub-ev)])
                   (expand (fx+ k 1) (cons expanded r))))))))]
      [else
       (loop (cdr rest)
             (cons (instantiate (car rest) bindings evars) result))])))

;; ---------------------------------------------------------------------------
;; Macro definition and application
;; ---------------------------------------------------------------------------

(define (delete-duplicates lst)
  (let loop ([rest lst] [seen '()])
    (cond
      [(null? rest) (reverse seen)]
      [(memv (car rest) seen) (loop (cdr rest) seen)]
      [else (loop (cdr rest) (cons (car rest) seen))])))

;; Level 1 hygiene: collect only symbols in BINDING positions within the
;; template — (let NAME ...) and (fn NAME (PARAMS...) ...).
;; Call-position symbols (including recursive macro self-references) are
;; deliberately excluded so external/macro names are never gensymmed away.
(define (template-introduced template pvars)
  (define (binding? sym)
    (and (symbol? sym)
         (not (memv sym pvars))
         (not (memv sym *special-forms*))
         (not (eq? sym '_))
         (not (eq? sym '...))))
  (define (scan expr)
    (cond
      [(not (pair? expr)) '()]
      [(eq? (car expr) 'let)
       (let ([nm (and (pair? (cdr expr)) (cadr expr))])
         (append (if (binding? nm) (list nm) '())
                 (if (pair? (cdr expr)) (scan (cddr expr)) '())))]
      [(eq? (car expr) 'fn)
       ;; Guard all cdr/cddr/cdddr accesses: `fn` may appear as a bare symbol
       ;; inside data positions (e.g. field names), producing short lists like (fn).
       (let* ([nm     (and (pair? (cdr expr)) (cadr expr))]
              [params (and (pair? (cdr expr))
                           (pair? (cddr expr))
                           (list? (caddr expr))
                           (caddr expr))])
         (append (if (binding? nm) (list nm) '())
                 (filter binding? (or params '()))
                 (if (and (pair? (cdr expr)) (pair? (cddr expr)))
                     (scan (cdddr expr))
                     '())))]
      [else
       (append (scan (car expr))
               (scan (cdr expr)))]))
  (delete-duplicates (scan template)))

(define (make-macro name literals rules)
  (let ([compiled
         (map (lambda (rule)
                (let* ([pattern    (car rule)]
                       [template   (cadr rule)]
                       [pvars      (pattern-vars pattern literals)]
                       [evars      (ellipsis-bound-vars pattern literals)]
                       [introduced (template-introduced template pvars)])
                  (list pattern template evars introduced)))
              rules)])
    (lambda (form)
      (let try ([rules compiled])
        (if (null? rules)
            (anchor-error/loc form "no matching syntax-rules clause")
            (let* ([rule       (car rules)]
                   [pattern    (list-ref rule 0)]
                   [template   (list-ref rule 1)]
                   [evars      (list-ref rule 2)]
                   [introduced (list-ref rule 3)]
                   [bindings   (match-pattern pattern form literals '())])
              (if bindings
                  (let* ([gsyms  (map (lambda (n) (cons n (anchor-gensym n)))
                                      introduced)]
                         [full-b (append gsyms bindings)])
                    (instantiate template full-b evars))
                  (try (cdr rules)))))))))

;; ---------------------------------------------------------------------------
;; syntax-case transformer compiler
;;
;; Converts (syntax-case (lits...) clause...) into a Chez lambda that:
;;   1. Pattern-matches the incoming form using existing match-pattern machinery
;;   2. Binds pattern variables as Chez let bindings
;;   3. Evaluates the guard (if present) and template as Chez expressions
;;
;; Templates are Chez quasiquote expressions — ,var splices the matched value,
;; ,@var splices a list (for ellipsis captures).  The result is an Anchor AST.
;; ---------------------------------------------------------------------------


;; ---------------------------------------------------------------------------
;; Quasisyntax support — #`template with #,expr and #,@expr escapes
;;
;; Strategy: walk the template ONCE before quoting it, replacing each
;; (unsyntax expr) / (unsyntax-splicing expr) with (unsyntax <gensym>) /
;; (unsyntax-splicing <gensym>).  The gensym→expr pairs are collected.
;;
;; The generated Chez code evaluates all escape exprs first (in the scope
;; where pattern variables are bound as Chez let vars), binds the results
;; to the gensyms, then passes everything to instantiate-quasi which treats
;; (unsyntax gs) as a lookup in the holes alist.
;; ---------------------------------------------------------------------------

(define (extract-unsyntax tmpl)
  ;; Returns (tmpl2 . ((gs . expr) ...))
  ;; tmpl2 is tmpl with all (unsyntax E)/(unsyntax-splicing E) replaced by
  ;; (unsyntax gs)/(unsyntax-splicing gs); the alist maps each gs to its E.
  (let ([collected '()])
    (define (walk t)
      (cond
        [(not (pair? t)) t]
        [(eq? (car t) 'unsyntax)
         (let ([gs (gensym "us")])
           (set! collected (cons (cons gs (cadr t)) collected))
           (list 'unsyntax gs))]
        [(eq? (car t) 'unsyntax-splicing)
         (let ([gs (gensym "uss")])
           (set! collected (cons (cons gs (cadr t)) collected))
           (list 'unsyntax-splicing gs))]
        [else (cons (walk (car t)) (walk (cdr t)))]))
    (let ([tmpl2 (walk tmpl)])
      (cons tmpl2 (reverse collected)))))

;; instantiate-quasi: like instantiate but handles (unsyntax gs) via holes alist.
;; holes = ((gs . value) ...) where each value was pre-computed from the user's expr.
(define (instantiate-quasi template bindings evars holes)
  (cond
    [(and (pair? template) (eq? (car template) 'unsyntax))
     (let ([v (assq (cadr template) holes)])
       (if v (cdr v) (anchor-error "unsyntax: missing hole" (cadr template))))]
    [(and (pair? template) (eq? (car template) 'unsyntax-splicing))
     (anchor-error "unsyntax-splicing: only valid in list context")]
    [(ellipsis-escape? template)
     (instantiate-escaped (cadr template) bindings evars)]
    [(symbol? template)
     (let ([b (assq template bindings)])
       (if (and b (not (evar? template evars))) (cdr b) template))]
    [(pair? template)
     (instantiate-quasi-list template bindings evars holes)]
    [else template]))

(define (instantiate-quasi-list items bindings evars holes)
  (let loop ([rest items] [result '()])
    (cond
      [(null? rest) (reverse result)]
      ;; unsyntax-splicing at head of current item
      [(and (pair? (car rest)) (eq? (caar rest) 'unsyntax-splicing))
       (let* ([v (assq (cadar rest) holes)]
              [spliced (if v (cdr v) (anchor-error "unsyntax-splicing: missing hole" (cadar rest)))])
         (unless (list? spliced)
           (anchor-error "unsyntax-splicing: expected a list, got" spliced))
         (loop (cdr rest) (append (reverse spliced) result)))]
      ;; ellipsis
      [(and (pair? (cdr rest)) (eq? (cadr rest) '...))
       (let* ([item    (car rest)]
              [used-ev (ellipsis-vars-in item evars)])
         (if (null? used-ev)
             (loop (cddr rest)
                   (cons '... (cons (instantiate-quasi item bindings evars holes) result)))
             (let* ([evar  (car used-ev)]
                    [count (length (cdr (assq evar bindings)))])
               (for-each (lambda (v)
                           (unless (fx= (length (cdr (assq v bindings))) count)
                             (anchor-error "mismatched ellipsis lengths")))
                         used-ev)
               (let expand ([k 0] [r result])
                 (if (fx= k count)
                     (loop (cddr rest) r)
                     (let* ([sub-b  (map (lambda (e)
                                           (if (memv (car e) used-ev)
                                               (cons (car e) (list-ref (cdr e) k))
                                               e))
                                         bindings)]
                            [sub-ev (let loop ([ev evars] [acc '()])
                                      (if (null? ev) acc
                                          (let ([e (car ev)])
                                            (if (memv (car e) used-ev)
                                                (if (fx> (cdr e) 1)
                                                    (loop (cdr ev) (cons (cons (car e) (fx- (cdr e) 1)) acc))
                                                    (loop (cdr ev) acc))
                                                (loop (cdr ev) (cons e acc))))))]
                            [expanded (instantiate-quasi item sub-b sub-ev holes)])
                       (expand (fx+ k 1) (cons expanded r))))))))]
      [else
       (loop (cdr rest)
             (cons (instantiate-quasi (car rest) bindings evars holes) result))])))

;; ---------------------------------------------------------------------------
;; Template-body transformer for macro (syntax-case) clauses
;;
;; Walks Chez code in a macro clause body and rewrites:
;;   (syntax template)  →  (instantiate 'template <b-sym> '<evars>)
;;   #'template         →  same (reader already expanded #' to (syntax ...))
;;   (with-syntax ([pat expr] ...) body ...)
;;              →  match each pat against expr, extend bindings alist, recurse
;;
;; b-sym  — Chez variable name holding the current match bindings alist
;; evars  — list of ellipsis-bound pattern variable names at this scope
;;
;; Does NOT recurse into (quote ...) since that is literal data.
;; ---------------------------------------------------------------------------

(define (transform-syntax-bodies expr b-sym evars)
  (cond
    [(not (pair? expr)) expr]
    [(null? expr) expr]
    [(eq? (car expr) 'quote) expr]
    [(eq? (car expr) 'syntax)
     ;; (syntax template) or #'template
     `(instantiate ',(cadr expr) ,b-sym ',evars)]
    [(eq? (car expr) 'quasisyntax)
     ;; #`template with #,expr / #,@expr escapes
     (let* ([extracted  (extract-unsyntax (cadr expr))]
            [tmpl2      (car extracted)]
            [pairs      (cdr extracted)]   ;; ((gs . chez-expr) ...)
            [hole-binds (map (lambda (p) `[,(car p) ,(cdr p)]) pairs)]
            [holes-arg  `(list ,@(map (lambda (p) `(cons ',(car p) ,(car p))) pairs))])
       (if (null? pairs)
           `(instantiate ',tmpl2 ,b-sym ',evars)
           `(let ,hole-binds
              (instantiate-quasi ',tmpl2 ,b-sym ',evars ,holes-arg))))]
    [(eq? (car expr) 'with-syntax)
     (transform-with-syntax (cadr expr) (cddr expr) b-sym evars)]
    [else
     (cons (transform-syntax-bodies (car expr) b-sym evars)
           (transform-syntax-bodies (cdr expr) b-sym evars))]))

(define (transform-with-syntax ws-clauses body b-sym evars)
  ;; Each ws-clause is [pattern expr].
  ;; Generate code that:
  ;;   1. Runs match-pattern for each clause
  ;;   2. Combines all match results into an extended bindings alist
  ;;   3. Evaluates body with the extended alist in scope
  (let* ([ws-evars    (apply append
                             (map (lambda (cl) (ellipsis-bound-vars (car cl) '()))
                                  ws-clauses))]
         [all-evars   (append ws-evars evars)]
         [new-b-sym   (gensym "wsb")]
         [clause-syms (map (lambda (_) (gensym "wsbi")) ws-clauses)]
         [combined-b  (fold-right (lambda (cs acc) `(append ,cs ,acc))
                                  b-sym clause-syms)])
    `(let* (,@(map (lambda (cs cl)
                     `[,cs (match-pattern ',(car cl) ,(cadr cl) '() '())])
                   clause-syms ws-clauses)
            [,new-b-sym ,combined-b])
       ,@(map (lambda (b) (transform-syntax-bodies b new-b-sym all-evars))
              body))))

(define (build-clause-chain form-var literals clauses)
  (if (null? clauses)
      `(anchor-error/loc ,form-var "no matching macro-case clause")
      (let* ([clause    (car clauses)]
             [pattern   (car clause)]
             [tail      (cdr clause)]
             ;; [pattern guard template] or [pattern template]
             [has-guard (fx= (length tail) 2)]
             [guard     (if has-guard (car tail) #f)]
             [template  (if has-guard (cadr tail) (car tail))]
             [pvars     (pattern-vars pattern literals)]
             [evars     (ellipsis-bound-vars pattern literals)]
             ;; Rewrite (syntax tmpl) / #'tmpl / (with-syntax ...) in body.
             ;; No pre-gensym scan needed — KFFD marks template-introduced symbols
             ;; as macro-introduced after the XOR step, and the resolver renames any
             ;; conflicting user bindings at that point.
             [template   (transform-syntax-bodies template '_anc_cur_b evars)]
             [bsym       (gensym "b")]
             [binds      (map (lambda (v) `(,v (cdr (assq ',v ,bsym)))) pvars)])
        `(let ([,bsym (match-pattern ',pattern ,form-var ',literals '())])
           (if (not ,bsym)
               ,(build-clause-chain form-var literals (cdr clauses))
               ;; _anc_cur_b holds the full bindings alist for #'/with-syntax use
               (let ([_anc_cur_b ,bsym] ,@binds)
                 ,(if has-guard
                      `(if ,guard
                           ,template
                           ,(build-clause-chain form-var literals (cdr clauses)))
                      template)))))))

(define (compile-syntax-case lits-form clauses)
  (unless (list? lits-form)
    (anchor-error "syntax-case: literals must be a list"))
  ;; In compiled-binary mode, top-level defines are not in the interaction
  ;; environment that eval uses.  Pass all expander helpers the template might
  ;; call as outer lambda parameters so they are closed over lexically rather
  ;; than looked up by name at runtime.
  ((eval `(lambda (match-pattern anchor-error anchor-error/loc id-sym anchor-gensym instantiate instantiate-quasi datum->syntax is-struct? filter-map local-expand)
            (lambda (_form)
              ,(build-clause-chain '_form lits-form clauses))))
   match-pattern anchor-error anchor-error/loc id-sym anchor-gensym instantiate instantiate-quasi anc-datum->syntax
   anchor-is-struct? filter-map local-expand))

;; Identity helpers available in transformer bodies — Anchor AST is plain data.
(define (anc-syntax->datum stx) stx)

;; datum->syntax: produce a symbol that appears to come from the SAME use site as ctx.
;; Propagates marks from ctx to datum, making the result "user-provided" after the KFFD
;; XOR step cancels those marks.  This is the tool for intentional (anaphoric) capture —
;; the introduced name blends with the user's own identifiers from that call site.
;;
;; ctx can be any stx or form; marks are taken from the first stx found in it.
;; Typical use: (datum->syntax self 'name) where self is the keyword pattern variable.
(define (anc-datum->syntax ctx datum)
  (define (ctx-marks x)
    (cond [(stx? x) (stx-marks x)] [(pair? x) (ctx-marks (car x))] [else '()]))
  (define (ctx-src x)
    (cond [(stx? x) (stx-src x)] [(pair? x) (or (ctx-src (car x)) (ctx-src (cdr x)))] [else #f]))
  (let ([m (ctx-marks ctx)] [s (ctx-src ctx)])
    (if (null? m)
        datum
        (make-stx datum m s))))

;; Strip all stx wrappers recursively, returning plain Chez values.
;; Used when a generated define-syntax form has KFFD marks on its keywords.
(define (strip-marks form)
  (cond
    [(stx? form)  (stx-sym form)]
    [(pair? form) (cons (strip-marks (car form)) (strip-marks (cdr form)))]
    [else         form]))

(define (parse-define-syntax form)
  (unless (and (pair? form) (fx= (length form) 3))
    (anchor-error "define-syntax: expected (define-syntax name transformer)"))
  (let ([name (id-sym (cadr form))]        ;; strip marks from generated names
        [body (strip-marks (caddr form))]) ;; strip marks from generated transformer
    (unless (symbol? name)
      (anchor-error "define-syntax: name must be a symbol" name))
    (unless (pair? body)
      (anchor-error "define-syntax: body must be (syntax-rules ...), (lambda ...), or (macro-case ...)" body))
    (let ([transformer
           (case (car body)
             [(syntax-rules)
              (let* ([lits-form (cadr body)]
                     [literals  (if (list? lits-form) lits-form
                                    (anchor-error "syntax-rules: literals must be a list"))]
                     [clauses   (cddr body)]
                     [rules     (map (lambda (clause)
                                       (unless (and (list? clause)
                                                    (fx= (length clause) 2)
                                                    (pair? (car clause)))
                                         (anchor-error "syntax-rules clause must be (pattern template)" clause))
                                       clause)
                                     clauses)])
                (make-macro name literals rules))]
             [(lambda)
              ;; Transformer body is Chez code; eval it to get a procedure.
              ;; The procedure receives the full macro call form and returns the expansion.
              (eval body)]
             [(macro-case)
              (compile-syntax-case (cadr body) (cddr body))]
             [else
              (anchor-error "define-syntax: expected syntax-rules, lambda, or macro-case" body)])])
      (cons name transformer))))

;; ---------------------------------------------------------------------------
;; Top-level expander
;; ---------------------------------------------------------------------------

;; ---------------------------------------------------------------------------
;; Struct registry — tracks struct names seen during expansion so macro-case
;; transformers can call (is-struct? name) in guard expressions.
;; ---------------------------------------------------------------------------

(define *anchor-known-structs* (make-eq-hashtable))

(define (anchor-is-struct? x)
  (let ([sym (cond [(stx? x) (stx-sym x)] [(symbol? x) x] [else #f])])
    (and sym (hashtable-ref *anchor-known-structs* sym #f))))

(define (anchor-register-struct! x)
  (let ([sym (cond [(stx? x) (stx-sym x)] [(symbol? x) x] [else #f])])
    (when sym (hashtable-set! *anchor-known-structs* sym #t))))

(define (make-expander)
  (let ([macros (make-eq-hashtable)])

    (define (expand expr)
      (cond
        [(not (pair? expr)) expr]   ;; atoms and stx objects pass through
        [(null? expr)       expr]
        [else
         (let* ([head (car expr)]
                [hs   (id-sym head)])  ;; strip marks for dispatch
           (cond
             [(eq? hs 'define-syntax)
              ;; Level 2: store (raw . def-expand) pair so the mark XOR step
              ;; can run between raw application and re-expansion.
              (let* ([entry     (parse-define-syntax expr)]
                     [name      (car entry)]
                     [raw       (cdr entry)]
                     [def-expand expand])
                (hashtable-set! macros name (cons raw def-expand)))
              #f]
             [(eq? hs 'quote)      expr]
             [(eq? hs 'quasiquote) (expand-quasiquote (cadr expr))]
             ;; Track struct/union definitions for is-struct? in macro-case guards
             [(memv hs '(struct unpacked-struct union))
              (when (and (pair? (cdr expr)) (or (symbol? (cadr expr)) (stx? (cadr expr))))
                (anchor-register-struct! (id-sym (cadr expr))))
              (filter-map expand expr)]
             [(hashtable-ref macros hs #f)
              ;; Level 3: KFFD mark/anti-mark mechanism.
              ;; Step 1 - mark input with fresh m: user identifiers acquire m.
              ;; Step 2 - apply raw transformer: pvar bindings carry m,
              ;;           template-introduced symbols remain plain.
              ;; Step 3 - mark output with m again (XOR):
              ;;           user-provided parts cancel to original marks,
              ;;           template-introduced plain symbols gain mark {m}.
              ;; Step 4 - re-expand in the definition-time environment.
              => (lambda (entry)
                   (let* ([raw        (car entry)]
                          [def-expand (cdr entry)]
                          [m          (fresh-mark)]
                          [in         (add-mark expr m)]
                          [out        (parameterize ([*current-expand* expand])
                                        (raw in))]
                          [marked     (add-mark out m)])
                     (def-expand marked)))]
             [else
              (filter-map expand expr)]))]))

    (define (expand-quasiquote expr)
      (cond
        [(not (pair? expr)) expr]
        [(eq? (id-sym (car expr)) 'unquote) (expand (cadr expr))]
        [else
         (let loop ([items expr] [result '()])
           (cond
             [(null? items) (reverse result)]
             [(and (pair? (car items)) (eq? (id-sym (caar items)) 'unquote-splicing))
              (let ([spliced (expand (cadar items))])
                (unless (list? spliced)
                  (anchor-error "unquote-splicing: expected a list"))
                (loop (cdr items) (append (reverse spliced) result)))]
             [else
              (loop (cdr items)
                    (cons (expand-quasiquote (car items)) result))]))]))

    expand))

(define (filter-map f lst)
  (let loop ([rest lst] [acc '()])
    (if (null? rest)
        (reverse acc)
        (let ([v (f (car rest))])
          (loop (cdr rest) (if v (cons v acc) acc))))))

;; ---------------------------------------------------------------------------
;; Mark resolution — strip stx wrappers, rename clashing user bindings
;; ---------------------------------------------------------------------------

;; Collect base names of all stx objects with non-empty marks in form.
(define (collect-stx-names form)
  (cond
    [(and (stx? form) (pair? (stx-marks form))) (list (stx-sym form))]
    [(pair? form) (append (collect-stx-names (car form))
                          (collect-stx-names (cdr form)))]
    [else '()]))

;; After KFFD XOR, identifiers fall into two categories:
;;   • Macro-introduced: stx objects with NON-EMPTY marks — refer to global/definition-time names.
;;     These are stripped to their base symbol (global reference); rename env does NOT apply.
;;   • User-provided: plain symbols OR stx with EMPTY marks (XOR cancelled) — refer to user names.
;;     These apply the rename env.
(define (id-user? x)
  (or (symbol? x)
      (and (stx? x) (null? (stx-marks x)))))

(define (resolve-id x env)
  ;; Always check env first — a macro-introduced binding may have been gensymmed
  ;; and added under its bare symbol key. Fall back to bare symbol.
  (let ([sym (id-sym x)])
    (let ([r (assq sym env)]) (if r (cdr r) sym))))

;; Walk form stripping stx and applying rename env.
;; globals: eq-hashtable of bare symbols declared with (global ...) or (const ...).
;; Macro-introduced references to globals strip marks to the bare symbol.
(define (resolve form env globals)
  (cond
    [(stx? form)
     (let ([sym (stx-sym form)] [marks (stx-marks form)] [src (stx-src form)])
       (if (null? marks)
           ;; User-provided (empty marks): look up by bare symbol.
           ;; Preserve source location if not renamed.
           (let ([r (assq sym env)])
             (if r (cdr r)
                 (if src (make-stx sym '() src) sym)))
           ;; Macro-introduced (non-empty marks): look up by (sym . marks).
           ;; If in env → local macro binding.
           ;; Else if bare symbol is a known global → strip marks to bare symbol.
           ;; Else preserve stx so c-ident can encode marks in the C name.
           (let ([r (assoc (cons sym marks) env)])
             (if r (cdr r)
                 (if (hashtable-ref globals sym #f) sym form)))))]
    [(symbol? form) (let ([r (assq form env)]) (if r (cdr r) form))]
    [(not (pair? form)) form]
    [(null? form) form]
    [else
     (let ([hs (id-sym (car form))])
       (cond
         ;; fn — collect stx names in body, build rename env for params, walk body
         ;; Guard: (fn 8) can appear as a struct field spec — skip short forms.
         [(and (eq? hs 'fn) (pair? (cdr form)) (pair? (cddr form)) (list? (caddr form)))
          (let* ([nm      (cadr form)]
                 [params  (caddr form)]
                 [body    (cdddr form)]
                 ;; Resolve fn name: macro-introduced names preserve their marks so
                 ;; c-ident encodes them as _anc_N — no gensym needed.
                 ;; User-visible names (datum->syntax or plain) resolve normally.
                 [nm-res  (resolve nm env globals)]
                 [stx     (delete-duplicates (collect-stx-names (cddr form)))]
                 [p-env   (filter-map
                            (lambda (p)
                              (and (id-user? p)
                                   (memv (id-sym p) stx)
                                   (cons (id-sym p) (anchor-gensym (id-sym p)))))
                            params)]
                 [env2    (append p-env env)]
                 [ps2     (map (lambda (p)
                                 (let ([r (assq (id-sym p) p-env)])
                                   (if r (cdr r) (if (id-user? p) (id-sym p) p))))
                               params)])
            (cons 'fn (cons nm-res (cons ps2 (resolve-seq body stx env2 globals)))))]
         ;; fn-c — same param-rename logic as fn
         [(eq? hs 'fn-c)
          (let* ([nm     (cadr form)]
                 [params (if (pair? (cddr form)) (caddr form) '())]
                 [rest   (if (pair? (cddr form)) (cdddr form) '())]
                 [body   (if (and (pair? rest) (eq? (id-sym (car rest)) '->))
                             (cddr rest) rest)]
                 [nm-res (resolve nm env globals)]
                 [stx    (delete-duplicates (collect-stx-names body))]
                 [p-env  (filter-map
                           (lambda (p)
                             (and (pair? p)
                                  (let ([pname (list-ref p (fx- (length p) 1))])
                                    (and (id-user? pname)
                                         (memv (id-sym pname) stx)
                                         (cons (id-sym pname) (anchor-gensym (id-sym pname)))))))
                           params)]
                 [env2   (append p-env env)]
                 [ps2    (map (lambda (p)
                                (if (pair? p)
                                    (let* ([n     (length p)]
                                           [pname (list-ref p (fx- n 1))]
                                           [r     (assq (id-sym pname) p-env)])
                                      (append (map id-sym (list-head p (fx- n 1)))
                                              (list (if r (cdr r) (id-sym pname)))))
                                    (list (id-sym p))))
                              params)])
            (cons 'fn-c (cons nm-res (cons ps2 (map (lambda (x) (resolve x env2 globals)) rest)))))]
         ;; block / do — sequential bodies with let threading
         [(memv hs '(block do))
          (let* ([stx (delete-duplicates (collect-stx-names form))])
            (cons hs (resolve-seq (cdr form) stx env globals)))]
         [(eq? hs 'while)
          (let ([stx (delete-duplicates (collect-stx-names form))])
            (cons 'while (cons (resolve (cadr form) env globals)
                               (resolve-seq (cddr form) stx env globals))))]
         ;; let — resolve name (preserve stx marks for macro-introduced), resolve value
         [(eq? hs 'let)
          (list 'let (resolve (cadr form) env globals) (resolve (caddr form) env globals))]
         ;; default — resolve head and all children
         [else
          (cons (resolve (car form) env globals)
                (map (lambda (c) (resolve c env globals)) (cdr form)))]))]))

;; Walk a sequential statement list, threading let-binding renames.
(define (resolve-seq stmts stx-names env globals)
  (if (null? stmts) '()
      (let* ([stmt (car stmts)]
             [hs   (and (pair? stmt) (id-sym (car stmt)))])
        (if (eq? hs 'let)
            (let* ([binding (cadr stmt)]
                   [sym     (id-sym binding)]
                   [val     (caddr stmt)]
                   [marks   (if (stx? binding) (stx-marks binding) '())]
                   [macro?  (not (id-user? binding))]
                   [new-sym (cond
                              [macro?              binding]
                              [(memv sym stx-names) (anchor-gensym sym)]
                              [else sym])]
                   [env2    (if (or macro? (eq? new-sym sym)) env
                                (cons (cons sym new-sym) env))])
              (cons (list 'let new-sym (resolve val env globals))
                    (resolve-seq (cdr stmts) stx-names env2 globals)))
            (cons (resolve stmt env globals)
                  (resolve-seq (cdr stmts) stx-names env globals))))))

(define (expand-all exprs)
  ;; Process left-to-right so define-syntax forms register before use.
  ;; After expansion, run the mark-resolution pass to strip stx objects
  ;; and rename any user bindings that conflict with macro global references.
  ;;
  ;; Top-level (do form ...) is spliced: its children are re-queued as
  ;; separate top-level forms.  This lets macros emit multiple definitions
  ;; (struct + fn + fn ...) by wrapping them in a single do.
  (let ([expand (make-expander)])
    (let loop ([rest exprs] [acc '()])
      (if (null? rest)
          ;; Collect known globals/consts so resolve can strip marks for them
          (let ([globals (make-eq-hashtable)])
            (for-each (lambda (f)
                        (when (and (pair? f) (pair? (cdr f)))
                          (let ([h (id-sym (car f))])
                            (when (memq h '(global const global-arena))
                              (hashtable-set! globals (id-sym (cadr f)) #t)))))
                      acc)
            (map (lambda (f) (resolve f '() globals)) (reverse acc)))
          (let ([v (expand (car rest))])
            (cond
              [(not v)
               (loop (cdr rest) acc)]
              [(and (pair? v) (eq? (id-sym (car v)) 'do))
               (loop (append (cdr v) (cdr rest)) acc)]
              [else
               (loop (cdr rest) (cons v acc))]))))))
