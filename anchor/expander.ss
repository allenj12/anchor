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
    cast alloc ref deref ptr-add array-get array-set!
    field-get field-set! sizeof-struct with-arena struct
    global global-set! extern-global const global-arena arena-reset!
    define-syntax syntax-rules syntax-case quote quasiquote unquote unquote-splicing
    embed-bytes embed-string
    cons car cdr nil null?
    unpacked-struct union enum
    + - * / % +f -f *f /f +u -u *u /u %u
    == != < > <= >= ==f !=f <f >f <=f >=f <u >u <=u >=u
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
  ;; Vars that appear under (pat ...) — these get list bindings from matching
  (cond
    [(pair? pattern)
     (let loop ([items pattern] [acc '()])
       (cond
         [(null? items) acc]
         [(and (pair? (cdr items)) (eq? (cadr items) '...))
          (loop (cddr items)
                (append (pattern-vars (car items) literals) acc))]
         [else
          (loop (cdr items)
                (append (ellipsis-bound-vars (car items) literals) acc))]))]
    [else '()]))

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
               ;; Ellipsis pattern
               (let* ([fixed-after (fx- plen (fx+ pi 2))]
                      [available   (fx- flen (fx+ fi fixed-after))])
                 (if (fx< available 0)
                     #f
                     (let* ([evars (pattern-vars pat literals)]
                            [b2    (fold-right
                                     (lambda (v acc)
                                       (if (assq v acc) acc (cons (cons v '()) acc)))
                                     b evars)])
                       (let cap ([k 0] [b3 b2])
                         (if (fx= k available)
                             (loop (fx+ pi 2) (fx+ fi available) b3)
                             (let ([sub (match-pattern pat (vector-ref fv (fx+ fi k))
                                                       literals '())])
                               (and sub
                                    (cap (fx+ k 1)
                                         (map (lambda (entry)
                                                (if (memv (car entry) evars)
                                                    (let ([cur (assq (car entry) b3)])
                                                      (cons (car entry)
                                                            (append (cdr cur)
                                                                    (list (cdr (assq (car entry) sub))))))
                                                    entry))
                                              b3)))))))))
               ;; Normal pattern item
               (and (fx< fi flen)
                    (let ([b2 (match-pattern pat (vector-ref fv fi) literals b)])
                      (and b2 (loop (fx+ pi 1) (fx+ fi 1) b2))))))]))))

;; ---------------------------------------------------------------------------
;; Template instantiation
;; ---------------------------------------------------------------------------

(define (ellipsis-vars-in template evars)
  ;; Which evars actually appear in template?
  (cond
    [(symbol? template)
     (if (memv template evars) (list template) '())]
    [(pair? template)
     (append (ellipsis-vars-in (car template) evars)
             (ellipsis-vars-in (cdr template) evars))]
    [else '()]))

(define (instantiate template bindings evars)
  (cond
    [(symbol? template)
     (let ([b (assq template bindings)])
       (if (and b (not (memv template evars)))
           (cdr b)
           template))]
    [(pair? template)
     (instantiate-list template bindings evars)]
    [else template]))

(define (instantiate-list items bindings evars)
  (let loop ([rest items] [result '()])
    (cond
      [(null? rest)
       (reverse result)]
      [(and (pair? (cdr rest)) (eq? (cadr rest) '...))
       (let* ([item    (car rest)]
              [used-ev (ellipsis-vars-in item evars)])
         (when (null? used-ev)
           (anchor-error "ellipsis in template but no ellipsis variable in subtemplate"))
         (let* ([evar  (car used-ev)]
                [count (length (cdr (assq evar bindings)))])
           (for-each (lambda (v)
                       (unless (fx= (length (cdr (assq v bindings))) count)
                         (anchor-error "mismatched ellipsis lengths")))
                     used-ev)
           ;; Expand k items in order, consing onto result (reversed accumulator).
           ;; The outer loop's final (reverse result) will put them in order.
           (let expand ([k 0] [r result])
             (if (fx= k count)
                 (loop (cddr rest) r)
                 (let* ([sub-b  (map (lambda (e)
                                       (if (memv (car e) used-ev)
                                           (cons (car e) (list-ref (cdr e) k))
                                           e))
                                     bindings)]
                        [sub-ev (filter (lambda (v) (not (memv v used-ev))) evars)]
                        ;; Insert at front of r; items will be reversed at end.
                        ;; To preserve forward order, we need to add the LAST item first.
                        ;; So we recurse k=0..count-1 but build reversed, then reverse once.
                        [expanded (instantiate item sub-b sub-ev)])
                   (expand (fx+ k 1) (cons expanded r)))))))]
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
                 (scan (cddr expr))))]
      [(eq? (car expr) 'fn)
       (let* ([nm     (and (pair? (cdr expr)) (cadr expr))]
              [params (and (pair? (cddr expr)) (list? (caddr expr)) (caddr expr))])
         (append (if (binding? nm) (list nm) '())
                 (filter binding? (or params '()))
                 (scan (cdddr expr))))]
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
            (anchor-error "no matching syntax-rules clause" form)
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
                  (try (cdr rules))))))))  )

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
;; Automatic hygiene for syntax-case templates
;;
;; Scans the template expression for symbols in quoted (quasiquote) position
;; that are not pattern variables, literals, or special forms.  These are
;; macro-introduced names that could capture user variables; we pre-substitute
;; fresh gensyms before the template is eval'd.
;;
;; Only quasiquote-based templates are analyzed — inside (unquote …) / (unquote-splicing …)
;; the expression is runtime Chez code and is not scanned.
;; ---------------------------------------------------------------------------

;; Find macro-introduced names: symbols in BINDING positions (let NAME, fn NAME,
;; fn params) within quasiquoted regions that are not pattern variables, literals,
;; special forms, or wildcards.  We deliberately exclude call-position symbols
;; (like printf, malloc) so external references are never renamed.
;; subst-quasi-syms then replaces ALL occurrences (both binding and call sites)
;; of these names, preserving internal consistency.
(define (template-sc-introduced template pvars literals)
  (define (introduced? sym)
    (and (symbol? sym)
         (not (memv sym pvars))
         (not (memv sym literals))
         (not (memv sym *special-forms*))
         (not (eq? sym '_))
         (not (eq? sym '...))))
  (define (scan-quasi expr)
    (cond
      [(not (pair? expr)) '()]
      [(or (eq? (car expr) 'unquote)
           (eq? (car expr) 'unquote-splicing))
       '()]
      [(eq? (car expr) 'let)
       ;; (let NAME val)
       (let ([nm (and (pair? (cdr expr)) (cadr expr))])
         (append (if (introduced? nm) (list nm) '())
                 (scan-quasi (cddr expr))))]
      [(eq? (car expr) 'fn)
       ;; (fn NAME (PARAMS...) body...)
       (let* ([nm     (and (pair? (cdr expr)) (cadr expr))]
              [params (and (pair? (cddr expr)) (list? (caddr expr)) (caddr expr))])
         (append (if (introduced? nm) (list nm) '())
                 (filter introduced? (or params '()))
                 (scan-quasi (cdddr expr))))]
      [else
       (append (scan-quasi (car expr))
               (scan-quasi (cdr expr)))]))
  (define (scan expr)
    (cond
      [(not (pair? expr)) '()]
      [(eq? (car expr) 'quasiquote) (scan-quasi (cadr expr))]
      [else (append (scan (car expr)) (scan (cdr expr)))]))
  (delete-duplicates (scan template)))

(define (subst-quasi-syms expr gsyms in-quasi?)
  ;; Substitute introduced symbols with their gensyms in quoted positions.
  (cond
    [(symbol? expr)
     (if in-quasi?
         (let ([g (assq expr gsyms)])
           (if g (cdr g) expr))
         expr)]
    [(not (pair? expr)) expr]
    [(eq? (car expr) 'quasiquote)
     (list 'quasiquote (subst-quasi-syms (cadr expr) gsyms #t))]
    [(and in-quasi? (eq? (car expr) 'unquote))
     (list 'unquote (subst-quasi-syms (cadr expr) gsyms #f))]
    [(and in-quasi? (eq? (car expr) 'unquote-splicing))
     (list 'unquote-splicing (subst-quasi-syms (cadr expr) gsyms #f))]
    [else
     (cons (subst-quasi-syms (car expr) gsyms in-quasi?)
           (subst-quasi-syms (cdr expr) gsyms in-quasi?))]))

(define (build-clause-chain form-var literals clauses)
  (if (null? clauses)
      `(anchor-error "no matching syntax-case clause" ,form-var)
      (let* ([clause    (car clauses)]
             [pattern   (car clause)]
             [tail      (cdr clause)]
             ;; [pattern guard template] or [pattern template]
             [has-guard (fx= (length tail) 2)]
             [guard     (if has-guard (car tail) #f)]
             [template  (if has-guard (cadr tail) (car tail))]
             [pvars     (pattern-vars pattern literals)]
             ;; Auto-hygiene: pre-gensym introduced names in quoted template positions
             [introduced (template-sc-introduced template pvars literals)]
             [gsyms      (map (lambda (n) (cons n (anchor-gensym n))) introduced)]
             [template   (if (null? gsyms) template
                             (subst-quasi-syms template gsyms #f))]
             [bsym      (gensym "b")]
             [binds     (map (lambda (v) `(,v (cdr (assq ',v ,bsym)))) pvars)])
        `(let ([,bsym (match-pattern ',pattern ,form-var ',literals '())])
           (if (not ,bsym)
               ,(build-clause-chain form-var literals (cdr clauses))
               (let ,binds
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
  ((eval `(lambda (match-pattern anchor-error id-sym anchor-gensym)
            (lambda (_form)
              ,(build-clause-chain '_form lits-form clauses))))
   match-pattern anchor-error id-sym anchor-gensym))

;; Identity helpers available in transformer bodies — Anchor AST is plain data.
(define (anc-syntax->datum stx) stx)
(define (anc-datum->syntax ctx datum) datum)

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
      (anchor-error "define-syntax: body must be (syntax-rules ...), (lambda ...), or (syntax-case ...)" body))
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
             [(syntax-case)
              (compile-syntax-case (cadr body) (cddr body))]
             [else
              (anchor-error "define-syntax: expected syntax-rules, lambda, or syntax-case" body)])])
      (cons name transformer))))

;; ---------------------------------------------------------------------------
;; Top-level expander
;; ---------------------------------------------------------------------------

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
                          [out        (raw in)]
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
  (if (id-user? x)
      (let ([r (assq (id-sym x) env)]) (if r (cdr r) (id-sym x)))
      (id-sym x)))  ;; macro-introduced: global ref, skip rename env

;; Walk form stripping stx and applying rename env.
(define (resolve form env)
  (cond
    [(stx? form)
     ;; Non-empty marks → macro-introduced global reference.
     ;; Empty marks → user-provided; apply rename env.
     (if (id-user? form)
         (let ([r (assq (stx-sym form) env)]) (if r (cdr r) (stx-sym form)))
         (stx-sym form))]
    [(symbol? form) (let ([r (assq form env)]) (if r (cdr r) form))]
    [(not (pair? form)) form]
    [(null? form) form]
    [else
     (let ([hs (id-sym (car form))])
       (cond
         ;; fn — collect stx names in body, build rename env for params, walk body
         [(eq? hs 'fn)
          (let* ([nm     (cadr form)]
                 [params (caddr form)]
                 [body   (cdddr form)]
                 [stx    (delete-duplicates (collect-stx-names (cddr form)))]
                 ;; Only rename user-provided params that conflict with macro global refs
                 [p-env  (filter-map
                           (lambda (p)
                             (and (id-user? p)
                                  (memv (id-sym p) stx)
                                  (cons (id-sym p) (anchor-gensym (id-sym p)))))
                           params)]
                 [env2   (append p-env env)]
                 [ps2    (map (lambda (p)
                                (let ([r (assq (id-sym p) p-env)])
                                  (if r (cdr r) (id-sym p))))
                              params)])
            (cons 'fn (cons (resolve-id nm env)
                            (cons ps2 (resolve-seq body stx env2)))))]
         ;; block / do / while — sequential bodies with let threading
         [(memv hs '(block do))
          (let ([stx (delete-duplicates (collect-stx-names form))])
            (cons hs (resolve-seq (cdr form) stx env)))]
         [(eq? hs 'while)
          (let ([stx (delete-duplicates (collect-stx-names form))])
            (cons 'while (cons (resolve (cadr form) env)
                               (resolve-seq (cddr form) stx env))))]
         ;; let — strip name, resolve value; sequential renaming done by resolve-seq
         [(eq? hs 'let)
          (list 'let (id-sym (cadr form)) (resolve (caddr form) env))]
         ;; default — resolve head and all children
         [else
          (cons (resolve (car form) env)
                (map (lambda (c) (resolve c env)) (cdr form)))]))]))

;; Walk a sequential statement list, threading let-binding renames.
;; Only renames USER-PROVIDED bindings (plain or empty-marks stx) that
;; conflict with macro-introduced global references (stx-names).
(define (resolve-seq stmts stx-names env)
  (if (null? stmts) '()
      (let* ([stmt (car stmts)]
             [hs   (and (pair? stmt) (id-sym (car stmt)))])
        (if (eq? hs 'let)
            (let* ([binding (cadr stmt)]
                   [sym     (id-sym binding)]
                   [val     (caddr stmt)]
                   ;; Rename only if this is a user-introduced binding that conflicts
                   [new-sym (if (and (id-user? binding) (memv sym stx-names))
                                (anchor-gensym sym)
                                sym)]
                   [env2    (if (eq? new-sym sym) env
                                (cons (cons sym new-sym) env))])
              (cons (list 'let new-sym (resolve val env))
                    (resolve-seq (cdr stmts) stx-names env2)))
            (cons (resolve stmt env)
                  (resolve-seq (cdr stmts) stx-names env))))))

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
          (map (lambda (f) (resolve f '())) (reverse acc))
          (let ([v (expand (car rest))])
            (cond
              [(not v)
               (loop (cdr rest) acc)]
              [(and (pair? v) (eq? (id-sym (car v)) 'do))
               (loop (append (cdr v) (cdr rest)) acc)]
              [else
               (loop (cdr rest) (cons v acc))]))))))
