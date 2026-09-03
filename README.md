# agent-shell-mermaid-renderer

Render Mermaid diagrams (` ```mermaid `) inline as high-contrast SVG images in [`agent-shell`](https://github.com/xenodium/agent-shell) buffers.

## Features

- **Non-blocking & Asynchronous:** Compiles diagrams in background processes so Emacs and agent streaming never stutter or freeze.
- **Native SVG Text Rendering:** Disables Mermaid's default HTML `foreignObject` tags (`htmlLabels: false`) so node text, labels, and titles render crisply via Emacs `librsvg`.
- **Theme-Aware Styling:** Automatically matches dark and light frames with contrast-optimized CSS for node fills, borders, and text.
- **On-Disk Caching:** SHA-256 content-hash caching prevents unnecessary recompilations across sessions.
- **Interactive Source Toggle:** Click on any diagram or press `RET` on the image to flip between the rendered SVG and raw Mermaid code.
- **Extensible Backend Dispatch:** Defaults to local `mmdc` (`mermaid-cli`), with a `cl-defgeneric` dispatch husk for future backends (e.g. Kroki HTTP, Docker).

---

## Requirements

- Emacs 29.1+ compiled with SVG support (`(image-type-available-p 'svg)`)
- [`agent-shell`](https://github.com/xenodium/agent-shell) (0.66.0+)
- `mmdc` executable from [`@mermaid-js/mermaid-cli`](https://github.com/mermaid-js/mermaid-cli):
  ```bash
  npm install -g @mermaid-js/mermaid-cli
  ```

---

## Installation

### Doom Emacs

In `~/.config/doom/packages.el`:
```elisp
(package! agent-shell-mermaid-renderer
  :recipe (:host github :repo "melito/agent-shell-mermaid-renderer" :files ("*.el")))

;; Or for local development:
;; (package! agent-shell-mermaid-renderer :recipe (:local-repo "~/code/agent-shell-mermaid-renderer"))
```

In `~/.config/doom/config.el`:
```elisp
(use-package! agent-shell-mermaid-renderer
  :after agent-shell
  :config
  (add-hook 'agent-shell-mode-hook #'agent-shell-mermaid-renderer-mode))
```

### Vanilla Emacs (use-package)

```elisp
(use-package agent-shell-mermaid-renderer
  :load-path "~/code/agent-shell-mermaid-renderer"
  :after agent-shell
  :hook (agent-shell-mode . agent-shell-mermaid-renderer-mode))
```

---

## Theme Configuration & Customization

### 1. Automatic Theme Detection
By default, `agent-shell-mermaid-theme` is set to `'auto`. It detects whether your current Emacs theme is dark or light via `(frame-parameter nil 'background-mode)` (with a fallback luminance calculation on the `default` face background).

### 2. Hardcoding the Mermaid Theme
You can explicitly lock in a Mermaid theme:
```elisp
;; Choices: "dark", "default" (light), "neutral", "forest", "base"
(setq agent-shell-mermaid-theme "dark")
```

### 3. Customizing Dark and Light Mode CSS
The renderer injects CSS rules to ensure text and nodes contrast against your buffer background. You can adjust the default CSS variables:

```elisp
;; Customize dark mode diagram colors
(setq agent-shell-mermaid-dark-css
      "text, tspan, .flowchartTitleText, .edgeLabel, .actor, .messageText, .label text {
  fill: #f0f6fc !important;
  color: #f0f6fc !important;
}
.node rect, .node circle, .node polygon, .node path {
  fill: #1e1e2e !important;
  stroke: #cba6f7 !important;
  stroke-width: 1.5px !important;
}")

;; Customize light mode diagram colors
(setq agent-shell-mermaid-light-css
      "text, tspan, .flowchartTitleText, .edgeLabel, .actor, .messageText, .label text {
  fill: #1f2328 !important;
  color: #1f2328 !important;
}
.node rect, .node circle, .node polygon, .node path {
  fill: #f6f8fa !important;
  stroke: #0969da !important;
  stroke-width: 1.5px !important;
}")
```

### 4. Full Custom CSS Override
To apply your own CSS stylesheet regardless of the active theme:
```elisp
(setq agent-shell-mermaid-custom-css
      "text, tspan { fill: #50fa7b !important; font-family: monospace !important; }
       .node rect { fill: #282a36 !important; stroke: #bd93f9 !important; }")
```

---

## Cache Management

Rendered SVG diagrams are cached to disk in `~/.config/emacs/agent-shell/mermaid-cache/` (or your Emacs cache directory).

- To purge the cache after modifying your theme or CSS settings:
  ```elisp
  M-x agent-shell-mermaid-clear-cache
  ```
- Change cache directory location:
  ```elisp
  (setq agent-shell-mermaid-cache-directory "~/my-custom-cache/mermaid/")
  ```

---

## Interactive Keybindings

When a Mermaid diagram is rendered in an `agent-shell` buffer:
- **`RET`** (or **Click**): Toggles between the rendered SVG image overlay and the underlying raw Mermaid code.

---

## Running Unit Tests

The test suite uses Emacs ERT (Emacs Regression Testing):

```bash
emacs -Q -batch -L . -l ert -l tests/agent-shell-mermaid-renderer-tests.el -f ert-run-tests-batch-and-exit
```

Or from within Emacs:
```elisp
(ert "agent-shell-mermaid-test-")
```

---

## License

GPL-3.0-or-later
