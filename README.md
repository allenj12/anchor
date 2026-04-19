# Anchor

Anchor is a systems programming language with Lisp syntax that compiles to C.

Every value is an `AnchorVal` fat pointer `{void* ptr, size_t size}`. Scalars live
unboxed in the `ptr` field. Memory is managed through arenas — bump-pointer regions
that free all at once when the function returns. There is no GC.

The macro system is hygienic `syntax-rules` plus `macro-case`, which runs arbitrary
Chez Scheme at expand time. This lets macros compute sizes, unroll loops, generate
families of functions, and define other macros — all before a line of C is emitted.

---

## Build

Requires [Chez Scheme](https://cisco.github.io/ChezScheme/).

```bash
chez --script build.ss   # → ./anchorc  (standalone binary, no Chez needed to run)
```

Run a file:

```bash
./anchorc examples/hello.anc --run          # compile + run
./anchorc examples/hello.anc -o hello       # compile to binary
./anchorc examples/hello.anc -o hello.c     # emit C only
./anchorc examples/hello.anc --emit-exp     # print macro-expanded AST
```

---

## Hello World

```anchor
(ffi printf (const char* ...) -> int)

(with-arena
  (fn main ()
    (printf "Hello, Anchor!\n")))
```

`with-arena` attaches a heap arena to the function. All `alloc` calls inside use it;
everything is freed on return. The default size is 64 MB.

---

## Language Tour

### Variables and control flow

```anchor
(let x 10)          ; declare
(set! x (+ x 1))   ; mutate

(if (> x 5)
  (printf "big\n")
  (printf "small\n"))

(while (< x 100)
  (set! x (* x 2)))

(while #t
  (if (== x 0) (break))
  (if (== (% x 2) 0) (do (set! x (- x 1)) (continue)))
  (set! x (- x 1)))

(block              ; introduces a C scope — variables declared here are local to it
  (let tmp x)
  (set! x 0))
```

`do` sequences expressions and returns the last one; `block` does the same but wraps
in `{ }` so `let` bindings inside don't escape. `break` and `continue` work exactly
as in C — they apply to the innermost enclosing `while`.

### Functions

```anchor
(fn square (n)
  (* n n))

(fn abs-val (n)
  (if (< n 0) (* n -1) n))
```

All functions return `AnchorVal`. `main` is the exception — it returns `int`.
Tail calls are not optimized; use `while` for loops.

### Arithmetic

```anchor
(+ a b)    (- a b)    (* a b)    (/ a b)    (% a b)   ; signed integer
(+f a b)   (-f a b)   (*f a b)   (/f a b)             ; float (double)
(+u a b)   (-u a b)   (*u a b)   (/u a b)   (%u a b)  ; unsigned

(band x mask)   (bor x y)   (bxor x y)   (bnot x)
(lshift x n)    (rshift x n)

(== a b)  (!= a b)  (< a b)  (> a b)  (<= a b)  (>= a b)
(<u a b)  (>u a b)  ; unsigned comparisons
```

### FFI

Declare a C function once; call it directly. Fixed parameters are automatically cast
to the declared types. Variadic arguments (after `...`) require explicit `(cast TYPE arg)`.

```anchor
(include <unistd.h>)
(include <string.h>)

(ffi write  (int const void* size_t) -> int)
(ffi memcpy (void* (const void*) size_t) -> void*)
(ffi strlen ((const char*)) -> size_t)

; call — types applied automatically for fixed params
(write 1 buf (strlen buf))

; variadic — explicit cast required
(ffi printf (const char* ...) -> int)
(printf "%d items\n" (cast int count))
```

Use `(c-const NAME)` to pull in a C preprocessor constant at compile time:

```anchor
(c-const STDOUT_FILENO)   ; → anchor_int((intptr_t)(STDOUT_FILENO))
(c-const CLOCKS_PER_SEC)
```

### Memory and arenas

`alloc` bumps the current arena pointer — O(1), no `malloc` overhead.

```anchor
(with-arena 4194304      ; 4 MB arena
  (fn process (n)
    (let buf (alloc (* n 8)))   ; slice of arena bytes
    ; buf freed automatically when process returns
    ))
```

`global-arena` declares a named arena whose backing buffer lives for the entire
program. Use it when allocations need to outlive the function that creates them —
linked lists, trees, or any per-request scratch buffer that gets rebuilt in a loop.

```anchor
(global-arena scratch 65536)   ; 64 KiB, allocated once

(fn build-list (n)
  (with-arena scratch           ; directs allocations into scratch
    (let result nil)
    (while (> n 0)
      (set! result (cons n result))
      (set! n (- n 1)))
    (return result)))           ; safe — scratch is never freed

(fn main ()
  (let lst (build-list 5))
  ; ... use lst ...
  (arena-reset! scratch)        ; reclaim all allocations in O(1)
  (let lst2 (build-list 3))     ; reuse same backing memory
  )
```

Returning a list from a `with-arena scratch` block is safe because the backing
memory is permanent. Contrast with anonymous `with-arena` scopes, where returning
a linked structure would dangle — only flat values copy out correctly there.

`(ref expr)` takes a stack address; `(deref ptr)` reads through one. Useful for
passing values by pointer to C functions that write into them.

```anchor
(let n 0)
(some-c-fn (ref n))     ; passes &n
(let result (deref ptr))
```

### Structs

Fields default to 8 bytes. Specify smaller sizes explicitly (e.g. 4 for `int`,
1 for `char`, 2 for `short`).

```anchor
(struct Point (x 8) (y 8))

(let p (alloc (sizeof-struct Point)))
(field-set! Point p x 100)
(field-set! Point p y 200)
(let px (field-get Point p x))   ; → anchor_int(100)
```

Nest structs inline using `(sizeof-struct Name)` as the field size. `field-get` on an
embedded field returns a sub-struct pointer, not a scalar — use a second `field-get` to
reach the inner value:

```anchor
(struct AABB
  (min (sizeof-struct Point))
  (max (sizeof-struct Point)))

(let b (alloc (sizeof-struct AABB)))
(let mn (field-get AABB b min))   ; pointer into AABB at offset of 'min'
(field-set! Point mn x 0)
(field-set! Point mn y 0)
(let mx (field-get AABB b max))
(field-set! Point mx x 800)
(field-set! Point mx y 600)
```

Array of structs — step by `sizeof-struct`:

```anchor
(let buf (alloc (* n (sizeof-struct Point))))
(let stride (sizeof-struct Point))
(let i 0)
(while (< i n)
  (let p (+ buf (* i stride)))
  (field-get Point p x)
  (set! i (+ i 1)))
```

### Unions

All fields share offset 0. Total size is the largest field.

```anchor
(union Num
  (as-int   8)
  (as-float 8))

(let u (alloc (sizeof-struct Num)))
(field-set! Num u as-int 42)
(field-get  Num u as-int)    ; 42
(field-get  Num u as-float)  ; reinterpret same bits as double
```

### Enums

Emit `#define` constants. Access them with `(c-const Name_Variant)`.

```anchor
(enum Direction
  (North 0) (East 1) (South 2) (West 3))

(if (== dir (c-const Direction_North))
  (printf "heading north\n"))
```

Auto-incrementing (omit the value):

```anchor
(enum Color Red Green Blue)   ; Red=0, Green=1, Blue=2
```

### Globals and constants

```anchor
(global count 0)              ; mutable global AnchorVal
(global-set! count (+ count 1))

(global buf (alloc 65536))    ; static 64 KB buffer

(const max-size 4096)         ; immutable — compiler may fold it
```

### Linked lists

`cons`, `car`, `cdr`, `nil`, and `null?` are built into the language.
`cons` allocates a two-slot cell from the current arena.

```anchor
(let lst (cons 1 (cons 2 (cons 3 nil))))

(let cur lst)
(while (! (null? cur))
  (printf "%d\n" (cast int (car cur)))
  (set! cur (cdr cur)))
```

---

## Macros

### `syntax-rules` — pattern-based

Hygienic: names introduced in a template (like `_tmp`) are automatically gensymmed
so they never clash with variables at the call site.

```anchor
; when / unless — one-armed conditionals
(define-syntax when
  (syntax-rules ()
    [(_ cond body ...)
     (if cond (do body ...))]))

(define-syntax unless
  (syntax-rules ()
    [(_ cond body ...)
     (if (! cond) (do body ...))]))

; for loop — block scopes the variable, so it doesn't leak after the loop
(define-syntax for
  (syntax-rules (to)
    [(_ var from to limit body ...)
     (block                      ; C scope: var not visible after the loop
       (let var from)
       (while (< var limit)
         body ...
         (set! var (+ var 1))))]))

; swap! — _tmp is gensymmed, so (let _tmp 99) in caller is safe
(define-syntax swap!
  (syntax-rules ()
    [(_ a b)
     (do (let _tmp a) (set! a b) (set! b _tmp))]))
```

Recursive patterns — `my-and` rewrites itself until base cases apply:

```anchor
(define-syntax my-and
  (syntax-rules ()
    [(_)          1]
    [(_ e)        e]
    [(_ e rest ...)  (if e (my-and rest ...) 0)]))
```

Literal keyword in pattern — `else` is matched exactly, not as a pattern variable:

```anchor
(define-syntax my-cond
  (syntax-rules (else)
    [(_ (else body ...))             (do body ...)]
    [(_ (test body ...) clause ...)  (if test (do body ...) (my-cond clause ...))]))
```

### `macro-case` — with expansion-time computation

Templates are plain Chez Scheme code. Pattern variables bind to the matched Anchor
AST values. This lets you run arbitrary computation — `length`, `map`, `iota`, string
manipulation — before emitting a single line of C.

Three template styles are available inside `macro-case` clause bodies:

| Style | Ellipsis vars | Ellipsis in template |
|-------|--------------|----------------------|
| `` ` `` (Chez quasiquote) | plain Chez lists | `,@var` to splice |
| `#'` (syntax template) | plain Chez lists | `var ...` via pattern engine |
| `` #` `` (quasisyntax) | plain Chez lists | `var ...` via pattern engine, `#,expr` for escapes |

With backtick, `body ...` in the template is a literal symbol pair — use `,@body` to splice.
With `#'` or `` #` ``, the pattern engine handles `var ...` expansion directly.

**`arena-array` — size computed at expand time, indices are literals:**

```anchor
(define-syntax arena-array
  (macro-case ()
    [(_ name val ...)
     (let* ([n    (length val)]
            [size (* n 8)])
       `(do
          (let ,name (alloc ,size))
          ,@(let loop ([i 0] [vs val])
              (if (null? vs) '()
                  (cons `(array-set! ,name ,i ,(car vs))
                        (loop (+ i 1) (cdr vs)))))))]))

(arena-array primes 2 3 5 7 11 13)
; expands to: (let primes (alloc 48))
;             (array-set! primes 0 2)
;             (array-set! primes 1 3) ...
```

**`unroll` — loop body inlined N times, enforced by guard:**

```anchor
(define-syntax unroll
  (macro-case ()
    [(_ n body ...)
     (number? n)
     `(do ,@(apply append (map (lambda (_) body) (iota n))))]))

(unroll 4 (set! ticks (+ ticks 1)))
; expands to four sequential set! calls — no loop, no branch
```

### Macros that define macros

`syntax-rules` cannot write macros whose inner templates contain `...` because the
outer instantiator would try to expand them. `macro-case` with quasiquote treats
the inner template as plain data — `r`, `...`, `x` are just symbols being consed
into a list:

```anchor
(define-syntax define-fold-op
  (macro-case ()
    [(_ name op identity)
     `(define-syntax ,name
        (syntax-rules ()
          [(_)         ,identity]
          [(_ x)       x]
          [(_ x r ...) (,op x (,name r ...))]))]))

(define-fold-op my-add + 0)
(define-fold-op my-mul * 1)

(my-add 1 2 3 4)   ; → 10
(my-mul 2 3 4)     ; → 24
```

### `define-struct` — generating multiple top-level definitions

A macro that returns `(do ...)` at the top level has its children spliced as
separate top-level forms. This lets one call site emit a struct definition, a
constructor, and accessor functions:

```anchor
(define-syntax define-struct
  (macro-case ()
    [(_ name (field size) ...)
     (let* ([sname  (id-sym name)]
            [cname  (string->symbol (string-append "make-" (symbol->string sname)))]
            [pnames (map (lambda (f) (string->symbol (string-append "p_" (symbol->string (id-sym f))))) field)]
            [anames (map (lambda (f) (string->symbol (string-append (symbol->string sname) "-" (symbol->string (id-sym f))))) field)])
       `(do
          (struct ,name ,@(map list field size))
          (fn ,cname (,@pnames)
            (let _ptr (alloc (sizeof-struct ,name)))
            ,@(map (lambda (f p) `(field-set! ,sname _ptr ,f ,p)) field pnames)
            (return _ptr))
          ,@(map (lambda (aname f)
                   `(fn ,aname (s) (return (field-get ,sname s ,f))))
                 anames field)))]))

(define-struct Vec2 (x 8) (y 8))

; Generated at compile time:
;   (struct Vec2 (x 8) (y 8))
;   (fn make-Vec2 (p_x p_y) ...)
;   (fn Vec2-x (s) ...)
;   (fn Vec2-y (s) ...)
```

### Anaphoric macros — intentional capture with `datum->syntax`

By default macros are hygienic: names introduced in a template never clash with
names at the call site.  For deliberately anaphoric macros (e.g. `aif`, which
binds `it` for the user to reference), use `datum->syntax` to place a name in the
call-site scope.  `_kw` is always bound in `macro-case` clause bodies — it is the
macro keyword with use-site marks, the standard context argument:

```anchor
(define-syntax aif
  (macro-case ()
    [(_ test then else-clause)
     (let ([it-id (datum->syntax _kw 'it)])
       #`(block
           (let #,it-id #,test)
           (if #,it-id #,then #,else-clause)))]))

(aif (find-item key table)
  (printf "found: %d\n" (cast int it))
  (printf "not found\n"))
```

`it` inside `then` refers to the macro-introduced binding, not any outer `it`.
The `block` scope means any outer `it` is simply shadowed, not renamed.

---

## Examples

| File | What it shows |
|------|---------------|
| `examples/hello.anc` | Hello World, `with-arena`, basic FFI |
| `examples/fizzbuzz.anc` | Functions, `while`, conditionals, `%` |
| `examples/array.anc` | `alloc`, `array-get/set!`, bubble sort, `for` macro |
| `examples/linked_list.anc` | `cons`/`car`/`cdr`/`nil`/`null?`, list operations |
| `examples/global_arena.anc` | `global-arena`, `arena-reset!`, lists escaping function scope |
| `examples/structs.anc` | Structs, nested structs, unions, enums, array-of-structs |
| `examples/macros_showcase.anc` | Full macro spectrum: `syntax-rules` → `macro-case` → macros defining macros |

---

## Design notes

**Fat pointers everywhere.** Every value carries both a pointer and a size. Scalars
store their integer value in the `ptr` field with the high bit of `size` set as a tag.
This means everything flows through a uniform ABI — no overloaded calling conventions,
no special-casing for primitives.

**Arenas, not GC.** `alloc` bumps a pointer. Anonymous `with-arena` scopes free all
allocations when the block exits. `global-arena` declares a named arena with permanent
backing memory — reset it explicitly with `arena-reset!` when you want to reclaim.
Arenas nest and stack; `cons` and `alloc` always use the innermost active arena.

**C as the backend.** The compiler emits a single `.c` file with no dependencies
beyond `anchor.h` (included from `anchor/runtime/`). You can inspect, modify, or
link the C output directly. `cc` is invoked automatically with `--run` or when
compiling to a binary.

**Hygiene without a runtime.** Macros use KFFD mark-based hygiene. Each macro
application gets a fresh mark; user-provided identifiers cancel (XOR) while
template-introduced names keep their mark and become global references after
resolution. No syntax objects, no scope chains — Anchor has no module system or
runtime environments, so the flat-namespace model is sufficient.
