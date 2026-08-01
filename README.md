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

## Related packages

`latex-to-svg` is a library, not a preview command: it turns one LaTeX string
into one image and leaves *finding* equations and *placing* images to a
front-end (such as
[`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) or
`agent-shell-math-renderer`). Several Emacs packages preview LaTeX for the
user; a few do, under the hood, the same string-to-image step this library
does. How they relate:

| Package | Renders with | Output | Tied to | Recolor / rescale from cache | Numbering |
| --- | --- | --- | --- | --- | --- |
| **latex-to-svg** (this) | `latex` + `dvisvgm` | SVG | nothing — any buffer, or a bare string | yes | not yet |
| AUCTeX preview-latex (+ `preview-dvisvgm`) | `latex` + `preview.sty` | PNG (SVG with `preview-dvisvgm`) | AUCTeX, a `.tex` document | no — color and size are baked in | yes |
| [`texfrag`](https://github.com/TobiasZawada/texfrag) | AUCTeX `preview.el` | PNG (SVG via `preview-dvisvgm`) | AUCTeX; works in many major modes | no | yes (per document) |
| Org `org-latex-preview` (built-in) | `latex` + `dvipng`/`dvisvgm` | PNG or SVG | Org | no — regenerates on a theme change | no |
| [`org-latex-impatient`](https://github.com/yangsheng6810/org-latex-impatient) | MathJax (Node) | SVG in a child frame | Org | no | — (MathJax, not full LaTeX) |
| [`org-xlatex`](https://github.com/ksqsf/org-xlatex) | MathJax / KaTeX | webkit in an xwidget | Org, xwidgets build | no | — |
| [`latex-math-preview`](https://gitlab.com/latex-math-preview/latex-math-preview) | `latex` + `dvipng` | PNG | an interactive command | no | no |

Two things set this library apart, both a consequence of compiling each
equation on its own and naming it by content:

- a theme switch, or a font/zoom change, updates previews straight from the
  cache with no LaTeX run — the others bake the colour and size into the image,
  so they re-run LaTeX;
- the cache is shared across front-ends and sessions, and the renderer takes a
  bare string, so it works outside a `.tex` document (for example, math in an
  agent's chat output).

The cost is equation numbering. The AUCTeX-based packages compile a whole
document, so `\ref` / `\eqref` and equation numbers come out right on their
own; here each fragment is compiled alone, so numbering has to be rebuilt by
the front-end and is not done yet. If you are editing a `.tex` file and want
correct numbers today, AUCTeX preview-latex (with `preview-dvisvgm` for SVG) or
`texfrag` is the better fit. If you want cheap recolouring and rescaling, or
rendering in buffers that are not TeX documents, this library is.

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
| `latex-to-svg-invalidate` | forget a cached render (delete its on-disk SVG + in-memory images, and its `.eld` sidecar) so the next call recompiles — an escape hatch for a stale/corrupt cache |
| `latex-to-svg-metadata` | read back compile metadata for a LaTeX body (see below), on cache hit or miss |

### Compile metadata (`.eld` sidecar)

A compile can pair a value the caller already knows with a number the *compile*
produces, and cache the pair next to the SVG — so a front-end can read it back
**without recompiling** (e.g. the range of equation numbers a block shows). It
is opt-in and the engine stays unaware of what the numbers mean.

The division of labour: the caller passes what it knows (`INITIAL`) as a Lisp
value via `:metadata`; only the thing the compile computes (`FINAL`) travels
through LaTeX, `\typeout`-ed on a line beginning with
`latex-to-svg-metadata-prefix`:

```elisp
(latex-to-svg
  (concat "\\setcounter{equation}{6}%\n"          ; K = 6
          "\\begin{equation}x=1\\end{equation}\n"
          "\\typeout{L2S \\arabic{equation}}%\n") ; -> FINAL in the log
  :callback #'my-refresh
  :metadata 7)                                    ; INITIAL = K+1, from Elisp
```

With `latex-to-svg-metadata-prefix` set to `"L2S"`, a successful compile takes
the first integer on a matching log line (`FINAL`), pairs it with `:metadata`
(`INITIAL`), and writes `<hash>.eld` beside `<hash>.svg`:

```elisp
;; metadata schema, v1
(:v 1 :nums (INITIAL . FINAL))     ; e.g. (:v 1 :nums (7 . 7))
```

`(latex-to-svg-metadata BODY)` returns that plist (or `nil` if absent/corrupt).
Here the block shows equation numbers `INITIAL`…`FINAL` (just `(7)`);
`FINAL < INITIAL` means it produced none. `latex-to-svg-invalidate` deletes the
`.eld` with the SVG. `\typeout` has no visual effect, so the SVG is
byte-identical to an un-probed one (only its content hash differs). Keep the
emitted line short — TeX wraps log lines near column 80.

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
(points→pixels conversion for sizing; default 96, rarely needs changing),
`-metadata-prefix` (nil = off; enable the `.eld` compile-metadata capture above).

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
