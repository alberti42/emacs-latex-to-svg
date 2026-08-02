# latex-to-svg-backend

A small, **buffer-agnostic** Emacs library that turns a LaTeX math string into an SVG image suitable for overlaying in a buffer. It is the rendering core extracted from [`agent-shell-math-renderer`](https://github.com/alberti42/agent-shell-math-renderer); front-ends do their own equation *detection* and image *placement* and delegate the typesetting here.

## Why

Equations are compiled once and then recolored and rescaled **without recompiling** — the two things that are expensive if you bake color/size into the render:

- **Content-addressed on disk.** Each unique equation (SHA-1 of LaTeX + preamble + style) compiles at most once, ever; the cache is shared across every front-end and buffer.
- **Color-independent SVG.** `dvisvgm --currentcolor` emits the default ink as the literal token `currentColor`, substituted with the buffer foreground at display time. A theme switch re-tints from cache — no recompile. The image background is transparent, so it always matches the buffer.
- **Size-independent SVG.** Compiled at `dvisvgm --scale=1` (natural point dimensions, glyphs as outline paths) and scaled at display time via `create-image`'s `:scale`, computed from the buffer font height so equations track the font — again no recompile.

## Related packages

`latex-to-svg-backend` is a library, not a preview command: it turns one LaTeX string into one image and leaves *finding* equations and *placing* images to a front-end. Two front-ends are built on it today:

- [**`org-latex-to-svg`**](https://github.com/alberti42/org-latex-to-svg) — previews Org-mode LaTeX math as SVG. It finds `latex-fragment` and `latex-environment` elements with `org-element` and overlays each with an SVG typeset here; because the engine renders its input verbatim, it passes each element's `:value` as-is, so inline vs display sizing follows from the delimiters. A drop-in replacement for built-in `org-latex-preview` that adds recolor-on-theme-switch and rescale-on-zoom straight from cache.
- [**`agent-shell-math-renderer`**](https://github.com/alberti42/agent-shell-math-renderer) — renders LaTeX math in [`agent-shell`](https://github.com/xenodium/agent-shell)'s streamed markdown output. Display and inline math in an agent's response are shown as theme-matched SVGs while the original LaTeX stays in the buffer, so copy and save round-trip renderable source. This library was extracted from it.

Because the on-disk cache is content-addressed, an equation that appears in both an Org buffer and an agent's chat compiles only once, shared across both.

Several other Emacs packages preview LaTeX for the user; a few do, under the hood, the same string-to-image step this library does. How they relate:

| Package | Renders → output | Tied to | Recolor | Numbers | `\eqref` | `.fmt` |
| --- | --- | --- | --- | --- | --- | --- |
| **latex-to-svg-backend** (this) | `latex`+`dvisvgm` → SVG | any buffer / bare string | yes | yes¹ | yes¹ | yes |
| AUCTeX preview-latex | `latex`+`preview.sty` → PNG/SVG² | AUCTeX + `.tex` | no | yes | yes | no |
| [`texfrag`](https://github.com/TobiasZawada/texfrag) | AUCTeX `preview.el` → PNG/SVG² | AUCTeX; many modes | no | yes | yes | no |
| Org `org-latex-preview` (built-in) | `latex`+`dvipng`/`dvisvgm` → PNG/SVG | Org | no | no | no | no |
| [tecosaur/karthink `org-latex-preview`](https://code.tecosaur.net/tec/org-mode) (fork) | `latex`+`dvisvgm` (`.fmt`) → SVG | Org branch (fork) | yes | partial | partial | yes |
| [`org-latex-impatient`](https://github.com/yangsheng6810/org-latex-impatient) | MathJax → SVG (child frame) | Org | no | no | no | no |
| [`org-xlatex`](https://github.com/ksqsf/org-xlatex) | MathJax/KaTeX → xwidget | Org + xwidgets | no | no | no | no |
| [`latex-math-preview`](https://gitlab.com/latex-math-preview/latex-math-preview) | `latex`+`dvipng` → PNG | interactive command | no | no | no | no |

¹ via the [`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) front-end (the engine supplies the numbering metadata; the front-end assigns numbers and resolves `\ref` / `\eqref`). ² SVG output requires `preview-dvisvgm`.

What sets this stack apart is that it pulls together strengths that used to live in separate tools:

- **Numbered equations + working `\ref` / `\eqref`** — the AUCTeX-based packages get these by compiling a whole `.tex`; here the [`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) front-end assigns each block's numbers (folded in as a `\setcounter`) and reads the true counter back through the engine's compile-metadata sidecar, so every fragment still compiles alone.
- **Recolour + rescale from cache** — a theme switch, or a font/zoom change, updates previews with no LaTeX run; the others bake the colour and size into the image and must re-run LaTeX.
- **Fast builds** — `.fmt` preamble precompilation (see [Preamble precompilation](#preamble-precompilation-fmt)).
- **A shared, bare-string cache** — content-addressed and shared across front-ends and sessions, and the renderer takes a bare string, so it works outside a `.tex` document (for example, math in an agent's chat output).

The last two fall out of compiling each equation on its own and naming it by content.

The closest relative is the in-progress next-generation `org-latex-preview` by tecosaur and karthink: it also caches a color-independent (`currentColor`) SVG that re-tints from cache on a theme change, and pioneered the `.fmt` preamble precompilation this library adopts (see [Preamble precompilation](#preamble-precompilation-fmt)). The difference is packaging — it ships as part of a patched Org branch and is Org-only, while `latex-to-svg-backend` is a standalone library any front-end (or a bare string, in any buffer) can call.

Equation numbering used to be the gap: the AUCTeX-based packages compile a whole document, so `\ref` / `\eqref` and equation numbers come out right on their own, whereas here each fragment is compiled alone. The [`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) front-end closes it — it scans the buffer to assign each block's numbers (folded into the fragment as a `\setcounter`), reads the true final counter back through the engine's compile-metadata sidecar, and renders `\ref` / `\eqref` as the resolved number with click-to-jump. To our knowledge, this is the only stack that combines numbered equations **and** working `\ref` / `\eqref` links **and** `.fmt` precompilation **and** recolour/rescale from cache: the tecosaur/karthink fork has `.fmt` and cache-recolour but only partial numbering and no full cross-references, while the AUCTeX packages have numbering and references but no `.fmt` and no cache-recolour.

## Requirements

- Emacs 29.1+ with SVG image support.
- `latex` and `dvisvgm` on `exec-path` (from any TeX distribution). Without them, a placeholder panel boxing the raw LaTeX is shown instead (or set `latex-to-svg-backend-use-placeholder`).
- Optionally the `mylatexformat` package (`mylatexformat.ltx`, bundled with most TeX distributions) for preamble precompilation. Absent, the engine simply skips the speedup — see [Preamble precompilation](#preamble-precompilation-fmt).

## Installation

The package (feature) is `latex-to-svg-backend`; the repository is **`alberti42/latex-to-svg-backend`**. It is not on MELPA yet, so install straight from the repository. This is a *library* — you normally install it as a dependency of a front-end (e.g.  [`org-latex-to-svg`](https://github.com/alberti42/org-latex-to-svg) or `agent-shell-math-renderer`), declaring it *before* the front-end.

```elisp
;; use-package + :vc (Emacs 30+)
(use-package latex-to-svg-backend
  :vc (:url "https://github.com/alberti42/latex-to-svg-backend" :rev :newest))

;; use-package + straight
(use-package latex-to-svg-backend
  :straight (latex-to-svg-backend :type git :host github
                          :repo "alberti42/latex-to-svg-backend"))

;; elpaca
(elpaca (latex-to-svg-backend :host github :repo "alberti42/latex-to-svg-backend"))

;; Emacs 29+ builtin, no package manager
(package-vc-install "https://github.com/alberti42/latex-to-svg-backend")
```

Note the recipe *name* stays `latex-to-svg-backend` (the feature you `require`), while
`:repo` is `alberti42/latex-to-svg-backend`.

## API

```elisp
(latex-to-svg-backend LATEX &key callback metadata rescale-by)
```

`LATEX` is placed **verbatim** in the LaTeX document body, so pass valid body LaTeX — math with its delimiters (`$x$`, `\(x\)`, `\[x\]`) or a full environment (`\begin{equation}…\end{equation}`). The delimiters also decide inline vs display sizing; the engine is deliberately unaware of that distinction (a front-end that has bare bodies wraps them itself). Equation numbering, if a front-end wants it, is just a `\setcounter{equation}{N}` prepended to the body — it folds into the content hash for free.

Returns an image now when one can be produced synchronously (cache / on-disk SVG / placeholder), else `nil` after scheduling an asynchronous compile; `CALLBACK` (a zero-argument function) is invoked once the SVG is ready, so the caller can re-query (`latex-to-svg-backend` again → now returns the image) and place it. Concurrent requests for the same equation are coalesced onto a single compile.

`RESCALE-BY` (default `1.0`) multiplies the display size of this one call on top of `latex-to-svg-backend-font-scale`. The engine has no inline/display awareness, so a front-end that wants display equations a touch larger than inline passes, say, `:rescale-by 1.1` for display and nothing for inline. It is a display-time scale only — same on-disk SVG, no recompile — and folds into the in-memory image cache key, so both sizes coexist. `METADATA` is documented under [Compile metadata](#compile-metadata-eld-sidecar) below.

The image is tinted to the current buffer foreground and scaled to the buffer font at build time, so call it within the target buffer.

Helpers a front-end typically needs for its refresh policy:

| Function | Purpose |
| --- | --- |
| `latex-to-svg-backend-available-p` | SVG build support + graphical (or non-graphic opt-in) |
| `latex-to-svg-backend-tools-available-p` | `latex` + `dvisvgm` on `exec-path` |
| `latex-to-svg-backend-appearance` | `(FOREGROUND BACKGROUND FONT-HEIGHT)` signature to detect color/size change |
| `latex-to-svg-backend-display-scale` | the `:scale` mapping the equation to the buffer font |
| `latex-to-svg-backend-foreground-color` | current tint color (`#rrggbb`) |
| `latex-to-svg-backend-invalidate` | forget a cached render (delete its on-disk SVG + in-memory images, and its `.eld` sidecar) so the next call recompiles — an escape hatch for a stale/corrupt cache |
| `latex-to-svg-backend-metadata` | read back compile metadata for a LaTeX body (see below), on cache hit or miss |

### Compile metadata (`.eld` sidecar)

A compile can pair a value the caller already knows with a number the *compile* produces, and cache the pair next to the SVG — so a front-end can read it back **without recompiling** (e.g. the range of equation numbers a block shows). It is opt-in and the engine stays unaware of what the numbers mean.

The division of labour: the caller passes what it knows (`INITIAL`) as a Lisp value via `:metadata`; only the thing the compile computes (`FINAL`) travels through LaTeX, `\typeout`-ed on a line beginning with `latex-to-svg-backend-metadata-prefix`:

```elisp
(latex-to-svg-backend
  (concat "\\setcounter{equation}{6}%\n"          ; K = 6
          "\\begin{equation}x=1\\end{equation}\n"
          "\\typeout{L2S \\arabic{equation}}%\n") ; -> FINAL in the log
  :callback #'my-refresh
  :metadata 7)                                    ; INITIAL = K+1, from Elisp
```

With `latex-to-svg-backend-metadata-prefix` set to `"L2S"`, a successful compile takes the first integer on a matching log line (`FINAL`), pairs it with `:metadata` (`INITIAL`), and writes `<hash>.eld` beside `<hash>.svg`:

```elisp
;; metadata schema, v1
(:v 1 :nums (INITIAL . FINAL))     ; e.g. (:v 1 :nums (7 . 7))
```

`(latex-to-svg-backend-metadata BODY)` returns that plist (or `nil` if absent/corrupt).  Here the block shows equation numbers `INITIAL`…`FINAL` (just `(7)`); `FINAL < INITIAL` means it produced none.

For an equation you *don't* want to track, do nothing extra: call `(latex-to-svg-backend BODY …)` with no `:metadata` and inject no `\typeout`. No sidecar is written and `(latex-to-svg-backend-metadata BODY)` returns `nil` — the whole mechanism is inert unless you opt in (and stays off entirely while `latex-to-svg-backend-metadata-prefix` is `nil`, its default). So `nil` is simply the normal answer for any un-probed equation; there is no "no number" sentinel to handle. `latex-to-svg-backend-invalidate` deletes the `.eld` with the SVG. `\typeout` has no visual effect, so the SVG is byte-identical to an un-probed one (only its content hash differs). Keep the emitted line short — TeX wraps log lines near column 80.

### Sketch of a front-end

```elisp
(defun my-place (buffer beg end latex)   ; LATEX is valid body LaTeX
  (with-current-buffer buffer
    (if-let ((img (latex-to-svg-backend latex)))
        (my-overlay buffer beg end img)          ; cached / placeholder
      (let ((s (copy-marker beg)) (e (copy-marker end)))
        (latex-to-svg-backend latex
          :callback (lambda ()
                      (with-current-buffer buffer
                        (my-overlay buffer s e (latex-to-svg-backend latex)))))))))
```

## Customization

| Variable | Default | Purpose |
| --- | --- | --- |
| `latex-to-svg-backend-latex-program` | `"latex"` | the `latex` binary |
| `latex-to-svg-backend-dvisvgm-program` | `"dvisvgm"` | the `dvisvgm` binary |
| `latex-to-svg-backend-preamble` | `standalone[varwidth]` + `amsmath`/`xcolor` | the document class and base packages |
| `latex-to-svg-backend-appended-preamble` | `""` | extra preamble lines (your macros, packages) appended to the base |
| `latex-to-svg-backend-cache-directory` | `$XDG_CACHE_HOME/latex-to-svg-backend/` | where `<hash>.svg` / `.eld` / `.fmt` live |
| `latex-to-svg-backend-font-scale` | `1.0` | equation size relative to the buffer font (1.0 = match) |
| `latex-to-svg-backend-use-placeholder` | `nil` | force the raw-LaTeX placeholder instead of compiling |
| `latex-to-svg-backend-render-on-non-graphic` | `nil` | allow rendering on a non-graphical frame |
| `latex-to-svg-backend-svg-dpi` | `96.0` | points→pixels constant for sizing; rarely needs changing |
| `latex-to-svg-backend-metadata-prefix` | `nil` | `nil` = off; the `\typeout` prefix enabling `.eld` compile-metadata capture (above) |
| `latex-to-svg-backend-precompile` | `t` | preamble precompilation to a `.fmt` (below) |

### Preamble precompilation (`.fmt`)

Every equation is its own tiny LaTeX document, so each compile re-reads the class and every package in the preamble (`amsmath`, `xcolor`, and whatever you add via `latex-to-svg-backend-appended-preamble`). That parsing dominates the runtime of a small equation. With `latex-to-svg-backend-precompile` (default `t`) the engine dumps the preamble **once** to a LaTeX format file (`.fmt`) using the [`mylatexformat`](https://ctan.org/pkg/mylatexformat) package, keyed by the preamble text, and every equation compile then loads it via a `%&` first line instead of re-parsing the packages — typically **25–40% faster per equation**, more with a heavier preamble.

It is a pure optimization with a graceful fallback: when `mylatexformat.ltx` isn't on the TeX search path, or the dump fails, or a compile that used the format later fails, the engine transparently reverts to embedding the full preamble. A stale format after a TeX toolchain upgrade is detected (the LaTeX binary is newer than the `.fmt`) and rebuilt automatically; `M-x latex-to-svg-backend-flush-format` is the manual escape hatch. Set `latex-to-svg-backend-precompile` to `nil` to disable it entirely.

The `%&`-loaded `.fmt` approach is borrowed from the work of Karthik Chikmagalur (karthink) and TEC (tecosaur) on fast Org math preview. It started as karthink's proof-of-concept [`org-preview`](https://github.com/karthink/org-preview) (now archived); the `.fmt`-based `org-latex-preview` it grew into lives in a [fork of Org mode](https://code.tecosaur.net/tec/org-mode.git) and is not part of upstream Org.

Preview size is derived deterministically from the buffer font height and `-svg-dpi` (SVG `pt` = dpi/72 px). Earlier versions measured this per-frame with `image-size`, which proved unreliable on some ports (returning wildly different pixel sizes for the same undisplayed SVG) and made preview sizes non-deterministic — that measurement was removed in 0.2.2.

## Tests

```sh
emacs -batch -l ert -l tests/latex-to-svg-backend-tests.el -f ert-run-tests-batch-and-exit
```

The suite runs without a TeX toolchain or a graphical display (graphical inputs are stubbed).

## License

GPL-3.0-or-later.
