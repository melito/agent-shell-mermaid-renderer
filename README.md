# agent-shell-mermaid-renderer

Render Mermaid diagrams (` ```mermaid `) inline as SVG images in [`agent-shell`](https://github.com/xenodium/agent-shell) buffers.

## Features

- **Non-blocking & Asynchronous:** Compiles diagrams in background processes so Emacs and agent streaming never stutter or freeze.
- **On-Disk Caching:** Content-hash caching prevents unnecessary recompilations.
- **Theme Awareness:** Automatically matches frame dark/light background mode (`-t dark` or `-t default`).
- **Interactive Source Toggle:** Click on any diagram or press `RET` at point to flip between the rendered SVG and the raw Mermaid code.
- **Pluggable Backend Architecture:** Defaults to local `mmdc` (`mermaid-cli`), with a generic dispatch interface ready for future backends (e.g. Kroki API, Docker).

## Requirements

- Emacs 29.1+ with SVG support (`(image-type-available-p 'svg)`)
- [`agent-shell`](https://github.com/xenodium/agent-shell)
- `mmdc` executable from [`@mermaid-js/mermaid-cli`](https://github.com/mermaid-js/mermaid-cli)

## Installation

### Doom Emacs

In `packages.el`:
```elisp
(package! agent-shell-mermaid-renderer
  :recipe (:host github :repo "melito/agent-shell-mermaid-renderer" :files ("*.el")))
;; Or local development:
;; (package! agent-shell-mermaid-renderer :recipe (:local-repo "~/code/agent-shell-mermaid-renderer"))
```

In `config.el`:
```elisp
(use-package! agent-shell-mermaid-renderer
  :after agent-shell
  :config
  (agent-shell-mermaid-renderer-mode 1))
```

## Customization

- `agent-shell-mermaid-backend`: Backend compiler (default: `'mmdc'`).
- `agent-shell-mermaid-mmdc-executable`: Path to `mmdc` executable.
- `agent-shell-mermaid-theme`: Mermaid theme (`'auto'`, `"dark"`, `"default"`, `"neutral"`, `"forest"`).
- `agent-shell-mermaid-cache-directory`: Where rendered SVGs are stored.
- `agent-shell-mermaid-max-width`: Optional pixel width constraint for diagrams.
