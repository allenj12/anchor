;;; anchorc.ss — Anchor language compiler (Chez Scheme implementation)
;;;
;;; Usage:
;;;   chez --script anchorc.ss <file.anc> [file2.anc ...] [options]
;;;
;;; Multiple input files are concatenated and processed as a single unit,
;;; producing one C file.  Output name is derived from the first input.
;;;
;;; Options:
;;;   -o <out>       Output file (.c → transpile only; no extension → compile binary)
;;;   --run          Transpile, compile with cc, and run
;;;   --emit-ast     Print parsed AST and exit
;;;   --emit-exp     Print macro-expanded AST and exit
;;;   --cc <cc>      C compiler to use (default: cc)
;;;   --cflags <f>   Extra C compiler flags

(import (chezscheme))

(define compiler-dir
  (let* ([path (if (null? (command-line)) "." (car (command-line)))]
         [dir  (path-parent path)]
         [dir  (if (string=? dir "") "." dir)])
    ;; Resolve to absolute path so -I flags work regardless of cwd
    (if (and (> (string-length dir) 0) (char=? (string-ref dir 0) #\/))
        dir
        (string-append (current-directory) "/" dir))))

(source-directories (cons compiler-dir (source-directories)))
(include "anchor/utils.ss")
(include "anchor/reader.ss")
(include "anchor/expander.ss")
(include "anchor/codegen.ss")

;; ---------------------------------------------------------------------------
;; Argument parsing
;; ---------------------------------------------------------------------------

(define (parse-args args)
  (let ([inputs   '()]
        [output   #f]
        [run?     #f]
        [emit-ast #f]
        [emit-exp #f]
        [cc       "cc"]
        [cflags   ""])
    (let loop ([rest args])
      (cond
        [(null? rest) (values)]
        [(string=? (car rest) "--run")
         (set! run? #t) (loop (cdr rest))]
        [(string=? (car rest) "--emit-ast")
         (set! emit-ast #t) (loop (cdr rest))]
        [(string=? (car rest) "--emit-exp")
         (set! emit-exp #t) (loop (cdr rest))]
        [(string=? (car rest) "--cc")
         (when (null? (cdr rest)) (anchor-error "--cc requires an argument"))
         (set! cc (cadr rest)) (loop (cddr rest))]
        [(string=? (car rest) "--cflags")
         (when (null? (cdr rest)) (anchor-error "--cflags requires an argument"))
         (set! cflags (cadr rest)) (loop (cddr rest))]
        [(string=? (car rest) "-o")
         (when (null? (cdr rest)) (anchor-error "-o requires an argument"))
         (set! output (cadr rest)) (loop (cddr rest))]
        [(and (fx> (string-length (car rest)) 1)
              (char=? (string-ref (car rest) 0) #\-))
         (anchor-error "unknown flag" (car rest))]
        [else
         (set! inputs (append inputs (list (car rest))))
         (loop (cdr rest))]))
    (lambda (key)
      (case key
        [(inputs)   inputs]
        [(output)   output]
        [(run?)     run?]
        [(emit-ast) emit-ast]
        [(emit-exp) emit-exp]
        [(cc)       cc]
        [(cflags)   cflags]
        [else (anchor-error "unknown option key" key)]))))

;; ---------------------------------------------------------------------------
;; Path helpers
;; ---------------------------------------------------------------------------

(define (path-strip-extension path)
  (let loop ([i (fx- (string-length path) 1)])
    (cond
      [(fx< i 0) path]
      [(char=? (string-ref path i) #\.)
       (substring path 0 i)]
      [(memv (string-ref path i) '(#\/ #\\)) path]
      [else (loop (fx- i 1))])))

;; ---------------------------------------------------------------------------
;; Main
;; ---------------------------------------------------------------------------

(define (run-command cmd)
  (let ([r (system cmd)])
    (unless (fx= r 0)
      (anchor-error "command failed" cmd))))

(define (write-c-file c-src path)
  (when (file-exists? path) (delete-file path))
  (call-with-port (open-output-file path)
    (lambda (p) (display c-src p)))
  (display (string-append "anchorc: wrote " path "\n")))

(define (effective-compiler-dir)
  (let* ([path (or (getenv "_ANCHORC_ARGV0")
                   (and (not (null? (command-line))) (car (command-line)))
                   ".")]
         [dir  (path-parent path)]
         [dir  (if (string=? dir "") "." dir)])
    (if (and (> (string-length dir) 0) (char=? (string-ref dir 0) #\/))
        dir
        (if (string=? dir ".")
            (current-directory)
            (string-append (current-directory) "/" dir)))))

(define (main . args)
  (let* ([opts   (parse-args args)]
         [inputs (opts 'inputs)])
    (when (null? inputs)
      (display "usage: anchorc <file.anc> [file2.anc ...] [--emit-ast] [--emit-exp] [--run] [-o out]\n")
      (exit 1))
    (for-each (lambda (p)
                (unless (file-exists? p)
                  (display (string-append "anchorc: file not found: " p "\n"))
                  (exit 1)))
              inputs)
    (let* ([prelude (anchor-parse (read-file (string-append (effective-compiler-dir) "/anchor/prelude.anc")))]
           [ast    (append prelude (apply append (map (lambda (p) (anchor-parse (read-file p))) inputs)))]
           [base   (path-strip-extension (car inputs))]
           [cc     (opts 'cc)]
           [cflags (opts 'cflags)])
        (cond
          [(opts 'emit-ast)
           (for-each (lambda (node) (pretty-print node) (newline)) ast)]
          [(opts 'emit-exp)
           (let ([expanded (expand-all ast)])
             (for-each (lambda (node) (pretty-print node) (newline)) expanded))]
          [else
           (let* ([expanded  (expand-all ast)]
                  [c-src     (anchor-generate expanded)]
                  [out-path  (opts 'output)]
                  [run?      (opts 'run?)]
                  ;; Determine what to produce
                  ;; -o foo.c  → transpile only
                  ;; -o foo    → compile to binary
                  ;; --run     → compile to temp binary and run
                  ;; (default) → transpile to <base>.c
                  [c-path    (cond
                               [run?     (string-append base ".c")]
                               [out-path (if (string=? (path-extension out-path) "c")
                                            out-path
                                            (string-append out-path ".c"))]
                               [else     (string-append base ".c")])]
                  [bin-path  (cond
                               [run?     base]
                               [(and out-path (not (string=? (path-extension out-path) "c")))
                                out-path]
                               [else #f])])
             (write-c-file c-src c-path)
             (when bin-path
               (let* ([flags (if (string=? cflags "") "" (string-append " " cflags))]
                      [cmd (string-append cc " " c-path
                                         flags
                                         " -o " bin-path)])
                 (display (string-append "anchorc: cc " c-path " -o " bin-path "\n"))
                 (run-command cmd)))
             (when run?
               ;; Prefix with ./ when there's no directory component so the
               ;; binary is found without needing . in PATH.
               (run-command
                 (if (string=? (path-parent base) "")
                     (string-append "./" base)
                     base))))])))

  (exit 0))

(suppress-greeting #t)
(scheme-start main)
;; In chez --script mode, scheme-start is never invoked by the runtime.
;; Detect this by the absence of _ANCHORC_ARGV0 (set by the C main in binary mode).
(when (not (getenv "_ANCHORC_ARGV0"))
  (unless (null? (command-line))
    (apply main (cdr (command-line)))))
