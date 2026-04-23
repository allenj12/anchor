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

### Character literals

Anchor uses Chez Scheme's `#\` syntax. Character literals evaluate to their Unicode codepoint as an integer:

```anchor
#\a        ; 97
#\newline  ; 10
#\space    ; 32
#\tab      ;  9
#\nul      ;  0
#\x41      ; 65  (hex codepoint)
#\[        ; 91  (punctuation)
```

### Includes

Split code across multiple files using `(include "path/to/file.anc")`. The compiler resolves includes at parse time and inlines them into the AST before expansion — so macros, structs, and functions defined in an included file are visible everywhere after the include point.

```anchor
(include "math.anc")
(include "utils/string.anc")
```

Paths are relative to the file containing the include. You only pass one file to the compiler; everything else comes in through includes:

```bash
./anchorc main.anc --run
```

Duplicate includes are silently ignored — each file is inlined at most once regardless of how many times it appears, so circular or redundant includes are safe.

C header includes pass through unchanged to the generated C file:

```anchor
(include <stdio.h>)
(include "mylib.h")
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

### `fn-c` — C-native-signature functions

Use `fn-c` when you need a function with a specific C signature — for callbacks,
`qsort` comparators, signal handlers, or any place the C ABI is fixed. Parameters
are automatically wrapped as `AnchorVal` inside the body so Anchor expressions work
normally; the return value is cast back to the declared C type.

```anchor
(include <stdlib.h>)

(fn-c compare-ints ((const void* a) (const void* b)) -> int
  (let av (deref (cast intptr_t* a)))
  (let bv (deref (cast intptr_t* b)))
  (return (- av bv)))

; qsort needs a C comparator — fn-c is it
(ffi qsort (void* size_t size_t void*) -> void)
(qsort arr n 8 (fn-ptr compare-ints))
```

No separate `(ffi ...)` declaration is needed for the `fn-c` function itself — the
compiler registers it in the extern table automatically.

Each parameter is a space-separated list ending with the parameter name:
`(const void* a)` → C type `const void*`, name `a`.

Because parameters are immediately re-boxed as `AnchorVal`, the declared C type is
only visible at the call boundary — inside the body every parameter is an `AnchorVal`
regardless of its declared type. To use a parameter as its original C type you must
cast it explicitly:

```anchor
(fn-c greet ((const char* name)) -> void
  (printf "Hello, %s\n" (cast char* name)))   ; cast needed — name is AnchorVal
```

### Function pointers

`fn-ptr` takes the address of any named function (`fn`, `fn-c`, or `ffi`) and boxes
it as an `AnchorVal`. The primary use is passing a callback pointer to a C function:

```anchor
; fn-c defines the callback; fn-ptr passes its address to C
(ffi qsort (void* size_t size_t void*) -> void)
(qsort arr n 8 (fn-ptr compare-ints))
```

`call-ptr` calls through a boxed pointer **for `fn` functions only** — it casts to
the `AnchorVal(AnchorVal, ...)` calling convention that all `fn` functions use:

```anchor
(fn add (a b) (return (+ a b)))

(let fp (fn-ptr add))          ; AnchorVal wrapping (void*)add
(let result (call-ptr fp 3 4)) ; → 7
```

For `fn-c` or `ffi` function pointers, use `call-ptr-c` with an explicit signature:

```anchor
(let fp (fn-ptr compare-ints))
(let result (call-ptr-c fp ((const void* const void*) -> int) (ref x) (ref y)))
```

The signature `((param-types...) -> ret-type)` matches the `ffi` declaration syntax.

### Memory and arenas

`alloc` bumps the current arena pointer — O(1), no `malloc` overhead.

`kb`, `mb`, and `gb` are built-in size macros that expand at compile time — they produce no C output:

```anchor
(with-arena (mb 4) ...)
(global-arena scratch (kb 64))
(alloc (kb 512))
```

```anchor
(with-arena (mb 4)       ; 4 MB arena
  (fn process (n)
    (let buf (alloc (* n 8)))   ; slice of arena bytes
    ; buf freed automatically when process returns
    ))
```

`byte-size` returns the allocation size of any value in bytes:

```anchor
(let arr (alloc (* 6 8)))
(byte-size arr)   ; → 48
(byte-size 42)    ; → 8  (scalar — always 8)
(byte-size nil)   ; → 0
```

This is useful for passing arrays around without a separate length: divide by element
size to recover element count, or use it as an end-of-allocation guard.

`global-arena` declares a named arena whose backing buffer lives for the entire
program. Use it when allocations need to outlive the function that creates them —
linked lists, trees, or any per-request scratch buffer that gets rebuilt in a loop.

To attach a global arena to a function so all its allocations go there, wrap the
`fn` definition with `with-arena`:

```anchor
(global-arena scratch (kb 64))

