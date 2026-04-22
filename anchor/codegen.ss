;;; codegen.ss — Anchor AST → C source

(define *anchor-runtime-h*
"#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* =========================================================
 * Anchor runtime — fat pointer + arena allocator
 * ========================================================= */

/* Every Anchor value is a fat pointer */
typedef struct {
    void*  ptr;
    size_t size;
} AnchorVal;

/* ---- Arena ---- */
#ifndef ANCHOR_DEFAULT_ARENA_CAP
#  define ANCHOR_DEFAULT_ARENA_CAP (1024 * 1024)   /* 1 MiB */
#endif

typedef struct AnchorArena {
    char*              buf;
    size_t             cap;
    size_t             used;
    struct AnchorArena* prev;
} AnchorArena;

/* Arena stack — each translation unit has its own (with-arena fns are self-contained) */
static _Thread_local AnchorArena* _anchor_arena_top = NULL;

/* Allocate SIZE bytes from the current arena, aligned to 8 bytes */
static inline AnchorVal anchor_alloc(size_t size) {
    AnchorArena* a = _anchor_arena_top;
    if (!a) { __builtin_trap(); }
    size_t aligned = (size + 7u) & ~7u;
    if (a->used + aligned > a->cap) { __builtin_trap(); }
    void* ptr = a->buf + a->used;
    a->used += aligned;
    return (AnchorVal){ ptr, size };
}

/* ---- Unboxed scalar representation ----
 * Scalars (int, float, etc.) are stored directly in the ptr field.
 * size has its high bit set to distinguish from real heap pointers
 * (no real allocation can be >= 2^63 bytes).
 * The operator — not the tag — determines how ptr bits are interpreted.
 */
#define ANCHOR_UNBOXED          ((size_t)1 << 63)
#define _ANCH_IS_UNBOXED(v)     ((v).size >> 63)
#define _ANCH_IVAL(v)           ((intptr_t)(uintptr_t)(v).ptr)
#define _ANCH_FVAL(v)           \
    ({ uint64_t _b = (uint64_t)(uintptr_t)(v).ptr; \
       double _f; __builtin_memcpy(&_f, &_b, sizeof(double)); _f; })

/* Hint: all pure arithmetic/comparison functions have no side effects.
 * __attribute__((const)) lets the compiler hoist loop-invariant calls. */
#if defined(__GNUC__) || defined(__clang__)
#  define ANCHOR_PURE __attribute__((const))
#else
#  define ANCHOR_PURE
#endif

/* ---- Literal constructors ---- */

static inline ANCHOR_PURE AnchorVal anchor_int(intptr_t v) {
    return (AnchorVal){ (void*)(uintptr_t)v, ANCHOR_UNBOXED };
}

static inline ANCHOR_PURE AnchorVal anchor_float(double v) {
    uint64_t bits;
    __builtin_memcpy(&bits, &v, sizeof(double));
    return (AnchorVal){ (void*)(uintptr_t)bits, ANCHOR_UNBOXED };
}

static inline AnchorVal anchor_str(const char* s) {
    size_t len = __builtin_strlen(s) + 1;
    AnchorVal val = anchor_alloc(len);
    __builtin_memcpy(val.ptr, s, len);
    return val;
}

/* Wrap an existing C pointer as a fat pointer (does NOT copy) */
static inline ANCHOR_PURE AnchorVal anchor_ptr(void* p, size_t size) {
    return (AnchorVal){ p, size };
}

/* ---- Integer arithmetic ---- */

static inline ANCHOR_PURE AnchorVal anchor_add(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) + _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_sub(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) - _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_mul(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) * _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_div(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) / _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_mod(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) % _ANCH_IVAL(b)); }

/* ---- Float arithmetic ---- */

static inline ANCHOR_PURE AnchorVal anchor_addf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) + _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_subf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) - _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_mulf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) * _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_divf(AnchorVal a, AnchorVal b) { return anchor_float(_ANCH_FVAL(a) / _ANCH_FVAL(b)); }

/* ---- Comparisons (result is AnchorVal wrapping 1 or 0) ---- */

static inline ANCHOR_PURE AnchorVal anchor_eq(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) == _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_ne(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) != _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_lt(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) <  _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gt(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) >  _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_le(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) <= _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_ge(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) >= _ANCH_IVAL(b)); }

/* ---- Bitwise ---- */

