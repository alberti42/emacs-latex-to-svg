;;; latex-to-svg-tests.el --- Tests for latex-to-svg -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/latex-to-svg-tests.el \
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

(require 'latex-to-svg)

;;;; Cache key

(ert-deftest latex-to-svg-cache-key-distinguishes-inputs ()
  ;; The content key must be stable for identical inputs and differ when the
  ;; equation changes — otherwise cached SVGs collide or never hit.  Neither
  ;; display size NOR color is part of this key: the on-disk SVG is font- and
  ;; color-independent (compiled with --currentcolor, tinted at display).
  (let ((base (latex-to-svg--cache-key "E=mc^2")))
    (should (equal base (latex-to-svg--cache-key "E=mc^2")))
    (should-not (equal base (latex-to-svg--cache-key "E=mc^3")))))

(ert-deftest latex-to-svg-cache-key-folds-in-preamble ()
  ;; Changing the preamble must invalidate the cache (different output).
  (let ((base (latex-to-svg--cache-key "E=mc^2")))
    (let ((latex-to-svg-preamble "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-cache-key-folds-in-appended-preamble ()
  ;; Changing the appended preamble must also invalidate the cache.
  (let ((base (latex-to-svg--cache-key "E=mc^2")))
    (let ((latex-to-svg-appended-preamble "\\usepackage{braket}"))
      (should-not (equal base (latex-to-svg--cache-key "E=mc^2"))))))

(ert-deftest latex-to-svg-cache-key-distinguishes-delimiters ()
  ;; The engine renders LATEX verbatim, so inline vs display (different
  ;; delimiters) are simply different strings and get distinct keys with no
  ;; special-casing — a `$x$' image never collides with a `\[x\]' one.
  (should-not (equal (latex-to-svg--cache-key "$x$")
                     (latex-to-svg--cache-key "\\[x\\]")))
  ;; And an injected \setcounter (equation numbering) folds in for free,
  ;; since it is part of the verbatim body string.
  (should-not
   (equal (latex-to-svg--cache-key "\\begin{equation}x\\end{equation}")
          (latex-to-svg--cache-key
           "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}"))))

;;;; Cache directory

(ert-deftest latex-to-svg-cache-dir-uses-xdg-default ()
  ;; With no explicit override, the cache lives under $XDG_CACHE_HOME in a
  ;; `latex-to-svg/' subdirectory, and is created on demand.
  (let* ((parent (make-temp-file "l2s-xdg" t))
         (latex-to-svg-cache-directory nil)
         (process-environment (cons (concat "XDG_CACHE_HOME=" parent)
                                    process-environment)))
    (unwind-protect
        (let ((dir (latex-to-svg--cache-dir)))
          (should (equal (file-name-as-directory dir)
                         (file-name-as-directory
                          (expand-file-name "latex-to-svg" parent))))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

(ert-deftest latex-to-svg-cache-dir-honors-explicit-override ()
  ;; An explicit `latex-to-svg-cache-directory' wins over the default and is
  ;; created on demand.
  (let* ((parent (make-temp-file "l2s-cache-override" t))
         (dir (file-name-concat parent "eqs"))
         (latex-to-svg-cache-directory dir))
    (unwind-protect
        (progn
          (should (equal (latex-to-svg--cache-dir) dir))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

;;;; Capability

(ert-deftest latex-to-svg-available-p-honors-non-graphic-opt-in ()
  ;; Renderability requires SVG build support, and then either a graphical
  ;; frame or the non-graphic opt-in (for daemon use).
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) t)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (let ((latex-to-svg-render-on-non-graphic nil))
        (should-not (latex-to-svg-available-p)))
      (let ((latex-to-svg-render-on-non-graphic t))
        (should (latex-to-svg-available-p))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (let ((latex-to-svg-render-on-non-graphic nil))
        (should (latex-to-svg-available-p)))))
  ;; No SVG support in the build => never renderable, even with the opt-in.
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) nil))
            ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (let ((latex-to-svg-render-on-non-graphic t))
      (should-not (latex-to-svg-available-p)))))

;;;; Scale

(ert-deftest latex-to-svg-display-scale-is-1-when-headless ()
  ;; With no graphical frame at all (batch) the font height is unknown, so
  ;; the image is left at natural size.
  (cl-letf (((symbol-function 'latex-to-svg--graphic-frame) (lambda () nil)))
    (should (equal (latex-to-svg-display-scale) 1.0))))

(ert-deftest latex-to-svg-px-per-pt-is-deterministic ()
  ;; Pixels-per-point is a pure function of `latex-to-svg-svg-dpi' — no
  ;; measurement, so it never varies between calls (the bug this fixed).
  (let ((latex-to-svg-svg-dpi 96.0))
    (should (equal (latex-to-svg--svg-px-per-pt) (/ 96.0 72.0))))
  (let ((latex-to-svg-svg-dpi 144.0))
    (should (equal (latex-to-svg--svg-px-per-pt) 2.0))))

(ert-deftest latex-to-svg-display-scale-matches-font ()
  ;; The display scale maps the LaTeX 10pt body font onto the buffer font
  ;; height: scale = target * font-scale / (10 * dpi/72).  Stub the graphic
  ;; frame + font height so the arithmetic is checked deterministically.
  (cl-letf (((symbol-function 'latex-to-svg--graphic-frame)
             (lambda () (selected-frame)))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28)))
    (let ((latex-to-svg-svg-dpi 144.0))   ; dpi/72 = 2.0
      (let ((latex-to-svg-font-scale 1.0))
        (should (equal (latex-to-svg-display-scale)
                       (/ 28.0 (* 10.0 2.0)))))
      ;; Doubling font-scale doubles the displayed size.
      (let* ((latex-to-svg-font-scale 1.0)
             (base (latex-to-svg-display-scale))
             (latex-to-svg-font-scale 2.0))
        (should (equal (latex-to-svg-display-scale) (* 2 base)))))))

(ert-deftest latex-to-svg-display-scale-rescale-by-multiplies ()
  ;; RESCALE-BY is a per-call multiplier on top of the global font-scale, so
  ;; a front-end can size display equations larger than inline without
  ;; touching the base.  Off a graphic frame it still scales the 1.0 default.
  (cl-letf (((symbol-function 'latex-to-svg--graphic-frame)
             (lambda () (selected-frame)))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28)))
    (let ((latex-to-svg-svg-dpi 144.0)      ; dpi/72 = 2.0
          (latex-to-svg-font-scale 1.0))
      (let ((base (latex-to-svg-display-scale)))
        (should (equal (latex-to-svg-display-scale 1.0) base))
        (should (< (abs (- (latex-to-svg-display-scale 1.5) (* 1.5 base)))
                   1e-9)))))
  ;; Headless (no graphic frame): returns RESCALE-BY itself, not a bare 1.0.
  (cl-letf (((symbol-function 'latex-to-svg--graphic-frame) (lambda () nil)))
    (should (equal (latex-to-svg-display-scale) 1.0))
    (should (equal (latex-to-svg-display-scale 1.3) 1.3))))

;;;; Appearance

(ert-deftest latex-to-svg-appearance-tracks-color-and-font ()
  ;; The appearance signature folds in both the colors and the buffer font
  ;; height, so a lazy refresh detects a font-size change as well as a color
  ;; change.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'latex-to-svg--svg-color)
             (lambda (_face attr _fallback)
               (if (eq attr :foreground) "#111111" "#eeeeee"))))
    (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 20)))
      (let ((a (latex-to-svg-appearance)))
        (should (equal a '("#111111" "#eeeeee" 20)))
        ;; Same colors, larger font => different signature => would refresh.
        (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 28)))
          (should-not (equal a (latex-to-svg-appearance))))))))

;;;; Image cache

(ert-deftest latex-to-svg-image-cache-key-includes-scale-and-color ()
  ;; The in-memory image-cache key folds in BOTH the display scale and the
  ;; tint color, so the same equation at two font sizes or two themes maps
  ;; to distinct entries (the on-disk SVG is shared).
  (should (equal (latex-to-svg--image-cache-key "K" 0.8 "#fff")
                 (latex-to-svg--image-cache-key "K" 0.8 "#fff")))
  (should-not (equal (latex-to-svg--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg--image-cache-key "K" 1.5 "#fff")))
  (should-not (equal (latex-to-svg--image-cache-key "K" 0.8 "#fff")
                     (latex-to-svg--image-cache-key "K" 0.8 "#000"))))

(ert-deftest latex-to-svg-load-svg-recolors-currentcolor ()
  ;; The on-disk SVG carries `currentColor'; loading substitutes the given
  ;; foreground in, so the image is tinted without recompiling.
  (let ((tmp (make-temp-file "l2s-cc" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg'>"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (let ((data (image-property
                       (latex-to-svg--load-svg-image tmp 1.0 "#abcdef")
                       :data)))
            (should (string-match-p "#abcdef" data))
            (should-not (string-match-p "currentColor" data))))
      (delete-file tmp))))

(ert-deftest latex-to-svg-image-cache-coexists-per-scale ()
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
          (clrhash latex-to-svg--image-cache)
          (cl-letf (((symbol-function 'latex-to-svg--svg-file)
                     (lambda (_key) tmp)))
            (let (img1 img2)
              (cl-letf (((symbol-function 'latex-to-svg-display-scale)
                         (lambda (&rest _) 0.8)))
                (setq img1 (latex-to-svg--cached-image "K")))
              (cl-letf (((symbol-function 'latex-to-svg-display-scale)
                         (lambda (&rest _) 1.5)))
                (setq img2 (latex-to-svg--cached-image "K")))
              (should img1)
              (should img2)
              ;; Two coexisting entries, one per scale.
              (should (= 2 (hash-table-count latex-to-svg--image-cache)))
              ;; The first is still served from cache (warm, not evicted).
              (cl-letf (((symbol-function 'latex-to-svg-display-scale)
                         (lambda (&rest _) 0.8)))
                (should (eq img1 (latex-to-svg--cached-image "K"))))
              ;; Each image carries its own scale.
              (should (equal (image-property img1 :scale) 0.8))
              (should (equal (image-property img2 :scale) 1.5)))))
      (delete-file tmp))))

;;;; Public entry point

(ert-deftest latex-to-svg-returns-nil-when-not-renderable ()
  ;; Off a renderable display the entry point yields nil (caller keeps the
  ;; raw text) and never schedules a compile.
  (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () nil)))
    (should-not (latex-to-svg "E=mc^2"))))

