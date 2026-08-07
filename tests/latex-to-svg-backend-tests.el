;;; latex-to-svg-backend-tests.el --- Tests for latex-to-svg-backend -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/latex-to-svg-backend-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; These exercise the rendering engine in isolation — no external TeX
;; toolchain and no graphical display are required (the graphical inputs
;; are stubbed where needed).

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

(require 'latex-to-svg-backend)

;;;; Cache key

(ert-deftest latex-to-svg-backend-cache-key-distinguishes-inputs ()
  ;; The content key must be stable for identical inputs and differ when the
  ;; equation changes — otherwise cached SVGs collide or never hit.  Neither
  ;; display size NOR color is part of this key: the on-disk SVG is font- and
  ;; color-independent (compiled with --currentcolor, tinted at display).
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (should (equal base (latex-to-svg-backend--cache-key "E=mc^2")))
    (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^3")))))

(ert-deftest latex-to-svg-backend-cache-key-folds-in-preamble ()
  ;; Changing the preamble must invalidate the cache (different output).
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (let ((latex-to-svg-backend-preamble "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-backend-cache-key-folds-in-appended-preamble ()
  ;; Changing the appended preamble must also invalidate the cache.
  (let ((base (latex-to-svg-backend--cache-key "E=mc^2")))
    (let ((latex-to-svg-backend-appended-preamble "\\usepackage{braket}"))
      (should-not (equal base (latex-to-svg-backend--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-backend-cache-key-distinguishes-delimiters ()
  ;; The engine renders LATEX verbatim, so inline vs display (different
  ;; delimiters) are simply different strings and get distinct keys with no
  ;; special-casing — a `$x$' image never collides with a `\[x\]' one.
  (should-not (equal (latex-to-svg-backend--cache-key "$x$")
                     (latex-to-svg-backend--cache-key "\\[x\\]")))
  ;; And an injected \setcounter (equation numbering) folds in for free,
  ;; since it is part of the verbatim body string.
  (should-not
   (equal (latex-to-svg-backend--cache-key "\\begin{equation}x\\end{equation}")
          (latex-to-svg-backend--cache-key
           "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}"))))

;;;; Cache directory

(ert-deftest latex-to-svg-backend-cache-dir-uses-xdg-default ()
  ;; With no explicit override, the cache lives under $XDG_CACHE_HOME in a
  ;; `latex-to-svg-backend/' subdirectory, and is created on demand.
  (let* ((parent (make-temp-file "l2s-xdg" t))
         (latex-to-svg-backend-cache-directory nil)
         (process-environment (cons (concat "XDG_CACHE_HOME=" parent)
                                    process-environment)))
    (unwind-protect
        (let ((dir (latex-to-svg-backend--cache-dir)))
          (should (equal (file-name-as-directory dir)
                         (file-name-as-directory
                          (expand-file-name "latex-to-svg-backend" parent))))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

(ert-deftest latex-to-svg-backend-cache-dir-honors-explicit-override ()
  ;; An explicit `latex-to-svg-backend-cache-directory' wins over the default and is
  ;; created on demand.
  (let* ((parent (make-temp-file "l2s-cache-override" t))
         (dir (file-name-concat parent "eqs"))
         (latex-to-svg-backend-cache-directory dir))
    (unwind-protect
        (progn
          (should (equal (latex-to-svg-backend--cache-dir) dir))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

;;;; Capability

(ert-deftest latex-to-svg-backend-available-p-honors-non-graphic-opt-in ()
  ;; Renderability requires SVG build support, and then either a graphical
  ;; frame or the non-graphic opt-in (for daemon use).
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) t)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (let ((latex-to-svg-backend-render-on-non-graphic nil))
        (should-not (latex-to-svg-backend-available-p)))
      (let ((latex-to-svg-backend-render-on-non-graphic t))
        (should (latex-to-svg-backend-available-p))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (let ((latex-to-svg-backend-render-on-non-graphic nil))
        (should (latex-to-svg-backend-available-p)))))
  ;; No SVG support in the build => never renderable, even with the opt-in.
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) nil))
            ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (let ((latex-to-svg-backend-render-on-non-graphic t))
      (should-not (latex-to-svg-backend-available-p)))))

;;;; Scale

(ert-deftest latex-to-svg-backend-display-scale-is-1-when-headless ()
  ;; With no graphical frame at all (batch) the font height is unknown, so
  ;; the image is left at natural size.
  (cl-letf (((symbol-function 'latex-to-svg-backend--graphic-frame) (lambda () nil)))
    (should (equal (latex-to-svg-backend-display-scale) 1.0))))

(ert-deftest latex-to-svg-backend-px-per-pt-is-deterministic ()
  ;; Pixels-per-point is a pure function of `latex-to-svg-backend-svg-dpi' — no
  ;; measurement, so it never varies between calls (the bug this fixed).
  (let ((latex-to-svg-backend-svg-dpi 96.0))
    (should (equal (latex-to-svg-backend--svg-px-per-pt) (/ 96.0 72.0))))
  (let ((latex-to-svg-backend-svg-dpi 144.0))
    (should (equal (latex-to-svg-backend--svg-px-per-pt) 2.0))))

(ert-deftest latex-to-svg-backend-display-scale-matches-font ()
  ;; The display scale maps the LaTeX 10pt body font onto the buffer font
  ;; height: scale = target * font-scale / (10 * dpi/72).  Stub the graphic
  ;; frame + font height so the arithmetic is checked deterministically.
  (cl-letf (((symbol-function 'latex-to-svg-backend--graphic-frame)
             (lambda () (selected-frame)))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28)))
    (let ((latex-to-svg-backend-svg-dpi 144.0))   ; dpi/72 = 2.0
      (let ((latex-to-svg-backend-font-scale 1.0))
        (should (equal (latex-to-svg-backend-display-scale)
                       (/ 28.0 (* 10.0 2.0)))))
      ;; Doubling font-scale doubles the displayed size.
      (let* ((latex-to-svg-backend-font-scale 1.0)
             (base (latex-to-svg-backend-display-scale))
             (latex-to-svg-backend-font-scale 2.0))
        (should (equal (latex-to-svg-backend-display-scale) (* 2 base)))))))

(ert-deftest latex-to-svg-backend-display-scale-rescale-by-multiplies ()
  ;; RESCALE-BY is a per-call multiplier on top of the global font-scale, so
  ;; a front-end can size display equations larger than inline without
  ;; touching the base.  Off a graphic frame it still scales the 1.0 default.
  (cl-letf (((symbol-function 'latex-to-svg-backend--graphic-frame)
             (lambda () (selected-frame)))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28)))
    (let ((latex-to-svg-backend-svg-dpi 144.0)      ; dpi/72 = 2.0
          (latex-to-svg-backend-font-scale 1.0))
      (let ((base (latex-to-svg-backend-display-scale)))
        (should (equal (latex-to-svg-backend-display-scale 1.0) base))
        (should (< (abs (- (latex-to-svg-backend-display-scale 1.5) (* 1.5 base)))
                   1e-9)))))
  ;; Headless (no graphic frame): returns RESCALE-BY itself, not a bare 1.0.
  (cl-letf (((symbol-function 'latex-to-svg-backend--graphic-frame) (lambda () nil)))
    (should (equal (latex-to-svg-backend-display-scale) 1.0))
    (should (equal (latex-to-svg-backend-display-scale 1.3) 1.3))))

;;;; Appearance

(ert-deftest latex-to-svg-backend-appearance-tracks-color-and-font ()
  ;; The appearance signature folds in both the colors and the buffer font
  ;; height, so a lazy refresh detects a font-size change as well as a color
  ;; change.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'latex-to-svg-backend--svg-color)
             (lambda (_face attr _fallback)
               (if (eq attr :foreground) "#111111" "#eeeeee"))))
    (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 20)))
      (let ((a (latex-to-svg-backend-appearance)))
        (should (equal a '("#111111" "#eeeeee" 20)))
        ;; Same colors, larger font => different signature => would refresh.
        (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 28)))
          (should-not (equal a (latex-to-svg-backend-appearance))))))))

;;;; Image cache

(ert-deftest latex-to-svg-backend-image-cache-key-includes-scale-and-color ()
  ;; The in-memory image-cache key folds in BOTH the display scale and the
  ;; tint color, so the same equation at two font sizes or two themes maps
  ;; to distinct entries (the on-disk SVG is shared).
  (should (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                 (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")))
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg-backend--image-cache-key "K" 1.5 "#fff")))
  (should-not (equal (latex-to-svg-backend--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg-backend--image-cache-key "K" 0.8 "#000"))))

(ert-deftest latex-to-svg-backend-load-svg-recolors-currentcolor ()
  ;; The on-disk SVG carries `currentColor'; loading substitutes the given
  ;; foreground in, so the image is tinted without recompiling.
  (let ((tmp (make-temp-file "l2s-cc" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg'>"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (let ((data (image-property
                       (latex-to-svg-backend--load-svg-image tmp 1.0 "#abcdef")
                       :data)))
            (should (string-match-p "#abcdef" data))
            (should-not (string-match-p "currentColor" data))))
      (delete-file tmp))))

(ert-deftest latex-to-svg-backend-image-cache-coexists-per-scale ()
  ;; The same on-disk SVG cached at two display scales yields two distinct
  ;; image objects that coexist: the first stays warm after the second is
  ;; created (so a sibling buffer's images survive a font change — no clear).
  (let ((tmp (make-temp-file "l2s-svg" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='10pt' height='10pt'>"
                    "<rect width='10' height='10'/></svg>"))
          (clrhash latex-to-svg-backend--image-cache)
          (cl-letf (((symbol-function 'latex-to-svg-backend--svg-file)
                     (lambda (_key) tmp)))
            (let (img1 img2)
              (cl-letf (((symbol-function 'latex-to-svg-backend-display-scale)
                         (lambda (&rest _) 0.8)))
                (setq img1 (latex-to-svg-backend--cached-image "K")))
              (cl-letf (((symbol-function 'latex-to-svg-backend-display-scale)
                         (lambda (&rest _) 1.5)))
                (setq img2 (latex-to-svg-backend--cached-image "K")))
              (should img1)
              (should img2)
              ;; Two coexisting entries, one per scale.
              (should (= 2 (hash-table-count latex-to-svg-backend--image-cache)))
              ;; The first is still served from cache (warm, not evicted).
              (cl-letf (((symbol-function 'latex-to-svg-backend-display-scale)
                         (lambda (&rest _) 0.8)))
                (should (eq img1 (latex-to-svg-backend--cached-image "K"))))
              ;; Each image carries its own scale.
              (should (equal (image-property img1 :scale) 0.8))
              (should (equal (image-property img2 :scale) 1.5)))))
      (delete-file tmp))))

;;;; Public entry point

(ert-deftest latex-to-svg-backend-returns-nil-when-not-renderable ()
  ;; Off a renderable display the entry point yields nil (caller keeps the
  ;; raw text) and never schedules a compile.
  (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () nil)))
    (should-not (latex-to-svg-backend "E=mc^2"))))

(ert-deftest latex-to-svg-backend-returns-placeholder-without-tools ()
  ;; Renderable but no toolchain => the placeholder panel image, not nil.
  (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
            ((symbol-function 'latex-to-svg-backend-tools-available-p) (lambda () nil))
            ((symbol-function 'latex-to-svg-backend--placeholder)
             (lambda (_latex) 'placeholder-image)))
    (should (eq (latex-to-svg-backend "E=mc^2") 'placeholder-image))))

(ert-deftest latex-to-svg-backend-schedules-and-coalesces-compiles ()
  ;; Renderable, tools present, SVG not yet on disk: the entry point returns
  ;; nil, schedules ONE compile, and queues every callback for the same
  ;; content key onto it.
  (let ((latex-to-svg-backend--pending (make-hash-table :test 'equal))
        (compiles 0))
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t))
              ((symbol-function 'latex-to-svg-backend-tools-available-p) (lambda () t))
              ((symbol-function 'latex-to-svg-backend--cached-image) (lambda (&rest _) nil))
              ((symbol-function 'latex-to-svg-backend--compile)
               (lambda (&rest _) (cl-incf compiles))))
      (should-not (latex-to-svg-backend "E=mc^2" :callback #'ignore))
      (should-not (latex-to-svg-backend "E=mc^2" :callback #'ignore))
      ;; Two requests for the same equation => a single in-flight compile.
      (should (= compiles 1))
      (should (= 2 (length (gethash (latex-to-svg-backend--cache-key "E=mc^2")
                                    latex-to-svg-backend--pending)))))))

;;;; Direct process pipeline

(defun latex-to-svg-backend-tests--finish-fake-process
    (process exit-status &optional output status event)
  "Finish fake PROCESS with EXIT-STATUS, optionally appending OUTPUT.
STATUS defaults to `exit', and EVENT defaults to a status-appropriate
completion event."
  (when output
    (with-current-buffer (plist-get (aref process 3) :buffer)
      (goto-char (point-max))
      (insert output)))
  (let ((status (or status 'exit)))
    (aset process 1 status)
    (aset process 2 exit-status)
    (funcall
     (plist-get (aref process 3) :sentinel)
     process
     (or event
         (cond
          ((eq status 'signal)
           (format "killed by signal %d\n" exit-status))
          ((zerop exit-status) "finished\n")
          (t (format "exited abnormally with code %d\n" exit-status)))))))

(defmacro latex-to-svg-backend-tests--with-fake-processes (&rest body)
  "Run BODY with direct asynchronous processes captured as fake processes."
  (declare (indent 0) (debug t))
  `(let* ((l2s-test-cache-dir (make-temp-file "l2s-process-cache" t))
          (latex-to-svg-backend-cache-directory l2s-test-cache-dir)
          (latex-to-svg-backend-precompile nil)
          (latex-to-svg-backend-latex-program "latex-direct")
          (latex-to-svg-backend-dvisvgm-program "dvisvgm-direct")
          (latex-to-svg-backend--pending (make-hash-table :test 'equal))
          (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
          (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal))
          (l2s-test-processes nil)
          (l2s-test-warnings nil))
     (unwind-protect
         (cl-letf
             (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (unless (buffer-live-p (plist-get plist :buffer))
                   (error "Process output buffer is not live"))
                 (let ((process
                        (vector 'fake-process 'run 0 plist default-directory)))
                   (push process l2s-test-processes)
                   process)))
              ((symbol-function 'process-status)
               (lambda (process) (aref process 1)))
              ((symbol-function 'process-exit-status)
               (lambda (process) (aref process 2)))
              ((symbol-function 'display-warning)
               (lambda (&rest warning)
                 (push warning l2s-test-warnings)))
              ((symbol-function 'start-process-shell-command)
               (lambda (&rest _)
                 (error "A shell pipeline must not be used"))))
           ,@body)
       (dolist (process l2s-test-processes)
         (let ((buffer (plist-get (aref process 3) :buffer))
               (dir (aref process 4)))
           (when (buffer-live-p buffer)
             (kill-buffer buffer))
           (when (and (file-directory-p dir)
                      (string-prefix-p
                       "latex-to-svg-backend"
                       (file-name-nondirectory (directory-file-name dir))))
             (delete-directory dir t))))
       (when (file-directory-p l2s-test-cache-dir)
         (delete-directory l2s-test-cache-dir t)))))

(ert-deftest latex-to-svg-backend-compile-direct-argv-ignores-user-shell ()
  ;; A Nu or invalid user shell is irrelevant: latex is started directly,
  ;; followed by dvisvgm only after the expected DVI appears.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((shell-file-name "nu")
           (latex-to-svg-backend-metadata-prefix "L2S")
           (doc "$x^2$")
           (key (latex-to-svg-backend--cache-key doc))
           (callbacks 0)
           metadata-seen)
      (puthash
       key
       (list (lambda () (error "callback marker"))
             (lambda ()
               (cl-incf callbacks)
               (setq metadata-seen (latex-to-svg-backend-metadata doc))))
       latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc 3)
      (should (= (length l2s-test-processes) 1))
      (let* ((latex-process (car l2s-test-processes))
             (latex-plist (aref latex-process 3))
             (latex-command (plist-get latex-plist :command))
             (scratch (aref latex-process 4))
             (output-buffer (plist-get latex-plist :buffer))
             (dvi (expand-file-name "equation.dvi" scratch))
             (tex-log (expand-file-name "equation.log" scratch))
             (svg (latex-to-svg-backend--svg-file key)))
        (should (equal latex-command
                       (list "latex-direct"
                             "-interaction=nonstopmode"
                             "-halt-on-error"
                             (expand-file-name "equation.tex" scratch))))
        (should (equal (plist-get latex-plist :connection-type) 'pipe))
        (should (plist-get latex-plist :noquery))
        (should (equal scratch (file-name-as-directory scratch)))
        (with-temp-file dvi
          (insert "fake dvi"))
        (with-temp-file tex-log
          (insert "L2S 3\n"))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 2))
        (let* ((dvisvgm-process (car l2s-test-processes))
               (dvisvgm-plist (aref dvisvgm-process 3)))
          (should (equal (aref dvisvgm-process 4) scratch))
          (should
           (equal (plist-get dvisvgm-plist :command)
                  (list "dvisvgm-direct"
                        "--no-fonts" "--exact-bbox" "--currentcolor"
                        "--scale=1" "-o" svg dvi)))
          (with-temp-file svg
            (insert "<svg/>"))
          (latex-to-svg-backend-tests--finish-fake-process
           dvisvgm-process 0))
        (should (= callbacks 1))
        (should (equal metadata-seen '(:v 1 :nums (3 . 3))))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should-not (buffer-live-p output-buffer))))))

(ert-deftest latex-to-svg-backend-latex-failure-saves-process-output ()
  ;; If latex fails before producing equation.log, captured stderr and the
  ;; terminal status are persisted; dvisvgm is not started.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$bad$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list #'ignore) latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (output-buffer (plist-get (aref latex-process 3) :buffer))
             (scratch (aref latex-process 4))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--key-dir key))))
        (latex-to-svg-backend-tests--finish-fake-process
         latex-process 1 "latex stderr marker\n")
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should-not (buffer-live-p output-buffer))
        (should (file-exists-p log))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward "latex stderr marker" nil t))
          (should (search-forward
                   "[latex] status=exit exit-status=1" nil t))
          (should (search-forward
                   "event=\"exited abnormally with code 1\\n\"" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-missing-stage-output-is-logged ()
  ;; A zero exit without the promised DVI fails with an explicit diagnostic.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$no-dvi$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list #'ignore) latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--key-dir key))))
        (should-not (file-exists-p dvi))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward
                   "[latex] status=exit exit-status=0" nil t))
          (should (search-forward "[latex] expected output missing:" nil t))
          (should (search-forward "equation.dvi" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-dead-process-log-still-cleans-up ()
  ;; Logging is best-effort: a dead output buffer that makes the next stage
  ;; fail to start must not suppress completion or leak pending/scratch state.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$x$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list #'ignore) latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (output-buffer (plist-get (aref latex-process 3) :buffer))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch)))
        (with-temp-file dvi
          (insert "fake dvi"))
        (kill-buffer output-buffer)
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 1))
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-dvisvgm-signal-keeps-both-logs ()
  ;; A second-stage signal keeps equation.log, process output, and signal data.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((doc "$bad-svg$")
           (key (latex-to-svg-backend--cache-key doc)))
      (puthash key (list #'ignore) latex-to-svg-backend--pending)
      (latex-to-svg-backend--compile key doc)
      (let* ((latex-process (car l2s-test-processes))
             (scratch (aref latex-process 4))
             (dvi (expand-file-name "equation.dvi" scratch))
             (tex-log (expand-file-name "equation.log" scratch))
             (log (expand-file-name (concat key ".log")
                                    (latex-to-svg-backend--key-dir key))))
        (with-temp-file dvi
          (insert "fake dvi"))
        (with-temp-file tex-log
          (insert "equation.log marker\n"))
        (latex-to-svg-backend-tests--finish-fake-process latex-process 0)
        (should (= (length l2s-test-processes) 2))
        (latex-to-svg-backend-tests--finish-fake-process
         (car l2s-test-processes) 9 "dvisvgm stderr marker\n"
         'signal "killed by signal 9\n")
        (should-not (gethash key latex-to-svg-backend--pending))
        (should-not (file-directory-p scratch))
        (with-temp-buffer
          (insert-file-contents log)
          (should (search-forward "equation.log marker" nil t))
          (should (search-forward "dvisvgm stderr marker" nil t))
          (should (search-forward
                   "[dvisvgm] status=signal exit-status=9" nil t))
          (should (search-forward
                   "event=\"killed by signal 9\\n\"" nil t)))
        (should l2s-test-warnings)))))

(ert-deftest latex-to-svg-backend-format-failure-retries-directly ()
  ;; A failed .fmt attempt is cleaned up and retried once with the full
  ;; preamble while keeping callbacks and metadata queued across attempts.
  (latex-to-svg-backend-tests--with-fake-processes
    (let* ((latex-to-svg-backend-precompile t)
           (latex-to-svg-backend-metadata-prefix "L2S")
           (doc "$retry$")
           (key (latex-to-svg-backend--cache-key doc))
           (fmt (latex-to-svg-backend--format-file "fake-format"))
           (ensure-calls 0)
           (callbacks 0)
           metadata-seen)
      (with-temp-file fmt
        (insert "fake format"))
      (puthash
       key
       (list (lambda ()
               (cl-incf callbacks)
               (setq metadata-seen (latex-to-svg-backend-metadata doc))))
       latex-to-svg-backend--pending)
      (cl-letf (((symbol-function 'latex-to-svg-backend--ensure-format)
                 (lambda ()
                   (cl-incf ensure-calls)
                   fmt)))
        (latex-to-svg-backend--compile key doc 7)
        (let* ((first-process (car l2s-test-processes))
               (first-plist (aref first-process 3))
               (first-buffer (plist-get first-plist :buffer))
               (first-scratch (aref first-process 4))
               (first-tex (car (last (plist-get first-plist :command))))
               (first-source
                (with-temp-buffer
                  (insert-file-contents first-tex)
                  (buffer-string))))
          (should (string-prefix-p "%& " first-source))
          (latex-to-svg-backend-tests--finish-fake-process
           first-process 1 "format compile failed\n")
          (should (= ensure-calls 1))
          (should (= (length l2s-test-processes) 2))
          (should-not (file-exists-p fmt))
          (should (gethash "fake-format"
                           latex-to-svg-backend--format-blocklist))
          (should (gethash key latex-to-svg-backend--pending))
          (should (= callbacks 0))
          (should-not (file-directory-p first-scratch))
          (should-not (buffer-live-p first-buffer))
          (let* ((retry-process (car l2s-test-processes))
                 (retry-plist (aref retry-process 3))
                 (retry-buffer (plist-get retry-plist :buffer))
                 (retry-scratch (aref retry-process 4))
                 (retry-tex (car (last (plist-get retry-plist :command))))
                 (retry-source
                  (with-temp-buffer
                    (insert-file-contents retry-tex)
                    (buffer-string)))
                 (dvi (expand-file-name "equation.dvi" retry-scratch))
                 (tex-log (expand-file-name "equation.log" retry-scratch))
                 (svg (latex-to-svg-backend--svg-file key)))
            (should-not (string-prefix-p "%& " retry-source))
            (should (string-prefix-p
                     (latex-to-svg-backend--preamble) retry-source))
            (with-temp-file dvi
              (insert "fake dvi"))
            (with-temp-file tex-log
              (insert "L2S 7\n"))
            (latex-to-svg-backend-tests--finish-fake-process retry-process 0)
            (should (= (length l2s-test-processes) 3))
            (with-temp-file svg
              (insert "<svg/>"))
            (latex-to-svg-backend-tests--finish-fake-process
             (car l2s-test-processes) 0)
            (should (= callbacks 1))
            (should (equal metadata-seen '(:v 1 :nums (7 . 7))))
            (should-not (gethash key latex-to-svg-backend--pending))
            (should-not (file-directory-p retry-scratch))
            (should-not (buffer-live-p retry-buffer))))))))

;;;; End-to-end (requires latex + dvisvgm; skipped otherwise)

(ert-deftest latex-to-svg-backend-compiles-verbatim-display-math ()
  ;; Guards the `varwidth' invariant: the verbatim body must accept *display*
  ;; math (`\[...\]', `equation', `align'), not just inline `$...$'.  Plain
  ;; `standalone' errors with "Missing $ inserted" on display math, so a
  ;; regression in `latex-to-svg-backend-preamble' would fail these real compiles.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-e2e" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (dolist (doc '("$E=mc^2$"
                         "\\[F=ma\\]"
                         "\\begin{equation}\nx=1\n\\end{equation}"
                         "\\begin{align}\na&=b\\\\\nc&=d\n\\end{align}"))
            (let ((done 'pending))
              (latex-to-svg-backend doc :callback (lambda () (setq done t)))
              (dotimes (_ 100)
                (when (eq done 'pending)
                  (accept-process-output nil 0.1)))
              (should (eq done t))
              (should (file-exists-p
                       (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key doc)))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Invalidate

(ert-deftest latex-to-svg-backend-invalidate-drops-disk-and-memory ()
  ;; `latex-to-svg-backend-invalidate' removes LATEX's on-disk SVG and every in-memory
  ;; image built from it (any scale/color), leaving other entries intact.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-inv" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (file (latex-to-svg-backend--svg-file key)))
          (with-temp-file file (insert "<svg/>"))
          (puthash (concat key "@1.0@#000000") 'img-a latex-to-svg-backend--image-cache)
          (puthash (concat key "@2.0@#ffffff") 'img-b latex-to-svg-backend--image-cache)
          (puthash "otherkey@1.0@#000000" 'other latex-to-svg-backend--image-cache)
          (should (file-exists-p file))
          (latex-to-svg-backend-invalidate "$x$")
          ;; On-disk SVG gone.
          (should-not (file-exists-p file))
          ;; Both images for this key dropped; the unrelated entry survives.
          (should (= 1 (hash-table-count latex-to-svg-backend--image-cache)))
          (should (eq 'other (gethash "otherkey@1.0@#000000"
                                      latex-to-svg-backend--image-cache))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-tolerates-missing ()
  ;; Invalidating something never rendered is a no-op, not an error.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-inv2" t)))
    (unwind-protect
        (should-not (latex-to-svg-backend-invalidate "$never-rendered$"))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Compile metadata (.eld sidecar)

(defun latex-to-svg-backend-tests--write-log (key body)
  "Write a fake compile scratch dir containing BODY as `equation.log'.
Return the scratch directory (caller deletes it).  KEY is unused here but
kept for symmetry with the compile pipeline."
  (ignore key)
  (let ((dir (make-temp-file "l2s-log" t)))
    (with-temp-file (expand-file-name "equation.log" dir) (insert body))
    dir))

(ert-deftest latex-to-svg-backend-metadata-round-trips ()
  ;; With a prefix set, `--write-metadata' captures FINAL (first integer on a
  ;; matching log line) and pairs it with the caller-supplied INITIAL, storing
  ;; `(INITIAL . FINAL)'; `latex-to-svg-backend-metadata' reads it back on a cache hit.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((latex "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}")
               (key (latex-to-svg-backend--cache-key latex))
               (dir (latex-to-svg-backend-tests--write-log
                     key (concat "This is pdfTeX...\n"
                                 "Overfull \\hbox ...\n"
                                 "L2S 3\n"))))
          (unwind-protect
              (progn
                ;; INITIAL = K+1 = 3, supplied by the caller; FINAL = 3 from log.
                (latex-to-svg-backend--write-metadata key dir 3)
                (should (file-exists-p (latex-to-svg-backend--meta-file key)))
                (should (equal (latex-to-svg-backend-metadata latex)
                               '(:v 1 :nums (3 . 3)))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-disabled-writes-nothing ()
  ;; With no prefix the engine captures nothing and writes no sidecar.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-off" t))
        (latex-to-svg-backend-metadata-prefix nil))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (dir (latex-to-svg-backend-tests--write-log key "L2S 3\n")))
          (unwind-protect
              (progn
                (latex-to-svg-backend--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg-backend--meta-file key)))
                (should-not (latex-to-svg-backend-metadata "$x$")))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-needs-a-final ()
  ;; No FINAL captured from the log => no sidecar (nothing to reconcile).
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-none" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (dir (latex-to-svg-backend-tests--write-log key "just noise\n")))
          (unwind-protect
              (progn
                (latex-to-svg-backend--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg-backend--meta-file key))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-missing-and-corrupt-yield-nil ()
  ;; No sidecar => nil; a half-written / corrupt sidecar => nil, not an error.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-bad" t)))
    (unwind-protect
        (progn
          (should-not (latex-to-svg-backend-metadata "$never$"))
          (with-temp-file (latex-to-svg-backend--meta-file (latex-to-svg-backend--cache-key "$x$"))
            (insert "(:v 1 :nums (3 . "))    ; truncated, unreadable
          (should-not (latex-to-svg-backend-metadata "$x$")))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-metadata-captured-from-real-compile ()
  ;; End to end (needs latex + dvisvgm): a `\typeout{L2S-AFTER=...}' injected
  ;; into the body is captured from the real compile log into `<key>.eld' and
  ;; read back — exercising actual TeX log formatting, not a synthetic log.
  (skip-unless (latex-to-svg-backend-tools-available-p))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-e2e" t))
        (latex-to-svg-backend-metadata-prefix "L2S"))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (let* ((doc (concat "\\setcounter{equation}{6}%\n"
                              "\\begin{equation}x=1\\end{equation}\n"
                              "\\typeout{L2S \\arabic{equation}}%\n"))
                 (done 'pending))
            ;; INITIAL = K+1 = 7 supplied in Elisp; FINAL = 7 from the compile.
            (latex-to-svg-backend doc :callback (lambda () (setq done t)) :metadata 7)
            (dotimes (_ 100)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (equal (latex-to-svg-backend-metadata doc)
                           '(:v 1 :nums (7 . 7))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-drops-metadata-sidecar ()
  ;; Invalidate removes the `.eld' alongside the `.svg' so they stay coupled.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-meta-inv" t)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (svg (latex-to-svg-backend--svg-file key))
               (meta (latex-to-svg-backend--meta-file key)))
          (with-temp-file svg (insert "<svg/>"))
          (with-temp-file meta (prin1 '(:v 1 :nums (1 . 1))
                                      (current-buffer)))
          (latex-to-svg-backend-invalidate "$x$")
          (should-not (file-exists-p svg))
          (should-not (file-exists-p meta)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Preamble precompilation (.fmt)

(ert-deftest latex-to-svg-backend-format-key-folds-in-preamble ()
  ;; The format key names the `.fmt'; it must change when the preamble (base
  ;; or appended) or the LaTeX program changes, so a stale format is never
  ;; reused after a preamble edit.
  (let ((base (latex-to-svg-backend--format-key)))
    (should (equal base (latex-to-svg-backend--format-key)))
    (let ((latex-to-svg-backend-appended-preamble "\\usepackage{physics}"))
      (should-not (equal base (latex-to-svg-backend--format-key))))
    (let ((latex-to-svg-backend-preamble "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg-backend--format-key))))
    (let ((latex-to-svg-backend-latex-program "xelatex"))
      (should-not (equal base (latex-to-svg-backend--format-key))))))

(ert-deftest latex-to-svg-backend-preamble-appends ()
  ;; The combined preamble is the base alone when nothing is appended, else
  ;; base + newline + appended (the exact text dumped and embedded).
  (let ((latex-to-svg-backend-preamble "BASE")
        (latex-to-svg-backend-appended-preamble ""))
    (should (equal (latex-to-svg-backend--preamble) "BASE")))
  (let ((latex-to-svg-backend-preamble "BASE")
        (latex-to-svg-backend-appended-preamble "EXTRA"))
    (should (equal (latex-to-svg-backend--preamble) "BASE\nEXTRA"))))

(ert-deftest latex-to-svg-backend-ensure-format-nil-when-disabled ()
  ;; With precompilation off, no format is produced or consulted (never even
  ;; probes for mylatexformat).
  (let ((latex-to-svg-backend-precompile nil))
    (cl-letf (((symbol-function 'latex-to-svg-backend--precompile-available-p)
               (lambda () (error "must not probe when disabled"))))
      (should-not (latex-to-svg-backend--ensure-format)))))

(ert-deftest latex-to-svg-backend-ensure-format-builds-once-and-reuses ()
  ;; First call builds the `.fmt' (stubbed); a fresh on-disk format newer than
  ;; the LaTeX binary is then reused with no rebuild.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
        (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal))
        (builds 0))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                   ;; A binary older than the about-to-be-built .fmt.
                   (lambda () (let ((f (make-temp-file "l2s-bin")))
                                (set-file-times f '(1 0)) f)))
                  ((symbol-function 'latex-to-svg-backend--precompile-available-p)
                   (lambda () t))
                  ((symbol-function 'latex-to-svg-backend--build-format)
                   (lambda (fkey)
                     (cl-incf builds)
                     (let ((f (latex-to-svg-backend--format-file fkey)))
                       (with-temp-file f (insert "fmt")) f))))
          (let ((f1 (latex-to-svg-backend--ensure-format)))
            (should f1)
            (should (file-exists-p f1))
            (should (= builds 1))
            ;; Second call: verified fresh, served from disk, no rebuild.
            (should (equal f1 (latex-to-svg-backend--ensure-format)))
            (should (= builds 1))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-ensure-format-rebuilds-when-stale ()
  ;; A `.fmt' older than the LaTeX binary (e.g. after a toolchain upgrade) is
  ;; deleted and rebuilt rather than reused.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-stale" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
        (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal))
        (builds 0))
    (unwind-protect
        (let* ((fkey (latex-to-svg-backend--format-key))
               (fmt (latex-to-svg-backend--format-file fkey))
               (newer-bin (make-temp-file "l2s-bin")))
          ;; Stale .fmt on disk (epoch), binary is current.
          (with-temp-file fmt (insert "old"))
          (set-file-times fmt '(1 0))
          (cl-letf (((symbol-function 'latex-to-svg-backend--latex-binary)
                     (lambda () newer-bin))
                    ((symbol-function 'latex-to-svg-backend--precompile-available-p)
                     (lambda () t))
                    ((symbol-function 'latex-to-svg-backend--build-format)
                     (lambda (k)
                       (cl-incf builds)
                       (let ((f (latex-to-svg-backend--format-file k)))
                         (with-temp-file f (insert "new")) f))))
            (should (latex-to-svg-backend--ensure-format))
            (should (= builds 1))
            (should (equal (with-temp-buffer (insert-file-contents fmt)
                                             (buffer-string))
                           "new"))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-block-format-blocklists-and-deletes ()
  ;; Abandoning a format deletes the `.fmt', records its key, and makes
  ;; `--ensure-format' skip precompilation for that preamble thereafter.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-block" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
        (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((fkey (latex-to-svg-backend--format-key))
               (fmt (latex-to-svg-backend--format-file fkey)))
          (with-temp-file fmt (insert "fmt"))
          (cl-letf (((symbol-function 'display-warning) #'ignore))
            (latex-to-svg-backend--block-format fmt))
          (should-not (file-exists-p fmt))
          (should (gethash fkey latex-to-svg-backend--format-blocklist))
          ;; Blocklisted => ensure-format yields nil without rebuilding.
          (cl-letf (((symbol-function 'latex-to-svg-backend--build-format)
                     (lambda (_k) (error "must not rebuild a blocklisted format"))))
            (should-not (latex-to-svg-backend--ensure-format))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-flush-format-clears-everything ()
  ;; `latex-to-svg-backend-flush-format' deletes every `.fmt' and resets session state.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-flush" t))
        (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
        (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((dir latex-to-svg-backend-cache-directory))
          (with-temp-file (expand-file-name "aaa.fmt" dir) (insert "1"))
          (with-temp-file (expand-file-name "bbb.fmt" dir) (insert "2"))
          ;; A sibling SVG must survive the flush.
          (with-temp-file (expand-file-name "ccc.svg" dir) (insert "<svg/>"))
          (puthash "aaa" t latex-to-svg-backend--format-checked)
          (puthash "bbb" t latex-to-svg-backend--format-blocklist)
          (latex-to-svg-backend-flush-format)
          (should-not (directory-files dir nil "\\.fmt\\'"))
          (should (file-exists-p (expand-file-name "ccc.svg" dir)))
          (should (= 0 (hash-table-count latex-to-svg-backend--format-checked)))
          (should (= 0 (hash-table-count latex-to-svg-backend--format-blocklist))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-precompiled-compile-end-to-end ()
  ;; End to end (needs latex + dvisvgm + mylatexformat): a real compile through
  ;; the precompiled preamble produces the SVG, and the `.fmt' is left cached.
  (skip-unless (and (latex-to-svg-backend-tools-available-p)
                    (let ((latex-to-svg-backend-precompile t))
                      (latex-to-svg-backend--precompile-available-p))))
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-fmt-e2e" t))
        (latex-to-svg-backend-precompile t)
        (latex-to-svg-backend--format-checked (make-hash-table :test 'equal))
        (latex-to-svg-backend--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) (lambda () t)))
          (let ((done 'pending)
                (doc "\\begin{equation}\ne^{i\\pi}+1=0\n\\end{equation}"))
            (latex-to-svg-backend doc :callback (lambda () (setq done t)))
            (dotimes (_ 200)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (file-exists-p
                     (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key doc))))
            ;; The format file was built and cached alongside the SVG.
            (should (file-exists-p
                     (latex-to-svg-backend--format-file (latex-to-svg-backend--format-key))))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Cache sharding

(ert-deftest latex-to-svg-backend-svg-file-is-sharded-by-key-prefix ()
  ;; The SVG (and its `.eld' sidecar) live in a subdirectory named by the
  ;; first two characters of the content key, created on demand.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-shard" t)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$x$"))
               (svg (latex-to-svg-backend--svg-file key))
               (eld (latex-to-svg-backend--meta-file key))
               (bucket (substring key 0 2)))
          (should (equal (file-name-nondirectory
                          (directory-file-name (file-name-directory svg)))
                         bucket))
          ;; SVG and sidecar share the same bucket, which now exists.
          (should (equal (file-name-directory svg) (file-name-directory eld)))
          (should (file-directory-p (file-name-directory svg)))
          (should (equal (file-name-nondirectory svg) (concat key ".svg"))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-invalidate-works-with-sharding ()
  ;; `invalidate' removes the sharded SVG and its sidecar.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-shard-inv" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((key (latex-to-svg-backend--cache-key "$y$"))
               (svg (latex-to-svg-backend--svg-file key))
               (eld (latex-to-svg-backend--meta-file key)))
          (with-temp-file svg (insert "<svg/>"))
          (with-temp-file eld (prin1 '(:v 1 :nums (1 . 1)) (current-buffer)))
          (latex-to-svg-backend-invalidate "$y$")
          (should-not (file-exists-p svg))
          (should-not (file-exists-p eld)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

;;;; Cache garbage collection

(defun latex-to-svg-backend-tests--fake-entry (latex bytes age-days)
  "Write a fake cache SVG of BYTES for LATEX, dated AGE-DAYS in the past.
Return the SVG path."
  (let ((svg (latex-to-svg-backend--svg-file (latex-to-svg-backend--cache-key latex)))
        (ts (- (float-time) (* age-days 86400))))
    (with-temp-file svg (insert (make-string bytes ?x)))
    (set-file-times svg (seconds-to-time ts))
    svg))

(ert-deftest latex-to-svg-backend-gc-expires-by-age ()
  ;; Entries older than the age cap are deleted (with siblings); fresh ones stay.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-age" t))
        (latex-to-svg-backend-cache-max-age 30))
    (unwind-protect
        (let ((old (latex-to-svg-backend-tests--fake-entry "$old$" 10 90))
              (new (latex-to-svg-backend-tests--fake-entry "$new$" 10 1))
              ;; A sidecar next to the stale SVG must go with it.
              (old-eld (latex-to-svg-backend--meta-file
                        (latex-to-svg-backend--cache-key "$old$"))))
          (with-temp-file old-eld (prin1 '(:v 1 :nums (1 . 1)) (current-buffer)))
          (let ((res (latex-to-svg-backend-gc)))
            (should (= 1 (car res))))
          (should-not (file-exists-p old))
          (should-not (file-exists-p old-eld))
          (should (file-exists-p new)))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-gc-records-timestamp-and-gates-cadence ()
  ;; `--maybe-gc' runs when the interval has elapsed and no-ops when it hasn't.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-gc-stamp" t))
        (latex-to-svg-backend-cache-max-age nil)
        (latex-to-svg-backend-gc-interval 1))
    (unwind-protect
        (progn
          (should (= 0 (latex-to-svg-backend--last-gc-time)))
          ;; First check runs a GC and records the time.
          (let ((ran nil))
            (cl-letf (((symbol-function 'latex-to-svg-backend-gc)
                       (lambda () (setq ran t)
                         (latex-to-svg-backend--record-gc-time) '(0 . 0))))
              (latex-to-svg-backend--maybe-gc)
              (should ran)
              (should (> (latex-to-svg-backend--last-gc-time) 0))
              ;; Second check within the interval is a no-op.
              (setq ran nil)
              (latex-to-svg-backend--maybe-gc)
              (should-not ran)))
          ;; A nil interval disables automatic GC entirely.
          (let ((latex-to-svg-backend-gc-interval nil) (ran nil))
            (cl-letf (((symbol-function 'latex-to-svg-backend-gc)
                       (lambda () (setq ran t) '(0 . 0))))
              (latex-to-svg-backend--maybe-gc)
              (should-not ran))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(ert-deftest latex-to-svg-backend-clear-cache-empties-svgs-keeps-fmt ()
  ;; `clear-cache' deletes svg/eld across shards and empties the image cache,
  ;; but leaves `.fmt' format files alone.
  (let ((latex-to-svg-backend-cache-directory (make-temp-file "l2s-clear" t))
        (latex-to-svg-backend--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((svg (latex-to-svg-backend-tests--fake-entry "$z$" 10 1))
              (eld (latex-to-svg-backend--meta-file
                    (latex-to-svg-backend--cache-key "$z$")))
              (fmt (latex-to-svg-backend--format-file "deadbeef")))
          (with-temp-file eld (prin1 '(:v 1 :nums (1 . 1)) (current-buffer)))
          (with-temp-file fmt (insert "format"))
          (puthash "k@1.0@#000000" 'img latex-to-svg-backend--image-cache)
          (latex-to-svg-backend-clear-cache)
          (should-not (file-exists-p svg))
          (should-not (file-exists-p eld))
          (should (file-exists-p fmt))
          (should (= 0 (hash-table-count latex-to-svg-backend--image-cache))))
      (delete-directory latex-to-svg-backend-cache-directory t))))

(provide 'latex-to-svg-backend-tests)

;;; latex-to-svg-backend-tests.el ends here
