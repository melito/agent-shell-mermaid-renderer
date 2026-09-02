;;; agent-shell-mermaid-renderer.el --- Render Mermaid diagrams inline in agent-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 Mel Gray

;; Author: Mel Gray
;; Keywords: multimedia, mermaid, agent-shell, llm
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.0"))
;; URL: https://github.com/melito/agent-shell-mermaid-renderer

;;; Commentary:
;; Renders ```mermaid fenced code blocks in `agent-shell' as inline SVG diagrams.
;; Uses an asynchronous backend (defaulting to `mmdc' / mermaid-cli) with disk caching
;; and a generic backend dispatch husk for future extensibility (e.g. Kroki HTTP, Docker).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(eval-when-compile (require 'agent-shell-markdown nil t))

(defgroup agent-shell-mermaid nil
  "Render Mermaid diagrams in `agent-shell' buffers."
  :group 'agent-shell
  :prefix "agent-shell-mermaid-")

;;; Customization

(defcustom agent-shell-mermaid-backend 'mmdc
  "Backend used to compile Mermaid diagrams to SVG.
Choices:
  `mmdc'        - Local mermaid-cli executable (default)
  `kroki-http'  - Remote Kroki HTTP API (placeholder for future backend)
  `docker'      - Run mermaid-cli inside Docker container (placeholder)"
  :type '(choice (const :tag "Local mermaid-cli (mmdc)" mmdc)
                 (const :tag "Kroki HTTP API" kroki-http)
                 (const :tag "Docker mermaid-cli" docker))
  :group 'agent-shell-mermaid)

(defcustom agent-shell-mermaid-mmdc-executable (or (executable-find "mmdc") "mmdc")
  "Path to the `mmdc' (mermaid-cli) executable."
  :type 'string
  :group 'agent-shell-mermaid)

(defcustom agent-shell-mermaid-theme 'auto
  "Mermaid theme to apply when rendering diagrams.
When `auto', detects dark vs light background mode from current frame."
  :type '(choice (const :tag "Auto (match frame background)" auto)
                 (const :tag "Dark" "dark")
                 (const :tag "Default (Light)" "default")
                 (const :tag "Neutral" "neutral")
                 (const :tag "Forest" "forest"))
  :group 'agent-shell-mermaid)

(defcustom agent-shell-mermaid-cache-directory
  (expand-file-name "agent-shell/mermaid-cache/" user-emacs-directory)
  "Directory where rendered SVG diagrams are cached."
  :type 'directory
  :group 'agent-shell-mermaid)

(defcustom agent-shell-mermaid-max-width nil
  "Maximum width in pixels for rendered diagrams, or nil for natural size."
  :type '(choice (const :tag "Natural size" nil)
                 (integer :tag "Pixels"))
  :group 'agent-shell-mermaid)

(defface agent-shell-mermaid-face
  '((t :inherit font-lock-doc-face))
  "Face applied to raw Mermaid code blocks under the diagram overlay."
  :group 'agent-shell-mermaid)

;;; Theme & Cache Helpers

(defun agent-shell-mermaid--resolved-theme ()
  "Resolve theme string ('dark', 'default', etc.) based on user settings."
  (if (eq agent-shell-mermaid-theme 'auto)
      (if (eq (frame-parameter nil 'background-mode) 'dark)
          "dark"
        "default")
    agent-shell-mermaid-theme))

(defun agent-shell-mermaid--cache-file (source)
  "Return destination SVG path for SOURCE string and active theme."
  (unless (file-directory-p agent-shell-mermaid-cache-directory)
    (make-directory agent-shell-mermaid-cache-directory t))
  (let* ((theme (agent-shell-mermaid--resolved-theme))
         (hash (secure-hash 'sha256 (format "%s::%s" theme (string-trim source)))))
    (expand-file-name (format "%s.svg" hash) agent-shell-mermaid-cache-directory)))

;;; Backend Dispatch Husk

(cl-defgeneric agent-shell-mermaid-compile-backend (backend source output-file callback)
  "Compile Mermaid SOURCE to OUTPUT-FILE using BACKEND.
CALLBACK is called with (OUTPUT-FILE-OR-NIL) upon completion.")

;; Default Backend: Local `mmdc` CLI
(cl-defmethod agent-shell-mermaid-compile-backend ((_backend (eql mmdc)) source output-file callback)
  "Asynchronously compile SOURCE to OUTPUT-FILE using `mmdc`."
  (unless (executable-find agent-shell-mermaid-mmdc-executable)
    (message "agent-shell-mermaid: `%s' executable not found in PATH"
             agent-shell-mermaid-mmdc-executable)
    (funcall callback nil))
  (let* ((temp-input (make-temp-file "agent-shell-mmd-" nil ".mmd" source))
         (theme (agent-shell-mermaid--resolved-theme))
         (proc-buffer (generate-new-buffer " *agent-shell-mermaid-mmdc*")))
    (make-process
     :name "agent-shell-mermaid-compile"
     :buffer proc-buffer
     :command (list agent-shell-mermaid-mmdc-executable
                    "-i" temp-input
                    "-o" output-file
                    "-t" theme
                    "-b" "transparent")
     :sentinel (lambda (proc _event)
                 (when (eq (process-status proc) 'exit)
                   (delete-file temp-input)
                   (if (and (= (process-exit-status proc) 0)
                            (file-exists-p output-file))
                       (funcall callback output-file)
                     (message "agent-shell-mermaid compile failed: %s"
                              (with-current-buffer (process-buffer proc) (buffer-string)))
                     (funcall callback nil))
                   (kill-buffer (process-buffer proc)))))))

