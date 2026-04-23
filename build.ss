#!/opt/homebrew/bin/chez --script

;;; Build script — produces a standalone anchorc binary.
;;; Run from the compiler/ directory:
;;;   chez --script build.ss

(import (chezscheme))

(define build-dir (current-directory))

(optimize-level 3)
(debug-level 0)
(compile-imported-libraries #t)

;; Embed prelude.anc as a string constant so the binary is self-contained.
(call-with-output-file "anchor/prelude-embedded.ss"
  (lambda (out)
    (write `(define *embedded-prelude*
              ,(call-with-input-file "anchor/prelude.anc" get-string-all)) out)
    (newline out))
  '(replace))

(compile-program "anchorc.ss")

(fasl-compressed #f)
(make-boot-file "anchorc.boot" '("petite") "anchorc.so")
(vfasl-convert-file "anchorc.boot" "anchorc.boot" '("petite"))

(define (boot->cheader src target name)
  (let ([in (open-file-input-port src)])
    (call-with-output-file target
      (lambda (out)
        (fprintf out "unsigned char ~a[] = {\n" name)
        (let loop ([byte (get-u8 in)] [count 0])
          (if (eof-object? byte)
              (fprintf out "\n};\nunsigned int ~a_len = ~a;\n" name count)
              (begin
                (fprintf out "0x~2,'0x" byte)
                (unless (port-eof? in) (fprintf out ", "))
                (when (fxzero? (fxmod (fx1+ count) 20)) (fprintf out "\n"))
                (loop (get-u8 in) (fx1+ count)))))
        (close-port in))
      '(truncate))))

(boot->cheader "anchorc.boot" "anchorc_boot.h" "anchorc_boot")

(define version
  (let-values ([(major minor bug) (scheme-version-number)])
    (string-append (number->string major) "." (number->string minor) "." (number->string bug))))

(define m-type (symbol->string (machine-type)))

(define lib-dir
  (find file-exists?
        (list (format "/opt/homebrew/Cellar/chezscheme/~a/lib/csv~a/~a" version version m-type)
              (format "/usr/lib/csv~a/~a" version m-type)
              (format "/usr/local/lib/csv~a/~a" version m-type))))

(unless lib-dir
  (display "could not find Chez Scheme installation\n") (exit 1))

(unless (file-exists? "petite_boot.h")
  (boot->cheader (format "~a/petite.boot" lib-dir) "petite_boot.h" "petite_boot"))

(define os
  (cond
    [(and (fx>= (string-length m-type) 3)
          (string=? "osx" (substring m-type (fx- (string-length m-type) 3) (string-length m-type))))
     'osx]
    [(and (fx>= (string-length m-type) 2)
          (member (substring m-type (fx- (string-length m-type) 2) (string-length m-type))
                  '("ob" "nb" "fb")))
     'bsd]
    [else 'linux]))

(let ([gcc-libs
       (case os
         [osx "-L/opt/homebrew/lib -lz -llz4 -liconv -lncurses -lpthread -ldl -lm -framework CoreFoundation -framework CoreServices"]
         [bsd "-L/usr/local/lib -lz -llz4 -liconv -lpthread -lm"]
         [linux "-lz -llz4 -lncurses -lpthread -ldl -lm -lrt"]
         [else (display "unsupported os\n") (exit 1)])])
  (system
    (format "gcc -O3 anchorc_main.c -rdynamic ~a/libkernel.a -I~a ~a -o anchorc"
            lib-dir lib-dir gcc-libs)))

(display "build complete: compiler/anchorc\n")
