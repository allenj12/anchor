#pragma once
#include <stddef.h>
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
#define ANCHOR_NULLP(v)    ((v).ptr == NULL)
#define ANCHOR_CAR(cell)   (((AnchorVal*)(cell).ptr)[0])
#define ANCHOR_CDR(cell)   (((AnchorVal*)(cell).ptr)[1])

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