(with-arena scratch
  (fn build-list (n) ...))     ; all allocs inside go into scratch
```

This is equivalent to `(with-arena scratch ...)` inside the function body but
signals intent at the definition site. Multiple functions can be wrapped together.

```anchor
(global-arena scratch (kb 64))   ; 64 KiB, allocated once

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
a linked structure would dangle — only flat values copy out correctly on return.

`with-parent-arena` temporarily redirects allocations into the arena one level up
the stack. Use it to deep-copy a data structure out of a scope that is about to end:

```anchor
(fn list-copy (lst)
  (if (null? lst)
    (return nil))
  (with-parent-arena
    (return (cons (car lst) (list-copy (cdr lst))))))

(with-arena
  (fn main ()
    (let original nil)
    (with-arena
      (set! original (cons 1 (cons 2 (cons 3 nil))))
      (set! original (list-copy original)))  ; copied into outer arena before inner dies
    ; original is safe to use here
    ))
```

Nesting `with-parent-arena` climbs one level each time. Global arenas behave the
same as local ones — the parent of whatever arena is currently active is used.

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

(let p (alloc (sizeof Point)))
(set! p Point x 100)
(set! p Point y 200)
(let px (get p Point x))   ; → anchor_int(100)
```

`get` and `set!` take the pointer first, then the struct type, then fields. Nest structs inline using `(sizeof Name)` as the field size — chain field names to navigate without an intermediate variable. Use `->` to follow a stored pointer instead of navigating into inline bytes:

```anchor
(struct AABB
  (min (sizeof Point))
  (max (sizeof Point)))

(let b (alloc (sizeof AABB)))

;; chained — embedded: navigate into inline Point bytes
(set! b AABB min Point x 0)
(set! b AABB min Point y 0)
(set! b AABB max Point x 800)
(set! b AABB max Point y 600)
(let x0 (get b AABB min Point x))

;; pointer field — node.next stores an address to another Node
;; (struct Node (val 8) (next 8))
(get n Node nxt -> Node val)   ; -> signals pointer dereference
(set! n Node nxt -> Node val 99)
```

Stopping a chain at a type name returns a fat pointer to the embedded struct:

```anchor
(let inner (get b AABB min Point))   ; {ptr+offset, sizeof(Point)} — chainable
```

### Arrays

A bare number or expression in `get`/`set!` is a **byte offset** into the buffer. For element `i` with element size `sz`, the offset is `(* i sz)`:

```anchor
(let arr (alloc (* n 8)))
(set! arr 0  42)              ; write to byte offset 0
(set! arr 8  99)              ; write to byte offset 8
(let v (get arr (* i 8)))     ; scalar read at offset i*8
```

A lone offset in terminal position does a scalar read (8 bytes). To get a fat pointer instead, follow the offset with a size expression:

```anchor
;; fat pointer to element i, carrying the full array size for correct slicing
(let fp (get arr 0 (* n 8)))       ; {arr.ptr, n*8}
(let sl (ptr-add fp (* i 8)))      ; {arr.ptr + i*8, n*8 - i*8}

;; literal or variable — both work
(let fp (get arr 0 48))            ; {arr.ptr, 48}
(let fp (get arr 0 total))         ; {arr.ptr, total}
```

Array of structs — byte offset then named chain in one form:

```anchor
(let pts (alloc (* n (sizeof Point))))
(let sz  (sizeof Point))
(set! pts 0      Point x 10)
(set! pts 0      Point y 20)
(let x0 (get pts 0      Point x))
(let x1 (get pts sz     Point x))
(let x2 (get pts (* 2 sz) Point x))

;; stopping at the type name returns a fat pointer to that element
(let p (get pts sz Point))          ; {pts.ptr + sz, sizeof(Point)}
```

Array of pointers — `->` dereferences a stored pointer:

```anchor
(let arr (alloc (* n 8)))
(set! arr 0 p0)
(let x (get arr 0 -> Point x))
(set! arr 0 -> Point x 99)
```

Pointer-to-array in a struct field — supply the array size at the use site:

```anchor
(struct Bag (len 8) (items 8))   ; items stores a raw pointer