static inline ANCHOR_PURE AnchorVal anchor_band(AnchorVal a, AnchorVal b)   { return anchor_int(_ANCH_IVAL(a) &  _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_bor (AnchorVal a, AnchorVal b)   { return anchor_int(_ANCH_IVAL(a) |  _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_bxor(AnchorVal a, AnchorVal b)   { return anchor_int(_ANCH_IVAL(a) ^  _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_bnot(AnchorVal a)                { return anchor_int(~_ANCH_IVAL(a)); }
static inline ANCHOR_PURE AnchorVal anchor_lshift(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_IVAL(a) << _ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_rshift(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) >> _ANCH_IVAL(b))); }

/* ---- Unsigned arithmetic ---- */

static inline ANCHOR_PURE AnchorVal anchor_addu(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) + (uintptr_t)_ANCH_IVAL(b))); }
static inline ANCHOR_PURE AnchorVal anchor_subu(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) - (uintptr_t)_ANCH_IVAL(b))); }
static inline ANCHOR_PURE AnchorVal anchor_mulu(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) * (uintptr_t)_ANCH_IVAL(b))); }
static inline ANCHOR_PURE AnchorVal anchor_divu(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) / (uintptr_t)_ANCH_IVAL(b))); }
static inline ANCHOR_PURE AnchorVal anchor_modu(AnchorVal a, AnchorVal b) { return anchor_int((intptr_t)((uintptr_t)_ANCH_IVAL(a) % (uintptr_t)_ANCH_IVAL(b))); }
static inline ANCHOR_PURE AnchorVal anchor_ltu (AnchorVal a, AnchorVal b) { return anchor_int((uintptr_t)_ANCH_IVAL(a) <  (uintptr_t)_ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gtu (AnchorVal a, AnchorVal b) { return anchor_int((uintptr_t)_ANCH_IVAL(a) >  (uintptr_t)_ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_leu (AnchorVal a, AnchorVal b) { return anchor_int((uintptr_t)_ANCH_IVAL(a) <= (uintptr_t)_ANCH_IVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_geu (AnchorVal a, AnchorVal b) { return anchor_int((uintptr_t)_ANCH_IVAL(a) >= (uintptr_t)_ANCH_IVAL(b)); }

/* ---- Float comparisons ---- */

static inline ANCHOR_PURE AnchorVal anchor_eqf(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) == _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_nef(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) != _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_ltf(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) <  _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gtf(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) >  _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_lef(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) <= _ANCH_FVAL(b)); }
static inline ANCHOR_PURE AnchorVal anchor_gef(AnchorVal a, AnchorVal b) { return anchor_int(_ANCH_FVAL(a) >= _ANCH_FVAL(b)); }

/* ---- Linked list (cons cells) ----
 *
 * A cons cell is two adjacent AnchorVals (16 bytes) arena-allocated.
 * nil is represented as {NULL, 0} — a naturally zero-sized pointer.
 *
 *   anchor_cons(car, cdr)  — allocate cell from current arena
 *   ANCHOR_CAR(cell)       — first element
 *   ANCHOR_CDR(cell)       — rest of list
 *   ANCHOR_NIL             — empty list sentinel
 *   ANCHOR_NULLP(v)        — true if v is nil
 */

#define ANCHOR_NIL         ((AnchorVal){NULL, 0})
#define ANCHOR_NULLP(v)    ((v).size == 0)
#define ANCHOR_CAR(cell)       (((AnchorVal*)(cell).ptr)[0])
#define ANCHOR_CDR(cell)       (((AnchorVal*)(cell).ptr)[1])
#define ANCHOR_SET_CAR(cell,v) (((AnchorVal*)(cell).ptr)[0] = (v))
#define ANCHOR_SET_CDR(cell,v) (((AnchorVal*)(cell).ptr)[1] = (v))

static inline AnchorVal anchor_cons(AnchorVal car, AnchorVal cdr) {
    AnchorVal cell = anchor_alloc(2 * sizeof(AnchorVal));
    ((AnchorVal*)cell.ptr)[0] = car;
    ((AnchorVal*)cell.ptr)[1] = cdr;
    return cell;
}

/* ---- Logical ---- */

static inline ANCHOR_PURE AnchorVal anchor_and(AnchorVal a, AnchorVal b) {
    return anchor_int(_ANCH_IVAL(a) && _ANCH_IVAL(b));
}
static inline ANCHOR_PURE AnchorVal anchor_or(AnchorVal a, AnchorVal b) {
    return anchor_int(_ANCH_IVAL(a) || _ANCH_IVAL(b));
}
static inline ANCHOR_PURE AnchorVal anchor_not(AnchorVal a) {
    return anchor_int(!_ANCH_IVAL(a));
}
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
    (mutable arena-stack  ctx-arena-stack  ctx-arena-stack-set!)
    (mutable fn-ret       ctx-fn-ret       ctx-fn-ret-set!)
    (mutable fwd-decls    ctx-fwd-decls    ctx-fwd-decls-set!)
    (mutable globals      ctx-globals      ctx-globals-set!)
    (mutable arena-depth  ctx-arena-depth  ctx-arena-depth-set!)
    (mutable var-depth    ctx-var-depth    ctx-var-depth-set!)
    (mutable global-arenas ctx-global-arenas ctx-global-arenas-set!))
  (protocol
    (lambda (new)
      (lambda ()
        (new '() 0 0
             (make-eq-hashtable) (make-eq-hashtable) (make-eq-hashtable)
             '() #f '() '() 0
             (make-eq-hashtable) (make-eq-hashtable))))))

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

(define (ctx-push-arena! ctx av global?)
  (ctx-arena-stack-set! ctx (cons (cons av global?) (ctx-arena-stack ctx))))
;; Push a restore entry: on cleanup, restores _anchor_arena_top to saved-var directly.
;; Used by with-parent-arena — no new arena is created, just the top pointer is redirected.
(define (ctx-push-restore! ctx saved-var)
  (ctx-arena-stack-set! ctx (cons (cons 'restore saved-var) (ctx-arena-stack ctx))))
(define (ctx-pop-arena!  ctx)    (ctx-arena-stack-set! ctx (cdr (ctx-arena-stack ctx))))
(define (ctx-in-arena?   ctx)    (pair? (ctx-arena-stack ctx)))
(define (ctx-arena-top-global? ctx)
  (and (pair? (ctx-arena-stack ctx))
       (let ([top (car (ctx-arena-stack ctx))])
         ;; restore entries allocate into the parent arena — treat as non-local (no copy needed)
         (or (eq? (car top) 'restore) (cdr top)))))

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

;; ---------------------------------------------------------------------------
;; Operator tables
;; ---------------------------------------------------------------------------

(define *arith-ops*
  '((+  . "anchor_add")  (-  . "anchor_sub")  (*  . "anchor_mul")
    (/  . "anchor_div")  (%  . "anchor_mod")
    (+f . "anchor_addf") (-f . "anchor_subf")  (*f . "anchor_mulf") (/f . "anchor_divf")
    (+u . "anchor_addu") (-u . "anchor_subu")  (*u . "anchor_mulu")
    (/u . "anchor_divu") (%u . "anchor_modu")
    (band . "anchor_band") (bor . "anchor_bor") (bxor . "anchor_bxor")
    (lshift . "anchor_lshift") (rshift . "anchor_rshift")))

(define *cmp-ops*
  '((==  . "anchor_eq")  (!=  . "anchor_ne")
    (<   . "anchor_lt")  (>   . "anchor_gt")  (<=  . "anchor_le")  (>=  . "anchor_ge")
    (==f . "anchor_eqf") (!=f . "anchor_nef")
    (<f  . "anchor_ltf") (>f  . "anchor_gtf") (<=f . "anchor_lef") (>=f . "anchor_gef")
    (<u  . "anchor_ltu") (>u  . "anchor_gtu") (<=u . "anchor_leu") (>=u . "anchor_geu")))

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
    [(sym? node) (symbol->string (id-sym node))]
    [(pair? node) (str-join (map cast-type-str node) " ")]
    [else (anchor-error "invalid type in cast" node)]))

;; ---------------------------------------------------------------------------
;; Field-chain helper — shared by field-get and get
;; Walks the chain (sn ptr rest) and returns a C expression string.
;; ---------------------------------------------------------------------------

(define (emit-field-chain sn ptr rest ctx pre)
  (let loop ([sn sn] [ptr ptr] [rest rest])
    (let ([fname (car rest)]
          [after (cdr rest)])
      (cond
        ;; (val f) or (val f1 f2) — reconstruct full AnchorVal from field(s)
        [(and (pair? fname) (eq? (id-sym (car fname)) 'val))
         (unless (null? after)
           (anchor-error "field-get: (val ...) must be terminal"))
         (let* ([vargs (cdr fname)]
                [nf    (length vargs)]
                [_     (unless (memv nf '(1 2))
                         (anchor-error "field-get val: 1 or 2 fields required"))]
                [csn   (c-ident sn)]
                [ht    (or (hashtable-ref (ctx-structs ctx) (id-sym sn) #f)
                           (anchor-error "field-get val: unknown struct" sn))]
                [tmp   (ctx-tmp! ctx)])
           (if (fx= nf 1)
               (let* ([f1n (car vargs)]
                      [cf1 (c-ident f1n)]
                      [e1  (or (hashtable-ref ht (id-sym f1n) #f)
                               (anchor-error "field-get val: unknown field" f1n))]
                      [_   (unless (fx= (cadr e1) 16)
                             (anchor-error "field-get val: single field must be 16 bytes" f1n))])
                 (pre-add! pre (string-append "AnchorVal " tmp ";"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf1 ", 16);"))
                 tmp)
               (let* ([f1n (car vargs)] [f2n (cadr vargs)]
                      [cf1 (c-ident f1n)] [cf2 (c-ident f2n)]
                      [e1  (or (hashtable-ref ht (id-sym f1n) #f)
                               (anchor-error "field-get val: unknown field" f1n))]
                      [e2  (or (hashtable-ref ht (id-sym f2n) #f)
                               (anchor-error "field-get val: unknown field" f2n))]
                      [_   (unless (fx= (cadr e1) 8)
                             (anchor-error "field-get val: f1 must be 8-byte field" f1n))]
                      [_   (unless (fx= (cadr e2) 8)
                             (anchor-error "field-get val: f2 must be 8-byte field" f2n))])
                 (pre-add! pre (string-append "intptr_t " tmp "_ptr = 0;"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp "_ptr, (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf1 ", 8);"))
                 (pre-add! pre (string-append "intptr_t " tmp "_sz = 0;"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp "_sz, (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf2 ", 8);"))
                 (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)(uintptr_t)" tmp "_ptr, (size_t)" tmp "_sz};"))
                 tmp)))]
        ;; byte-offset step — bare number or any expression (not a symbol)
        [(not (sym? fname))
         (let* ([offset (emit-expr fname ctx pre)]
                [tmp    (ctx-tmp! ctx)])
           (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + _ANCH_IVAL(" offset ")), 0};"))
           (cond
             [(null? after)
              ;; lone terminal offset — scalar read (8 bytes)
              (let ([stmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "intptr_t " stmp "_raw = 0;"))
                (pre-add! pre (string-append "__builtin_memcpy(&" stmp "_raw, " tmp ".ptr, 8);"))
                (pre-add! pre (string-append "AnchorVal " stmp " = anchor_int(" stmp "_raw);"))
                stmp)]
             ;; struct type next: terminal or named chain
             [(and (sym? (car after)) (hashtable-ref (ctx-structs ctx) (id-sym (car after)) #f))
              (if (null? (cdr after))
                  (let* ([sz   (struct-total-size ctx (id-sym (car after)))]
                         [ptmp (ctx-tmp! ctx)])
                    (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){" tmp ".ptr, " (number->string sz) "};"))
                    ptmp)
                  (loop (id-sym (car after)) tmp (cdr after)))]
             ;; -> after offset: dereference stored pointer
             [(and (sym? (car after)) (eq? (id-sym (car after)) '->))
              (when (null? (cdr after))
                (anchor-error "field-get: expected type after ->"))
              (let* ([next (cadr after)]
                     [ptmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "intptr_t " ptmp "_raw = 0;"))
                (pre-add! pre (string-append "__builtin_memcpy(&" ptmp "_raw, " tmp ".ptr, 8);"))
                (if (and (sym? next) (hashtable-ref (ctx-structs ctx) (id-sym next) #f))
                    (let ([sz (struct-total-size ctx (id-sym next))])
                      (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){(void*)(uintptr_t)" ptmp "_raw, " (number->string (or sz 0)) "};"))
                      (if (null? (cddr after))
                          ptmp
                          (loop (id-sym next) ptmp (cddr after))))
                    (begin
                      (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){(void*)(uintptr_t)" ptmp "_raw, 0};"))
                      (loop sn ptmp (cddr after)))))]
             ;; size terminal — any non-struct, non--> symbol or expression
             [else
              (let* ([sz-e  (emit-expr (car after) ctx pre)]
                     [ptmp  (ctx-tmp! ctx)])
                (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){" tmp ".ptr, (size_t)_ANCH_IVAL(" sz-e ")};" ))
                (if (null? (cdr after))
                    ptmp
                    (loop sn ptmp (cdr after))))]))]
        [else
         ;; If fname is not actually a field of sn, treat it as an offset or type context
         (let* ([ht    (and (sym? sn) (hashtable-ref (ctx-structs ctx) (id-sym sn) #f))]
                [field (and ht (hashtable-ref ht (id-sym fname) #f))])
           (if (not field)
               ;; Not a known field — struct name or offset variable
               (if (and (sym? fname) (hashtable-ref (ctx-structs ctx) (id-sym fname) #f))
                   ;; Struct name: type terminal or named chain
                   (if (null? after)
                       (let* ([sz   (struct-total-size ctx (id-sym fname))]
                              [ptmp (ctx-tmp! ctx)])
                         (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){" ptr ".ptr, " (number->string sz) "};"))
                         ptmp)
                       (loop (id-sym fname) ptr after))
                   ;; Offset variable: evaluate as expression
                   (let* ([offset (emit-expr fname ctx pre)]
                          [tmp    (ctx-tmp! ctx)])
                     (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + _ANCH_IVAL(" offset ")), 0};"))
                     (cond
                       [(null? after) tmp]
                       [(and (sym? (car after)) (hashtable-ref (ctx-structs ctx) (id-sym (car after)) #f))
                        (if (null? (cdr after))
                            (let* ([sz   (struct-total-size ctx (id-sym (car after)))]
                                   [ptmp (ctx-tmp! ctx)])
                              (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){" tmp ".ptr, " (number->string sz) "};"))
                              ptmp)
                            (loop (id-sym (car after)) tmp (cdr after)))]
                       [else (loop sn tmp after)])))
               ;; IS a known field — proceed normally
               (let* ([csn (c-ident sn)] [cfn (c-ident fname)])
           (cond
             [(null? after)
              (let ([tmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "intptr_t " tmp "_raw = 0;"))
                (pre-add! pre (string-append "__builtin_memcpy(&" tmp "_raw, (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn ", ANCHOR_SIZE_" csn "_" cfn ");"))
                (pre-add! pre (string-append "AnchorVal " tmp " = anchor_int((intptr_t)" tmp "_raw);"))
                tmp)]
             ;; field followed by offset expression (number or non-symbol)
             [(not (sym? (car after)))
              (let ([tmp (ctx-tmp! ctx)])
                (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn "), 0};"))
                (loop sn tmp after))]
             [(eq? (id-sym (car after)) '->)
              (when (null? (cdr after))
                (anchor-error "field-get: expected struct type or [i stride] after ->"))
              (let* ([next  (cadr after)]
                     [tmp   (ctx-tmp! ctx)])
                (pre-add! pre (string-append "intptr_t " tmp "_raw = 0;"))
                (pre-add! pre (string-append "__builtin_memcpy(&" tmp "_raw, (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn ", 8);"))
                (if (not (and (sym? next) (hashtable-ref (ctx-structs ctx) (id-sym next) #f)))
                    ;; -> expression ... : read pointer, then continue with offset
                    (let ([base (ctx-tmp! ctx)])
                      (pre-add! pre (string-append "AnchorVal " base " = (AnchorVal){(void*)(uintptr_t)" tmp "_raw, 0};"))
                      (loop sn base (cdr after)))
                    ;; -> TypeName ... : typed pointer follow
                    (let* ([s2n   next]
                           [s2_sz (struct-total-size ctx (id-sym s2n))])
                      (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)(uintptr_t)" tmp "_raw, " (number->string (or s2_sz 0)) "};"))
                      (if (null? (cddr after))
                          tmp
                          (loop s2n tmp (cddr after))))))]
             [else
              (if (and (sym? (car after)) (hashtable-ref (ctx-structs ctx) (id-sym (car after)) #f))
                  ;; next is a known struct type — navigate into it
                  (let* ([s2n   (car after)]
                         [s2_sz (struct-total-size ctx (id-sym s2n))]
                         [tmp   (ctx-tmp! ctx)])
                    (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn "), " (number->string s2_sz) "};"))
                    (if (null? (cdr after))
                        tmp
                        (loop s2n tmp (cdr after))))
                  ;; next is a symbol offset variable (e.g. sz from let)
                  (let* ([tmp   (ctx-tmp! ctx)]
                         [off-e (emit-expr (car after) ctx pre)]
                         [rest2 (cdr after)])
                    (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn "), 0};"))
                    (let ([tmp2 (ctx-tmp! ctx)])
                      (pre-add! pre (string-append "AnchorVal " tmp2 " = (AnchorVal){(void*)((char*)" tmp ".ptr + _ANCH_IVAL(" off-e ")), 0};"))
                      (cond
                        [(null? rest2) tmp2]
                        [(and (sym? (car rest2)) (hashtable-ref (ctx-structs ctx) (id-sym (car rest2)) #f))
                         (if (null? (cdr rest2))
                             (let* ([sz2  (struct-total-size ctx (id-sym (car rest2)))]
                                    [ptmp (ctx-tmp! ctx)])
                               (pre-add! pre (string-append "AnchorVal " ptmp " = (AnchorVal){" tmp2 ".ptr, " (number->string sz2) "};"))
                               ptmp)
                             (loop (id-sym (car rest2)) tmp2 (cdr rest2)))]
                        [else (loop sn tmp2 rest2)]))))]))))]))))

;; ---------------------------------------------------------------------------
;; Expression emitter — returns a C expression string; side-effects go to pre
;; ---------------------------------------------------------------------------

(define (emit-expr node ctx pre)
  (cond
    ;; Boolean (#t/#f from transformer bodies or reader)
    [(boolean? node)
     (if node "anchor_int(1)" "anchor_int(0)")]

    ;; Bytevector — embed as static const array, yield anchor_ptr to it
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
       (string-append "anchor_ptr((void*)" tmp "_data, " (number->string len) ")"))]

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
     (string-append "anchor_ptr((void*)\"" (escape-c-str node) "\", "
                    (number->string (string-length node)) ")")]

    ;; nil — empty list sentinel
    [(and (sym? node) (eq? (id-sym node) 'nil)) "ANCHOR_NIL"]

    ;; Symbol or stx object → C identifier (stx stripped by c-ident)
    [(or (symbol? node) (stx? node)) (c-ident node)]

    [(pair? node)
     (let ([h (id-sym (car node))] [args (cdr node)])
       (cond
         ;; cons / car / cdr / null?
         [(eq? h 'cons)
          (unless (fx= (length args) 2) (anchor-error "cons: (cons car cdr)"))
          (string-append "anchor_cons(" (emit-expr (car args) ctx pre)
                         ", " (emit-expr (cadr args) ctx pre) ")")]

         [(eq? h 'car)
          (unless (fx= (length args) 1) (anchor-error "car: (car lst)"))
          (let* ([tmp (ctx-tmp! ctx)]
                 [cv  (emit-expr (car args) ctx pre)])
            (pre-add! pre (string-append "AnchorVal " tmp " = " cv ";"))
            (string-append "ANCHOR_CAR(" tmp ")"))]

         [(eq? h 'cdr)
          (unless (fx= (length args) 1) (anchor-error "cdr: (cdr lst)"))
          (let* ([tmp (ctx-tmp! ctx)]
                 [cv  (emit-expr (car args) ctx pre)])
            (pre-add! pre (string-append "AnchorVal " tmp " = " cv ";"))
            (string-append "ANCHOR_CDR(" tmp ")"))]

         [(eq? h 'set-car!)
          (unless (fx= (length args) 2) (anchor-error "set-car!: (set-car! cell val)"))
          (let* ([tmp (ctx-tmp! ctx)]
                 [cv  (emit-expr (car args) ctx pre)]
                 [vv  (emit-expr (cadr args) ctx pre)])
            (pre-add! pre (string-append "AnchorVal " tmp " = " cv ";"))
            (string-append "ANCHOR_SET_CAR(" tmp ", " vv ")"))]

         [(eq? h 'set-cdr!)
          (unless (fx= (length args) 2) (anchor-error "set-cdr!: (set-cdr! cell val)"))
          (let* ([tmp (ctx-tmp! ctx)]
                 [cv  (emit-expr (car args) ctx pre)]
                 [vv  (emit-expr (cadr args) ctx pre)])
            (pre-add! pre (string-append "AnchorVal " tmp " = " cv ";"))
            (string-append "ANCHOR_SET_CDR(" tmp ", " vv ")"))]

         [(eq? h 'null?)
          (unless (fx= (length args) 1) (anchor-error "null?: (null? lst)"))
          (string-append "anchor_int(ANCHOR_NULLP(" (emit-expr (car args) ctx pre) "))")]

         [(eq? h 'byte-size)
          (unless (fx= (length args) 1) (anchor-error "byte-size: (byte-size val)"))
          (let ([v (emit-expr (car args) ctx pre)])
            (string-append "anchor_int((" v ").size & ANCHOR_UNBOXED ? 8 : (intptr_t)(" v ").size)"))]

         ;; embed-bytes: (embed-bytes bv) — explicit bytevector embedding
         [(eq? h 'embed-bytes)
          (unless (and (fx= (length args) 1) (bytevector? (car args)))
            (anchor-error "embed-bytes: expected a single bytevector"))
          (emit-expr (car args) ctx pre)]

         ;; embed-string: (embed-string str) — null-terminated string as static data
         [(eq? h 'embed-string)
          (unless (and (fx= (length args) 1) (string? (car args)))
            (anchor-error "embed-string: expected a single string"))
          (let* ([s    (car args)]
                 [tmp  (ctx-tmp! ctx)]
                 [len  (string-length s)]
                 [bv   (string->utf8 s)]
                 [elts (let loop ([i 0] [acc '()])
                         (if (fx= i (bytevector-length bv)) (reverse (cons "0" acc))
                             (loop (fx+ i 1)
                                   (cons (number->string (bytevector-u8-ref bv i)) acc))))]
                 [decl (string-append "static const char " tmp "_str[] = {"
                                      (str-join elts ", ") "};")])
            (ctx-fwd-decls-set! ctx (append (ctx-fwd-decls ctx) (list decl)))
            (string-append "anchor_ptr((void*)" tmp "_str, " (number->string len) ")"))]

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
               (string-append "anchor_ptr((" ct ")" iv ".ptr, " iv ".size)")]
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

         ;; sizeof — unified: Anchor struct/enum or C type
         [(or (eq? h 'sizeof) (eq? h 'sizeof-struct))
          (unless (fx= (length args) 1)
            (anchor-error "sizeof: (sizeof Name)"))
          (let ([arg (car args)])
            (cond
              [(hashtable-ref (ctx-enums ctx) (id-sym arg) #f)
               "anchor_int(4)"]
              [(hashtable-ref (ctx-structs ctx) (id-sym arg) #f)
               (string-append "anchor_int(ANCHOR_SIZEOF_" (c-ident arg) ")")]
              [else
               (string-append "anchor_int((intptr_t)sizeof(" (cast-type-str arg) "))")]))]

         ;; get — unified access form (ptr first)
         ;; (get ptr Type field ...)              — named chain (ptr before type)
         ;; (get ptr [i esz])                     — terminal indexed: scalar
         ;; (get ptr [i esz] Type field ...)      — indexed step then named chain
         [(eq? h 'get)
          (unless (fx>= (length args) 2)
            (anchor-error "get: (get ptr [i esz]) or (get ptr Type field ...)"))
          (let* ([ptr-e  (emit-expr (car args) ctx pre)]
                 [second (cadr args)]
                 [rest   (cddr args)])
            (cond
              ;; [(val i)] — fat pointer element: read full AnchorVal from slot i
              ;; parses as ((val i)) — one-element list wrapping (val i)
              [(and (pair? second) (null? (cdr second))
                    (pair? (car second)) (eq? (id-sym (caar second)) 'val))
               (let* ([idx  (emit-expr (cadar second) ctx pre)]
                      [tmp  (ctx-tmp! ctx)])
                 (pre-add! pre (string-append "AnchorVal " tmp ";"))
                 (pre-add! pre (string-append "__builtin_memcpy(&" tmp ", (char*)" ptr-e ".ptr + _ANCH_IVAL(" idx ") * sizeof(AnchorVal), sizeof(AnchorVal));"))
                 (if (null? rest)
                     tmp
                     (emit-field-chain (car rest) tmp (cdr rest) ctx pre)))]
              ;; named first step: known struct type
              [(and (sym? second) (hashtable-ref (ctx-structs ctx) (id-sym second) #f))
               (unless (fx>= (length args) 3)
                 (anchor-error "get: (get ptr Type field ...) requires a field name"))
               (emit-field-chain second ptr-e rest ctx pre)]
              ;; byte-offset first step: number or any expression
              [else
               (emit-field-chain 'NONE ptr-e (cons second rest) ctx pre)]))]

         ;; ref / deref / ptr-add
         [(eq? h 'ref)
          (unless (fx= (length args) 1) (anchor-error "ref: (ref expr)"))
          (let* ([iv (emit-expr (car args) ctx pre)] [tmp (ctx-tmp! ctx)])
            (pre-add! pre (string-append "AnchorVal " tmp "_base = " iv ";"))
            (string-append "((AnchorVal){(void*)&" tmp "_base, sizeof(AnchorVal)})"))]

         [(eq? h 'deref)
          (unless (fx= (length args) 1) (anchor-error "deref: (deref expr)"))
          (string-append "(*(AnchorVal*)" (emit-expr (car args) ctx pre) ".ptr)")]

         [(eq? h 'ptr-add)
          (unless (fx= (length args) 2) (anchor-error "ptr-add: (ptr-add ptr n)"))
          (let ([p (emit-expr (car args) ctx pre)]
                [n (emit-expr (cadr args) ctx pre)])
            (string-append "((AnchorVal){(void*)((char*)" p ".ptr + _ANCH_IVAL(" n ")), " p ".size - (size_t)_ANCH_IVAL(" n ")})"))]

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
         ;; Use void* as the FFI param type when passing to C callbacks.
         [(eq? h 'fn-ptr)
          (unless (fx= (length args) 1) (anchor-error "fn-ptr: (fn-ptr name)"))
          (string-append "anchor_ptr((void*)" (c-ident (car args)) ", 0)")]

         ;; call-ptr: call through a function pointer stored in an AnchorVal.
         ;; (call-ptr fp arg ...) — AnchorVal ABI only (fn functions).
         [(eq? h 'call-ptr)
          (when (null? args) (anchor-error "call-ptr: (call-ptr fp arg ...)"))
          (let* ([fp         (emit-expr (car args) ctx pre)]
                 [c-args     (map (lambda (a) (emit-expr a ctx pre)) (cdr args))]
                 [param-types (if (null? c-args) "void"
                                  (str-join (map (lambda (_) "AnchorVal") c-args) ", "))]
                 [fn-cast    (string-append "((AnchorVal(*)(" param-types "))" fp ".ptr)")])
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
                 [fn-cast   (string-append "((" ret-str "(*)(" ptypes-s "))" fp ".ptr)")]
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
            (if ext
                (let* ([ret    (car ext)]
                       [ptypes (cdr ext)]
                       [c-args (let loop ([as args] [i 0] [acc '()])
                                 (if (null? as) (reverse acc)
                                     (loop (cdr as) (fx+ i 1)
                                           (cons (emit-call-arg (car as) ctx pre #t
                                                                (ffi-param-type ptypes i))
                                                 acc))))])
                  (wrap-extern-ret (string-append (c-ident (car node)) "(" (str-join c-args ", ") ")") ret ctx pre))
                (let ([c-args (map (lambda (a) (emit-call-arg a ctx pre #f #f)) args)])
                  (string-append (c-ident (car node)) "(" (str-join c-args ", ") ")"))))]

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
    [(and (pair? arg) (memv (id-sym (car arg)) '(sizeof sizeof-struct)))
     (let ([n (id-sym (cadr arg))])
       (or (struct-total-size ctx n)
           (anchor-error "sizeof: unknown struct" n)))]
    [else (anchor-error "array-get/set!: element size must be a literal or (sizeof Name)")]))

(define (emit-size-expr node ctx)
  (cond
    [(and (number? node) (exact? node)) (number->string node)]
    [(and (pair? node) (memv (id-sym (car node)) '(sizeof sizeof-struct)))
     (let ([arg (cadr node)])
       (cond
         [(hashtable-ref (ctx-structs ctx) (id-sym arg) #f)
          (string-append "ANCHOR_SIZEOF_" (c-ident arg))]
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
           (pre-add! pre (string-append "AnchorVal " tmp " = anchor_ptr((void*)" tmp "_raw, 0);"))]
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
             [(pointer-type? ct) (string-append "((" ct ")" iv ".ptr)")]
             [(or (string=? ct "double") (string=? ct "float")) (string-append "_ANCH_FVAL(" iv ")")]
             [else (string-append "(" ct ")_ANCH_IVAL(" iv ")")]))]
        [else
         (let ([iv (emit-expr node ctx pre)])
           (if ptype
               (cond
                 [(pointer-type? ptype) (string-append "((" ptype ")" iv ".ptr)")]
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

          ;; set!
          [(eq? h 'set!)
           (let ([n (length args)])
             (cond
               ;; (set! name val) — variable rebind
               [(and (fx= n 2) (sym? (car args)))
                (let* ([pre (make-pre)]
                       [rhs (emit-expr (cadr args) ctx pre)])
                  (pre-emit! pre ctx)
                  (ctx-emit! ctx (string-append (c-ident (car args)) " = " rhs ";")))]
               ;; (set! ptr [(val i)] expr) — write full AnchorVal to slot i
               ;; [(val i)] parses as ((val i)) — one-element list wrapping (val i)
               [(and (fx= n 3) (pair? (cadr args)) (null? (cdr (cadr args)))
                     (pair? (caar (cdr args))) (eq? (id-sym (caar (cadr args))) 'val))
                (let* ([pre   (make-pre)]
                       [ptr-e (emit-expr (car args) ctx pre)]
                       [idx   (emit-expr (cadar (cadr args)) ctx pre)]
                       [val-e (emit-expr (caddr args) ctx pre)]
                       [tmp   (ctx-tmp! ctx)])
                  (pre-emit! pre ctx)
                  (ctx-emit! ctx (string-append "{ AnchorVal " tmp " = " val-e "; __builtin_memcpy((char*)" ptr-e ".ptr + _ANCH_IVAL(" idx ") * sizeof(AnchorVal), &" tmp ", sizeof(AnchorVal)); }")))]
               ;; (set! ptr Type field ... val) — named chain write
               [(and (fx>= n 4) (sym? (cadr args)) (hashtable-ref (ctx-structs ctx) (id-sym (cadr args)) #f))
                (emit-stmt `(field-set! ,(cadr args) ,(car args) ,@(cddr args)) ctx)]
               ;; (set! ptr offset ...) — byte-offset write
               [(fx>= n 3)
                (let* ([pre    (make-pre)]
                       [ptr-e  (emit-expr (car args) ctx pre)]
                       [off-e  (emit-expr (cadr args) ctx pre)]
                       [rest   (cddr args)]
                       [tmp    (ctx-tmp! ctx)])
                  (pre-emit! pre ctx)
                  (cond
                    ;; (set! ptr offset val) — raw 8-byte write
                    [(fx= (length rest) 1)
                     (let* ([pre2  (make-pre)]
                            [val-e (emit-expr (car rest) ctx pre2)])
                       (pre-emit! pre2 ctx)
                       (ctx-emit! ctx (string-append "{ intptr_t " tmp "_ival = _ANCH_IVAL(" val-e "); __builtin_memcpy((char*)" ptr-e ".ptr + _ANCH_IVAL(" off-e "), &" tmp "_ival, 8); }")))]
                    ;; (set! ptr offset -> Type field ... val)
                    [(and (sym? (car rest)) (eq? (id-sym (car rest)) '->))
                     (ctx-emit! ctx (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr-e ".ptr + _ANCH_IVAL(" off-e ")), 0};"))
                     (let* ([type-name (cadr rest)]
                            [sz        (struct-total-size ctx (id-sym type-name))]
                            [ptmp      (ctx-tmp! ctx)])
                       (ctx-emit! ctx (string-append "intptr_t " ptmp "_raw = 0;"))
                       (ctx-emit! ctx (string-append "__builtin_memcpy(&" ptmp "_raw, " tmp ".ptr, 8);"))
                       (ctx-emit! ctx (string-append "AnchorVal " ptmp " = (AnchorVal){(void*)(uintptr_t)" ptmp "_raw, " (number->string sz) "};"))
                       (emit-stmt `(field-set! ,type-name ,(string->symbol ptmp) ,@(cddr rest)) ctx))]
                    ;; (set! ptr offset Type field ... val)
                    [else
                     (ctx-emit! ctx (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr-e ".ptr + _ANCH_IVAL(" off-e ")), 0};"))
                     (emit-stmt `(field-set! ,(car rest) ,(string->symbol tmp) ,@(cdr rest)) ctx)]))]
))]

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
                            (if (and (ctx-in-arena? ctx) (not (ctx-arena-top-global? ctx)))
                                (let ([tmp (ctx-tmp! ctx)])
                                  (ctx-emit! ctx (string-append "AnchorVal " tmp "_inner = " e ";"))
                                  (ctx-emit! ctx (string-append "if (_ANCH_IS_UNBOXED(" tmp "_inner)) {"))
                                  (for-each (lambda (s) (ctx-emit! ctx (string-append "    " s))) (ctx-arena-cleanup ctx))
                                  (ctx-emit! ctx (string-append "    return " tmp "_inner;"))
                                  (ctx-emit! ctx "}")
                                  (ctx-emit! ctx (string-append "size_t " tmp "_size = " tmp "_inner.size;"))
                                  (ctx-emit! ctx (string-append "char* " tmp "_bytes = (char*)__builtin_malloc(" tmp "_size);"))
                                  (ctx-emit! ctx (string-append "__builtin_memcpy(" tmp "_bytes, " tmp "_inner.ptr, " tmp "_size);"))
                                  (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                                  (ctx-emit! ctx (string-append "AnchorVal " tmp "_out = anchor_alloc(" tmp "_size);"))
                                  (ctx-emit! ctx (string-append "__builtin_memcpy(" tmp "_out.ptr, " tmp "_bytes, " tmp "_size);"))
                                  (ctx-emit! ctx (string-append "__builtin_free(" tmp "_bytes);"))
                                  (ctx-emit! ctx (string-append "return " tmp "_out;")))
                                (begin
                                  (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                                  (ctx-emit! ctx (string-append "return " e ";"))))]
                           [(string=? ret "void")
                            (for-each (lambda (s) (ctx-emit! ctx s)) (ctx-arena-cleanup ctx))
                            (ctx-emit! ctx "return;")]
                           [(pointer-type? ret)
                            (let ([tmp (ctx-tmp! ctx)])
                              (ctx-emit! ctx (string-append ret " " tmp " = (" ret ")" e ".ptr;"))
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
             (pre-emit! pre ctx)
             (ctx-emit! ctx (string-append "while (_ANCH_IVAL(" cond-e ")) {"))
             (ctx-indent! ctx)
             (for-each (lambda (s) (emit-stmt s ctx)) (cdr args))
             (when (pair? (pre-list pre))
               (for-each (lambda (s) (ctx-emit! ctx s)) (pre-list pre)))
             (ctx-dedent! ctx)
             (ctx-emit! ctx "}"))]

          ;; break / continue
          [(eq? h 'break)    (ctx-emit! ctx "break;")]
          [(eq? h 'continue) (ctx-emit! ctx "continue;")]

          ;; do
          [(eq? h 'do)
           (for-each (lambda (s) (emit-stmt s ctx)) args)]

          ;; block
          [(eq? h 'block)
           (ctx-emit! ctx "{")
           (ctx-indent! ctx)
           (for-each (lambda (s) (emit-stmt s ctx)) args)
           (ctx-dedent! ctx)
           (ctx-emit! ctx "}")]

          ;; field-set! as statement — internal, used by set! — single or chained
          ;; (field-set! S ptr f val)               — single field
          ;; (field-set! S ptr f S2 f2 ... val)     — navigate embedded chain, set last field
          ;; (field-set! S ptr f -> S2 f2 ... val)  — follow pointer, then set last field
          [(eq? h 'field-set!)
           (unless (fx>= (length args) 4)
             (anchor-error "field-set!: (field-set! S ptr f [-> S2 f2 ...] val)"))
           (let* ([pre     (make-pre)]
                  [chain   (cddr args)]
                  [val     (emit-expr (car (last-pair chain)) ctx pre)]
                  [fields  (reverse (cdr (reverse chain)))]
                  [inner-ptr
                   (let loop ([sn  (car args)]
                              [ptr (emit-expr (cadr args) ctx pre)]
                              [rest fields])
                     (if (null? (cdr rest))
                         (cons sn ptr)
                         (let* ([fname (car rest)]
                                [csn   (c-ident sn)] [cfn (c-ident fname)]
                                [tmp   (ctx-tmp! ctx)])
                           (cond
                             ;; field followed by offset expression (non-symbol or non-struct symbol)
                             [(and (not (and (sym? (cadr rest)) (eq? (id-sym (cadr rest)) '->)))
                                   (not (and (sym? (cadr rest)) (hashtable-ref (ctx-structs ctx) (id-sym (cadr rest)) #f))))
                              (let ([tmp (ctx-tmp! ctx)])
                                (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn "), 0};"))
                                (let* ([off-e  (emit-expr (cadr rest) ctx pre)]
                                       [s2n    (caddr rest)]
                                       [s2_sz  (struct-total-size ctx (id-sym s2n))]
                                       [tmp2   (ctx-tmp! ctx)])
                                  (pre-add! pre (string-append "AnchorVal " tmp2 " = (AnchorVal){(void*)((char*)" tmp ".ptr + _ANCH_IVAL(" off-e ")), " (number->string s2_sz) "};"))
                                  (loop s2n tmp2 (cdddr rest))))]
                                                          [(eq? (id-sym (cadr rest)) '->)
                              (when (fx< (length (cdr rest)) 3)
                                (anchor-error "field-set!: expected (-> S2 f2) after field"))
                              (let* ([next  (caddr rest)])
                                (pre-add! pre (string-append "intptr_t " tmp "_raw = 0;"))
                                (pre-add! pre (string-append "__builtin_memcpy(&" tmp "_raw, (char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn ", 8);"))
                                (if (not (and (sym? next) (hashtable-ref (ctx-structs ctx) (id-sym next) #f)))
                                    ;; -> expression offset: follow pointer then advance
                                    (let* ([s2n    (cadddr rest)]
                                           [off-e  (emit-expr next ctx pre)]
                                           [s2_sz  (struct-total-size ctx (id-sym s2n))]
                                           [base   (ctx-tmp! ctx)]
                                           [tmp2   (ctx-tmp! ctx)])
                                      (pre-add! pre (string-append "AnchorVal " base " = (AnchorVal){(void*)(uintptr_t)" tmp "_raw, 0};"))
                                      (pre-add! pre (string-append "AnchorVal " tmp2 " = (AnchorVal){(void*)((char*)" base ".ptr + _ANCH_IVAL(" off-e ")), " (number->string s2_sz) "};"))
                                      (loop s2n tmp2 (cddddr rest)))
                                    ;; -> TypeName ... : typed pointer follow
                                    (let* ([s2n   next]
                                           [s2_sz (struct-total-size ctx (id-sym s2n))])
                                      (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)(uintptr_t)" tmp "_raw, " (number->string (or s2_sz 0)) "};"))
                                      (loop s2n tmp (cdddr rest)))))]
                             [else
                              (let* ([s2n   (cadr rest)]
                                     [s2_sz (struct-total-size ctx (id-sym s2n))])
                                (pre-add! pre (string-append "AnchorVal " tmp " = (AnchorVal){(void*)((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn "), " (number->string s2_sz) "};"))
                                (loop s2n tmp (cddr rest)))]))))]
                  [sn    (car inner-ptr)]
                  [ptr   (cdr inner-ptr)]
                  [fname (car (last-pair fields))]
                  [csn   (c-ident sn)]
                  [tmp   (ctx-tmp! ctx)])
             (pre-emit! pre ctx)
             (if (and (pair? fname) (eq? (id-sym (car fname)) 'val))
                 ;; (val ...) terminal — store AnchorVal halves without UNBOXED check
                 (let* ([vargs (cdr fname)]
                        [nf    (length vargs)]
                        [_     (unless (memv nf '(1 2))
                                 (anchor-error "field-set! val: 1 or 2 fields required"))]
                        [ht    (or (hashtable-ref (ctx-structs ctx) (id-sym sn) #f)
                                   (anchor-error "field-set! val: unknown struct" sn))])
                   (ctx-emit! ctx (string-append "{ AnchorVal " tmp " = " val ";"))
                   (if (fx= nf 1)
                       ;; 1-field 16-byte: store full AnchorVal verbatim
                       (let* ([f1n (car vargs)]
                              [cf1 (c-ident f1n)]
                              [e1  (or (hashtable-ref ht (id-sym f1n) #f)
                                       (anchor-error "field-set! val: unknown field" f1n))]
                              [_   (unless (fx= (cadr e1) 16)
                                     (anchor-error "field-set! val: single field must be 16 bytes" f1n))])
                         (ctx-emit! ctx (string-append "  __builtin_memcpy((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf1 ", &" tmp ", 16); }")))
                       ;; 2-field: ptr → f1 (8 bytes), size → f2 (8 bytes)
                       (let* ([f1n (car vargs)] [f2n (cadr vargs)]
                              [cf1 (c-ident f1n)] [cf2 (c-ident f2n)]
                              [e1  (or (hashtable-ref ht (id-sym f1n) #f)
                                       (anchor-error "field-set! val: unknown field" f1n))]
                              [e2  (or (hashtable-ref ht (id-sym f2n) #f)
                                       (anchor-error "field-set! val: unknown field" f2n))]
                              [_   (unless (fx= (cadr e1) 8)
                                     (anchor-error "field-set! val: f1 must be 8-byte field" f1n))]
                              [_   (unless (fx= (cadr e2) 8)
                                     (anchor-error "field-set! val: f2 must be 8-byte field" f2n))])
                         (ctx-emit! ctx (string-append "  intptr_t " tmp "_addr = (intptr_t)" tmp ".ptr;"))
                         (ctx-emit! ctx (string-append "  __builtin_memcpy((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf1 ", &" tmp "_addr, 8);"))
                         (ctx-emit! ctx (string-append "  __builtin_memcpy((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cf2 ", &" tmp ".size, 8); }")))))
                 ;; normal field — UNBOXED/BOXED dispatch
                 (let ([cfn (c-ident fname)])
                   (ctx-emit! ctx (string-append "if (_ANCH_IS_UNBOXED(" val ")) {"))
                   (ctx-emit! ctx (string-append "    intptr_t " tmp "_ival = _ANCH_IVAL(" val ");"))
                   (ctx-emit! ctx (string-append "    __builtin_memcpy((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn ", &" tmp "_ival, ANCHOR_SIZE_" csn "_" cfn ");"))
                   (ctx-emit! ctx "} else {")
                   (ctx-emit! ctx (string-append "    intptr_t " tmp "_addr = (intptr_t)" val ".ptr;"))
                   (ctx-emit! ctx (string-append "    __builtin_memcpy((char*)" ptr ".ptr + ANCHOR_OFFSET_" csn "_" cfn ", &" tmp "_addr, ANCHOR_SIZE_" csn "_" cfn ");"))
                   (ctx-emit! ctx "}"))))]

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
             (ctx-emit! ctx (string-append cname ".used = 0;")))]

          ;; extern-global
          [(eq? h 'extern-global)
           (unless (and (fx= (length args) 1) (sym? (car args)))
             (anchor-error "extern-global: (extern-global name)"))
           (ctx-fwd-decls-set! ctx
             (append (ctx-fwd-decls ctx)
                     (list (string-append "extern AnchorVal " (c-ident (car args)) ";"))))]

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
                 (ctx-emit! ctx (string-append (c-ident (car node)) "(" (str-join c-args ", ") ");")))
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
      [else (anchor-error "sizeof-struct: unknown struct or enum" name)])))

(define (resolve-field-size form ctx)
  ;; Returns the byte size of a struct field size spec:
  ;;   number            → literal byte count
  ;;   (sizeof N)        → total size of struct/union N
  ;;   omitted           → default field size
  (cond
    [(number? form) (exact form)]
    [(and (pair? form) (memv (id-sym (car form)) '(sizeof sizeof-struct)))
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
    (ctx-emit! ctx (string-append "/* struct " (symbol->string name) " */"))
    (ctx-emit! ctx (string-append "#define ANCHOR_SIZEOF_" cn " " (number->string total)))
    (for-each (lambda (f)
                (let ([cf (c-ident (car f))])
                  (ctx-emit! ctx (string-append "#define ANCHOR_OFFSET_" cn "_" cf " " (number->string (cadr f))))
                  (ctx-emit! ctx (string-append "#define ANCHOR_SIZE_" cn "_" cf "  " (number->string (caddr f))))))
              fi)
    (ctx-emit-blank! ctx)))

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
            (map (lambda (p) (if (sym? p) (id-sym p) '_)) (car rest))
            (cdr rest)))))

(define (emit-fn node ctx arena-sz . rest)
  ;; rest: optional global-arena C name (string) — use a global arena instead of allocating one
  (let* ([global-arena (and (pair? rest) (car rest))]
         [sig    (parse-fn-sig node)]
         [name   (car sig)] [params (cadr sig)] [body (caddr sig)]
         [ret    (if (eq? (id-sym name) 'main) "int" "AnchorVal")]
         [cn     (c-ident name)]
         [main2? (and (eq? (id-sym name) 'main) (fx= (length params) 2))]
         [c-params
          (if main2? "int _argc_raw, char** _argv_raw"
              (if (null? params) "void"
                  (str-join (map (lambda (p) (string-append "AnchorVal " (c-ident p))) params) ", ")))])
    (ctx-emit-blank! ctx)
    (ctx-emit! ctx (string-append ret " " cn "(" c-params ") {"))
    (ctx-indent! ctx)
    (when main2?
      (ctx-emit! ctx (string-append "AnchorVal " (c-ident (car params)) " = anchor_int(_argc_raw);"))
      (ctx-emit! ctx (string-append "AnchorVal " (c-ident (cadr params)) " = anchor_ptr(_argv_raw, (size_t)_argc_raw * sizeof(char*));")))
    (let ([old-ret   (ctx-fn-ret ctx)]
          [old-vd    (ctx-var-depth ctx)])
      (ctx-fn-ret-set! ctx ret)
      (ctx-var-depth-set! ctx (make-eq-hashtable))
      ;; Arena setup
      (let ([av #f] [use-heap #f])
        (cond
          [global-arena
           ;; Link in an existing global arena for this function's allocations
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
             (ctx-emit! ctx (string-append "AnchorArena " av " = {(char*)" av "_buf, " cap ", 0, _anchor_arena_top};"))
             (ctx-emit! ctx (string-append "_anchor_arena_top = &" av ";"))
             (ctx-push-arena! ctx av #f)
             (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1)))])
        (for-each (lambda (s) (emit-stmt s ctx)) body)
        (let* ([last (and (pair? body) (list-ref body (fx- (length body) 1)))]
               [has-ret (and last (pair? last) (eq? (id-sym (car last)) 'return))])
          (unless has-ret
            (when av
              (if global-arena
                  (ctx-emit! ctx (string-append "_anchor_arena_top = " global-arena ".prev;"))
                  (begin
                    (ctx-emit! ctx (string-append "_anchor_arena_top = " av ".prev;"))
                    (when use-heap (ctx-emit! ctx (string-append "__builtin_free(" av "_buf);")))))
              (ctx-pop-arena! ctx)
              (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1)))
            (ctx-emit! ctx (if (string=? ret "int") "return 0;" "return anchor_int(0);")))
          (when (and has-ret av)
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
      ;; (with-arena name body...) — use existing global arena, no alloc/reset
      [(and (sym? first) (not (number? first)))
       (let* ([name  first]
              [body  (cdr items)]
              [cname (hashtable-ref (ctx-global-arenas ctx) (id-sym name) #f)])
         (unless cname (anchor-error "with-arena: not a declared global-arena" name))
         (when (null? body) (anchor-error "with-arena: empty body"))
         ;; If body is all fn/fn-c, attach the global arena to each function directly
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
               (ctx-emit! ctx (string-append "AnchorArena " av " = {(char*)" av "_buf, " cap ", 0, _anchor_arena_top};"))
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
  ;; (with-parent-arena body...) — direct allocations into the arena one level up.
  ;; Saves _anchor_arena_top, sets it to its own ->prev, runs body, restores.
  ;; On return inside the body, ctx-arena-cleanup emits the restore automatically.
  (let ([body (cdr node)])
    (when (null? body) (anchor-error "with-parent-arena: empty body"))
    (let ([sv (string-append "_anc_psaved_" (ctx-tmp! ctx))])
      (ctx-emit! ctx "{")
      (ctx-indent! ctx)
      (ctx-emit! ctx (string-append "AnchorArena* " sv " = _anchor_arena_top;"))
      (ctx-emit! ctx (string-append "_anchor_arena_top = _anchor_arena_top ? _anchor_arena_top->prev : NULL;"))
      (ctx-push-restore! ctx sv)
      (for-each (lambda (s) (emit-stmt s ctx)) body)
      (ctx-emit! ctx (string-append "_anchor_arena_top = " sv ";"))
      (ctx-pop-arena! ctx)
      (ctx-dedent! ctx)
      (ctx-emit! ctx "}"))))

(define (emit-global-arena node ctx)
  ;; (global-arena name size)
  (let* ([items (cdr node)]
         [name  (car items)]
         [size  (cadr items)]
         [cname (string-append "_anc_ga_" (c-ident name))]
         [cap   (number->string (exact size))])
    (hashtable-set! (ctx-global-arenas ctx) (id-sym name) cname)
    (ctx-globals-set! ctx
      (append (ctx-globals ctx)
              (list (string-append "static char " cname "_buf[" cap "];"))
              (list (string-append "static AnchorArena " cname
                                   " = {" cname "_buf, " cap ", 0, NULL};"))))))

(define (emit-global node ctx const?)
  (let* ([name  (cadr node)]
         [cname (c-ident name)]
         [expr  (caddr node)])
    (cond
      [(and (number? expr) (inexact? expr))
       (ctx-globals-set! ctx
         (append (ctx-globals ctx)
                 (list (string-append "AnchorVal " cname ";")
                       (string-append "__attribute__((constructor)) static void _anc_init_" cname
                                      "(void) { " cname " = anchor_float(" (number->string expr) "); }"))))]
      [(and (number? expr) (exact? expr))
       (ctx-globals-set! ctx
         (append (ctx-globals ctx)
                 (list (string-append (if const? "const " "") "AnchorVal " cname
                                      " = { (void*)(uintptr_t)(intptr_t)" (number->string expr)
                                      ", ANCHOR_UNBOXED };"))))]
      [(and (not const?) (pair? expr) (eq? (id-sym (car expr)) 'alloc)
            (pair? (cdr expr)) (number? (cadr expr)) (exact? (cadr expr)))
       (let ([sz (cadr expr)])
         (ctx-globals-set! ctx
           (append (ctx-globals ctx)
                   (list (string-append "static char _g_" cname "_storage[" (number->string sz) "];")
                         (string-append "AnchorVal " cname " = { _g_" cname "_storage, "
                                        (number->string sz) " };")))))]
      [(and (not const?) (pair? expr) (eq? (id-sym (car expr)) 'alloc)
            (pair? (cdr expr)) (pair? (cadr expr))
            (memv (id-sym (car (cadr expr))) '(sizeof sizeof-struct)))
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
                         (string-append "AnchorVal " cname " = { _g_" cname "_storage, "
                                        sz " };")))))]
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
                                                  " = anchor_ptr((void*)" raw ", 0);")
                                   (string-append "AnchorVal " pname
                                                  " = anchor_int((intptr_t)" raw ");"))])
                  (ctx-emit! ctx wrap)))
              parsed)
    ;; Optional arena setup (when wrapped in with-arena)
    (cond
      [global-arena
       (ctx-emit! ctx (string-append global-arena ".prev = _anchor_arena_top;"))
       (ctx-emit! ctx (string-append "_anchor_arena_top = &" global-arena ";"))
       (ctx-push-arena! ctx global-arena #t)
       (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1))]
      [arena-sz
       (let* ([cap (if (and (number? arena-sz) (fx> arena-sz 0))
                       (number->string arena-sz)
                       "ANCHOR_DEFAULT_ARENA_CAP")]
              [use-heap (and (number? arena-sz) (fx> arena-sz 1048576))]
              [av "_anc_arena"])
         (if use-heap
             (ctx-emit! ctx (string-append "char* " av "_buf = (char*)__builtin_malloc(" cap ");"))
             (ctx-emit! ctx (string-append "char " av "_buf[" cap "];")))
         (ctx-emit! ctx (string-append "AnchorArena " av " = {(char*)" av "_buf, " cap ", 0, _anchor_arena_top};"))
         (ctx-emit! ctx (string-append "_anchor_arena_top = &" av ";"))
         (ctx-push-arena! ctx av #f)
         (ctx-arena-depth-set! ctx (fx+ (ctx-arena-depth ctx) 1)))])
    ;; Emit body; ctx-fn-ret set so return emits the right C cast
    (let ([prev-ret (ctx-fn-ret ctx)])
      (ctx-fn-ret-set! ctx ret-str)
      (for-each (lambda (s) (emit-stmt s ctx)) body)
      (ctx-fn-ret-set! ctx prev-ret))
    (when (or arena-sz global-arena)
      (ctx-pop-arena! ctx)
      (ctx-arena-depth-set! ctx (fx- (ctx-arena-depth ctx) 1)))
    (ctx-dedent! ctx)
    (ctx-emit! ctx "}"))))

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
            (let ([parts (list *anchor-runtime-h*)])
              (when (pair? (ctx-fwd-decls ctx))
                (set! parts (append parts (list "") (ctx-fwd-decls ctx))))
              (when (pair? (ctx-globals ctx))
                (set! parts (append parts (list "") (ctx-globals ctx))))
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
                  [(fn-c)          (emit-fn-c e ctx)           (loop (cdr es) body)]
                  [(include)       (emit-stmt e ctx)           (loop (cdr es) body)]
                  [(global)        (emit-global e ctx #f)      (loop (cdr es) body)]
                  [(const)         (emit-global e ctx #t)      (loop (cdr es) body)]
                  [(global-arena)  (emit-global-arena e ctx)   (loop (cdr es) body)]
                  [(struct)        (emit-struct e ctx #t) (loop (cdr es) body)]
                  [(unpacked-struct) (emit-struct e ctx #f) (loop (cdr es) body)]
                  [(union)         (emit-union  e ctx)    (loop (cdr es) body)]
                  [(enum)          (emit-enum   e ctx)    (loop (cdr es) body)]
                  [else            (loop (cdr es) (cons e body))])))))))
