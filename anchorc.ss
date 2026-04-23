;;; anchorc.ss — Anchor language compiler (Chez Scheme implementation)
;;;
;;; Usage:
;;;   chez --script anchorc.ss <file.anc> [options]
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
(include "anchor/prelude-embedded.ss")

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
         (when (not (null? inputs))
           (anchor-error "only one input file is supported; use (include \"...\") for additional files"))
         (set! inputs (list (car rest)))
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
;; Include resolution
;; ---------------------------------------------------------------------------

(define *included-files* (make-hashtable string-hash string=?))

(define (anc-include? form)
  (and (pair? form)
       (eq? (id-sym (car form)) 'include)
       (fx= (length form) 2)
       (string? (cadr form))
       (let ([s (cadr form)])
         (and (fx>= (string-length s) 4)
              (string=? (substring s (fx- (string-length s) 4) (string-length s)) ".anc")))))

(define (resolve-path base-dir rel)
  (if (or (fx= (string-length rel) 0) (char=? (string-ref rel 0) #\/))
      rel
      (string-append base-dir "/" rel)))

(define (resolve-anc-includes forms base-dir)
  (apply append
    (map (lambda (form)
           (if (anc-include? form)
             (let* ([rel     (cadr form)]
                    [path    (resolve-path base-dir rel)]
                    [key     path])
               (if (hashtable-ref *included-files* key #f)
                 '()
                 (begin
                   (hashtable-set! *included-files* key #t)
                   (unless (file-exists? path)
                     (anchor-error "include: file not found" path))
                   (resolve-anc-includes
                     (anchor-parse (read-file path) path)
                     (path-parent path)))))
             (list form)))
         forms)))

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
  (let* ([opts  (parse-args args)]
         [input (let ([ins (opts 'inputs)])
                  (when (null? ins)
                    (display "usage: anchorc <file.anc> [--emit-ast] [--emit-exp] [--run] [-o out]\n")
                    (exit 1))
                  (car ins))])
    (unless (file-exists? input)
      (display (string-append "anchorc: file not found: " input "\n"))
      (exit 1))
    (hashtable-set! *included-files* input #t)
    (let* ([prelude (anchor-parse *embedded-prelude* "<prelude>")]
           [raw    (anchor-parse (read-file input) input)]
           [ast    (append prelude (resolve-anc-includes raw (path-parent input)))]
           [base   (path-strip-extension input)]
           [cc     (opts 'cc)]
           [cflags (opts 'cflags)])
        (cond
          [(opts 'emit-ast)
           (for-each (lambda (node) (pretty-print (strip-marks node)) (newline)) ast)]
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
                      [cmd (string-append cc " -O2 " c-path
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