(ert-deftest latex-to-svg-returns-placeholder-without-tools ()
  ;; Renderable but no toolchain => the placeholder panel image, not nil.
  (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () t))
            ((symbol-function 'latex-to-svg-tools-available-p) (lambda () nil))
            ((symbol-function 'latex-to-svg--placeholder)
             (lambda (_latex) 'placeholder-image)))
    (should (eq (latex-to-svg "E=mc^2") 'placeholder-image))))

(ert-deftest latex-to-svg-schedules-and-coalesces-compiles ()
  ;; Renderable, tools present, SVG not yet on disk: the entry point returns
  ;; nil, schedules ONE compile, and queues every callback for the same
  ;; content key onto it.
  (let ((latex-to-svg--pending (make-hash-table :test 'equal))
        (compiles 0))
    (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () t))
              ((symbol-function 'latex-to-svg-tools-available-p) (lambda () t))
              ((symbol-function 'latex-to-svg--cached-image) (lambda (&rest _) nil))
              ((symbol-function 'latex-to-svg--compile)
               (lambda (&rest _) (cl-incf compiles))))
      (should-not (latex-to-svg "E=mc^2" :callback #'ignore))
      (should-not (latex-to-svg "E=mc^2" :callback #'ignore))
      ;; Two requests for the same equation => a single in-flight compile.
      (should (= compiles 1))
      (should (= 2 (length (gethash (latex-to-svg--cache-key "E=mc^2")
                                    latex-to-svg--pending)))))))

;;;; End-to-end (requires latex + dvisvgm; skipped otherwise)

(ert-deftest latex-to-svg-compiles-verbatim-display-math ()
  ;; Guards the `varwidth' invariant: the verbatim body must accept *display*
  ;; math (`\[...\]', `equation', `align'), not just inline `$...$'.  Plain
  ;; `standalone' errors with "Missing $ inserted" on display math, so a
  ;; regression in `latex-to-svg-preamble' would fail these real compiles.
  (skip-unless (latex-to-svg-tools-available-p))
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-e2e" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () t)))
          (dolist (doc '("$E=mc^2$"
                         "\\[F=ma\\]"
                         "\\begin{equation}\nx=1\n\\end{equation}"
                         "\\begin{align}\na&=b\\\\\nc&=d\n\\end{align}"))
            (let ((done 'pending))
              (latex-to-svg doc :callback (lambda () (setq done t)))
              (dotimes (_ 100)
                (when (eq done 'pending)
                  (accept-process-output nil 0.1)))
              (should (eq done t))
              (should (file-exists-p
                       (latex-to-svg--svg-file (latex-to-svg--cache-key doc)))))))
      (delete-directory latex-to-svg-cache-directory t))))

;;;; Invalidate

(ert-deftest latex-to-svg-invalidate-drops-disk-and-memory ()
  ;; `latex-to-svg-invalidate' removes LATEX's on-disk SVG and every in-memory
  ;; image built from it (any scale/color), leaving other entries intact.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-inv" t))
        (latex-to-svg--image-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((key (latex-to-svg--cache-key "$x$"))
               (file (latex-to-svg--svg-file key)))
          (with-temp-file file (insert "<svg/>"))
          (puthash (concat key "@1.0@#000000") 'img-a latex-to-svg--image-cache)
          (puthash (concat key "@2.0@#ffffff") 'img-b latex-to-svg--image-cache)
          (puthash "otherkey@1.0@#000000" 'other latex-to-svg--image-cache)
          (should (file-exists-p file))
          (latex-to-svg-invalidate "$x$")
          ;; On-disk SVG gone.
          (should-not (file-exists-p file))
          ;; Both images for this key dropped; the unrelated entry survives.
          (should (= 1 (hash-table-count latex-to-svg--image-cache)))
          (should (eq 'other (gethash "otherkey@1.0@#000000"
                                      latex-to-svg--image-cache))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-invalidate-tolerates-missing ()
  ;; Invalidating something never rendered is a no-op, not an error.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-inv2" t)))
    (unwind-protect
        (should-not (latex-to-svg-invalidate "$never-rendered$"))
      (delete-directory latex-to-svg-cache-directory t))))

;;;; Compile metadata (.eld sidecar)

(defun latex-to-svg-tests--write-log (key body)
  "Write a fake compile scratch dir containing BODY as `equation.log'.
Return the scratch directory (caller deletes it).  KEY is unused here but
kept for symmetry with the compile pipeline."
  (ignore key)
  (let ((dir (make-temp-file "l2s-log" t)))
    (with-temp-file (expand-file-name "equation.log" dir) (insert body))
    dir))

(ert-deftest latex-to-svg-metadata-round-trips ()
  ;; With a prefix set, `--write-metadata' captures FINAL (first integer on a
  ;; matching log line) and pairs it with the caller-supplied INITIAL, storing
  ;; `(INITIAL . FINAL)'; `latex-to-svg-metadata' reads it back on a cache hit.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta" t))
        (latex-to-svg-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((latex "\\setcounter{equation}{2}\\begin{equation}x\\end{equation}")
               (key (latex-to-svg--cache-key latex))
               (dir (latex-to-svg-tests--write-log
                     key (concat "This is pdfTeX...\n"
                                 "Overfull \\hbox ...\n"
                                 "L2S 3\n"))))
          (unwind-protect
              (progn
                ;; INITIAL = K+1 = 3, supplied by the caller; FINAL = 3 from log.
                (latex-to-svg--write-metadata key dir 3)
                (should (file-exists-p (latex-to-svg--meta-file key)))
                (should (equal (latex-to-svg-metadata latex)
                               '(:v 1 :nums (3 . 3)))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-metadata-disabled-writes-nothing ()
  ;; With no prefix the engine captures nothing and writes no sidecar.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta-off" t))
        (latex-to-svg-metadata-prefix nil))
    (unwind-protect
        (let* ((key (latex-to-svg--cache-key "$x$"))
               (dir (latex-to-svg-tests--write-log key "L2S 3\n")))
          (unwind-protect
              (progn
                (latex-to-svg--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg--meta-file key)))
                (should-not (latex-to-svg-metadata "$x$")))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-metadata-needs-a-final ()
  ;; No FINAL captured from the log => no sidecar (nothing to reconcile).
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta-none" t))
        (latex-to-svg-metadata-prefix "L2S"))
    (unwind-protect
        (let* ((key (latex-to-svg--cache-key "$x$"))
               (dir (latex-to-svg-tests--write-log key "just noise\n")))
          (unwind-protect
              (progn
                (latex-to-svg--write-metadata key dir 3)
                (should-not (file-exists-p (latex-to-svg--meta-file key))))
            (delete-directory dir t)))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-metadata-missing-and-corrupt-yield-nil ()
  ;; No sidecar => nil; a half-written / corrupt sidecar => nil, not an error.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta-bad" t)))
    (unwind-protect
        (progn
          (should-not (latex-to-svg-metadata "$never$"))
          (with-temp-file (latex-to-svg--meta-file (latex-to-svg--cache-key "$x$"))
            (insert "(:v 1 :nums (3 . "))    ; truncated, unreadable
          (should-not (latex-to-svg-metadata "$x$")))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-metadata-captured-from-real-compile ()
  ;; End to end (needs latex + dvisvgm): a `\typeout{L2S-AFTER=...}' injected
  ;; into the body is captured from the real compile log into `<key>.eld' and
  ;; read back — exercising actual TeX log formatting, not a synthetic log.
  (skip-unless (latex-to-svg-tools-available-p))
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta-e2e" t))
        (latex-to-svg-metadata-prefix "L2S"))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () t)))
          (let* ((doc (concat "\\setcounter{equation}{6}%\n"
                              "\\begin{equation}x=1\\end{equation}\n"
                              "\\typeout{L2S \\arabic{equation}}%\n"))
                 (done 'pending))
            ;; INITIAL = K+1 = 7 supplied in Elisp; FINAL = 7 from the compile.
            (latex-to-svg doc :callback (lambda () (setq done t)) :metadata 7)
            (dotimes (_ 100)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (equal (latex-to-svg-metadata doc)
                           '(:v 1 :nums (7 . 7))))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-invalidate-drops-metadata-sidecar ()
  ;; Invalidate removes the `.eld' alongside the `.svg' so they stay coupled.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-meta-inv" t)))
    (unwind-protect
        (let* ((key (latex-to-svg--cache-key "$x$"))
               (svg (latex-to-svg--svg-file key))
               (meta (latex-to-svg--meta-file key)))
          (with-temp-file svg (insert "<svg/>"))
          (with-temp-file meta (prin1 '(:v 1 :nums (1 . 1))
                                      (current-buffer)))
          (latex-to-svg-invalidate "$x$")
          (should-not (file-exists-p svg))
          (should-not (file-exists-p meta)))
      (delete-directory latex-to-svg-cache-directory t))))

;;;; Preamble precompilation (.fmt)

(ert-deftest latex-to-svg-format-key-folds-in-preamble ()
  ;; The format key names the `.fmt'; it must change when the preamble (base
  ;; or appended) or the LaTeX program changes, so a stale format is never
  ;; reused after a preamble edit.
  (let ((base (latex-to-svg--format-key)))
    (should (equal base (latex-to-svg--format-key)))
    (let ((latex-to-svg-appended-preamble "\\usepackage{physics}"))
      (should-not (equal base (latex-to-svg--format-key))))
    (let ((latex-to-svg-preamble "\\documentclass{minimal}"))
      (should-not (equal base (latex-to-svg--format-key))))
    (let ((latex-to-svg-latex-program "xelatex"))
      (should-not (equal base (latex-to-svg--format-key))))))

(ert-deftest latex-to-svg-preamble-appends ()
  ;; The combined preamble is the base alone when nothing is appended, else
  ;; base + newline + appended (the exact text dumped and embedded).
  (let ((latex-to-svg-preamble "BASE")
        (latex-to-svg-appended-preamble ""))
    (should (equal (latex-to-svg--preamble) "BASE")))
  (let ((latex-to-svg-preamble "BASE")
        (latex-to-svg-appended-preamble "EXTRA"))
    (should (equal (latex-to-svg--preamble) "BASE\nEXTRA"))))

(ert-deftest latex-to-svg-ensure-format-nil-when-disabled ()
  ;; With precompilation off, no format is produced or consulted (never even
  ;; probes for mylatexformat).
  (let ((latex-to-svg-precompile nil))
    (cl-letf (((symbol-function 'latex-to-svg--precompile-available-p)
               (lambda () (error "must not probe when disabled"))))
      (should-not (latex-to-svg--ensure-format)))))

(ert-deftest latex-to-svg-ensure-format-builds-once-and-reuses ()
  ;; First call builds the `.fmt' (stubbed); a fresh on-disk format newer than
  ;; the LaTeX binary is then reused with no rebuild.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-fmt" t))
        (latex-to-svg-precompile t)
        (latex-to-svg--format-checked (make-hash-table :test 'equal))
        (latex-to-svg--format-blocklist (make-hash-table :test 'equal))
        (builds 0))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg--latex-binary)
                   ;; A binary older than the about-to-be-built .fmt.
                   (lambda () (let ((f (make-temp-file "l2s-bin")))
                                (set-file-times f '(1 0)) f)))
                  ((symbol-function 'latex-to-svg--precompile-available-p)
                   (lambda () t))
                  ((symbol-function 'latex-to-svg--build-format)
                   (lambda (fkey)
                     (cl-incf builds)
                     (let ((f (latex-to-svg--format-file fkey)))
                       (with-temp-file f (insert "fmt")) f))))
          (let ((f1 (latex-to-svg--ensure-format)))
            (should f1)
            (should (file-exists-p f1))
            (should (= builds 1))
            ;; Second call: verified fresh, served from disk, no rebuild.
            (should (equal f1 (latex-to-svg--ensure-format)))
            (should (= builds 1))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-ensure-format-rebuilds-when-stale ()
  ;; A `.fmt' older than the LaTeX binary (e.g. after a toolchain upgrade) is
  ;; deleted and rebuilt rather than reused.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-fmt-stale" t))
        (latex-to-svg-precompile t)
        (latex-to-svg--format-checked (make-hash-table :test 'equal))
        (latex-to-svg--format-blocklist (make-hash-table :test 'equal))
        (builds 0))
    (unwind-protect
        (let* ((fkey (latex-to-svg--format-key))
               (fmt (latex-to-svg--format-file fkey))
               (newer-bin (make-temp-file "l2s-bin")))
          ;; Stale .fmt on disk (epoch), binary is current.
          (with-temp-file fmt (insert "old"))
          (set-file-times fmt '(1 0))
          (cl-letf (((symbol-function 'latex-to-svg--latex-binary)
                     (lambda () newer-bin))
                    ((symbol-function 'latex-to-svg--precompile-available-p)
                     (lambda () t))
                    ((symbol-function 'latex-to-svg--build-format)
                     (lambda (k)
                       (cl-incf builds)
                       (let ((f (latex-to-svg--format-file k)))
                         (with-temp-file f (insert "new")) f))))
            (should (latex-to-svg--ensure-format))
            (should (= builds 1))
            (should (equal (with-temp-buffer (insert-file-contents fmt)
                                             (buffer-string))
                           "new"))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-block-format-blocklists-and-deletes ()
  ;; Abandoning a format deletes the `.fmt', records its key, and makes
  ;; `--ensure-format' skip precompilation for that preamble thereafter.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-fmt-block" t))
        (latex-to-svg-precompile t)
        (latex-to-svg--format-checked (make-hash-table :test 'equal))
        (latex-to-svg--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (let* ((fkey (latex-to-svg--format-key))
               (fmt (latex-to-svg--format-file fkey)))
          (with-temp-file fmt (insert "fmt"))
          (cl-letf (((symbol-function 'display-warning) #'ignore))
            (latex-to-svg--block-format fmt))
          (should-not (file-exists-p fmt))
          (should (gethash fkey latex-to-svg--format-blocklist))
          ;; Blocklisted => ensure-format yields nil without rebuilding.
          (cl-letf (((symbol-function 'latex-to-svg--build-format)
                     (lambda (_k) (error "must not rebuild a blocklisted format"))))
            (should-not (latex-to-svg--ensure-format))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-flush-format-clears-everything ()
  ;; `latex-to-svg-flush-format' deletes every `.fmt' and resets session state.
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-fmt-flush" t))
        (latex-to-svg--format-checked (make-hash-table :test 'equal))
        (latex-to-svg--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((dir latex-to-svg-cache-directory))
          (with-temp-file (expand-file-name "aaa.fmt" dir) (insert "1"))
          (with-temp-file (expand-file-name "bbb.fmt" dir) (insert "2"))
          ;; A sibling SVG must survive the flush.
          (with-temp-file (expand-file-name "ccc.svg" dir) (insert "<svg/>"))
          (puthash "aaa" t latex-to-svg--format-checked)
          (puthash "bbb" t latex-to-svg--format-blocklist)
          (latex-to-svg-flush-format)
          (should-not (directory-files dir nil "\\.fmt\\'"))
          (should (file-exists-p (expand-file-name "ccc.svg" dir)))
          (should (= 0 (hash-table-count latex-to-svg--format-checked)))
          (should (= 0 (hash-table-count latex-to-svg--format-blocklist))))
      (delete-directory latex-to-svg-cache-directory t))))

(ert-deftest latex-to-svg-precompiled-compile-end-to-end ()
  ;; End to end (needs latex + dvisvgm + mylatexformat): a real compile through
  ;; the precompiled preamble produces the SVG, and the `.fmt' is left cached.
  (skip-unless (and (latex-to-svg-tools-available-p)
                    (let ((latex-to-svg-precompile t))
                      (latex-to-svg--precompile-available-p))))
  (let ((latex-to-svg-cache-directory (make-temp-file "l2s-fmt-e2e" t))
        (latex-to-svg-precompile t)
        (latex-to-svg--format-checked (make-hash-table :test 'equal))
        (latex-to-svg--format-blocklist (make-hash-table :test 'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'latex-to-svg-available-p) (lambda () t)))
          (let ((done 'pending)
                (doc "\\begin{equation}\ne^{i\\pi}+1=0\n\\end{equation}"))
            (latex-to-svg doc :callback (lambda () (setq done t)))
            (dotimes (_ 200)
              (when (eq done 'pending) (accept-process-output nil 0.1)))
            (should (eq done t))
            (should (file-exists-p
                     (latex-to-svg--svg-file (latex-to-svg--cache-key doc))))
            ;; The format file was built and cached alongside the SVG.
            (should (file-exists-p
                     (latex-to-svg--format-file (latex-to-svg--format-key))))))
      (delete-directory latex-to-svg-cache-directory t))))

(provide 'latex-to-svg-tests)

;;; latex-to-svg-tests.el ends here
