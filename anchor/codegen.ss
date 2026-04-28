;;; codegen.ss — Anchor AST → C source

(define *multi-threaded* #f)

(define *anchor-runtime-h*
"#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

/* =========================================================
 * Anchor runtime — raw 64-bit value representation
 * =========================================================
 *
 * AnchorVal is a single 64-bit word.
 * Integers: raw signed 64-bit value.
 * Pointers: raw address (from malloc-backed arenas).
 * null = 0.
 *
 * All arithmetic operates directly on raw values — zero overhead vs C.
 * ========================================================= */

typedef uint64_t AnchorVal;

#define ANCHOR_NIL ((AnchorVal)0)

/* Pointer → void*: direct cast */
#define _ANCH_HPTR(v)  ((void*)(uintptr_t)(v))

/* Integer value: identity cast */
#define _ANCH_IVAL(v)  ((intptr_t)(int64_t)(v))

/* Float: reinterpret bits as double */
#define _ANCH_FVAL(v) \
    ({ AnchorVal _av = (v); double _fv; __builtin_memcpy(&_fv, &_av, sizeof(double)); _fv; })

#if defined(__GNUC__) || defined(__clang__)
#  define ANCHOR_PURE __attribute__((const))
#else
#  define ANCHOR_PURE
#endif

/* ---- Arena ---- */

typedef struct _AnchorArena {
    char*                buf;
    size_t               cap;
    size_t               used;
    struct _AnchorArena* prev;
} _AnchorArena;

#ifdef ANCHOR_MULTI_THREADED
static _Thread_local _AnchorArena* _anchor_arena_top = NULL;
#else
static _AnchorArena* _anchor_arena_top = NULL;
#endif
#define ANCHOR_DEFAULT_ARENA_CAP (1024 * 1024)

static inline AnchorVal anchor_alloc(size_t size) {
    _AnchorArena* a = _anchor_arena_top;
    if (!a) __builtin_trap();
    size_t aligned = (size + 7u) & ~7u;
    if (a->used + aligned > a->cap) __builtin_trap();
    AnchorVal r = (AnchorVal)(uintptr_t)(a->buf + a->used);
    a->used += aligned;
    return r;
}

static inline void _anchor_arena_reset(_AnchorArena* a) { a->used = 0; }

/* Wrap a raw C pointer as an AnchorVal */
static inline ANCHOR_PURE AnchorVal anchor_ext(void* p) {
    return p ? (AnchorVal)(uintptr_t)p : ANCHOR_NIL;
}

/* Unwrap AnchorVal pointer → void* */
static inline void* _anch_ptr(AnchorVal v) { return (void*)(uintptr_t)v; }

/* ---- Integer constructors / arithmetic — all raw, zero overhead vs C ---- */

static inline ANCHOR_PURE AnchorVal anchor_int(intptr_t v)  { return (AnchorVal)(int64_t)v; }
static inline ANCHOR_PURE AnchorVal anchor_add(AnchorVal a, AnchorVal b) { return a + b; }
static inline ANCHOR_PURE AnchorVal anchor_sub(AnchorVal a, AnchorVal b) { return a - b; }
static inline ANCHOR_PURE AnchorVal anchor_mul(AnchorVal a, AnchorVal b) { return a * b; }
static inline ANCHOR_PURE AnchorVal anchor_div(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a / (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_mod(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a % (int64_t)b); }

/* ---- Float constructor / arithmetic ---- */

static inline ANCHOR_PURE AnchorVal anchor_float(double v) {
    AnchorVal bits; __builtin_memcpy(&bits, &v, sizeof(double)); return bits;
}
static inline ANCHOR_PURE AnchorVal anchor_addf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) + _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_subf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) - _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_mulf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) * _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_divf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) / _ANCH_FVAL(b)); }

/* ---- Comparisons — direct on raw values ---- */

