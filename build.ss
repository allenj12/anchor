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

(define-values (v-major v-minor v-bug) (scheme-version-number))
(define version
  (string-append (number->string v-major) "." (number->string v-minor) "." (number->string v-bug)))

(define m-type (symbol->string (machine-type)))

(define lib-dir
  (find file-exists?
        (list (format "/opt/homebrew/Cellar/chezscheme/~a/lib/csv~a/~a" version version m-type)
              (format "/usr/lib/csv~a/~a" version m-type)
              (format "/usr/local/lib/csv~a/~a" version m-type)
              ;; Windows: boot/<machine-type>/ holds scheme.h and petite.boot
              (format "C:/Program Files/Chez Scheme ~a/boot/~a" version m-type))))

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
    [(and (fx>= (string-length m-type) 2)
          (string=? "nt" (substring m-type (fx- (string-length m-type) 2) (string-length m-type))))
     'windows]
    [else 'linux]))

(if (eq? os 'windows)
    ;; Windows: link against csv<ver>.lib (import lib for csv<ver>.dll) from bin/<machine-type>/
    (let* ([bin-dir  (format "C:/Program Files/Chez Scheme ~a/bin/~a" version m-type)]
           [lib-name (format "csv~a~a~a.lib" v-major v-minor v-bug)])
      (system (format "gcc -O3 -static-libgcc anchorc_main.c -I\"~a\" -L\"~a\" -l:~a -o anchorc.exe"
                      lib-dir bin-dir lib-name)))
    (let ([gcc-libs
           (case os
             [osx "-L/opt/homebrew/lib -lz -llz4 -liconv -lncurses -lpthread -ldl -lm -framework CoreFoundation -framework CoreServices"]
             [bsd "-L/usr/local/lib -lz -llz4 -liconv -lpthread -lm"]
             [linux "-lz -llz4 -lncurses -lpthread -ldl -lm -lrt"]
             [else (display "unsupported os\n") (exit 1)])])
      (system
        (format "gcc -O3 anchorc_main.c -rdynamic ~a/libkernel.a -I~a ~a -o anchorc"
                lib-dir lib-dir gcc-libs))))

(display (string-append "build complete: " (if (eq? os 'windows) "anchorc.exe" "anchorc") "\n"))
