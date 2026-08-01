# latex-to-svg

A small, **buffer-agnostic** Emacs library that turns a LaTeX math string
into an SVG image suitable for overlaying in a buffer. It is the rendering
core extracted from
[`agent-shell-math-renderer`](https://github.com/alberti42/agent-shell-math-renderer);
front-ends do their own equation *detection* and image *placement* and
delegate the typesetting here.

## Why

Equations are compiled once and then recolored and rescaled **without
recompiling** — the two things that are expensive if you bake color/size into
the render:

- **Content-addressed on disk.** Each unique equation (SHA-1 of LaTeX +
  preamble + style) compiles at most once, ever; the cache is shared across
  every front-end and buffer.
- **Color-independent SVG.** `dvisvgm --currentcolor` emits the default ink as
  the literal token `currentColor`, substituted with the buffer foreground at
  display time. A theme switch re-tints from cache — no recompile. The image
  background is transparent, so it always matches the buffer.
- **Size-independent SVG.** Compiled at `dvisvgm --scale=1` (natural point
  dimensions, glyphs as outline paths) and scaled at display time via
  `create-image`'s `:scale`, computed from the buffer font height so equations
  track the font — again no recompile.

## Requirements

- Emacs 29.1+ with SVG image support.
- `latex` and `dvisvgm` on `exec-path` (from any TeX distribution). Without
  them, a placeholder panel boxing the raw LaTeX is shown instead (or set
  `latex-to-svg-use-placeholder`).

## Installation

The package (feature) is `latex-to-svg`; the repository is
**`alberti42/emacs-latex-to-svg`** (the `emacs-` prefix disambiguates the repo
name). It is not on MELPA yet, so install straight from the repository. This is
a *library* — you normally install it as a dependency of a front-end (e.g.
[`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) or
`agent-shell-math-renderer`), declaring it *before* the front-end.

```elisp
;; use-package + :vc (Emacs 30+)
(use-package latex-to-svg
  :vc (:url "https://github.com/alberti42/emacs-latex-to-svg" :rev :newest))

;; use-package + straight
(use-package latex-to-svg
  :straight (latex-to-svg :type git :host github
                          :repo "alberti42/emacs-latex-to-svg"))

;; elpaca
(elpaca (latex-to-svg :host github :repo "alberti42/emacs-latex-to-svg"))

;; Emacs 29+ builtin, no package manager
(package-vc-install "https://github.com/alberti42/emacs-latex-to-svg")
```

Note the recipe *name* stays `latex-to-svg` (the feature you `require`), while
`:repo` is `alberti42/emacs-latex-to-svg`.

## API

```elisp
(latex-to-svg LATEX &key callback)
```

`LATEX` is placed **verbatim** in the LaTeX document body, so pass valid body
LaTeX — math with its delimiters (`$x$`, `\(x\)`, `\[x\]`) or a full
environment (`\begin{equation}…\end{equation}`). The delimiters also decide
inline vs display sizing; the engine is deliberately unaware of that
distinction (a front-end that has bare bodies wraps them itself). Equation
numbering, if a front-end wants it, is just a `\setcounter{equation}{N}`
prepended to the body — it folds into the content hash for free.

Returns an image now when one can be produced synchronously (cache / on-disk
SVG / placeholder), else `nil` after scheduling an asynchronous compile;
`CALLBACK` (a zero-argument function) is invoked once the SVG is ready, so the
caller can re-query (`latex-to-svg` again → now returns the image) and place
it. Concurrent requests for the same equation are coalesced onto a single
compile.

The image is tinted to the current buffer foreground and scaled to the buffer
font at build time, so call it within the target buffer.

Helpers a front-end typically needs for its refresh policy:

| Function | Purpose |
| --- | --- |
| `latex-to-svg-available-p` | SVG build support + graphical (or non-graphic opt-in) |
| `latex-to-svg-tools-available-p` | `latex` + `dvisvgm` on `exec-path` |
| `latex-to-svg-appearance` | `(FOREGROUND BACKGROUND FONT-HEIGHT)` signature to detect color/size change |
| `latex-to-svg-display-scale` | the `:scale` mapping the equation to the buffer font |
| `latex-to-svg-foreground-color` | current tint color (`#rrggbb`) |
| `latex-to-svg-flush-metrics` | deprecated no-op (sizing is now deterministic; kept for API compatibility) |
| `latex-to-svg-invalidate` | forget a cached render (delete its on-disk SVG + in-memory images) so the next call recompiles — an escape hatch for a stale/corrupt cache |

### Sketch of a front-end

```elisp
(defun my-place (buffer beg end latex)   ; LATEX is valid body LaTeX
  (with-current-buffer buffer
    (if-let ((img (latex-to-svg latex)))
        (my-overlay buffer beg end img)          ; cached / placeholder
      (let ((s (copy-marker beg)) (e (copy-marker end)))
        (latex-to-svg latex
          :callback (lambda ()
                      (with-current-buffer buffer
                        (my-overlay buffer s e (latex-to-svg latex)))))))))
```

## Customization

`latex-to-svg-latex-program`, `-dvisvgm-program`, `-preamble`,
`-appended-preamble`, `-cache-directory` (default `$XDG_CACHE_HOME/latex-to-svg/`),
`-font-scale`, `-use-placeholder`, `-render-on-non-graphic`, `-svg-dpi`
(points→pixels conversion for sizing; default 96, rarely needs changing).

Preview size is derived deterministically from the buffer font height and
`-svg-dpi` (SVG `pt` = dpi/72 px). Earlier versions measured this per-frame with
`image-size`, which proved unreliable on some ports (returning wildly different
pixel sizes for the same undisplayed SVG) and made preview sizes
non-deterministic — that measurement was removed in 0.2.2.

## Tests

```sh
emacs -batch -l ert -l tests/latex-to-svg-tests.el -f ert-run-tests-batch-and-exit
```

The suite runs without a TeX toolchain or a graphical display (graphical
inputs are stubbed).

## License

GPL-3.0-or-later.