static inline ANCHOR_PURE AnchorVal anchor_eq(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a == (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_ne(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a != (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_lt(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a <  (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_gt(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a >  (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_le(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a <= (int64_t)b); }
static inline ANCHOR_PURE AnchorVal anchor_ge(AnchorVal a, AnchorVal b) { return (AnchorVal)((int64_t)a >= (int64_t)b); }

/* ---- Bitwise ---- */

static inline ANCHOR_PURE AnchorVal anchor_band(AnchorVal a, AnchorVal b)   { return a & b; }
static inline ANCHOR_PURE AnchorVal anchor_bor (AnchorVal a, AnchorVal b)   { return a | b; }
static inline ANCHOR_PURE AnchorVal anchor_bxor(AnchorVal a, AnchorVal b)   { return a ^ b; }
static inline ANCHOR_PURE AnchorVal anchor_bnot(AnchorVal a)                { return ~a; }
static inline ANCHOR_PURE AnchorVal anchor_lshift(AnchorVal a, AnchorVal b) { return a << b; }
static inline ANCHOR_PURE AnchorVal anchor_rshift(AnchorVal a, AnchorVal b) { return (AnchorVal)((uint64_t)a >> b); }

/* ---- Unsigned arithmetic ---- */

static inline ANCHOR_PURE AnchorVal anchor_addu(AnchorVal a, AnchorVal b) { return a + b; }
static inline ANCHOR_PURE AnchorVal anchor_subu(AnchorVal a, AnchorVal b) { return a - b; }
static inline ANCHOR_PURE AnchorVal anchor_mulu(AnchorVal a, AnchorVal b) { return a * b; }
static inline ANCHOR_PURE AnchorVal anchor_divu(AnchorVal a, AnchorVal b) { return a / b; }
static inline ANCHOR_PURE AnchorVal anchor_modu(AnchorVal a, AnchorVal b) { return a % b; }
static inline ANCHOR_PURE AnchorVal anchor_ltu (AnchorVal a, AnchorVal b) { return (AnchorVal)(a <  b); }
static inline ANCHOR_PURE AnchorVal anchor_gtu (AnchorVal a, AnchorVal b) { return (AnchorVal)(a >  b); }
static inline ANCHOR_PURE AnchorVal anchor_leu (AnchorVal a, AnchorVal b) { return (AnchorVal)(a <= b); }
static inline ANCHOR_PURE AnchorVal anchor_geu (AnchorVal a, AnchorVal b) { return (AnchorVal)(a >= b); }

/* ---- Float comparisons ---- */

static inline ANCHOR_PURE AnchorVal anchor_eqf(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) == _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_nef(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) != _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_ltf(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) <  _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gtf(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) >  _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_lef(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) <= _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gef(AnchorVal a, AnchorVal b) { return (AnchorVal)(_ANCH_FVAL(a) >= _ANCH_FVAL(b)); }

/* ---- Logical ---- */

static inline ANCHOR_PURE AnchorVal anchor_and(AnchorVal a, AnchorVal b) { return (AnchorVal)(!!a && !!b); }
static inline ANCHOR_PURE AnchorVal anchor_or (AnchorVal a, AnchorVal b) { return (AnchorVal)(!!a || !!b); }
static inline ANCHOR_PURE AnchorVal anchor_not(AnchorVal a)              { return (AnchorVal)(!a); }
")


;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

;; After resolve, user-written symbols are stx objects (location preserved);
;; template-introduced symbols are plain symbols.  sym? accepts both.
(define (sym? x) (or (symbol? x) (stx? x)))

(define (c-ident sym)
  ;; Macro-introduced symbols carry marks — encode them in the C name so two
  ;; expansions of the same template produce distinct C identifiers.
  (let* ([marks  (if (stx? sym) (stx-marks sym) '())]
         [s      (if (stx? sym) (stx-sym sym) sym)]
         [base   (list->string
                   (let loop ([cs (string->list (symbol->string s))])
                     (if (null? cs) '()
                         (case (car cs)
                           [(#\-) (cons #\_ (loop (cdr cs)))]
                           [(#\!) (append (string->list "_mut") (loop (cdr cs)))]
                           [(#\?) (append (string->list "_p")   (loop (cdr cs)))]
                           [(#\>) (append (string->list "gt_")  (loop (cdr cs)))]
                           [(#\<) (append (string->list "lt_")  (loop (cdr cs)))]
                           [(#\%) (append (string->list "_pct_") (loop (cdr cs)))]
                           [(#\.) (append (string->list "_dot_") (loop (cdr cs)))]
                           [else  (cons (car cs) (loop (cdr cs)))]))))])
    (if (null? marks)
        base
        (string-append base "_anc"
                       (apply string-append
                              (map (lambda (m) (string-append "_" (number->string m)))
                                   marks))))))


(define (pointer-type? s)
  (and (string? s) (fx> (string-length s) 0)
       (char=? (string-ref s (fx- (string-length s) 1)) #\*)))

(define (escape-c-str s)
  (let ([out (open-output-string)])
    (let loop ([i 0])
      (if (fx>= i (string-length s))
          (get-output-string out)
          (let ([c (string-ref s i)])
            (cond
              [(char=? c #\\)    (display "\\\\" out)]
              [(char=? c #\")    (display "\\\"" out)]
              [(char=? c #\newline) (display "\\n" out)]
              [(char=? c #\return)  (display "\\r" out)]
              [(char=? c #\tab)     (display "\\t" out)]
              [(or (fx< (char->integer c) 32) (fx= (char->integer c) 127))
               (display (string-append "\\x" (number->string (char->integer c) 16)) out)]
              [else (write-char c out)])
            (loop (fx+ i 1)))))))

(define (str-join strs sep)
  (if (null? strs) ""
      (fold-left (lambda (a s) (string-append a sep s)) (car strs) (cdr strs))))

;; ---------------------------------------------------------------------------
;; Context record
;; ---------------------------------------------------------------------------

(define-record-type ctx
  (fields
    (mutable lines        ctx-lines        ctx-lines-set!)
    (mutable indent-lv    ctx-indent-lv    ctx-indent-lv-set!)
    (mutable tmp-n        ctx-tmp-n        ctx-tmp-n-set!)
    (mutable structs      ctx-structs      ctx-structs-set!)   ; sym → ht{sym→(off.sz)}
    (mutable enums        ctx-enums        ctx-enums-set!)     ; sym → size (always 4)
    (mutable externs      ctx-externs      ctx-externs-set!)   ; sym → (ret . params)
    (mutable arena-stack  ctx-arena-stack  ctx-arena-stack-set!) ; (type prev-var arena-var)
    (mutable fn-ret       ctx-fn-ret       ctx-fn-ret-set!)
    (mutable fwd-decls    ctx-fwd-decls    ctx-fwd-decls-set!)
    (mutable globals      ctx-globals      ctx-globals-set!)
    (mutable arena-depth  ctx-arena-depth  ctx-arena-depth-set!)
    (mutable var-depth    ctx-var-depth    ctx-var-depth-set!)
    (mutable global-arenas ctx-global-arenas ctx-global-arenas-set!) ; sym → c-var (string)
    (mutable hoisted       ctx-hoisted       ctx-hoisted-set!)       ; lines hoisted to file scope
    (mutable fns           ctx-fns           ctx-fns-set!))          ; sym → C-name string for known top-level fns
  (protocol
    (lambda (new)
      (lambda ()
        (new '() 0 0
             (make-eq-hashtable) (make-eq-hashtable) (make-eq-hashtable)
             '() #f '() '() 0
             (make-eq-hashtable) (make-eq-hashtable) '()
             (make-eq-hashtable))))))

(define (ctx-emit! ctx line)
  (ctx-lines-set! ctx
    (cons (string-append (make-string (fx* (ctx-indent-lv ctx) 4) #\space) line)
          (ctx-lines ctx))))

(define (ctx-emit-blank! ctx) (ctx-lines-set! ctx (cons "" (ctx-lines ctx))))
(define (ctx-indent!  ctx) (ctx-indent-lv-set! ctx (fx+ (ctx-indent-lv ctx) 1)))
(define (ctx-dedent!  ctx) (ctx-indent-lv-set! ctx (fx- (ctx-indent-lv ctx) 1)))

(define (ctx-tmp! ctx)
  (let ([n (ctx-tmp-n ctx)])
    (ctx-tmp-n-set! ctx (fx+ n 1))
    (string-append "_anc_t" (number->string n))))

;; Arena stack entries:
;;   (av . use-heap?) — arena var name (C string) + whether buf was malloc'd
;;   ('restore . saved-var) — for with-parent-arena: restore top to saved-var
(define (ctx-push-arena! ctx av use-heap?)
  (ctx-arena-stack-set! ctx (cons (cons av use-heap?) (ctx-arena-stack ctx))))
(define (ctx-push-restore! ctx saved-var)
  (ctx-arena-stack-set! ctx (cons (cons 'restore saved-var) (ctx-arena-stack ctx))))
(define (ctx-pop-arena!  ctx) (ctx-arena-stack-set! ctx (cdr (ctx-arena-stack ctx))))
(define (ctx-in-arena?   ctx) (pair? (ctx-arena-stack ctx)))

;; Emit teardown for all arenas on stack (used on early return).
;; Note: heap-buf frees are NOT emitted here — only top pointer restoration.
;; Early returns from large arenas will leak the buffer (acceptable trade-off).
(define (ctx-arena-cleanup ctx)
  (map (lambda (entry)
         (if (eq? (car entry) 'restore)
             (string-append "_anchor_arena_top = " (cdr entry) ";")
             (string-append "_anchor_arena_top = " (car entry) ".prev;")))
       (ctx-arena-stack ctx)))

(define (ctx-output ctx) (str-join (reverse (ctx-lines ctx)) "\n"))

;; Pre-collector: reversed list in a box
(define (make-pre) (list '()))
(define (pre-add! p s) (set-car! p (cons s (car p))))
(define (pre-list  p)  (reverse (car p)))
(define (pre-emit! p ctx) (for-each (lambda (s) (ctx-emit! ctx s)) (pre-list p)))

;; Split a pre item "TYPE name = EXPR;" into (cons "TYPE name;" "name = EXPR;").
;; For block items "{ ... }" that are self-contained, returns (cons #f item)
;; so they are re-emitted as-is (no outer declaration needed).
(define (pre-item-split item)
  (let ([n (string-length item)])
    (if (and (fx> n 0) (char=? (string-ref item 0) #\{))
        (cons #f item)
        (let loop ([i 0])
          (cond
            [(fx>= (fx+ i 2) n) (cons #f item)]
            [(and (char=? (string-ref item i)           #\space)
                  (char=? (string-ref item (fx+ i 1))   #\=)
                  (char=? (string-ref item (fx+ i 2))   #\space))
             (let* ([before     (substring item 0 i)]
                    [after      (substring item (fx+ i 3) n)]
                    [name-start (let lp ([j (fx- (string-length before) 1)])
                                  (if (fx< j 0) 0
                                      (if (char=? (string-ref before j) #\space)
                                          (fx+ j 1)
                                          (lp (fx- j 1)))))]
                    [name       (substring before name-start (string-length before))])
               (cons (string-append before ";")
                     (string-append name " = " after)))]
            [else (loop (fx+ i 1))])))))

;; ---------------------------------------------------------------------------
;; Operator tables
;; ---------------------------------------------------------------------------

(define *arith-ops*
  '((+  . "anchor_add")  (-  . "anchor_sub")  (*  . "anchor_mul")
    (/  . "anchor_div")  (%  . "anchor_mod")
    (f+ . "anchor_addf") (f- . "anchor_subf")  (f* . "anchor_mulf") (f/ . "anchor_divf")
    (u+ . "anchor_addu") (u- . "anchor_subu")  (u* . "anchor_mulu")
    (u/ . "anchor_divu") (u% . "anchor_modu")
    (band . "anchor_band") (bor . "anchor_bor") (bxor . "anchor_bxor")
    (lshift . "anchor_lshift") (rshift . "anchor_rshift")))

(define *cmp-ops*
  '((==  . "anchor_eq")  (!=  . "anchor_ne")
    (<   . "anchor_lt")  (>   . "anchor_gt")  (<=  . "anchor_le")  (>=  . "anchor_ge")
    (f== . "anchor_eqf") (f!= . "anchor_nef")
    (f<  . "anchor_ltf") (f>  . "anchor_gtf") (f<= . "anchor_lef") (f>= . "anchor_gef")
    (u<  . "anchor_ltu") (u>  . "anchor_gtu") (u<= . "anchor_leu") (u>= . "anchor_geu")))

(define *logic-ops*
  `((&& . "anchor_and")
    (,(string->symbol "||") . "anchor_or")))

(define *type-qualifiers*
  '("const" "volatile" "restrict" "unsigned" "signed" "long" "short" "_Atomic"))

;; ---------------------------------------------------------------------------
;; Type helpers
;; ---------------------------------------------------------------------------

(define (cast-type-str node)
  (cond
    [(sym? node) (let ([s (symbol->string (id-sym node))])
                   ;; unsigned-long → "unsigned long" etc.
                   (list->string (map (lambda (c) (if (char=? c #\-) #\space c))
                                      (string->list s))))]
    [(pair? node) (str-join (map cast-type-str node) " ")]
    [else (anchor-error "invalid type in cast" node)]))

;; ---------------------------------------------------------------------------
;; Expression emitter — returns a C expression string; side-effects go to pre
;; ---------------------------------------------------------------------------

(define (emit-expr node ctx pre)
  (cond
    ;; Boolean (#t/#f from transformer bodies or reader)
    [(boolean? node)
     (if node "anchor_int(1)" "anchor_int(0)")]

    ;; Bytevector — embed as static const array, yield anchor_ext pointer to it
    [(bytevector? node)
     (let* ([tmp  (ctx-tmp! ctx)]
            [len  (bytevector-length node)]
            [elts (let loop ([i 0] [acc '()])
                    (if (fx= i len) (reverse acc)
                        (loop (fx+ i 1)
                              (cons (number->string (bytevector-u8-ref node i)) acc))))]
            [decl (string-append "static const unsigned char " tmp "_data[] = {"
                                 (str-join elts ", ") "};")])
       (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx) (list decl)))
       (string-append "anchor_ext((void*)" tmp "_data)"))]

    ;; Integer
    [(and (number? node) (exact? node))
     (let ([v node])
       (if (or (> v #x7FFFFFFFFFFFFFFF) (< v -9223372036854775808))
           (string-append "anchor_int((intptr_t)" (number->string v) "ULL)")
           (string-append "anchor_int(" (number->string v) ")")))]

    ;; Float
    [(and (number? node) (inexact? node))
     (string-append "anchor_float(" (number->string node) ")")]

    ;; String
    [(string? node)
     (string-append "anchor_ext((void*)\"" (escape-c-str node) "\")")]

    ;; nil — empty list sentinel
    [(and (sym? node) (eq? (id-sym node) 'nil)) "ANCHOR_NIL"]

    ;; Symbol or stx object → C identifier (stx stripped by c-ident)
    [(or (symbol? node) (stx? node)) (c-ident node)]

    [(pair? node)
     (let ([h (id-sym (car node))] [args (cdr node)])
       (cond
         ;; %null-check — null test: value == 0
         [(eq? h '%null-check)
          (unless (fx= (length args) 1) (anchor-error "%null-check: (%null-check val)"))
          (let ([v (emit-expr (car args) ctx pre)])
            (string-append "anchor_int(" v " == ANCHOR_NIL)"))]

         ;; trap — unconditional abort (__builtin_trap)
         [(eq? h 'trap)
          (unless (null? args) (anchor-error "trap: no arguments"))
          (pre-add! pre "__builtin_trap();")
          "ANCHOR_NIL"]

         ;; embed-bytes: (embed-bytes bv) — raw bytevector as static data, no null terminator
         [(eq? h 'embed-bytes)
          (unless (and (fx= (length args) 1) (bytevector? (car args)))
            (anchor-error "embed-bytes: expected a single bytevector literal"))
          (let* ([bv   (car args)]
                 [tmp  (ctx-tmp! ctx)]
                 [elts (let loop ([i 0] [acc '()])
                         (if (fx= i (bytevector-length bv)) (reverse acc)
                             (loop (fx+ i 1)
                                   (cons (number->string (bytevector-u8-ref bv i)) acc))))]
                 [decl (string-append "static const uint8_t " tmp "_bytes[] = {"
                                      (str-join elts ", ") "};")])
            (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx) (list decl)))
            (string-append "anchor_ext((void*)" tmp "_bytes"))]

         ;; embed-string: (embed-string str) — null-terminated string as static data
         [(eq? h 'embed-string)
          (unless (and (fx= (length args) 1) (string? (car args)))
            (anchor-error "embed-string: expected a single string"))
          (let* ([s    (car args)]
                 [tmp  (ctx-tmp! ctx)]
                 [bv   (string->utf8 s)]
                 [elts (let loop ([i 0] [acc '()])
                         (if (fx= i (bytevector-length bv)) (reverse (cons "0" acc))
                             (loop (fx+ i 1)
                                   (cons (number->string (bytevector-u8-ref bv i)) acc))))]
                 [decl (string-append "static const char " tmp "_str[] = {"
                                      (str-join elts ", ") "};")])
            (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx) (list decl)))
            (string-append "anchor_ext((void*)" tmp "_str)"))]

         ;; Arithmetic (left-fold for 2+ args)
         [(assq (id-sym h) *arith-ops*)
          => (lambda (p)
               (when (fx< (length args) 2)
                 (anchor-error (symbol->string (id-sym h)) "requires at least 2 arguments"))
               (fold-left (lambda (acc a)
                            (string-append (cdr p) "(" acc ", " (emit-expr a ctx pre) ")"))
                          (emit-expr (car args) ctx pre)
                          (cdr args)))]

         ;; Comparison
         [(assq (id-sym h) *cmp-ops*)
          => (lambda (p)
               (unless (fx= (length args) 2)
                 (anchor-error (symbol->string (id-sym h)) "requires exactly 2 arguments"))
               (string-append (cdr p) "(" (emit-expr (car args) ctx pre)
                              ", " (emit-expr (cadr args) ctx pre) ")"))]

         ;; Logical &&, ||
         [(assq (id-sym h) *logic-ops*)
          => (lambda (p)
               (unless (fx= (length args) 2)
                 (anchor-error (symbol->string (id-sym h)) "requires exactly 2 arguments"))
               (string-append (cdr p) "(" (emit-expr (car args) ctx pre)
                              ", " (emit-expr (cadr args) ctx pre) ")"))]

         [(eq? h '!)
          (unless (fx= (length args) 1) (anchor-error "! requires 1 argument"))
          (string-append "anchor_not(" (emit-expr (car args) ctx pre) ")")]

         [(eq? h 'bnot)
          (unless (fx= (length args) 1) (anchor-error "bnot requires 1 argument"))
          (string-append "anchor_bnot(" (emit-expr (car args) ctx pre) ")")]

         ;; cast
         [(eq? h 'cast)
          (unless (fx= (length args) 2) (anchor-error "cast: (cast TYPE expr)"))
          (let ([ct (cast-type-str (car args))]
                [iv (emit-expr (cadr args) ctx pre)])
            (cond
              [(pointer-type? ct)
               (string-append "anchor_ext((" ct ")_anch_ptr(" iv "))")]
              [(or (string=? ct "double") (string=? ct "float"))
               (string-append "anchor_float((double)_ANCH_FVAL(" iv "))")]
              [else
               (string-append "anchor_int((intptr_t)(" ct ")_ANCH_IVAL(" iv "))") ]))]

         ;; c-const
         [(eq? h 'c-const)
          (unless (and (fx= (length args) 1) (sym? (car args)))
            (anchor-error "c-const: (c-const NAME)"))
          (string-append "anchor_int((intptr_t)(" (symbol->string (id-sym (car args))) "))")]

         ;; alloc
         [(eq? h 'alloc)
          (unless (fx= (length args) 1) (anchor-error "alloc: (alloc SIZE)"))
          (string-append "anchor_alloc(" (emit-size-expr (car args) ctx) ")")]

         ;; arena-remaining — bytes left in current arena
         [(eq? h 'arena-remaining)
          (unless (null? args) (anchor-error "arena-remaining: no arguments"))
          "anchor_int((intptr_t)(_anchor_arena_top->cap - _anchor_arena_top->used))"]

         ;; arena-in? — 1 if ptr falls within the current arena's buffer, 0 otherwise
         [(eq? h 'arena-in?)
          (unless (fx= (length args) 1) (anchor-error "arena-in?: (arena-in? ptr)"))
          (let ([v (emit-expr (car args) ctx pre)])
            (string-append
              "anchor_int((char*)(uintptr_t)(" v ") >= _anchor_arena_top->buf && "
              "(char*)(uintptr_t)(" v ") < _anchor_arena_top->buf + _anchor_arena_top->cap ? 1 : 0)"))]

         ;; sizeof — Anchor struct/enum or C type
         [(eq? h 'sizeof)
          (unless (fx= (length args) 1)
            (anchor-error "sizeof: (sizeof Name)"))
          (let ([arg (car args)])
            (cond
              [(hashtable-ref (ctx-enums ctx) (id-sym arg) #f)
               "anchor_int(4)"]
              [(hashtable-ref (ctx-structs ctx) (id-sym arg) #f)
               (string-append "anchor_int(ANCHOR_SIZEOF_" (symbol->string (id-sym arg)) ")")]
              [else
               (string-append "anchor_int((intptr_t)sizeof(" (cast-type-str arg) "))")]))]

         ;; get — unified access form (ptr first)
         ;; (get ptr Type field ...)              — named chain (ptr before type)
         ;; (get ptr [i esz])                     — terminal indexed: scalar
         ;; (get ptr [i esz] Type field ...)      — indexed step then named chain
         ;; ref / deref
         [(eq? h 'ref)
          (unless (fx= (length args) 1) (anchor-error "ref: (ref expr)"))
          (let ([arg (car args)])
            (if (sym? arg)
              (string-append "anchor_ext((void*)&" (c-ident arg) ")")
              (let* ([iv (emit-expr arg ctx pre)] [tmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "AnchorVal " tmp "_base = " iv ";"))
                (string-append "anchor_ext((void*)&" tmp "_base)"))))]

         [(eq? h 'deref)
          (unless (fx= (length args) 1) (anchor-error "deref: (deref expr)"))
          (let ([arg (car args)])
            (if (and (pair? arg) (eq? (id-sym (car arg)) '%addr-offset))
              (let* ([ao    (cdr arg)]
                     [ptr-e (emit-expr (car ao) ctx pre)]
                     [sn    (id-sym (cadr ao))]
                     [fn    (id-sym (caddr ao))]
                     [csn   (c-ident sn)]
                     [cfn   (c-ident fn)]
                     [_     (or (hashtable-ref (ctx-structs ctx) sn #f)
                                (anchor-error "deref/%addr-offset: unknown struct" sn))]
                     [tmp   (ctx-tmp! ctx)])
                (pre-add! pre (string-append "AnchorVal " tmp ";"))
                (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)_ANCH_HPTR(" ptr-e ") + ANCHOR_OFFSET_" csn "_" cfn ", sizeof(AnchorVal));"))
                tmp)
              (let* ([a   (emit-expr arg ctx pre)]
                     [tmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "AnchorVal " tmp ";"))
                (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", _ANCH_HPTR(" a "), sizeof(AnchorVal));"))
                tmp)))]

         ;; %addr-offset — navigate one struct field, return address of field
         ;; (%addr-offset ptr Struct field)
         [(eq? h '%addr-offset)
          (unless (fx= (length args) 3)
            (anchor-error "%addr-offset: (%addr-offset ptr Struct field)"))
          (let* ([ptr-e (emit-expr (car args) ctx pre)]
                 [sn    (id-sym (cadr args))]
                 [fn    (id-sym (caddr args))]
                 [csn   (c-ident sn)]
                 [cfn   (c-ident fn)]
                 [_     (or (hashtable-ref (ctx-structs ctx) sn #f)
                            (anchor-error "%addr-offset: unknown struct" sn))]
                 [tmp   (ctx-tmp! ctx)])
            (pre-add! pre (string-append "AnchorVal " tmp " = " ptr-e " + ANCHOR_OFFSET_" csn "_" cfn ";"))
            tmp)]

         ;; %scalar — read scalar from pointer address
         ;; Fast path: if addr is (%addr-offset ptr S f), use ANCHOR_SIZE_S_f directly.
         [(eq? h '%scalar)
          ;; Load an AnchorVal (8 bytes) from a struct field or raw address.
          ;; In the 8-byte system every struct field IS an AnchorVal — just memcpy it.
          (unless (fx= (length args) 1) (anchor-error "%scalar: (%scalar addr)"))
          (let ([arg (car args)])
            (cond
              [(and (pair? arg) (eq? (id-sym (car arg)) '%addr-offset))
               (let* ([ao    (cdr arg)]
                      [inner (car ao)]
                      [sn    (id-sym (cadr ao))]
                      [fn    (id-sym (caddr ao))]
                      [csn   (c-ident sn)]
                      [cfn   (c-ident fn)]
                      [_     (or (hashtable-ref (ctx-structs ctx) sn #f)
                                 (anchor-error "%scalar/%addr-offset: unknown struct" sn))]
                      [tmp   (ctx-tmp! ctx)])
                 (if (and (pair? inner) (eq? (id-sym (car inner)) '%ptr+))
                   ;; two-level fast path: (%scalar (%addr-offset (%ptr+ base off) S f))
                   ;; emit _ANCH_HPTR(base) + _ANCH_IVAL(off) + FIELD — base is loop-hoistable
                   (let* ([base-e (emit-expr (cadr inner) ctx pre)]
                          [off-e  (emit-expr (caddr inner) ctx pre)])
                     (pre-add! pre (string-append "AnchorVal " tmp " = 0;"))
                     (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)_ANCH_HPTR(" base-e ") + _ANCH_IVAL(" off-e ") + ANCHOR_OFFSET_" csn "_" cfn ", ANCHOR_SIZE_" csn "_" cfn ");"))
                     tmp)
                   ;; single-level fast path: (%scalar (%addr-offset base S f))
                   (let ([ptr-e (emit-expr inner ctx pre)])
                     (pre-add! pre (string-append "AnchorVal " tmp " = 0;"))
                     (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)_ANCH_HPTR(" ptr-e ") + ANCHOR_OFFSET_" csn "_" cfn ", ANCHOR_SIZE_" csn "_" cfn ");"))
                     tmp)))]
              [(and (pair? arg) (eq? (id-sym (car arg)) '%ptr+))
               (let* ([ro    (cdr arg)]
                      [ptr-e (emit-expr (car ro) ctx pre)]
                      [off-e (emit-expr (cadr ro) ctx pre)]
                      [tmp   (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "AnchorVal " tmp " = 0;"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)_ANCH_HPTR(" ptr-e ") + _ANCH_IVAL(" off-e "), 8);"))
                 tmp)]
              [else
               (let* ([a   (emit-expr arg ctx pre)]
                      [tmp (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "AnchorVal " tmp " = 0;"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", _ANCH_HPTR(" a "), 8);"))
                 tmp)]))]

         ;; %store — write AnchorVal to address
         ;; (%store addr val)
         [(eq? h '%store)
          (unless (fx= (length args) 2) (anchor-error "%store: (%store addr val)"))
          (let ([addr-arg (car args)] [val-arg (cadr args)])
            (cond
              [(and (pair? addr-arg) (eq? (id-sym (car addr-arg)) '%addr-offset))
               (let* ([ao    (cdr addr-arg)]
                      [ptr-e (emit-expr (car ao) ctx pre)]
                      [sn    (id-sym (cadr ao))]
                      [fn    (id-sym (caddr ao))]
                      [csn   (c-ident sn)]
                      [cfn   (c-ident fn)]
                      [_     (or (hashtable-ref (ctx-structs ctx) sn #f)
                                 (anchor-error "%store/%addr-offset: unknown struct" sn))]
                      [v     (emit-expr val-arg ctx pre)]
                      [tmp   (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                 (pre-add! pre (string-append "  __builtin_memcpy((char*)_ANCH_HPTR(" ptr-e ") + ANCHOR_OFFSET_" csn "_" cfn ", &" tmp ", sizeof(AnchorVal)); }"))
                 "ANCHOR_NIL")]
              [(and (pair? addr-arg) (eq? (id-sym (car addr-arg)) '%ptr+))
               (let* ([ro    (cdr addr-arg)]
                      [ptr-e (emit-expr (car ro) ctx pre)]
                      [off-e (emit-expr (cadr ro) ctx pre)]
                      [v     (emit-expr val-arg ctx pre)]
                      [tmp   (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                 (pre-add! pre (string-append "  __builtin_memcpy((char*)_ANCH_HPTR(" ptr-e ") + _ANCH_IVAL(" off-e "), &" tmp ", sizeof(AnchorVal)); }"))
                 "ANCHOR_NIL")]
              [else
               (let* ([a   (emit-expr addr-arg ctx pre)]
                      [v   (emit-expr val-arg ctx pre)]
                      [tmp (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                 (pre-add! pre (string-append "  __builtin_memcpy(_ANCH_HPTR(" a "), &" tmp ", sizeof(AnchorVal)); }"))
                 "ANCHOR_NIL")]))]

         ;; %load-ptr — load an AnchorVal from a field and use it as the next base pointer.
         ;; In the 8-byte system every field is an AnchorVal — same as %scalar.
         ;; %ptr+ — advance pointer by byte offset.
         [(eq? h '%ptr+)
          (unless (fx= (length args) 2) (anchor-error "%ptr+: (%ptr+ ptr offset)"))
          (let ([p (emit-expr (car args) ctx pre)]
                [o (emit-expr (cadr args) ctx pre)])
            (string-append "(" p " + " o ")"))]

         ;; %scalar-store — write an AnchorVal into a struct field or raw address.
         ;; In the 8-byte system every field holds a raw AnchorVal — just memcpy.
         [(eq? h '%scalar-store)
          (unless (fx= (length args) 2) (anchor-error "%scalar-store: (%scalar-store addr val)"))
          (let ([addr-arg (car args)] [val-arg (cadr args)])
            (cond
              [(and (pair? addr-arg) (eq? (id-sym (car addr-arg)) '%addr-offset))
               (let* ([ao    (cdr addr-arg)]
                      [inner (car ao)]
                      [sn    (id-sym (cadr ao))]
                      [fn    (id-sym (caddr ao))]
                      [csn   (c-ident sn)]
                      [cfn   (c-ident fn)]
                      [_     (or (hashtable-ref (ctx-structs ctx) sn #f)
                                 (anchor-error "%scalar-store/%addr-offset: unknown struct" sn))]
                      [v     (emit-expr val-arg ctx pre)]
                      [tmp   (ctx-tmp! ctx)])
                 (if (and (pair? inner) (eq? (id-sym (car inner)) '%ptr+))
                   ;; two-level fast path
                   (let* ([base-e (emit-expr (cadr inner) ctx pre)]
                          [off-e  (emit-expr (caddr inner) ctx pre)])
                     (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                     (pre-add! pre (string-append "  __builtin_memcpy((char*)_ANCH_HPTR(" base-e ") + _ANCH_IVAL(" off-e ") + ANCHOR_OFFSET_" csn "_" cfn ", &" tmp ", ANCHOR_SIZE_" csn "_" cfn "); }"))
                     "ANCHOR_NIL")
                   ;; single-level fast path
                   (let ([ptr-e (emit-expr inner ctx pre)])
                     (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                     (pre-add! pre (string-append "  __builtin_memcpy((char*)_ANCH_HPTR(" ptr-e ") + ANCHOR_OFFSET_" csn "_" cfn ", &" tmp ", ANCHOR_SIZE_" csn "_" cfn "); }"))
                     "ANCHOR_NIL")))]
              [(and (pair? addr-arg) (eq? (id-sym (car addr-arg)) '%ptr+))
               (let* ([ro    (cdr addr-arg)]
                      [ptr-e (emit-expr (car ro) ctx pre)]
                      [off-e (emit-expr (cadr ro) ctx pre)]
                      [v     (emit-expr val-arg ctx pre)]
                      [tmp   (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                 (pre-add! pre (string-append "  __builtin_memcpy((char*)_ANCH_HPTR(" ptr-e ") + _ANCH_IVAL(" off-e "), &" tmp ", sizeof(AnchorVal)); }"))
                 "ANCHOR_NIL")]
              [else
               (let* ([a   (emit-expr addr-arg ctx pre)]
                      [v   (emit-expr val-arg ctx pre)]
                      [tmp (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "{ AnchorVal " tmp " = " v ";"))
                 (pre-add! pre (string-append "  __builtin_memcpy(_ANCH_HPTR(" a "), &" tmp ", sizeof(AnchorVal)); }"))
                 "ANCHOR_NIL")]))]

         ;; if as expression
         [(eq? h 'if)
          (unless (memv (length args) '(2 3)) (anchor-error "if: wrong arg count"))
          (let* ([cond-e (emit-expr (car args) ctx pre)]
                 [tmp    (ctx-tmp! ctx)]
                 [tp     (make-pre)]
                 [te     (emit-expr (cadr args) ctx tp)]
                 [ep     (make-pre)]
                 [ee     (if (fx= (length args) 3) (emit-expr (caddr args) ctx ep) "anchor_int(0)")])
            (pre-add! pre (string-append "AnchorVal " tmp ";"))
            (pre-add! pre (string-append "if (_ANCH_IVAL(" cond-e ")) {"))
            (for-each (lambda (s) (pre-add! pre (string-append "    " s))) (pre-list tp))
            (pre-add! pre (string-append "    " tmp " = " te ";"))
            (pre-add! pre "} else {")
            (for-each (lambda (s) (pre-add! pre (string-append "    " s))) (pre-list ep))
            (pre-add! pre (string-append "    " tmp " = " ee ";"))
            (pre-add! pre "}")
            tmp)]

         ;; do as expression (last item is the value)
         [(eq? h 'do)
          (if (null? args) "anchor_int(0)"
              (let ([tmp (ctx-tmp! ctx)]
                    [n   (length args)])
                (pre-add! pre (string-append "AnchorVal " tmp " = anchor_int(0);"))
                (for-each (lambda (s) (emit-stmt-into s ctx pre))
                          (list-head args (fx- n 1)))
                (let* ([lp (make-pre)]
                       [le (emit-expr (list-ref args (fx- n 1)) ctx lp)])
                  (for-each (lambda (s) (pre-add! pre s)) (pre-list lp))
                  (pre-add! pre (string-append tmp " = " le ";")))
                tmp))]

         ;; fn-ptr: take the address of a named Anchor function as an AnchorVal.
         ;; Use the registered C name so macro-introduced and user fns both resolve correctly.
         [(eq? h 'fn-ptr)
          (unless (fx= (length args) 1) (anchor-error "fn-ptr: (fn-ptr name)"))
          (let* ([sym (id-sym (car args))]
                 [cn  (or (hashtable-ref (ctx-fns ctx) sym #f) (c-ident (car args)))])
            (string-append "anchor_ext((void*)" cn ")"))]

         ;; call-ptr: call through a function pointer stored in an AnchorVal.
         ;; (call-ptr fp arg ...) — AnchorVal ABI only (fn functions).
         [(eq? h 'call-ptr)
          (when (null? args) (anchor-error "call-ptr: (call-ptr fp arg ...)"))
          (let* ([fp         (emit-expr (car args) ctx pre)]
                 [c-args     (map (lambda (a) (emit-expr a ctx pre)) (cdr args))]
                 [param-types (if (null? c-args) "void"
                                  (str-join (map (lambda (_) "AnchorVal") c-args) ", "))]
                 [fn-cast    (string-append "((AnchorVal(*)(" param-types "))_anch_ptr(" fp "))")])
            (string-append fn-cast "(" (str-join c-args ", ") ")"))]

         ;; call-ptr-c: call through a C-typed function pointer.
         ;; (call-ptr-c fp ((param-type ...) -> ret-type)  arg ...)
         [(eq? h 'call-ptr-c)
          (when (fx< (length args) 2)
            (anchor-error "call-ptr-c: (call-ptr-c fp ((param-type ...) -> ret-type) arg ...)"))
          (let* ([fp-expr   (car args)]
                 [sig       (cadr args)]   ; ((param-type...) -> ret-type)
                 [call-args (cddr args)]
                 [params    (car sig)]
                 [ret-str   (if (and (fx>= (length sig) 3) (eq? (id-sym (cadr sig)) '->))
                                (cast-type-str (caddr sig))
                                (anchor-error "call-ptr-c: sig must be ((types...) -> ret)"))]
                 [fp        (emit-expr fp-expr ctx pre)]
                 [ptypes    (parse-ffi-params params)]
                 [ptypes-s  (if (null? ptypes) "void" (str-join ptypes ", "))]
                 [fn-cast   (string-append "((" ret-str "(*)(" ptypes-s "))_anch_ptr(" fp "))")]
                 [c-args    (let loop ([as call-args] [i 0] [acc '()])
                              (if (null? as) (reverse acc)
                                  (loop (cdr as) (fx+ i 1)
                                        (cons (emit-call-arg (car as) ctx pre #t
                                                             (ffi-param-type ptypes i))
                                              acc))))])
            (wrap-extern-ret (string-append fn-cast "(" (str-join c-args ", ") ")") ret-str ctx pre))]

         ;; function call (plain symbol or stx — strip marks via c-ident)
         [(or (symbol? h) (stx? h))
          (let* ([hs  (id-sym h)]
                 [ext (hashtable-ref (ctx-externs ctx) hs #f)])
            (cond
              ;; FFI extern — use typed C calling convention.
              ;; Use the bare symbol name (hs), not c-ident of the call node, so that
              ;; macro-introduced references (stx with marks) still emit the plain C name.
              [ext
               (let* ([ret    (car ext)]
                      [ptypes (cdr ext)]
                      [c-args (let loop ([as args] [i 0] [acc '()])
                                (if (null? as) (reverse acc)
                                    (loop (cdr as) (fx+ i 1)
                                          (cons (emit-call-arg (car as) ctx pre #t
                                                               (ffi-param-type ptypes i))
                                                acc))))])
                 (wrap-extern-ret (string-append (symbol->string hs) "(" (str-join c-args ", ") ")") ret ctx pre))]
              ;; Known Anchor fn — direct call using the registered C name.
              ;; This handles both plain user fns (registered as "my_fn") and
              ;; macro-introduced fns (registered as "_helper_anc_1") correctly,
              ;; regardless of whether the call site has marks on the head symbol.
              [(hashtable-ref (ctx-fns ctx) hs #f)
               => (lambda (cn)
                    (let ([c-args (map (lambda (a) (emit-call-arg a ctx pre #f #f)) args)])
                      (string-append cn "(" (str-join c-args ", ") ")")))]
              ;; Unknown symbol — treat as lambda/closure value: (fn-ptr . env)
              ;; Emit car/cdr directly via %scalar/%addr-offset to avoid recursion.
              [else
               (let* ([head    (car node)]
                      [fn-ptr  (emit-expr `(%scalar (%addr-offset ,head Cons car)) ctx pre)]
                      [env     (emit-expr `(%scalar (%addr-offset ,head Cons cdr)) ctx pre)]
                      [c-args  (map (lambda (a) (emit-call-arg a ctx pre #f #f)) args)]
                      [all-args (cons env c-args)]
                      [ptypes  (str-join (map (lambda (_) "AnchorVal") all-args) ", ")]
                      [fn-cast (string-append "((AnchorVal(*)(" ptypes "))_anch_ptr(" fn-ptr "))")])
                 (string-append fn-cast "(" (str-join all-args ", ") ")"))]))]

         ;; Compound-expression call head — head is not a symbol, must be a closure value.
         ;; Evaluate it into a tmp, then call via closure convention (cons(fn-ptr, env)).
         [(pair? h)
          (let* ([tmp     (ctx-tmp! ctx)]
                 [tmp-sym (string->symbol tmp)]
                 [_       (pre-add! pre (string-append "AnchorVal " tmp " = " (emit-expr (car node) ctx pre) ";"))]
                 [fn-ptr  (emit-expr `(%scalar (%addr-offset ,tmp-sym Cons car)) ctx pre)]
                 [env     (emit-expr `(%scalar (%addr-offset ,tmp-sym Cons cdr)) ctx pre)]
                 [c-args  (map (lambda (a) (emit-call-arg a ctx pre #f #f)) args)]
                 [all-args (cons env c-args)]
                 [ptypes  (str-join (map (lambda (_) "AnchorVal") all-args) ", ")]
                 [fn-cast (string-append "((AnchorVal(*)(" ptypes "))_anch_ptr(" fn-ptr "))")])
            (string-append fn-cast "(" (str-join all-args ", ") ")"))]

         [else (anchor-error "cannot emit expression" node)]))]

    [else (anchor-error "cannot emit expression" node)]))

(define (resolve-esz arg ctx)
  ;; Resolve array element size from optional arg:
  ;;   literal number       → that number
  ;;   (sizeof Name)        → looked up from structs/enums table
  ;;   absent               → 8 (default AnchorVal slot size)
  (cond
    [(not arg) 8]
    [(and (number? arg) (exact? arg)) (exact arg)]
    [(and (pair? arg) (memv (id-sym (car arg)) '(sizeof)))
     (let ([n (id-sym (cadr arg))])
       (or (struct-total-size ctx n)
           (anchor-error "sizeof: unknown struct" n)))]
    [else (anchor-error "array-get/set!: element size must be a literal or (sizeof Name)")]))

(define (emit-size-expr node ctx)
  (cond
    [(and (number? node) (exact? node)) (number->string node)]
    [(and (pair? node) (memv (id-sym (car node)) '(sizeof)))
     (let ([arg (cadr node)])
       (cond
         [(hashtable-ref (ctx-structs ctx) (id-sym arg) #f)
          (string-append "ANCHOR_SIZEOF_" (symbol->string (id-sym arg)))]
         [(hashtable-ref (ctx-enums ctx) (id-sym arg) #f)
          "4"]
         [else
          (string-append "sizeof(" (cast-type-str arg) ")")]))]
    [(sym? node) (string-append "(size_t)_ANCH_IVAL(" (c-ident node) ")")]
    [else
     (let ([pre (make-pre)])
       (string-append "(size_t)_ANCH_IVAL(" (emit-expr node ctx pre) ")"))]))

(define (wrap-extern-ret call ret ctx pre)
  (if (string=? ret "void")
      (begin (pre-add! pre (string-append call ";")) "anchor_int(0)")
      (let ([tmp (ctx-tmp! ctx)])
        (cond
          [(or (string=? ret "double") (string=? ret "float"))
           (pre-add! pre (string-append ret " " tmp "_raw = " call ";"))
           (pre-add! pre (string-append "AnchorVal " tmp " = anchor_float((double)" tmp "_raw);"))]
          [(pointer-type? ret)
           (pre-add! pre (string-append ret " " tmp "_raw = " call ";"))
           (pre-add! pre (string-append "AnchorVal " tmp " = anchor_ext((void*)" tmp "_raw);"))]
          [else
           (pre-add! pre (string-append ret " " tmp "_raw = " call ";"))
           (pre-add! pre (string-append "AnchorVal " tmp " = anchor_int((intptr_t)" tmp "_raw);"))])
        tmp)))

(define (ffi-param-type ptypes i)
  (if (null? ptypes) #f
      (let* ([last (list-ref ptypes (fx- (length ptypes) 1))]
             [fixed (if (string=? last "...")
                        (list-head ptypes (fx- (length ptypes) 1))
                        ptypes)])
        (if (fx< i (length fixed)) (list-ref fixed i) #f))))

(define (emit-call-arg node ctx pre is-extern ptype)
  (if (not is-extern)
      (emit-expr node ctx pre)
      (cond
        [(string? node)  (string-append "\"" (escape-c-str node) "\"")]
        [(and (number? node) (exact? node))
         (if (and ptype (pointer-type? ptype) (= node 0))
             (string-append "(" ptype ")0")
             (number->string node))]
        [(and (number? node) (inexact? node)) (number->string node)]
        [(and (pair? node) (eq? (id-sym (car node)) 'cast))
         (let* ([ct (cast-type-str (cadr node))]
                [iv (emit-expr (caddr node) ctx pre)])
           (cond
             [(pointer-type? ct) (string-append "((" ct ")_anch_ptr(" iv "))")]
             [(or (string=? ct "double") (string=? ct "float")) (string-append "_ANCH_FVAL(" iv ")")]
             [else (string-append "(" ct ")_ANCH_IVAL(" iv ")")]))]
        [else
         (let ([iv (emit-expr node ctx pre)])
           (if ptype
               (cond
                 [(pointer-type? ptype) (string-append "((" ptype ")_anch_ptr(" iv "))")]
                 [(or (string=? ptype "double") (string=? ptype "float")) (string-append "_ANCH_FVAL(" iv ")")]
                 [else (string-append "(" ptype ")_ANCH_IVAL(" iv ")")])
               iv))])))

;; ---------------------------------------------------------------------------
;; Statement emitter
;; ---------------------------------------------------------------------------

(define (emit-stmt-into node ctx pre)
  ;; Capture emitted lines into pre without affecting main output
  (let ([saved (ctx-lines ctx)]
        [saved-lv (ctx-indent-lv ctx)])
    (ctx-lines-set! ctx '())
    (ctx-indent-lv-set! ctx 0)
    (emit-stmt node ctx)
    (let ([captured (reverse (ctx-lines ctx))])
      (ctx-lines-set! ctx saved)
      (ctx-indent-lv-set! ctx saved-lv)
      (for-each (lambda (s) (pre-add! pre s)) captured))))

(define (empty-do? node)
  (and (pair? node) (eq? (id-sym (car node)) 'do) (null? (cdr node))))

(define (emit-stmt node ctx)
  (if (not (pair? node))
      ;; Atom as statement
      (let ([pre (make-pre)])
        (let ([e (emit-expr node ctx pre)])
          (pre-emit! pre ctx)
          (ctx-emit! ctx (string-append e ";"))))
      (let ([h (id-sym (car node))] [args (cdr node)])
        (cond

          ;; let
          [(eq? h 'let)
           (unless (fx= (length args) 2) (anchor-error "let: (let name expr)"))
           (let* ([nm  (car args)]
                  [pre (make-pre)]
                  [e   (emit-expr (cadr args) ctx pre)])
             (pre-emit! pre ctx)
             (ctx-emit! ctx (string-append "AnchorVal " (c-ident nm) " = " e ";"))
             (hashtable-set! (ctx-var-depth ctx) nm (ctx-arena-depth ctx)))]

          ;; set-var! — variable rebind (used by set! macro expansion)
          [(eq? h 'set-var!)
           (unless (fx= (length args) 2) (anchor-error "set-var!: (set-var! name val)"))
           (let* ([pre (make-pre)]
                  [rhs (emit-expr (cadr args) ctx pre)])
             (pre-emit! pre ctx)
             (ctx-emit! ctx (string-append (c-ident (car args)) " = " rhs ";")))]

          ;; set!
          ;; return
          [(eq? h 'return)
           (let ([ret (or (ctx-fn-ret ctx) "AnchorVal")])
             (if (null? args)
                 (begin
                   (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                   (ctx-emit! ctx "return;"))
                 (let ([v (car args)])
                   ;; Optimization: bare integer with scalar C return
                   (if (and (number? v) (exact? v)
                            (not (member ret '("AnchorVal" "void")))
                            (not (pointer-type? ret)))
                       (begin
                         (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                         (ctx-emit! ctx (string-append "return " (number->string v) ";")))
                       (let* ([pre (make-pre)]
                              [e   (emit-expr v ctx pre)])
                         (pre-emit! pre ctx)
                         (cond
                           [(string=? ret "AnchorVal")
                            ;; AnchorVal is a raw uint64_t — return as-is.
                            ;; Arena cleanup deactivates local arenas.
                            (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                            (ctx-emit! ctx (string-append "return " e ";"))]
                           [(string=? ret "void")
                            (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                            (ctx-emit! ctx "return;")]
                           [(pointer-type? ret)
                            (let ([tmp (ctx-tmp! ctx)])
                              (ctx-emit! ctx (string-append ret " " tmp " = (" ret ")_anch_ptr(" e ");"))
                              (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                              (ctx-emit! ctx (string-append "return " tmp ";")))]
                           [else
                            (let ([tmp (ctx-tmp! ctx)])
                              (ctx-emit! ctx (string-append ret " " tmp " = (" ret ")_ANCH_IVAL(" e ");"))
                              (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                              (ctx-emit! ctx (string-append "return " tmp ";")))]))))))]

          ;; if
          [(eq? h 'if)
           (unless (memv (length args) '(2 3)) (anchor-error "if: wrong arg count"))
           (let* ([pre    (make-pre)]
                  [cond-e (emit-expr (car args) ctx pre)]
                  [t-empty (empty-do? (cadr args))]
                  [e-empty (or (fx< (length args) 3) (empty-do? (caddr args)))])
             (pre-emit! pre ctx)
             (if (and t-empty (not e-empty))
                 (begin
                   (ctx-emit! ctx (string-append "if (!_ANCH_IVAL(" cond-e ")) {"))
                   (ctx-indent! ctx) (emit-stmt (caddr args) ctx) (ctx-dedent! ctx)
                   (ctx-emit! ctx "}"))
                 (begin
                   (ctx-emit! ctx (string-append "if (_ANCH_IVAL(" cond-e ")) {"))
                   (ctx-indent! ctx)
                   (unless t-empty (emit-stmt (cadr args) ctx))
                   (ctx-dedent! ctx)
                   (unless e-empty
                     (ctx-emit! ctx "} else {")
                     (ctx-indent! ctx) (emit-stmt (caddr args) ctx) (ctx-dedent! ctx))
                   (ctx-emit! ctx "}"))))]

          ;; while
          [(eq? h 'while)
           (when (fx< (length args) 2) (anchor-error "while: (while cond body...)"))
           (let* ([pre    (make-pre)]
                  [cond-e (emit-expr (car args) ctx pre)])
             (if (null? (pre-list pre))
                 ;; Simple condition — no temporaries, plain while.
                 (begin
                   (ctx-emit! ctx (string-append "while (_ANCH_IVAL(" cond-e ")) {"))
                   (ctx-indent! ctx)
                   (for-each (lambda (s) (emit-stmt s ctx)) (cdr args))
                   (ctx-dedent! ctx)
                   (ctx-emit! ctx "}"))
                 ;; Complex condition with temporaries.
                 ;; Split each pre item "TYPE name = EXPR;" into a declaration
                 ;; "TYPE name;" and an assignment "name = EXPR;" so we can:
                 ;;   1. declare temps before the while
                 ;;   2. assign them (initial evaluation)
                 ;;   3. while (cond) { body; re-assign temps; }
                 ;; This keeps the natural while(cond) form without shadowing.
                 (let* ([splits  (map pre-item-split (pre-list pre))]
                        [decls   (let loop ([ss splits] [acc '()])
                                   (if (null? ss) (reverse acc)
                                       (loop (cdr ss) (if (car (car ss))
                                                          (cons (car (car ss)) acc)
                                                          acc))))]
                        [assigns (map cdr splits)])
                   (for-each (lambda (d) (ctx-emit! ctx d)) decls)
                   (for-each (lambda (a) (ctx-emit! ctx a)) assigns)
                   (ctx-emit! ctx (string-append "while (_ANCH_IVAL(" cond-e ")) {"))
                   (ctx-indent! ctx)
                   (for-each (lambda (s) (emit-stmt s ctx)) (cdr args))
                   (for-each (lambda (a) (ctx-emit! ctx a)) assigns)
                   (ctx-dedent! ctx)
                   (ctx-emit! ctx "}"))))]

          ;; break / continue
          [(eq? h 'break)    (ctx-emit! ctx "break;")]
          [(eq? h 'continue) (ctx-emit! ctx "continue;")]

          ;; do
          [(eq? h 'do)
           (for-each (lambda (s) (emit-stmt s ctx)) args)]

          ;; hoist — emit a declaration at file scope (used by lambda/closure)
          [(eq? h 'hoist)
           (unless (fx= (length args) 1) (anchor-error "hoist: (hoist form)"))
           (let ([saved-lines  (ctx-lines ctx)]
                 [saved-indent (ctx-indent-lv ctx)]
                 [saved-arena  (ctx-arena-stack ctx)]
                 [saved-depth  (ctx-arena-depth ctx)]
                 [saved-fn-ret (ctx-fn-ret ctx)])
             (ctx-lines-set!       ctx '())
             (ctx-indent-lv-set!   ctx 0)
             (ctx-arena-stack-set! ctx '())
             (ctx-arena-depth-set! ctx 0)
             (ctx-fn-ret-set!      ctx #f)
             (emit-stmt (car args) ctx)
             (ctx-hoisted-set! ctx
               (append (ctx-hoisted ctx) (reverse (ctx-lines ctx)) (list "")))
             (ctx-lines-set!       ctx saved-lines)
             (ctx-indent-lv-set!   ctx saved-indent)
             (ctx-arena-stack-set! ctx saved-arena)
             (ctx-arena-depth-set! ctx saved-depth)
             (ctx-fn-ret-set!      ctx saved-fn-ret))]

          ;; block
          [(eq? h 'block)
           (ctx-emit! ctx "{")
           (ctx-indent! ctx)
           (for-each (lambda (s) (emit-stmt s ctx)) args)
           (ctx-dedent! ctx)
           (ctx-emit! ctx "}")]

          ;; global-set!
          [(eq? h 'global-set!)
           (unless (fx= (length args) 2) (anchor-error "global-set!: (global-set! name val)"))
           (let* ([pre (make-pre)]
                  [val (emit-expr (cadr args) ctx pre)])
             (pre-emit! pre ctx)
             (ctx-emit! ctx (string-append (c-ident (car args)) " = " val ";")))]

          ;; arena-reset!
          [(eq? h 'arena-reset!)
           (unless (and (fx= (length args) 1) (sym? (car args)))
             (anchor-error "arena-reset!: (arena-reset! name)"))
           (let ([cname (hashtable-ref (ctx-global-arenas ctx) (id-sym (car args)) #f)])
             (unless cname (anchor-error "arena-reset!: not a declared global-arena" (car args)))
             (ctx-emit! ctx (string-append "_anchor_arena_reset(&" cname ");")))]

          ;; extern-global
          [(eq? h 'extern-global)
           (unless (and (fx= (length args) 1) (sym? (car args)))
             (anchor-error "extern-global: (extern-global name)"))
           (ctx-fwd-decls-set! ctx
             (append (ctx-fwd-decls ctx)
                     (list (string-append "extern AnchorVal " (c-ident (car args)) ";  /* = uint64_t */"))))]

          ;; ffi
          [(eq? h 'ffi)
           (emit-ffi node ctx)]

          ;; include
          [(eq? h 'include)
           (unless (fx= (length args) 1) (anchor-error "include: 1 argument required"))
           (let ([hdr (car args)])
             (ctx-fwd-decls-set! ctx
               (append (ctx-fwd-decls ctx)
                       (list (cond
                               [(sym? hdr)
                                (let ([s (symbol->string (id-sym hdr))])
                                  (if (and (char=? (string-ref s 0) #\<)
                                           (char=? (string-ref s (fx- (string-length s) 1)) #\>))
                                      (string-append "#include " s)
                                      (string-append "#include <" s ">")))]
                               [(string? hdr)
                                (string-append "#include \"" hdr "\"")]
                               [else (anchor-error "include: bad header" hdr)])))))]

          ;; struct / unpacked-struct / union / enum
          [(eq? h 'struct)
           (emit-struct node ctx #t)]
          [(eq? h 'unpacked-struct)
           (emit-struct node ctx #f)]
          [(eq? h 'union)
           (emit-union node ctx)]
          [(eq? h 'enum)
           (emit-enum node ctx)]

          ;; fn
          [(eq? h 'fn)
           (emit-fn node ctx #f)]

          ;; with-arena / with-parent-arena
          [(eq? h 'with-arena)
           (emit-with-arena node ctx)]
          [(eq? h 'with-parent-arena)
           (emit-with-parent-arena node ctx)]

          ;; call-ptr-c as statement — avoid synthesizing anchor_int(0) for void returns
          [(eq? h 'call-ptr-c)
           (when (fx< (length args) 2)
             (anchor-error "call-ptr-c: (call-ptr-c fp ((param-type ...) -> ret-type) arg ...)"))
           (let* ([sig     (cadr args)]
                  [ret-str (if (and (fx>= (length sig) 3) (eq? (id-sym (cadr sig)) '->))
                               (cast-type-str (caddr sig))
                               (anchor-error "call-ptr-c: sig must be ((types...) -> ret)"))])
             (if (string=? ret-str "void")
                 ;; Void return: emit the call directly as a statement, no anchor_int(0)
                 (let* ([pre       (make-pre)]
                        [fp-expr   (car args)]
                        [call-args (cddr args)]
                        [params    (car sig)]
                        [fp        (emit-expr fp-expr ctx pre)]
                        [ptypes    (parse-ffi-params params)]
                        [ptypes-s  (if (null? ptypes) "void" (str-join ptypes ", "))]
                        [fn-cast   (string-append "((" ret-str "(*)(" ptypes-s "))_anch_ptr(" fp "))")]
                        [c-args    (let loop ([as call-args] [i 0] [acc '()])
                                     (if (null? as) (reverse acc)
                                         (loop (cdr as) (fx+ i 1)
                                               (cons (emit-call-arg (car as) ctx pre #t
                                                                    (ffi-param-type ptypes i))
                                                     acc))))])
                   (pre-emit! pre ctx)
                   (ctx-emit! ctx (string-append fn-cast "(" (str-join c-args ", ") ");")))
                 ;; Non-void: fall through to expression statement path
                 (let ([pre (make-pre)])
                   (let ([e (emit-expr node ctx pre)])
                     (pre-emit! pre ctx)
                     (ctx-emit! ctx (string-append e ";"))))))]

          ;; bare extern call or expression statement
          [else
           (if (and (sym? h) (hashtable-ref (ctx-externs ctx) (id-sym h) #f))
               (let* ([ext    (hashtable-ref (ctx-externs ctx) (id-sym h) #f)]
                      [ptypes (cdr ext)]
                      [pre    (make-pre)]
                      [c-args (let loop ([as args] [i 0] [acc '()])
                                (if (null? as) (reverse acc)
                                    (loop (cdr as) (fx+ i 1)
                                          (cons (emit-call-arg (car as) ctx pre #t
                                                               (ffi-param-type ptypes i))
                                                acc))))])
                 (pre-emit! pre ctx)
                 ;; c-ident of the bare symbol (marks already stripped via id-sym),
                 ;; so hyphens become underscores without adding mark suffixes.
                 (ctx-emit! ctx (string-append (symbol->string h) "(" (str-join c-args ", ") ");")))
               (let ([pre (make-pre)])
                 (let ([e (emit-expr node ctx pre)])
                   (pre-emit! pre ctx)
                   (ctx-emit! ctx (string-append e ";")))))]))))

;; ---------------------------------------------------------------------------
;; Top-level forms
;; ---------------------------------------------------------------------------

(define (emit-ffi node ctx)
  ;; (ffi name (param-types...) -> ret-type)
  (let ([items (cdr node)])
    (when (fx< (length items) 2)
      (anchor-error "ffi: (ffi name (types...) -> ret)"))
    (let* ([name   (car items)]
           [params (cadr items)]
           [rest   (cddr items)]
           [ret    (if (and (fx>= (length rest) 2) (eq? (id-sym (car rest)) '->))
                       (cast-type-str (cadr rest))
                       "void")]
           [ptypes (parse-ffi-params params)])
      (hashtable-set! (ctx-externs ctx) (id-sym name) (cons ret ptypes)))))

(define (parse-ffi-params params)
  ;; Returns a list of C type strings parsed from Anchor param tokens.
  ;; Groups consecutive qualifier symbols (const, unsigned, etc.) with the base type.
  (define (collect-type items parts)
    ;; Consume tokens until we have a complete type; return (type . remaining-items)
    (cond
      [(null? items)
       (cons (str-join (reverse parts) " ") '())]
      [(and (sym? (car items)) (string=? (symbol->string (id-sym (car items))) "..."))
       (cons (str-join (reverse parts) " ") items)]
      [(pair? (car items))
       (cons (str-join (append (reverse parts) (list (cast-type-str (car items)))) " ")
             (cdr items))]
      [else
       (let ([part (symbol->string (id-sym (car items)))])
         (if (member part *type-qualifiers*)
             (collect-type (cdr items) (cons part parts))
             (cons (str-join (reverse (cons part parts)) " ") (cdr items))))]))
  (let loop ([items params] [acc '()])
    (cond
      [(null? items) (reverse acc)]
      [(and (sym? (car items)) (string=? (symbol->string (id-sym (car items))) "..."))
       (reverse (cons "..." acc))]
      [(pair? (car items))
       (loop (cdr items) (cons (cast-type-str (car items)) acc))]
      [else
       (let ([result (collect-type items '())])
         (loop (cdr result) (cons (car result) acc)))])))

(define *default-field-sz* 8)

(define (align-up offset alignment)
  (let ([r (fxmod offset alignment)])
    (if (fx= r 0) offset (fx+ offset (fx- alignment r)))))

(define (field-alignment sz)
  (cond [(fx<= sz 1) 1]
        [(fx<= sz 2) 2]
        [(fx<= sz 4) 4]
        [else 8]))

(define (struct-total-size ctx name)
  ;; Total size for a struct/union (stored under '_total) or enum (always 4).
  (let ([n (id-sym name)])
    (cond
      [(hashtable-ref (ctx-structs ctx) n #f) =>
       (lambda (tbl) (hashtable-ref tbl '_total #f))]
      [(hashtable-ref (ctx-enums ctx) n #f) => (lambda (_) 4)]
      [else (anchor-error "sizeof: unknown struct or enum" name)])))

(define (resolve-field-size form ctx)
  ;; Returns the byte size of a struct field size spec:
  ;;   number            → literal byte count
  ;;   (sizeof N)        → total size of struct/union N
  ;;   omitted           → default field size
  (cond
    [(number? form) (exact form)]
    [(and (pair? form) (memv (id-sym (car form)) '(sizeof)))
     (unless (and (pair? (cdr form)) (sym? (cadr form)))
       (anchor-error "sizeof in struct field: expected (sizeof Name)"))
     (struct-total-size ctx (id-sym (cadr form)))]
    [else *default-field-sz*]))

(define (emit-struct node ctx packed?)
  ;; (struct Name (field sz) (field (sizeof Other)) (field) ...)
  ;; packed? = #t → no padding; #f → natural C alignment
  ;; Metadata stored per field: fname → (list offset size)
  ;; '_total key stores the struct's total byte size.
  (let* ([name (id-sym (cadr node))]
         [cn   (c-ident name)]
         [fi+total
          (let loop ([fs (cddr node)] [off 0] [max-align 1] [acc '()])
            (if (null? fs)
                (let ([total (if packed? off (align-up off max-align))])
                  (cons (reverse acc) total))
                (let* ([f     (car fs)]
                       [fname (id-sym (if (pair? f) (car f) f))]
                       [sz    (if (and (pair? f) (pair? (cdr f)))
                                  (resolve-field-size (cadr f) ctx)
                                  *default-field-sz*)]
                       [align (if packed? 1 (field-alignment sz))]
                       [aoff  (align-up off align)])
                  (loop (cdr fs) (fx+ aoff sz) (max max-align align)
                        (cons (list fname aoff sz) acc)))))]
         [fi    (car fi+total)]
         [total (cdr fi+total)]
         [tbl   (make-eq-hashtable)])
    (for-each (lambda (f)
                (hashtable-set! tbl (car f) (list (cadr f) (caddr f))))
              fi)
    (hashtable-set! tbl '_total total)
    (hashtable-set! (ctx-structs ctx) name tbl)
    ;; At top level, emit struct macros to fwd-decls so they precede hoisted functions.
    ;; Inside a function body (ctx-fn-ret is set), emit inline.
    (let ([emit! (if (ctx-fn-ret ctx)
                     (lambda (line) (ctx-emit! ctx line))
                     (lambda (line) (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx) (list line)))))])
      (emit! (string-append "/* struct " (symbol->string name) " */"))
      (emit! (string-append "#define ANCHOR_SIZEOF_" cn " " (number->string total)))
      (for-each (lambda (f)
                  (let ([cf (c-ident (car f))])
                    (emit! (string-append "#define ANCHOR_OFFSET_" cn "_" cf " " (number->string (cadr f))))
                    (emit! (string-append "#define ANCHOR_SIZE_" cn "_" cf "  " (number->string (caddr f))))))
                fi)
      (emit! ""))))

(define (emit-union node ctx)
  ;; (union Name (field sz) ...)
  ;; All fields at offset 0; total = max field size.
  (let* ([name  (id-sym (cadr node))]
         [cn    (c-ident name)]
         [fi    (map (lambda (f)
                       (let* ([fname (id-sym (if (pair? f) (car f) f))]
                              [sz    (if (and (pair? f) (pair? (cdr f)))
                                         (resolve-field-size (cadr f) ctx)
                                         *default-field-sz*)])
                         (list fname 0 sz)))
                     (cddr node))]
         [total (fold-left (lambda (acc f) (max acc (caddr f))) 0 fi)]
         [tbl   (make-eq-hashtable)])
    (for-each (lambda (f)
                (hashtable-set! tbl (car f) (list (cadr f) (caddr f))))
              fi)
    (hashtable-set! tbl '_total total)
    (hashtable-set! (ctx-structs ctx) name tbl)
    (ctx-emit! ctx (string-append "/* union " (symbol->string name) " */"))
    (ctx-emit! ctx (string-append "#define ANCHOR_SIZEOF_" cn " " (number->string total)))
    (for-each (lambda (f)
                (let ([cf (c-ident (car f))])
                  (ctx-emit! ctx (string-append "#define ANCHOR_OFFSET_" cn "_" cf " 0"))
                  (ctx-emit! ctx (string-append "#define ANCHOR_SIZE_" cn "_" cf "  " (number->string (caddr f))))))
              fi)
    (ctx-emit-blank! ctx)))

(define (emit-enum node ctx)
  ;; (enum Name (Variant value) ...)
  ;; Emits: #define Name_Variant value
  ;; Registers enum name with size 4 for use in (sizeof-enum Name).
  (let* ([name (id-sym (cadr node))]
         [cn   (c-ident name)])
    (hashtable-set! (ctx-enums ctx) name 4)
    (ctx-emit! ctx (string-append "/* enum " (symbol->string name) " */"))
    (let loop ([variants (cddr node)] [i 0])
      (unless (null? variants)
        (let* ([v    (car variants)]
               [vn   (c-ident (if (pair? v) (car v) v))]
               [val  (if (and (pair? v) (pair? (cdr v)))
                         (number->string (cadr v))
                         (number->string i))])
          (ctx-emit! ctx (string-append "#define " cn "_" vn " " val))
          (loop (cdr variants) (fx+ i 1)))))
    (ctx-emit-blank! ctx)))

(define (parse-fn-sig node)
  ;; node = (fn name (params...) body...)
  ;; returns (name params body)
  (let ([items (cdr node)])
    (unless (and (pair? items) (sym? (car items)))
      (anchor-error "fn: expected name"))
    (let ([name (car items)] [rest (cdr items)])
      (unless (and (pair? rest) (list? (car rest)))
        (anchor-error "fn: expected param list"))
      (list name
            (map (lambda (p) (if (sym? p) p '_)) (car rest))
            (cdr rest)))))

(define (emit-fn node ctx arena-sz . rest)
  ;; rest: optional global-arena C name (string) — use a global arena instead of allocating one
  (let* ([global-arena (and (pair? rest) (car rest))]
         [sig    (parse-fn-sig node)]
         [name   (car sig)] [params (cadr sig)] [body (caddr sig)]
         [cn     (c-ident name)]
         [_      (hashtable-set! (ctx-fns ctx) (id-sym name) cn)]
         [ret    (if (eq? (id-sym name) 'main) "int" "AnchorVal")]
         [main2? (and (eq? (id-sym name) 'main) (fx= (length params) 2))]
         [c-params
          (if main2? "int _argc_raw, char** _argv_raw"
              (if (null? params) "void"
                  (str-join (map (lambda (p) (string-append "AnchorVal " (c-ident p))) params) ", ")))])
    ;; Forward declaration so hoisted lambdas can call this fn before its definition
    (unless (string=? cn "main")
      (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx)
                                      (list (string-append ret " " cn "(" c-params ");")))))
    (ctx-emit-blank! ctx)
    (ctx-emit! ctx (string-append ret " " cn "(" c-params ") {"))
    (ctx-indent! ctx)
    (when main2?
      (ctx-emit! ctx (string-append "AnchorVal " (c-ident (car params)) " = anchor_int(_argc_raw);"))
      (ctx-emit! ctx (string-append "AnchorVal " (c-ident (cadr params)) " = anchor_ext((void*)_argv_raw);")))
    (let ([old-ret   (ctx-fn-ret ctx)]
          [old-vd    (ctx-var-depth ctx)])
      (ctx-fn-ret-set! ctx ret)
      (ctx-var-depth-set! ctx (make-eq-hashtable))
      ;; Arena setup
      (let ([av #f] [use-heap #f] [has-arena #f])
        (cond
          [global-arena
           (set! av global-arena)
           (ctx-emit! ctx (string-append global-arena ".prev = _anchor_arena_top;"))
           (ctx-emit! ctx (string-append "_anchor_arena_top = &" global-arena ";"))
           (ctx-push-arena! ctx global-arena #t)
           (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))
           (set! has-arena #t)]
          [arena-sz
           (set! av "_anc_arena")
           (let ([cap (if (and (number? arena-sz) (fx> arena-sz 0))
                          (number->string (exact arena-sz))
                          "ANCHOR_DEFAULT_ARENA_CAP")])
             (set! use-heap (and (number? arena-sz) (fx> arena-sz 1048576)))
             (if use-heap
                 (ctx-emit! ctx (string-append "char* " av "_buf = (char*)__builtin_malloc(" cap ");"))
                 (ctx-emit! ctx (string-append "char " av "_buf[" cap "];")))
             (ctx-emit! ctx (string-append "_AnchorArena " av " = {" av "_buf, " cap ", 0, _anchor_arena_top};"))
             (ctx-emit! ctx (string-append "_anchor_arena_top = &" av ";"))
             (ctx-push-arena! ctx av #f)
             (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))
             (set! has-arena #t))])
        (for-each (lambda (s) (emit-stmt s ctx)) body)
        (let* ([last (and (pair? body) (list-ref body (fx- (length body) 1)))]
               [has-ret (and last (pair? last) (eq? (id-sym (car last)) 'return))])
          (unless has-ret
            (when has-arena
              (if global-arena
                  (ctx-emit! ctx (string-append "_anchor_arena_top = " global-arena ".prev;"))
                  (begin
                    (ctx-emit! ctx (string-append "_anchor_arena_top = " av ".prev;"))
                    (when use-heap (ctx-emit! ctx (string-append "__builtin_free(" av "_buf);")))))
              (ctx-pop-arena! ctx)
              (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1)))
            (ctx-emit! ctx (if (string=? ret "int") "return 0;" "return anchor_int(0);")))
          (when (and has-ret has-arena)
            (ctx-pop-arena! ctx)
            (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1)))))
      (ctx-fn-ret-set! ctx old-ret)
      (ctx-var-depth-set! ctx old-vd))
    (ctx-dedent! ctx)
    (ctx-emit! ctx "}")))

(define (emit-with-arena node ctx)
  (let* ([items (cdr node)]
         [first (and (pair? items) (car items))])
    (cond
      ;; (with-arena name body...) — use existing global arena
      [(and (sym? first) (not (number? first)))
       (let* ([name  first]
              [body  (cdr items)]
              [cname (hashtable-ref (ctx-global-arenas ctx) (id-sym name) #f)])
         (unless cname (anchor-error "with-arena: not a declared global-arena" name))
         (when (null? body) (anchor-error "with-arena: empty body"))
         (if (for-all (lambda (f) (and (pair? f) (memv (id-sym (car f)) '(fn fn-c)))) body)
             (for-each (lambda (f)
                         (if (eq? (id-sym (car f)) 'fn-c)
                             (emit-fn-c f ctx 0 cname)
                             (emit-fn f ctx #f cname))) body)
             (begin
               (ctx-emit! ctx "{")
               (ctx-indent! ctx)
               (ctx-emit! ctx (string-append cname ".prev = _anchor_arena_top;"))
               (ctx-emit! ctx (string-append "_anchor_arena_top = &" cname ";"))
               (ctx-push-arena! ctx cname #t)
               (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))
               (for-each (lambda (f) (emit-stmt f ctx)) body)
               (ctx-emit! ctx (string-append "_anchor_arena_top = " cname ".prev;"))
               (ctx-pop-arena! ctx)
               (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1))
               (ctx-dedent! ctx)
               (ctx-emit! ctx "}"))))]
      ;; (with-arena size body...) or (with-arena body...) — anonymous scoped arena
      [else
       (let* ([sz   (if (number? first) (exact first) 0)]
              [body (if (number? first) (cdr items) items)])
         (when (null? body) (anchor-error "with-arena: empty body"))
         (if (for-all (lambda (f) (and (pair? f) (memv (id-sym (car f)) '(fn fn-c)))) body)
             (for-each (lambda (f)
                         (if (eq? (id-sym (car f)) 'fn-c)
                             (emit-fn-c f ctx sz)
                             (emit-fn f ctx sz))) body)
             (let* ([cap      (if (fx> sz 0) (number->string sz) "ANCHOR_DEFAULT_ARENA_CAP")]
                    [av       (string-append "_anc_arena_" (ctx-tmp! ctx))]
                    [use-heap (fx> sz 1048576)])
               (ctx-emit! ctx "{")
               (ctx-indent! ctx)
               (if use-heap
                   (ctx-emit! ctx (string-append "char* " av "_buf = (char*)__builtin_malloc(" cap ");"))
                   (ctx-emit! ctx (string-append "char " av "_buf[" cap "];")))
               (ctx-emit! ctx (string-append "_AnchorArena " av " = {" av "_buf, " cap ", 0, _anchor_arena_top};"))
               (ctx-emit! ctx (string-append "_anchor_arena_top = &" av ";"))
               (ctx-push-arena! ctx av #f)
               (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))
               (for-each (lambda (f) (emit-stmt f ctx)) body)
               (ctx-emit! ctx (string-append "_anchor_arena_top = " av ".prev;"))
               (when use-heap (ctx-emit! ctx (string-append "__builtin_free(" av "_buf);")))
               (ctx-pop-arena! ctx)
               (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1))
               (ctx-dedent! ctx)
               (ctx-emit! ctx "}"))))])))

(define (emit-with-parent-arena node ctx)
  ;; (with-parent-arena body...) — allocations go into the arena one level up.
  ;; Saves _anchor_arena_top, sets it to top->prev, runs body, restores.
  (let ([body (cdr node)])
    (when (null? body) (anchor-error "with-parent-arena: empty body"))
    (let ([sv (string-append "_anc_psaved_" (ctx-tmp! ctx))])
      (ctx-emit! ctx "{")
      (ctx-indent! ctx)
      (ctx-emit! ctx (string-append "_AnchorArena* " sv " = _anchor_arena_top;"))
      (ctx-emit! ctx (string-append "_anchor_arena_top = _anchor_arena_top ? _anchor_arena_top->prev : NULL;"))
      (ctx-push-restore! ctx sv)
      (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))
      (for-each (lambda (s) (emit-stmt s ctx)) body)
      (ctx-emit! ctx (string-append "_anchor_arena_top = " sv ";"))
      (ctx-pop-arena! ctx)
      (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1))
      (ctx-dedent! ctx)
      (ctx-emit! ctx "}"))))

(define (emit-global-arena node ctx)
  ;; (global-arena name size) — static buffer, linked into arena stack at runtime
  (let* ([items  (cdr node)]
         [name   (car items)]
         [size   (cadr items)]
         [cap    (number->string (exact size))]
         [cn     (c-ident name)]
         [cname  (string-append "_anc_ga_" cn)])
    (hashtable-set! (ctx-global-arenas ctx) (id-sym name) cname)
    (ctx-globals-set! ctx
      (append (ctx-globals ctx)
              (list (string-append "static char " cname "_buf[" cap "];")
                    (string-append "static _AnchorArena " cname
                                   " = {" cname "_buf, " cap ", 0, NULL};"))))))

(define (emit-global node ctx const?)
  (let* ([name  (cadr node)]
         [cname (c-ident name)]
         [expr  (caddr node)])
    (cond
      [(and (number? expr) (inexact? expr))
       ;; Float: must use constructor since anchor_float is not a constant expression
       (ctx-globals-set! ctx
         (append (ctx-globals ctx)
                 (list (string-append "AnchorVal " cname " = 0;")
                       (string-append "__attribute__((constructor)) static void _anc_init_" cname
                                      "(void) { " cname " = anchor_float(" (number->string expr) "); }"))))]
      [(and (number? expr) (exact? expr))
       ;; Integer: raw int64 — static initializer
       (ctx-globals-set! ctx
         (append (ctx-globals ctx)
                 (list (string-append (if const? "const " "") "AnchorVal " cname
                                      " = (AnchorVal)(int64_t)"
                                      (number->string expr) ";"))))]
      [(and (not const?) (pair? expr) (eq? (id-sym (car expr)) 'alloc)
            (pair? (cdr expr)) (number? (cadr expr)) (exact? (cadr expr)))
       (let* ([sz    (cadr expr)]
              [ss    (number->string sz)])
         (ctx-globals-set! ctx
           (append (ctx-globals ctx)
                   (list (string-append "static char _g_" cname "_storage[" ss "];")
                         (string-append "AnchorVal " cname " = 0;")
                         (string-append "__attribute__((constructor)) static void _anc_init_" cname
                                        "(void) { " cname " = anchor_ext(_g_" cname "_storage); }")))))]
      [(and (not const?) (pair? expr) (eq? (id-sym (car expr)) 'alloc)
            (pair? (cdr expr)) (pair? (cadr expr))
            (memv (id-sym (car (cadr expr))) '(sizeof)))
       (let* ([sz-expr  (cadr expr)]
              [sname    (cadr sz-expr)]
              [anc-sz   (let ([ht (hashtable-ref (ctx-structs ctx) (id-sym sname) #f)])
                          (and ht (hashtable-ref ht '_total #f)))]
              [sz       (if anc-sz
                            (number->string anc-sz)
                            (string-append "sizeof(" (c-ident sname) ")"))])
         (ctx-globals-set! ctx
           (append (ctx-globals ctx)
                   (list (string-append "static char _g_" cname "_storage[" sz "];")
                         (string-append "AnchorVal " cname " = 0;")
                         (string-append "__attribute__((constructor)) static void _anc_init_" cname
                                        "(void) { " cname " = anchor_ext(_g_" cname "_storage); }")))))]
      [else
       (anchor-error (if const? "const: initializer must be a number"
                                "global: initializer must be number or (alloc N) or (alloc (sizeof Name))"))])))

(define (emit-fn-c node ctx . rest-args)
  ;; (fn-c name ((type... pname) ...) -> ret-type  body ...)
  ;; Emits a C-native-signature function.  Parameters are wrapped as AnchorVals
  ;; inside the body so normal Anchor expressions work.  The return statement
  ;; casts back to the declared C return type.
  ;; The function is also registered in the externs table so Anchor call sites
  ;; get the correct FFI casting without a separate ffi declaration.
  (let ([arena-sz     (and (pair? rest-args) (car rest-args))]
        [global-arena (and (pair? rest-args) (pair? (cdr rest-args)) (cadr rest-args))])
  (unless (fx>= (length node) 4)
    (anchor-error "fn-c: (fn-c name ((type... pname) ...) -> ret-type body...)"))
  (let* ([name      (cadr node)]
         [params    (caddr node)]
         [rest      (cdddr node)]
         [ret-str   (if (and (fx>= (length rest) 2) (eq? (id-sym (car rest)) '->))
                        (cast-type-str (cadr rest))
                        (anchor-error "fn-c: missing -> ret-type"))]
         [body      (if (and (fx>= (length rest) 2) (eq? (id-sym (car rest)) '->))
                        (cddr rest) rest)]
         [cname     (c-ident name)]
         ;; Each param is (type-token ... param-name); last token is the name.
         [parsed    (map (lambda (p)
                           (let* ([syms   (map (lambda (s) (symbol->string (id-sym s))) p)]
                                  [n      (length syms)]
                                  [pname  (list-ref syms (fx- n 1))]
                                  [type-s (str-join (list-head syms (fx- n 1)) " ")])
                             (cons type-s pname)))
                         params)]
         [c-params  (str-join (map (lambda (p)
                                     (string-append (car p) " _raw_" (cdr p)))
                                   parsed) ", ")]
         [c-sig     (string-append ret-str " " cname
                                   "(" (if (null? parsed) "void" c-params) ")")]
         [param-types (map car parsed)])
    ;; Register so (name arg ...) call sites get FFI casting without ffi decl
    (hashtable-set! (ctx-externs ctx) (id-sym name) (cons ret-str param-types))
    ;; Forward declaration
    (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx)
                                    (list (string-append c-sig ";"))))
    ;; Function definition
    (ctx-emit! ctx (string-append c-sig " {"))
    (ctx-indent! ctx)
    ;; Wrap each raw C parameter as an AnchorVal for the body
    (for-each (lambda (p)
                (let* ([c-type (car p)]
                       [pname  (cdr p)]
                       [raw    (string-append "_raw_" pname)]
                       [wrap   (if (pointer-type? c-type)
                                   (string-append "AnchorVal " pname
                                                  " = anchor_ext((void*)" raw ");")
                                   (string-append "AnchorVal " pname
                                                  " = anchor_int((intptr_t)" raw ");"))])
                  (ctx-emit! ctx wrap)))
              parsed)
    ;; Optional arena setup (when wrapped in with-arena)
    (let ([av #f] [use-heap #f])
      (cond
        [global-arena
         (set! av global-arena)
         (ctx-emit! ctx (string-append global-arena ".prev = _anchor_arena_top;"))
         (ctx-emit! ctx (string-append "_anchor_arena_top = &" global-arena ";"))
         (ctx-push-arena! ctx global-arena #t)
         (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))]
        [arena-sz
         (set! av "_anc_arena")
         (let ([cap (if (and (number? arena-sz) (fx> arena-sz 0))
                        (number->string arena-sz)
                        "ANCHOR_DEFAULT_ARENA_CAP")])
           (set! use-heap (and (number? arena-sz) (fx> arena-sz 1048576)))
           (if use-heap
               (ctx-emit! ctx (string-append "char* " av "_buf = (char*)__builtin_malloc(" cap ");"))
               (ctx-emit! ctx (string-append "char " av "_buf[" cap "];")))
           (ctx-emit! ctx (string-append "_AnchorArena " av " = {" av "_buf, " cap ", 0, _anchor_arena_top};"))
           (ctx-emit! ctx (string-append "_anchor_arena_top = &" av ";"))
           (ctx-push-arena! ctx av #f)
           (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1)))])
    ;; Emit body; ctx-fn-ret set so return emits the right C cast
    (let ([prev-ret (ctx-fn-ret ctx)])
      (ctx-fn-ret-set! ctx ret-str)
      (for-each (lambda (s) (emit-stmt s ctx)) body)
      (ctx-fn-ret-set! ctx prev-ret))
    (when (or arena-sz global-arena)
      (if global-arena
          (ctx-emit! ctx (string-append "_anchor_arena_top = " global-arena ".prev;"))
          (begin
            (ctx-emit! ctx (string-append "_anchor_arena_top = " av ".prev;"))
            (when use-heap (ctx-emit! ctx (string-append "__builtin_free(" av "_buf);")))))
      (ctx-pop-arena! ctx)
      (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1)))
    (ctx-dedent! ctx)
    (ctx-emit! ctx "}")))))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

(define (anchor-generate exprs)
  (let ([ctx (make-ctx)])
    ;; First pass: process declarations; collect body forms
    (let loop ([es exprs] [body '()])
      (if (null? es)
          ;; Second pass: emit body forms
          (let ([body (reverse body)])
            (for-each (lambda (e) (emit-stmt e ctx)) body)
            ;; Assemble output
            (let ([parts (list (if *multi-threaded*
                                    (string-append "#define ANCHOR_MULTI_THREADED 1\n" *anchor-runtime-h*)
                                    *anchor-runtime-h*))])
              (when (pair? (ctx-fwd-decls ctx))
                (set! parts (append parts (list "") (ctx-fwd-decls ctx))))
              (when (pair? (ctx-globals ctx))
                (set! parts (append parts (list "") (ctx-globals ctx))))
              (when (pair? (ctx-hoisted ctx))
                (set! parts (append parts (list "") (ctx-hoisted ctx))))
              (let ([body-out (ctx-output ctx)])
                (when (fx> (string-length body-out) 0)
                  (set! parts (append parts (list "" body-out)))))
              (str-join parts "\n")))
          (let ([e (car es)])
            (if (not (pair? e))
                (loop (cdr es) body)
                (case (id-sym (car e))
                  [(extern-global) (emit-stmt e ctx)           (loop (cdr es) body)]
                  [(ffi)           (emit-ffi  e ctx)           (loop (cdr es) body)]
                  [(fn-c)          (hashtable-set! (ctx-fns ctx) (id-sym (cadr e)) (c-ident (cadr e)))
                                   (emit-fn-c e ctx)           (loop (cdr es) body)]
                  [(include)       (emit-stmt e ctx)           (loop (cdr es) body)]
                  [(global)        (emit-global e ctx #f)      (loop (cdr es) body)]
                  [(const)         (emit-global e ctx #t)      (loop (cdr es) body)]
                  [(global-arena)  (emit-global-arena e ctx)   (loop (cdr es) body)]
                  [(struct)        (emit-struct e ctx #t) (loop (cdr es) body)]
                  [(unpacked-struct) (emit-struct e ctx #f) (loop (cdr es) body)]
                  [(union)         (emit-union  e ctx)    (loop (cdr es) body)]
                  [(enum)          (emit-enum   e ctx)    (loop (cdr es) body)]
                  [(fn)            (hashtable-set! (ctx-fns ctx) (id-sym (cadr e)) (c-ident (cadr e)))
                                   (loop (cdr es) (cons e body))]
                  [else            (loop (cdr es) (cons e body))])))))))
