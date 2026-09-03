;;; agent-shell-mermaid-renderer.el --- Render Mermaid diagrams inline in agent-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 Mel Gray

;; Author: Mel Gray
;; Keywords: multimedia, mermaid, agent-shell, llm
;; Version: 0.5.1
;; Package-Requires: ((emacs "29.1") (agent-shell "0.66.0"))
;; URL: https://github.com/melito/agent-shell-mermaid-renderer

;;; Commentary:
;; Renders ```mermaid fenced code blocks in `agent-shell' as inline SVG diagrams.
;; Uses an asynchronous backend (defaulting to `mmdc' / mermaid-cli) with disk caching,
;; native SVG text rendering (htmlLabels: false), and theme-derived face styling.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(eval-when-compile (require 'agent-shell-markdown nil t))

(defgroup agent-shell-mermaid nil
  "Render Mermaid diagrams in `agent-shell' buffers."
  :group 'agent-shell
  :prefix "agent-shell-mermaid-")

;;; Customization

(defcustom agent-shell-mermaid-enable t
  "When non-nil, enable inline rendering of Mermaid diagrams."
  :type 'boolean
  :group 'agent-shell-mermaid)

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
When `auto', automatically detects dark vs light background mode
from the current frame.  You can also hardcode any valid Mermaid
theme name:
  \"dark\"    - Mermaid dark theme
  \"default\" - Mermaid light theme
  \"neutral\" - Neutral grayscale theme
  \"forest\"  - Forest green theme
  \"base\"    - Base unstyled theme"
  :type '(choice (const :tag "Auto (detect dark/light from Emacs theme)" auto)
                 (const :tag "Dark" "dark")
                 (const :tag "Default (Light)" "default")
                 (const :tag "Neutral" "neutral")
                 (const :tag "Forest" "forest")
                 (const :tag "Base" "base")
                 (string :tag "Custom Theme Name"))
  :group 'agent-shell-mermaid)

(defcustom agent-shell-mermaid-custom-css nil
  "Optional custom CSS string to inject into diagrams via `--cssFile'.
When nil (default), CSS is dynamically derived from active Emacs faces
  (`agent-shell-mermaid-text-face', `agent-shell-mermaid-node-face', etc.)."
  :type '(choice (const :tag "Auto-derive from Emacs faces" nil)
                 (string :tag "Custom CSS override"))
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

;;; Faces

(defface agent-shell-mermaid-face
  '((t :inherit font-lock-doc-face))
  "Face applied to raw Mermaid code blocks under the diagram overlay."
  :group 'agent-shell-mermaid)

(defface agent-shell-mermaid-text-face
  '((t :inherit default))
  "Face used to style text and labels in Mermaid diagrams."
  :group 'agent-shell-mermaid)

(defface agent-shell-mermaid-node-face
  '((t :inherit highlight))
  "Face used for node background fills in Mermaid diagrams."
  :group 'agent-shell-mermaid)

(defface agent-shell-mermaid-border-face
  '((t :inherit font-lock-keyword-face))
  "Face used for node borders and accents in Mermaid diagrams."
  :group 'agent-shell-mermaid)

(defface agent-shell-mermaid-line-face
  '((t :inherit shadow))
  "Face used for connector lines and arrows in Mermaid diagrams."
  :group 'agent-shell-mermaid)

;;; Theme & Face-Derived CSS Helpers

(defun agent-shell-mermaid--dark-background-p ()
  "Return non-nil if current frame background is dark."
  (let ((bg-mode (frame-parameter nil 'background-mode)))
    (if (memq bg-mode '(dark light))
        (eq bg-mode 'dark)
      ;; Fallback: compute relative luminance of the default background color
      (let* ((bg-color (face-attribute 'default :background nil t))
             (rgb (and (stringp bg-color) (color-values bg-color))))
        (if rgb
            (< (+ (* 0.299 (nth 0 rgb))
                  (* 0.587 (nth 1 rgb))
                  (* 0.114 (nth 2 rgb)))
               32768)
          t)))))

(defun agent-shell-mermaid--face-color (face attribute &optional fallback-face fallback-attribute default-dark default-light)
  "Extract valid color string from FACE's ATTRIBUTE.
Falls back to FALLBACK-FACE and FALLBACK-ATTRIBUTE if unspecified.
If still unspecified or invalid face, returns DEFAULT-DARK or DEFAULT-LIGHT
based on frame background."
  (let ((val (when (facep face)
               (face-attribute face attribute nil t))))
    (if (and (stringp val) (not (string-prefix-p "unspecified" val)))
        val
      (if (and fallback-face (facep fallback-face))
          (agent-shell-mermaid--face-color fallback-face (or fallback-attribute attribute)
                                           nil nil default-dark default-light)
        (if (agent-shell-mermaid--dark-background-p)
            (or default-dark "#f0f6fc")
          (or default-light "#1f2328"))))))

(cl-defun agent-shell-mermaid--build-stylesheet (&key text-color node-bg node-border line-color)
  "Build CSS stylesheet for Mermaid diagrams given color specifications.
TEXT-COLOR is applied to labels, titles, and text nodes.
NODE-BG is applied as the fill color for diagram nodes.
NODE-BORDER is applied as the stroke color for node boundaries.
LINE-COLOR is applied to connector lines, arrows, and edges."
  (format
   "text, tspan, .flowchartTitleText, .edgeLabel, .actor, .messageText, .label text {
  fill: %s !important;
  color: %s !important;
}
.node rect, .node circle, .node polygon, .node path, .actor {
  fill: %s !important;
  stroke: %s !important;
  stroke-width: 1.5px !important;
}
.actor-line, .messageLine0, .messageLine1, .flowchart-link {
  stroke: %s !important;
}"
   text-color text-color
   node-bg node-border
   line-color))

(defun agent-shell-mermaid--resolved-theme ()
  "Resolve theme string (e.g. `\"dark\"', `\"default\"') based on user settings."
  (if (eq agent-shell-mermaid-theme 'auto)
      (if (agent-shell-mermaid--dark-background-p)
          "dark"
        "default")
    (format "%s" agent-shell-mermaid-theme)))

(defun agent-shell-mermaid--resolved-css ()
  "Return active CSS string (custom override or derived from Emacs faces)."
  (or agent-shell-mermaid-custom-css
      (agent-shell-mermaid--build-stylesheet
       :text-color  (agent-shell-mermaid--face-color
                     'agent-shell-mermaid-text-face :foreground 'default :foreground "#f0f6fc" "#1f2328")
       :node-bg     (agent-shell-mermaid--face-color
                     'agent-shell-mermaid-node-face :background 'highlight :background "#21262d" "#f6f8fa")
       :node-border (agent-shell-mermaid--face-color
                     'agent-shell-mermaid-border-face :foreground 'font-lock-keyword-face :foreground "#58a6ff" "#0969da")
       :line-color  (agent-shell-mermaid--face-color
                     'agent-shell-mermaid-line-face :foreground 'shadow :foreground "#8b949e" "#57606a"))))

(defun agent-shell-mermaid--json-config ()
  "Return Mermaid JSON configuration string with native SVG text enabled."
  (let ((theme (agent-shell-mermaid--resolved-theme)))
    (json-encode
     `((theme . ,theme)
       (htmlLabels . :json-false)
       (flowchart . ((htmlLabels . :json-false)))
       (sequence . ((useMaxWidth . :json-false)))))))

(defun agent-shell-mermaid--cache-file (source)
  "Return destination SVG path for SOURCE string, active theme, and CSS."
  (unless (file-directory-p agent-shell-mermaid-cache-directory)
    (make-directory agent-shell-mermaid-cache-directory t))
  (let* ((theme (agent-shell-mermaid--resolved-theme))
         (css (agent-shell-mermaid--resolved-css))
         (hash (secure-hash 'sha256 (format "v5::%s::%s::%s" theme css (string-trim source)))))
    (expand-file-name (format "%s.svg" hash) agent-shell-mermaid-cache-directory)))

;;;###autoload
(defun agent-shell-mermaid-clear-cache ()
  "Clear all cached Mermaid SVG diagram files from disk."
  (interactive)
  (when (file-directory-p agent-shell-mermaid-cache-directory)
    (delete-directory agent-shell-mermaid-cache-directory t)
    (make-directory agent-shell-mermaid-cache-directory t)
    (message "agent-shell-mermaid: cache cleared (%s)" agent-shell-mermaid-cache-directory)))

;;; Backend Dispatch Husk

(cl-defgeneric agent-shell-mermaid-compile-backend (backend source output-file callback)
  "Compile Mermaid SOURCE to OUTPUT-FILE using BACKEND.
CALLBACK is called with (OUTPUT-FILE-OR-NIL) upon completion.")

;; Default Backend: Local `mmdc` CLI
(cl-defmethod agent-shell-mermaid-compile-backend ((_backend (eql mmdc)) source output-file callback)
  "Asynchronously compile SOURCE to OUTPUT-FILE using `mmdc'.
Calls CALLBACK with OUTPUT-FILE on success or nil on failure."
  (unless (executable-find agent-shell-mermaid-mmdc-executable)
    (message "agent-shell-mermaid: `%s' executable not found in PATH"
             agent-shell-mermaid-mmdc-executable)
    (funcall callback nil))
  (let* ((temp-input (make-temp-file "agent-shell-mmd-" nil ".mmd" source))
         (temp-css (make-temp-file "agent-shell-css-" nil ".css" (agent-shell-mermaid--resolved-css)))
         (temp-config (make-temp-file "agent-shell-cfg-" nil ".json" (agent-shell-mermaid--json-config)))
         (theme (agent-shell-mermaid--resolved-theme))
         (proc-buffer (generate-new-buffer " *agent-shell-mermaid-mmdc*")))
    (make-process
     :name "agent-shell-mermaid-compile"
     :buffer proc-buffer
     :command (list agent-shell-mermaid-mmdc-executable
                    "-i" temp-input
                    "-o" output-file
                    "-t" theme
                    "-c" temp-config
                    "-C" temp-css
                    "-b" "transparent")
     :sentinel (lambda (proc _event)
                 (when (eq (process-status proc) 'exit)
                   (delete-file temp-input)
                   (delete-file temp-css)
                   (delete-file temp-config)
                   (if (and (= (process-exit-status proc) 0)
                            (file-exists-p output-file))
                       (funcall callback output-file)
                     (message "agent-shell-mermaid compile failed: %s"
                              (with-current-buffer (process-buffer proc) (buffer-string)))
                     (funcall callback nil))
                   (kill-buffer (process-buffer proc)))))))

;; Placeholder Backend: Kroki HTTP (for future expansion)
(cl-defmethod agent-shell-mermaid-compile-backend ((_backend (eql kroki-http)) _source _output-file callback)
  "Compile diagram using remote Kroki HTTP backend.
Calls CALLBACK with nil as it is not yet implemented."
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
  "Overlay SVG-PATH image over START-MARKER..END-MARKER in BUFFER for SOURCE."
  (unwind-protect
      (when (and (buffer-live-p buffer) (file-exists-p svg-path))
        (with-current-buffer buffer
          (let ((s (if (markerp start-marker) (marker-position start-marker) start-marker))
                (e (if (markerp end-marker) (marker-position end-marker) end-marker)))
            (when (and s e (<= (point-min) s) (< s e) (<= e (point-max)))
              (with-silent-modifications
                (let ((image (create-image svg-path 'svg nil
                                           :max-width agent-shell-mermaid-max-width
                                           :scale 1.0))
                      (line-prefix (get-text-property s 'line-prefix))
                      (wrap-prefix (get-text-property s 'wrap-prefix)))
                  (put-text-property s e 'display image)
                  (put-text-property s e 'keymap agent-shell-mermaid-image-map)
                  (put-text-property s e 'help-echo (concat source "\n\n(Click or RET to toggle code)"))
                  (put-text-property s e 'mouse-face 'highlight)
                  (when line-prefix
                    (put-text-property s e 'line-prefix line-prefix))
                  (when wrap-prefix
                    (put-text-property s e 'wrap-prefix wrap-prefix))))))))
    (when (markerp start-marker) (set-marker start-marker nil))
    (when (markerp end-marker) (set-marker end-marker nil))))

(defun agent-shell-mermaid--apply-region (buffer start end source)
  "Mark BUFFER's region from START to END as mermaid and compile SOURCE."
  (with-current-buffer buffer
    (add-face-text-property start end 'agent-shell-mermaid-face)
    (add-text-properties
     start end
     `(help-echo ,source
       agent-shell-mermaid-source ,source
       agent-shell-markdown-frozen t
       rear-nonsticky (agent-shell-markdown-frozen)))
    (let ((cache-file (agent-shell-mermaid--cache-file source))
          (start-m (copy-marker start))
          (end-m (copy-marker end t)))
      (if (file-exists-p cache-file)
          (agent-shell-mermaid--apply-image buffer start-m end-m cache-file source)
        (agent-shell-mermaid-compile-backend
         agent-shell-mermaid-backend
         source
         cache-file
         (lambda (output)
           (when output
             (agent-shell-mermaid--apply-image buffer start-m end-m output source))))))))

(defun agent-shell-mermaid--render-fenced-block (buffer start end source)
  "Trim START..END around fenced block and render SOURCE in BUFFER."
  (with-current-buffer buffer
    (let ((s (save-excursion (goto-char start) (skip-chars-forward "\n") (point)))
          (e (if (eq (char-before end) ?\n) (1- end) end)))
      (when (< s e)
        (agent-shell-mermaid--apply-region buffer s e source)))))

(defun agent-shell-mermaid-renderer--render-context (context)
  "Render mermaid fences from CONTEXT alist."
  (let ((source-blocks (map-elt context :source-blocks)))
    (dolist (sb source-blocks)
      (when-let* ((lang (or (map-elt sb :language) (map-elt sb :info)))
                  ((string= (downcase (string-trim lang)) "mermaid"))
                  ((map-elt sb :complete))
                  (start (map-nested-elt sb '(:block :start)))
                  (end (map-nested-elt sb '(:block :end)))
                  ((and (<= (point-min) start (point-max))
                        (not (get-text-property start 'agent-shell-markdown-frozen))))
                  (body (map-elt sb :body))
                  (source (string-trim body))
                  ((not (string-empty-p source))))
        (agent-shell-mermaid--render-fenced-block (current-buffer) start end source)))))

;;; Hook & Minor Mode

(defun agent-shell-mermaid-renderer--render-hook (context)
  "Hook function called by `agent-shell-markdown' on streaming markdown CONTEXT."
  (when (and (display-graphic-p)
             (or (bound-and-true-p agent-shell-mermaid-renderer-mode)
                 agent-shell-mermaid-enable))
    (agent-shell-mermaid-renderer--render-context context)))

;;;###autoload
(define-minor-mode agent-shell-mermaid-renderer-mode
  "Render Mermaid diagrams in this `agent-shell' buffer's markdown output.
Enable it per buffer from `agent-shell-mode-hook':
  (add-hook \\='agent-shell-mode-hook #\\='agent-shell-mermaid-renderer-mode)"
  :lighter nil
  (if agent-shell-mermaid-renderer-mode
      (add-hook 'agent-shell-markdown-render-functions
                #'agent-shell-mermaid-renderer--render-hook nil t)
    (remove-hook 'agent-shell-markdown-render-functions
                 #'agent-shell-mermaid-renderer--render-hook t)))

;;;###autoload
(defun agent-shell-mermaid-renderer-setup ()
  "Enable Mermaid rendering globally across all `agent-shell' buffers."
  (interactive)
  (add-hook 'agent-shell-mode-hook #'agent-shell-mermaid-renderer-mode)
  ;; Also hook into existing buffers
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'agent-shell-mode)
        (agent-shell-mermaid-renderer-mode 1)))))

(provide 'agent-shell-mermaid-renderer)
;;; agent-shell-mermaid-renderer.el ends here
