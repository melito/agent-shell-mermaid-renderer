# agent-shell-mermaid-renderer

Render Mermaid diagrams (` ```mermaid `) inline as high-contrast SVG images in [`agent-shell`](https://github.com/xenodium/agent-shell) buffers.

## Features

- **Non-blocking & Asynchronous:** Compiles diagrams in background processes so Emacs and agent streaming never stutter or freeze.
- **Native SVG Text Rendering:** Disables Mermaid's default HTML `foreignObject` tags (`htmlLabels: false`) so node text, labels, and titles render crisply via Emacs `librsvg`.
- **Emacs Face-Derived Palette:** Automatically derives diagram colors (text, node fills, borders, connectors) from your active Emacs theme faces (`default`, `highlight`, `font-lock-keyword-face`, `shadow`).
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

## Theme & Face Customization

### 1. Automatic Palette Inheritance
By default, the renderer inspects your active Emacs theme and inherits colors directly from standard faces:

| Element | Default Face Inheritance |
| :--- | :--- |
| **Diagram Text & Labels** | `agent-shell-mermaid-text-face` $\rightarrow$ `default` |
| **Node Box Background** | `agent-shell-mermaid-node-face` $\rightarrow$ `highlight` |
| **Node Borders & Accents** | `agent-shell-mermaid-border-face` $\rightarrow$ `font-lock-keyword-face` |
| **Connector Lines & Arrows** | `agent-shell-mermaid-line-face` $\rightarrow$ `shadow` |

When you switch your Doom / Emacs theme, newly rendered diagrams automatically adopt the new theme's color scheme.

### 2. Customizing Faces
You can customize the diagram appearance using standard Emacs face configuration (e.g. in Doom's `custom-set-faces!` or `custom-theme-set-faces!`):

```elisp
;; In ~/.config/doom/config.el:
(custom-set-faces!
  '(agent-shell-mermaid-text-face :foreground "#ffffff")
  '(agent-shell-mermaid-node-face :background "#1e1e2e")
  '(agent-shell-mermaid-border-face :foreground "#cba6f7")
  '(agent-shell-mermaid-line-face :foreground "#89b4fa"))
```

### 3. Hardcoding the Mermaid CLI Theme
You can also explicitly set the Mermaid CLI theme via `agent-shell-mermaid-theme`:
```elisp
;; Choices: 'auto (default), "dark", "default", "neutral", "forest", "base"
(setq agent-shell-mermaid-theme "dark")
```

### 4. Custom CSS Override
For complete control over the generated SVG stylesheet:
```elisp
(setq agent-shell-mermaid-custom-css
      "text, tspan { fill: #50fa7b !important; font-family: monospace !important; }
       .node rect { fill: #282a36 !important; stroke: #bd93f9 !important; }")
```

---

## Cache Management

Rendered SVG diagrams are cached on disk in `~/.config/emacs/agent-shell/mermaid-cache/` (or your Emacs cache directory).

- To purge the cache after modifying face or theme settings:
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