;; Placeholder Backend: Kroki HTTP (for future expansion)
(cl-defmethod agent-shell-mermaid-compile-backend ((_backend (eql kroki-http)) _source _output-file callback)
  (message "agent-shell-mermaid: kroki-http backend is not yet implemented")
  (funcall callback nil))

;;; Diagram Overlay & Image Handling

(defvar-keymap agent-shell-mermaid-image-map
  :doc "Keymap active on rendered Mermaid diagrams."
  "RET" #'agent-shell-mermaid-toggle-source
  "<mouse-1>" #'agent-shell-mermaid-toggle-source)

(defun agent-shell-mermaid-toggle-source ()
  "Toggle between the rendered diagram image and raw Mermaid code at point."
  (interactive)
  (let* ((pos (point))
         (disp (get-text-property pos 'display))
         (img (get-text-property pos 'agent-shell-mermaid--saved-image)))
    (with-silent-modifications
      (if disp
          ;; Hide image, reveal source
          (let ((s (previous-single-property-change (1+ pos) 'display nil (point-min)))
                (e (next-single-property-change pos 'display nil (point-max))))
            (put-text-property s e 'agent-shell-mermaid--saved-image disp)
            (remove-text-properties s e '(display nil)))
        ;; Restore image
        (when img
          (let ((s (previous-single-property-change (1+ pos) 'agent-shell-mermaid--saved-image nil (point-min)))
                (e (next-single-property-change pos 'agent-shell-mermaid--saved-image nil (point-max))))
            (put-text-property s e 'display img)
            (remove-text-properties s e '(agent-shell-mermaid--saved-image nil))))))))

(defun agent-shell-mermaid--apply-image (buffer start-marker end-marker svg-path source)
  "Overlay SVG-PATH image over START-MARKER..END-MARKER in BUFFER."
  (when (and (buffer-live-p buffer) (file-exists-p svg-path))
    (with-current-buffer buffer
      (let ((s (marker-position start-marker))
            (e (marker-position end-marker)))
        (when (and s e (<= (point-min) s) (< s e) (<= e (point-max)))
          (with-silent-modifications
            (let ((image (create-image svg-path 'svg nil
                                       :max-width agent-shell-mermaid-max-width
                                       :scale 1.0)))
              (put-text-property s e 'display image)
              (put-text-property s e 'keymap agent-shell-mermaid-image-map)
              (put-text-property s e 'help-echo (concat source "\n\n(Click or RET to toggle code)"))
              (put-text-property s e 'mouse-face 'highlight))))))))

;;; Hook & Fenced Block Parsing

(defconst agent-shell-mermaid--fence-regex
  "^\\([ \t]*\\)```\\(?:mermaid\\)[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n\\1```"
  "Regex matching a complete, closed ```mermaid fence.")

(defun agent-shell-mermaid--scan-and-render (buffer)
  "Scan BUFFER for complete ```mermaid fences and trigger rendering."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward agent-shell-mermaid--fence-regex nil t)
        (let* ((start (match-beginning 0))
               (end (match-end 0))
               (source (match-string-no-properties 2))
               (frozen (get-text-property start 'agent-shell-markdown-frozen)))
          ;; Only process blocks that haven't been tagged frozen
          (unless (or frozen (string-blank-p source))
            ;; Freeze region to prevent markdown parser / streaming from thrashing it
            (add-face-text-property start end 'agent-shell-mermaid-face)
            (put-text-property start end 'agent-shell-markdown-frozen t)
            (let ((cache-file (agent-shell-mermaid--cache-file source))
                  (start-m (copy-marker start))
                  (end-m (copy-marker end t)))
              (if (file-exists-p cache-file)
                  (agent-shell-mermaid--apply-image buffer start-m end-m cache-file source)
                ;; Asynchronous compilation
                (agent-shell-mermaid-compile-backend
                 agent-shell-mermaid-backend
                 source
                 cache-file
                 (lambda (output)
                   (when output
                     (agent-shell-mermaid--apply-image buffer start-m end-m output source))))))))))))

;;; Entry Point / Hook Function

(defun agent-shell-mermaid-renderer--render-hook (&rest _args)
  "Hook function called by `agent-shell-markdown' on streaming markdown chunks."
  (when (and (display-graphic-p) (derived-mode-p 'agent-shell-mode))
    (agent-shell-mermaid--scan-and-render (current-buffer))))

;;; Minor Mode

;;;###autoload
(define-minor-mode agent-shell-mermaid-renderer-mode
  "Global minor mode to render Mermaid diagrams inline in `agent-shell`."
  :global t
  :group 'agent-shell-mermaid
  (if agent-shell-mermaid-renderer-mode
      (add-hook 'agent-shell-markdown-render-functions #'agent-shell-mermaid-renderer--render-hook)
    (remove-hook 'agent-shell-markdown-render-functions #'agent-shell-mermaid-renderer--render-hook)))

(provide 'agent-shell-mermaid-renderer)
;;; agent-shell-mermaid-renderer.el ends here
