;;; latex-to-svg.el --- Content-addressed LaTeX-to-SVG image rendering -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; URL: https://github.com/alberti42/emacs-latex-to-svg
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, math, images

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A small, buffer-agnostic engine that turns a LaTeX math string into an
;; SVG image suitable for overlaying in an Emacs buffer.  It is the
;; rendering core extracted from `agent-shell-math-renderer'; front-ends
;; (agent-shell's markdown renderer, an Org preview mode, ...) do their own
;; equation detection and image *placement* and delegate the actual
;; typesetting here.
;;
;; Design (why it is cheap to recolor and rescale):
;;
;;   * Equations are compiled with `latex' + `dvisvgm' to a standalone SVG,
;;     content-addressed on disk (SHA-1 of LaTeX + preamble + style).  Each
;;     unique equation therefore compiles at most once, ever, and the cache
;;     is shared across every front-end.
;;
;;   * The on-disk SVG is COLOR-INDEPENDENT: dvisvgm `--currentcolor' emits
;;     the default ink as the literal token `currentColor', which is
;;     substituted with the buffer foreground at display time.  A theme
;;     switch therefore re-tints from cache with no recompile.  The image
;;     background is transparent, so it always matches the buffer.
;;
;;   * The on-disk SVG is SIZE-INDEPENDENT: it is compiled at dvisvgm
;;     `--scale=1' (natural point dimensions, glyphs as outline paths) and
;;     scaled at display time via `create-image' :scale, computed from the
;;     buffer font height so equations track the font — again no recompile.
;;
;; Public entry point:
;;
;;   (latex-to-svg LATEX &key callback)
;;
;; LATEX is placed *verbatim* in the document body, so the caller passes
;; valid body LaTeX and decides inline vs display by the delimiters it uses
;; (`$x$', `\(x\)', `\[x\]', `\begin{equation}...\end{equation}', ...).
;; The engine is deliberately unaware of that distinction.
;;
;; Returns an image now when one can be produced synchronously (cache /
;; on-disk SVG / placeholder), else nil after scheduling an asynchronous
;; compile; CALLBACK (a zero-argument function) is invoked once the SVG is
;; ready, so the caller can re-query and place the image.  Concurrent
;; requests for the same equation are coalesced onto a single compile.
;;
;; Helpers a front-end typically needs for its refresh policy:
;; `latex-to-svg-available-p', `latex-to-svg-appearance',
;; `latex-to-svg-display-scale', `latex-to-svg-foreground-color', and
;; `latex-to-svg-flush-metrics'.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'color)
(require 'seq)
(require 'svg)

(defgroup latex-to-svg nil
  "Render LaTeX math to SVG images with `latex' + `dvisvgm'.
Equations are compiled to a color- and size-independent SVG, cached
on disk by content, then tinted to the buffer foreground and scaled
to the buffer font at display time."
  :group 'tex
  :prefix "latex-to-svg-")

;;;; Customization

