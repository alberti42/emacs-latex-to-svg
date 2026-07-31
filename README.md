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

## API

```elisp
(latex-to-svg LATEX &key inline callback)
```

Returns an image now when one can be produced synchronously (cache / on-disk
SVG / placeholder), else `nil` after scheduling an asynchronous compile;
`CALLBACK` (a zero-argument function) is invoked once the SVG is ready, so the
caller can re-query (`latex-to-svg` again → now returns the image) and place
it. Concurrent requests for the same equation are coalesced onto a single
compile. `INLINE` non-nil typesets in text style rather than display style.

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
| `latex-to-svg-flush-metrics` | drop the pixels-per-point calibration after a display change |

### Sketch of a front-end

```elisp
(defun my-place (buffer beg end latex &optional inline)
  (with-current-buffer buffer
    (if-let ((img (latex-to-svg latex :inline inline)))
        (my-overlay buffer beg end img)          ; cached / placeholder
      (let ((s (copy-marker beg)) (e (copy-marker end)))
        (latex-to-svg latex :inline inline
          :callback (lambda ()
                      (with-current-buffer buffer
                        (my-overlay buffer s e
                                    (latex-to-svg latex :inline inline)))))))))
```

## Customization

`latex-to-svg-latex-program`, `-dvisvgm-program`, `-preamble`,
`-appended-preamble`, `-cache-directory` (default `$XDG_CACHE_HOME/latex-to-svg/`),
`-font-scale`, `-use-placeholder`, `-render-on-non-graphic`.

## Tests

```sh
emacs -batch -l ert -l tests/latex-to-svg-tests.el -f ert-run-tests-batch-and-exit
```

The suite runs without a TeX toolchain or a graphical display (graphical
inputs are stubbed).

## License

GPL-3.0-or-later.
