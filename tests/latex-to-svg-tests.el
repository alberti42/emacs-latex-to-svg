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

(ert-deftest latex-to-svg-cache-key-distinguishes-inline ()
  ;; Inline and display renders of the same source must not collide: the
  ;; inline flag changes the key, while the default (display) key is
  ;; unchanged from the no-flag form.
  (should (equal (latex-to-svg--cache-key "x")
                 (latex-to-svg--cache-key "x" nil)))
  (should-not (equal (latex-to-svg--cache-key "x")
                     (latex-to-svg--cache-key "x" t))))

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

(ert-deftest latex-to-svg-display-scale-is-1-when-non-graphical ()
  ;; Off a graphical frame (batch, the daemon-prerender path) the font
  ;; height is unknown, so the image is left at natural size.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    (should (equal (latex-to-svg-display-scale) 1.0))))

(ert-deftest latex-to-svg-svg-px-per-pt-falls-back-uncached ()
  ;; Without a graphical frame the calibration returns the 96/72 fallback
  ;; and must NOT cache it, so a later graphical frame can still measure.
  (let ((latex-to-svg--svg-px-per-pt nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should (equal (latex-to-svg--svg-px-per-pt) (/ 96.0 72.0)))
      (should-not latex-to-svg--svg-px-per-pt))))

(ert-deftest latex-to-svg-display-scale-matches-font ()
  ;; The display scale maps the LaTeX 10pt body font onto the buffer font
  ;; height: scale = target * font-scale / (10 * px-per-pt).
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28))
            ((symbol-function 'latex-to-svg--svg-px-per-pt)
             (lambda () 2.0)))
    (let ((latex-to-svg-font-scale 1.0))
      (should (equal (latex-to-svg-display-scale)
                     (/ 28.0 (* 10.0 2.0)))))
    ;; Doubling font-scale doubles the displayed size.
    (let* ((latex-to-svg-font-scale 1.0)
           (base (latex-to-svg-display-scale))
           (latex-to-svg-font-scale 2.0))
      (should (equal (latex-to-svg-display-scale) (* 2 base))))))

(ert-deftest latex-to-svg-flush-metrics-resets-calibration ()
  ;; `latex-to-svg-flush-metrics' drops the cached pixels-per-point so a
  ;; later call re-measures.
  (let ((latex-to-svg--svg-px-per-pt 3.0))
    (latex-to-svg-flush-metrics)
    (should-not latex-to-svg--svg-px-per-pt)))

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
                         (lambda () 0.8)))
                (setq img1 (latex-to-svg--cached-image "K")))
              (cl-letf (((symbol-function 'latex-to-svg-display-scale)
                         (lambda () 1.5)))
                (setq img2 (latex-to-svg--cached-image "K")))
              (should img1)
              (should img2)
              ;; Two coexisting entries, one per scale.
              (should (= 2 (hash-table-count latex-to-svg--image-cache)))
              ;; The first is still served from cache (warm, not evicted).
              (cl-letf (((symbol-function 'latex-to-svg-display-scale)
                         (lambda () 0.8)))
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
              ((symbol-function 'latex-to-svg--cached-image) (lambda (_key) nil))
              ((symbol-function 'latex-to-svg--compile)
               (lambda (&rest _) (cl-incf compiles))))
      (should-not (latex-to-svg "E=mc^2" :callback #'ignore))
      (should-not (latex-to-svg "E=mc^2" :callback #'ignore))
      ;; Two requests for the same equation => a single in-flight compile.
      (should (= compiles 1))
      (should (= 2 (length (gethash (latex-to-svg--cache-key "E=mc^2")
                                    latex-to-svg--pending)))))))

(provide 'latex-to-svg-tests)

;;; latex-to-svg-tests.el ends here