(defcustom latex-to-svg-latex-program "latex"
  "Program that compiles a LaTeX document to DVI."
  :type 'string
  :group 'latex-to-svg)

(defcustom latex-to-svg-dvisvgm-program "dvisvgm"
  "Program that converts DVI to SVG."
  :type 'string
  :group 'latex-to-svg)

(defcustom latex-to-svg-preamble
  "\\documentclass[varwidth,border=2pt]{standalone}
\\usepackage{amsmath}
\\usepackage{amssymb}
\\usepackage{xcolor}"
  "LaTeX preamble (everything before `\\begin{document}') for equations.
The `standalone' class crops the page tightly to the equation, so
no `preview' package is required.  The `varwidth' option is what lets
the verbatim body use *display* math — `\\[...\\]' and display
environments like `equation'/`align' — not just inline `$...$'
\(plain `standalone' typesets its body as a single horizontal box and
errors with \"Missing $ inserted\" on display math).  dvisvgm's
`--exact-bbox' then crops to the actual ink.

See also `latex-to-svg-appended-preamble' for adding extra packages
without replacing this base."
  :type 'string
  :group 'latex-to-svg)

(defcustom latex-to-svg-appended-preamble ""
  "Extra LaTeX code appended after `latex-to-svg-preamble'.
Use this to load additional packages (e.g. `\\usepackage{braket}',
`\\usepackage{physics}') without replacing the base preamble.  The
value is folded into the cache key, so changing it automatically
invalidates cached SVGs."
  :type 'string
  :group 'latex-to-svg)

(defcustom latex-to-svg-cache-directory nil
  "Directory for cached equation SVGs and scratch compiles.
When nil, `$XDG_CACHE_HOME/latex-to-svg/' (or `~/.cache/latex-to-svg/')
is used, so equation SVGs persist across sessions and each unique
equation compiles at most once ever.  Because the cache is
content-addressed and color/size-independent, it is safe to share
across every front-end and buffer."
  :type '(choice (const :tag "Default XDG cache" nil) directory)
  :group 'latex-to-svg)

(defcustom latex-to-svg-metadata-prefix nil
  "Line prefix marking compile metadata to capture, or nil to disable.
When a string, after each successful compile the first integer on a LaTeX
log line beginning with it (the FINAL value) is paired with the caller's
`:metadata' value (the INITIAL value) and stored as the cons
`(:v 1 :nums (INITIAL . FINAL))' in the equation's `.eld' sidecar next to
its SVG, exposed by `latex-to-svg-metadata' (on cache hit or miss).

So the caller supplies INITIAL directly (a value it already knows, in
Elisp), and only FINAL — the thing the compile computes — travels through
LaTeX, emitted with `\\typeout{PREFIX \\arabic{COUNTER}}'.  Keep that line
short: TeX wraps log lines near column 80."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'latex-to-svg)

(defcustom latex-to-svg-font-scale 1.0
  "Size of rendered equations relative to the buffer font.

Equation images are scaled so LaTeX's 10pt body font maps onto the
buffer's font height; this multiplier rides on top of that match.
1.0 makes equation text the same size as the surrounding text;
greater than 1 enlarges, less than 1 shrinks.  Because the match is
recomputed from the current font on each render, equations track the
buffer font across themes, faces, and text scale."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg)

(defcustom latex-to-svg-use-placeholder nil
  "When non-nil, draw the placeholder panel instead of typesetting LaTeX.
Also used as the automatic fallback when the toolchain
\(`latex-to-svg-latex-program' / `latex-to-svg-dvisvgm-program') is
unavailable."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg)

(defcustom latex-to-svg-render-on-non-graphic nil
  "When non-nil, render equation images even on a non-graphical frame.

By default equations are only compiled when the selected frame is
graphical (`display-graphic-p').  In an Emacs daemon a buffer may
be rendered while a TTY frame is selected, yet later viewed in a
graphical frame; without this the equation would never have been
produced and stays raw text in the GUI too.

Set non-nil (typically in a daemon setup) to always compile the
SVG when the build supports it: it is ignored on a TTY frame (the
raw LaTeX shows) but appears as soon as a graphical frame views
the buffer.  The trade-off is that a purely terminal session then
spawns LaTeX compiles whose images it never displays."
  :type 'boolean
  :safe #'booleanp
  :group 'latex-to-svg)

(defcustom latex-to-svg-svg-dpi 96.0
  "Dots-per-inch Emacs's SVG renderer uses to convert points to pixels.

Used to size equation previews to the buffer font: an SVG `pt' is
rendered as `latex-to-svg-svg-dpi' / 72 pixels.  librsvg (Emacs's SVG
backend) converts SVG length units at 96 DPI, so the default suits
almost all systems; override only if previews come out uniformly too
big or too small.  HiDPI is handled separately by `image-scaling-factor'
\(it scales the reference and the equation alike, so it cancels) and
does not belong here.

This replaced a per-frame `image-size' measurement that proved
unreliable on some ports (returning wildly different pixel sizes for
the same undisplayed SVG), which made preview sizing non-deterministic."
  :type 'number
  :safe #'numberp
  :group 'latex-to-svg)

;;;; State

;; image-cache key = content key (sha1 of latex + preamble + style) plus the
;; display scale and tint color, via `latex-to-svg--image-cache-key'.  Folding
;; scale and color in lets images at different font sizes / themes coexist, so
;; a font or theme change just adds an entry (no cache clear) and sibling
;; buffers' warm images survive.  The underlying SVG is still compiled at most
;; once per content key (the disk cache is font- AND color-independent); only
;; the cheap `create-image' is per scale/color.
(defvar latex-to-svg--image-cache (make-hash-table :test 'equal)
  "In-memory map of image-cache key to rendered equation image.")

;; key -> list of zero-argument callbacks awaiting one in-flight compile.
;; Dedupes concurrent compiles of the same equation and records every
;; consumer to notify once the SVG is ready.
(defvar latex-to-svg--pending (make-hash-table :test 'equal)
  "In-memory map of cache key to callbacks awaiting an in-flight compile.")

;;;; Colors and appearance

(defun latex-to-svg--svg-color (face attribute fallback)
  "Return FACE's ATTRIBUTE color as a `#rrggbb' string, or FALLBACK.

ATTRIBUTE is `:foreground' or `:background'.  FALLBACK is returned
when the attribute is unspecified or can't be resolved to RGB
\(e.g. on a terminal that reports symbolic colors)."
  (let ((color (face-attribute face attribute nil 'default)))
    ;; `color-name-to-rgb' both returns nil for unknown names and
    ;; signals (e.g. on the "unspecified-fg" sentinel, or off a window
    ;; system) — guard both so we always fall back cleanly.
    (if-let* (((stringp color))
              (rgb (ignore-errors (color-name-to-rgb color))))
        (apply #'color-rgb-to-hex (append rgb '(2)))
      fallback)))

(defun latex-to-svg-foreground-color ()
  "Return the `#rrggbb' foreground equations should be tinted with now.
Resolved from the `default' face of the selected frame."
  (latex-to-svg--svg-color 'default :foreground "#000000"))

(defun latex-to-svg--current-colors ()
  "Return the (FOREGROUND . BACKGROUND) equations should render for now.
Both are `#rrggbb' strings resolved from the `default' face."
  (cons (latex-to-svg-foreground-color)
        (latex-to-svg--svg-color 'default :background "#ffffff")))

(defun latex-to-svg-appearance ()
  "Return the appearance signature equations should render for now.
A list (FOREGROUND BACKGROUND FONT-HEIGHT): the colors equations
are tinted with (see `latex-to-svg--current-colors') and the buffer
font pixel height they are sized to (nil off a graphical frame).
Front-ends compare this against the value stored at their last
render to detect a color *or* font-size change and refresh."
  (let ((colors (latex-to-svg--current-colors)))
    (list (car colors) (cdr colors)
          (and (display-graphic-p) (ignore-errors (default-font-height))))))

;;;; Capability

(defun latex-to-svg-available-p ()
  "Return non-nil when equation images should be produced.

Requires SVG image support in this Emacs build, plus either a
graphical selected frame or `latex-to-svg-render-on-non-graphic'
\(the daemon / mixed TTY+GUI case — the image is ignored on a TTY
frame but shows once a graphical frame views the buffer)."
  (and (image-type-available-p 'svg)
       (or (display-graphic-p)
           latex-to-svg-render-on-non-graphic)))

(defun latex-to-svg-tools-available-p ()
  "Return non-nil when the LaTeX-to-SVG toolchain is on the variable `exec-path'."
  (and (executable-find latex-to-svg-latex-program)
       (executable-find latex-to-svg-dvisvgm-program)))

;;;; Cache addressing

(defun latex-to-svg--cache-dir ()
  "Return the equation cache directory, creating it if needed.
Honours `latex-to-svg-cache-directory', else `$XDG_CACHE_HOME'
\(or `~/.cache') under `latex-to-svg/'."
  (let ((dir (or latex-to-svg-cache-directory
                 (expand-file-name
                  "latex-to-svg/"
                  (or (getenv "XDG_CACHE_HOME")
                      (expand-file-name "~/.cache"))))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun latex-to-svg--cache-key (latex)
  "Return a stable content cache key for LATEX.
The preamble is folded in so changing it invalidates the cache.
LATEX is the verbatim document body, so any change to it — including
inline vs display delimiters or an injected `\setcounter' for
equation numbering — changes the key on its own.  The key names the
on-disk SVG, which is both font- AND color-independent (equations
are compiled with dvisvgm `--currentcolor', then sized and tinted at
display time), so neither size nor color is part of this key."
  (secure-hash 'sha1 (format "%s\0%s%s"
                             latex
                             latex-to-svg-preamble
                             latex-to-svg-appended-preamble)))

(defun latex-to-svg--svg-file (key)
  "Return the cache SVG path for KEY."
  (expand-file-name (concat key ".svg")
                    (latex-to-svg--cache-dir)))

(defun latex-to-svg--meta-file (key)
  "Return the compile-metadata sidecar path for KEY (a `.eld' next to the SVG)."
  (expand-file-name (concat key ".eld")
                    (latex-to-svg--cache-dir)))

;;;; Scale

(defun latex-to-svg--graphic-frame ()
  "Return a graphical frame to measure font metrics against, or nil.
Prefer the selected frame when it is graphical; otherwise any graphical
frame (so a render triggered while a TTY/daemon frame is selected — e.g.
an async compile callback — still sizes against the GUI rather than
collapsing to the fallback scale)."
  (if (display-graphic-p)
      (selected-frame)
    (seq-find #'display-graphic-p (frame-list))))

(defun latex-to-svg--svg-px-per-pt ()
  "Return how many pixels Emacs renders one SVG point as.
A constant derived from `latex-to-svg-svg-dpi' (SVG `pt' = dpi/72 px).
Not measured — see `latex-to-svg-svg-dpi' for why."
  (/ latex-to-svg-svg-dpi 72.0))

(defun latex-to-svg-display-scale ()
  "Return the `create-image' :scale that sizes equations to the buffer font.

Maps the LaTeX document's 10pt body font (the `standalone' default,
compiled at dvisvgm scale 1, so 10pt of LaTeX = 10 SVG points) onto
the buffer's font pixel height, times `latex-to-svg-font-scale'.  An
equation's displayed font height is (10 * px-per-pt * scale) px, so
scale = target * font-scale / (10 * px-per-pt), where px-per-pt is the
deterministic `latex-to-svg-svg-dpi' / 72.

The font height is read against a graphical frame (see
`latex-to-svg--graphic-frame') with the current buffer kept current, so
it honours a buffer-local text scale and does not collapse to 1.0 when
an async render fires while a TTY frame is selected.  Returns 1.0 only
when no graphical frame exists (truly headless), leaving the image at
its natural size."
  (let* ((buf (current-buffer))
         (frame (latex-to-svg--graphic-frame))
         (target (and frame
                      (ignore-errors
                        (with-selected-frame frame
                          (with-current-buffer buf
                            (default-font-height)))))))
    (if target
        (/ (* target latex-to-svg-font-scale)
           (* 10.0 (latex-to-svg--svg-px-per-pt)))
      1.0)))

(defun latex-to-svg-flush-metrics ()
  "Deprecated no-op, kept for API compatibility.
Preview sizing is now derived deterministically from the buffer font
and `latex-to-svg-svg-dpi', so there is no measured calibration to
flush.  (Previously this reset a cached, and unreliable, `image-size'
measurement.)"
  nil)

;;;; Image build

(defun latex-to-svg--load-svg-image (file &optional scale color)
  "Return an SVG image from FILE, tinted COLOR and sized to the buffer font.
The on-disk SVG emits its default ink as the literal token
`currentColor' (dvisvgm `--currentcolor'); when COLOR (a `#rrggbb'
string) is given it is substituted in, so the equation matches the
buffer foreground without recompiling.  Scaled by SCALE (default
`latex-to-svg-display-scale') so the body font matches the
surrounding text, and centred vertically for inline display."
  (let ((data (with-temp-buffer
                (insert-file-contents file)
                (buffer-string))))
    (when color
      (setq data (replace-regexp-in-string "currentColor" color data t t)))
    (create-image data 'svg t
                  :scale (or scale (latex-to-svg-display-scale))
                  :ascent 'center)))

(defun latex-to-svg--image-cache-key (key scale color)
  "Return the in-memory image-cache key for content KEY at SCALE and COLOR.
KEY names the font- and color-independent on-disk SVG; the cached
image object bakes in a display `:scale' and a tint COLOR, so the
in-memory key adds both.  Images at different font sizes or colors
coexist, so a font or theme change just creates a new entry — no
cache clearing, and a sibling buffer's warm images survive."
  (format "%s@%s@%s" key scale color))

(defun latex-to-svg--cached-image (key)
  "Return the rendered image for content KEY at the current font and color.
Checks the in-memory cache (keyed by KEY, the display scale, and the
buffer foreground via `latex-to-svg--image-cache-key', so each size /
color has its own image), else loads KEY's on-disk SVG and caches a
freshly scaled, tinted image.  Returns nil when the SVG isn't on disk
yet (its compile hasn't finished).  Reads the scale and color from
the current buffer / frame, so call it within the target buffer to
honour a buffer-local text scale."
  (let* ((scale (latex-to-svg-display-scale))
         (color (car (latex-to-svg--current-colors)))
         (image-key (latex-to-svg--image-cache-key key scale color)))
    (or (gethash image-key latex-to-svg--image-cache)
        (let ((file (latex-to-svg--svg-file key)))
          (when (file-exists-p file)
            (puthash image-key
                     (latex-to-svg--load-svg-image file scale color)
                     latex-to-svg--image-cache))))))

;;;; Placeholder

(defun latex-to-svg--placeholder (latex)
  "Return a placeholder SVG image boxing the raw LATEX, or nil.

This does NOT typeset LATEX — it draws the source inside a bordered
panel.  Used when `latex-to-svg-use-placeholder' is set or the
toolchain is unavailable, so math still has a visible (if un-typeset)
rendering.  Returns nil when equations aren't renderable (see
`latex-to-svg-available-p'), so callers fall back to the raw text.

LATEX is the equation source with the surrounding delimiters
already stripped, e.g. \"E=mc^2\"."
  (when (latex-to-svg-available-p)
    (let* ((lines (split-string latex "\n"))
           ;; `frame-char-width' / `-height' give per-char pixel
           ;; dimensions on a graphical frame and stay robust off it
           ;; (unlike `default-font-width', which calls `font-info' and
           ;; errors with no live font).  Good enough for placeholder
           ;; sizing; real typesetting will set its own dimensions.
           (char-w (frame-char-width))
           (char-h (frame-char-height))
           (pad char-h)
           (badge-h char-h)
           (text-w (* char-w (apply #'max 1 (mapcar #'length lines))))
           (width (+ text-w (* 2 pad)))
           (height (+ badge-h (* char-h (length lines)) (* 2 pad)))
           (fg (latex-to-svg--svg-color 'default :foreground "#000000"))
           (border (latex-to-svg--svg-color 'shadow :foreground "#888888"))
           (panel (latex-to-svg--svg-color 'default :background "#f4f4f4"))
           (svg (svg-create width height)))
      (svg-rectangle svg 0 0 width height
                     :rx (/ char-h 2)
                     :fill panel
                     :stroke border
                     :stroke-width 1)
      (svg-text svg "tex"
                :x pad
                :y (* badge-h 0.85)
                :font-size (* badge-h 0.7)
                :font-style "italic"
                :fill border)
      (seq-do-indexed
       (lambda (line i)
         (svg-text svg (if (string-empty-p line) " " line)
                   :x pad
                   :y (+ badge-h pad (* char-h (1+ i)) (- (/ char-h 4)))
                   :font-family "monospace"
                   :font-size char-h
                   :fill fg))
       lines)
      (svg-image svg :scale 1.0 :ascent 'center))))

;;;; Async compile

(defun latex-to-svg--compile-failed (key latex dir)
  "Handle a failed LaTeX compile for KEY with source LATEX.
DIR is the scratch directory containing the build log.  The log is
copied to a persistent file in the cache directory, and a warning is
emitted with a clickable link to it."
  (let* ((log-src (expand-file-name "equation.log" dir))
         (log-dst (expand-file-name (concat key ".log")
                                    (latex-to-svg--cache-dir)))
         (snippet (truncate-string-to-width latex 60 nil nil t)))
    (when (file-exists-p log-src)
      (copy-file log-src log-dst t))
    (display-warning
     'latex-to-svg
     (format "LaTeX compile failed for: %s\nSee log: %s"
             snippet
             (if (file-exists-p log-dst) log-dst "(no log available)"))
     :warning)
    (when (file-exists-p log-dst)
      (with-current-buffer "*Warnings*"
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (save-excursion
            (when (search-backward log-dst nil t)
              (make-text-button (point) (+ (point) (length log-dst))
                                'action (lambda (_) (find-file log-dst))
                                'help-echo "Open LaTeX log"))))))))

(defun latex-to-svg--write-metadata (key dir initial)
  "Write KEY's `.eld' sidecar pairing INITIAL with the compile's FINAL.
Scans the just-finished compile's `equation.log' in scratch DIR for the
first integer on a line beginning with `latex-to-svg-metadata-prefix'
\(FINAL), and writes `(:v 1 :nums (INITIAL . FINAL))' to `<KEY>.eld'.
INITIAL is the caller's value (from `latex-to-svg's `:metadata'), stored
verbatim.  Writes nothing when the prefix is nil or no FINAL was found.
Called on a successful compile, before DIR is cleaned up."
  (when latex-to-svg-metadata-prefix
    (let ((log (expand-file-name "equation.log" dir))
          (final nil))
      (when (file-readable-p log)
        (with-temp-buffer
          (insert-file-contents log)
          (goto-char (point-min))
          (while (and (not final) (not (eobp)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              (when (string-prefix-p latex-to-svg-metadata-prefix line)
                (let ((rest (substring line (length latex-to-svg-metadata-prefix))))
                  (when (string-match "-?[0-9]+" rest)
                    (setq final (string-to-number (match-string 0 rest)))))))
            (forward-line 1))))
      (when final
        (ignore-errors
          (with-temp-file (latex-to-svg--meta-file key)
            (prin1 (list :v 1 :nums (cons initial final)) (current-buffer))))))))

(defun latex-to-svg--compile (key latex &optional metadata)
  "Asynchronously compile LATEX to the color-independent cache SVG for KEY.
METADATA, when non-nil, is stored as the INITIAL value in KEY's `.eld'
sidecar alongside the FINAL captured from the log (see
`latex-to-svg--write-metadata').

LATEX is placed verbatim in the document body (the caller supplies
valid body LaTeX and chooses inline vs display via delimiters).
Writes a standalone LaTeX document, runs `latex-to-svg-latex-program'
then `latex-to-svg-dvisvgm-program' in a scratch directory, and on
success caches the SVG and notifies every callback queued for KEY
\(see `latex-to-svg--enqueue').  On failure the log is saved and a
warning emitted (see `latex-to-svg--compile-failed'); queued
callbacks are not run.  The scratch directory is removed when the
process exits.

No color is baked in: the equation's default ink is emitted as the
literal `currentColor' (dvisvgm `--currentcolor'), so the SVG is
color-independent and is tinted to the buffer foreground at display
time (`latex-to-svg--load-svg-image').  A theme change therefore
re-tints from cache without recompiling."
  (let* ((dir (make-temp-file "latex-to-svg" t))
         (tex (expand-file-name "equation.tex" dir))
         (dvi (expand-file-name "equation.dvi" dir))
         (svg (latex-to-svg--svg-file key))
         (cleanup (lambda () (ignore-errors (delete-directory dir t)))))
    (with-temp-file tex
      (insert latex-to-svg-preamble "\n"
              (if (string-empty-p latex-to-svg-appended-preamble)
                  ""
                (concat latex-to-svg-appended-preamble "\n"))
              "\\begin{document}\n"
              ;; LATEX is inserted verbatim: it already carries its own math
              ;; delimiters / environment (chosen by the front-end), which
              ;; also decide inline vs display sizing.  No `\color' —
              ;; `--currentcolor' below turns the default (black) ink into
              ;; the `currentColor' token, tinted at display.
              latex "\n"
              "\\end{document}\n"))
    ;; Compile at dvisvgm scale 1: the SVG is vector (glyphs are outline
    ;; paths via --no-fonts), so the scale doesn't affect quality, and the
    ;; displayed size is set later by `latex-to-svg-display-scale'.  Fixing
    ;; it at 1 means the SVG carries the equation's natural point dimensions.
    ;; `--currentcolor' rewrites the default ink to the `currentColor' token
    ;; so the file is color-independent (tinted at display time).
    (let ((command
           (format "cd %s && %s -interaction=nonstopmode -halt-on-error %s && %s --no-fonts --exact-bbox --currentcolor --scale=1 -o %s %s"
                   (shell-quote-argument dir)
                   (shell-quote-argument latex-to-svg-latex-program)
                   (shell-quote-argument tex)
                   (shell-quote-argument latex-to-svg-dvisvgm-program)
                   (shell-quote-argument svg)
                   (shell-quote-argument dvi))))
      (condition-case err
          (set-process-sentinel
           (start-process-shell-command "latex-to-svg" nil command)
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (if (and (eq (process-status process) 'exit)
                        (zerop (process-exit-status process))
                        (file-exists-p svg))
                   (progn
                     ;; Capture compile metadata before DIR is cleaned up.
                     (latex-to-svg--write-metadata key dir metadata)
                     (dolist (cb (gethash key latex-to-svg--pending))
                       (condition-case cb-err
                           (funcall cb)
                         (error
                          (message "latex-to-svg: callback error: %S" cb-err)))))
                 (latex-to-svg--compile-failed key latex dir))
               (remhash key latex-to-svg--pending)
               (funcall cleanup))))
        (error
         ;; Couldn't even spawn the process — drop the queue and clean up.
         (remhash key latex-to-svg--pending)
         (funcall cleanup)
         (signal (car err) (cdr err)))))))

(defun latex-to-svg--enqueue (key latex callback &optional metadata)
  "Queue CALLBACK for KEY and start a compile if none is running.

KEY identifies the equation; LATEX is forwarded to
`latex-to-svg--compile' for the render, along with METADATA (the INITIAL
value for the `.eld' sidecar).  Multiple callbacks sharing KEY (the same
equation requested more than once) are coalesced onto a single in-flight
compile; all are notified when it finishes."
  (let ((pending (gethash key latex-to-svg--pending)))
    (puthash key (cons callback pending) latex-to-svg--pending)
    (unless pending
      (latex-to-svg--compile key latex metadata))))

;;;; Public entry point

(cl-defun latex-to-svg (latex &key callback metadata)
  "Return an SVG image for LATEX, or nil while it compiles.

METADATA, when non-nil and `latex-to-svg-metadata-prefix' is set, is the
INITIAL value stored in this equation's `.eld' sidecar (see
`latex-to-svg-metadata'); the FINAL value is captured from the compile
log.  It is only recorded when a compile actually runs (a miss).

LATEX is placed *verbatim* in the LaTeX document body, so it must be
valid there: pass math with its delimiters (`$x$', `\\(x\\)', `\\[x\\]')
or a full environment (`\\begin{equation}...\\end{equation}').  The
delimiters also choose inline vs display sizing — the engine does not.

Returns immediately with:

  * the placeholder panel image, when `latex-to-svg-use-placeholder'
    is set or the toolchain is unavailable (see
    `latex-to-svg--placeholder');
  * the cached / on-disk equation image when it is ready;
  * nil when equations aren't renderable (see
    `latex-to-svg-available-p') — the caller keeps the raw text.

When the equation is renderable but not yet compiled, returns nil and
schedules an asynchronous compile; CALLBACK (a zero-argument function)
is invoked once, when the SVG is ready, so the caller can re-query
\(call `latex-to-svg' again, which now returns the image) and place
it.  Concurrent requests for the same equation share one compile.

The image is tinted to the current buffer foreground and scaled to
the buffer font at build time, so call within the target buffer."
  (when (latex-to-svg-available-p)
    (cond
     ((or latex-to-svg-use-placeholder
          (not (latex-to-svg-tools-available-p)))
      (latex-to-svg--placeholder latex))
     (t
      (let* ((key (latex-to-svg--cache-key latex))
             (image (latex-to-svg--cached-image key)))
        (or image
            (progn
              (when callback
                (latex-to-svg--enqueue key latex callback metadata))
              nil)))))))

;;;###autoload
(defun latex-to-svg-invalidate (latex)
  "Forget any cached render of LATEX and force a recompile next time.

Deletes LATEX's on-disk SVG (content-addressed) and drops every
in-memory image built from it (all sizes / colors), so a subsequent
`latex-to-svg' for LATEX recompiles from scratch.  Use this to recover
from a stale or corrupt cached SVG — ordinarily the content hash makes
that impossible, so this is an escape hatch, not part of the normal
flow."
  (let* ((key (latex-to-svg--cache-key latex))
         (file (latex-to-svg--svg-file key))
         (meta (latex-to-svg--meta-file key))
         (prefix (concat key "@"))
         (stale nil))
    (when (file-exists-p file)
      (delete-file file))
    ;; Keep the metadata sidecar coupled to its SVG.
    (when (file-exists-p meta)
      (delete-file meta))
    (maphash (lambda (k _v)
               (when (string-prefix-p prefix k)
                 (push k stale)))
             latex-to-svg--image-cache)
    (dolist (k stale)
      (remhash k latex-to-svg--image-cache))))

;;;###autoload
(defun latex-to-svg-metadata (latex)
  "Return cached compile metadata for LATEX, or nil.

Returns the plist `(:v 1 :nums (INITIAL . FINAL))' read from LATEX's
`.eld' sidecar: INITIAL is the caller's `:metadata' at render time and
FINAL is the first integer the compile emitted on a
`latex-to-svg-metadata-prefix' line.  Available on cache hit or miss once
LATEX has compiled at least once with the prefix set; nil otherwise (a
corrupt or half-written sidecar also yields nil)."
  (let ((file (latex-to-svg--meta-file (latex-to-svg--cache-key latex))))
    (when (file-readable-p file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))))))

(provide 'latex-to-svg)

;;; latex-to-svg.el ends here