(let base (get bag Bag items -> 0 (* n sz)))   ; fat ptr, size = n*sz
(let sl   (ptr-add base (* i sz)))             ; slice from element i
```

**Storing fat pointers in struct fields.** When you store a pointer into a field, only the address is kept — `byte-size` on the recovered value falls back to the compile-time type size. To preserve the runtime size (e.g. for a dynamic array), use `(val ...)` as the final field specifier:

```anchor
;; 1-field: 16-byte field stores the full AnchorVal (ptr + size) verbatim
(struct Slot (buf 16))
(set! s Slot (val buf) data)        ; store
(let v (get s Slot (val buf)))      ; recover — byte-size works

;; 2-field: split across two 8-byte fields (also individually accessible)
(struct DynArray (data 8) (len 8))
(set! arr DynArray (val data len) buf)
(let v (get arr DynArray (val data len)))
(printf "elements: %d\n" (cast int (/ (byte-size v) (sizeof Elem))))
```

**Fat pointer arrays.** Use `[(val i)]` to store and retrieve full AnchorVals (ptr + size) from a 16-byte-per-element array:

```anchor
(let arr (alloc (* n 16)))
(set! arr [(val 0)] buf)             ; store full AnchorVal at slot 0
(let v (get arr [(val 0)]))          ; recover — byte-size intact
```

The retrieved value is a fully boxed `AnchorVal` — `byte-size`, pointer arithmetic, and all Anchor operations work on it normally.

### Unions

All fields share offset 0. Total size is the largest field.

```anchor
(union Num
  (as-int   8)
  (as-float 8))

(let u (alloc (sizeof Num)))
(set! u Num as-int 42)
(get u Num as-int)    ; 42
(get u Num as-float)  ; reinterpret same bits as double
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

(global buf (alloc (kb 64)))  ; static 64 KB buffer

(const max-size 4096)         ; immutable — compiler may fold it
```

### Linked lists

`cons`, `car`, `cdr`, `set-car!`, `set-cdr!`, `nil`, and `null?` are built into the language.
`cons` allocates a two-slot cell from the current arena.

`nil` is `{NULL, 0}` — the same value serves as the empty list sentinel and as a
null pointer. Pass it to any `ffi` function expecting a pointer; `null?` tests for
it by checking the size field, which is uniquely `0` for nil (distinct from integer
`0`, which is an unboxed scalar with a different size tag).

```anchor
(let lst (cons 1 (cons 2 (cons 3 nil))))

(let cur lst)
(while (! (null? cur))
  (printf "%d\n" (cast int (car cur)))
  (set! cur (cdr cur)))
```

`set-car!` and `set-cdr!` mutate a cons cell in place:

```anchor
(set-car! lst 99)          ; replace head value
(set-cdr! lst (cons 5 nil)) ; replace tail
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
                  (cons `(set! ,name ,(* i 8) ,(car vs))
                        (loop (+ i 1) (cdr vs)))))))]))

(arena-array primes 2 3 5 7 11 13)
; expands to: (let primes (alloc 48))
;             (set! primes 0 2)
;             (set! primes 8 3) ...
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
            (let _ptr (alloc (sizeof ,name)))
            ,@(map (lambda (f p) `(set! _ptr ,name ,f ,p)) field pnames)
            (return _ptr))
          ,@(map (lambda (aname f)
                   `(fn ,aname (s) (return (get s ,name ,f))))
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
call-site scope.  Name the keyword position in the pattern (rather than `_`) to
get a handle carrying the call-site marks:

```anchor
(define-syntax aif
  (macro-case ()
    [(self test then else-clause)
     `(block
        (let ,(datum->syntax self 'it) ,test)
        (if ,(datum->syntax self 'it) ,then ,else-clause))]))

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
| `examples/array.anc` | `alloc`, `get`/`set!`, bubble sort, `for` macro |
| `examples/linked_list.anc` | `cons`/`car`/`cdr`/`nil`/`null?`, list operations |
| `examples/global_arena.anc` | `global-arena`, `arena-reset!`, lists escaping function scope |
| `examples/structs.anc` | Structs, nested structs, unions, enums, `val` fields, array-of-structs |
| `examples/macros_showcase.anc` | Full macro spectrum: `syntax-rules` → `macro-case` → macros defining macros |
| `examples/fn_pointers.anc` | `fn-ptr`, `call-ptr`, `fn-c`, `call-ptr-c`, passing callbacks to `qsort` |
| `examples/get_set_chains.anc` | `get`/`set!` edge cases: array-of-structs, array-of-pointers, `->` chaining, byte-offset chains, size terminals, `ptr-add` slicing, `(val ...)` round-trips |

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
