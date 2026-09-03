;;; agent-shell-mermaid-renderer-tests.el --- Tests for agent-shell-mermaid-renderer -*- lexical-binding: t -*-

;; Copyright (C) 2026 Mel Gray

;; Author: Mel Gray

;;; Code:

(require 'ert)
(require 'json)
(require 'agent-shell-mermaid-renderer)

(ert-deftest agent-shell-mermaid-test--resolved-theme ()
  "Test theme resolution for auto and explicit themes."
  ;; Explicit themes
  (let ((agent-shell-mermaid-theme "forest"))
    (should (equal (agent-shell-mermaid--resolved-theme) "forest")))
  (let ((agent-shell-mermaid-theme "neutral"))
    (should (equal (agent-shell-mermaid--resolved-theme) "neutral")))
  ;; Auto theme fallback
  (let ((agent-shell-mermaid-theme 'auto))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (should (equal (agent-shell-mermaid--resolved-theme) "dark")))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'light))))
      (should (equal (agent-shell-mermaid--resolved-theme) "default")))))

(ert-deftest agent-shell-mermaid-test--resolved-css ()
  "Test resolved CSS behavior (custom override vs auto-derived face CSS)."
  ;; Custom CSS override takes precedence
  (let ((agent-shell-mermaid-custom-css ".custom { color: red; }"))
    (should (equal (agent-shell-mermaid--resolved-css) ".custom { color: red; }")))
  ;; Auto-derived face CSS generates valid SVG text fill rules
  (let ((agent-shell-mermaid-custom-css nil)
        (agent-shell-mermaid-theme "dark"))
    (should (string-match-p "fill: " (agent-shell-mermaid--resolved-css)))
    (should (string-match-p "stroke: " (agent-shell-mermaid--resolved-css)))))

(ert-deftest agent-shell-mermaid-test--json-config ()
  "Test that the generated Mermaid JSON configuration contains required flags."
  (let* ((agent-shell-mermaid-theme "dark")
         (config-str (agent-shell-mermaid--json-config))
         (config (json-read-from-string config-str)))
    ;; Theme should match
    (should (equal (cdr (assoc 'theme config)) "dark"))
    ;; htmlLabels must be false for pure SVG text
    (should (eq (cdr (assoc 'htmlLabels config)) :json-false))
    (let ((flowchart (cdr (assoc 'flowchart config))))
      (should flowchart)
      (should (eq (cdr (assoc 'htmlLabels flowchart)) :json-false)))
    (let ((sequence (cdr (assoc 'sequence config))))
      (should sequence)
      (should (eq (cdr (assoc 'useMaxWidth sequence)) :json-false)))))

(ert-deftest agent-shell-mermaid-test--cache-file ()
  "Test cache path computation and hash determinism."
  (let ((temp-dir (make-temp-file "agent-shell-mermaid-cache-" t)))
    (unwind-protect
        (let ((agent-shell-mermaid-cache-directory temp-dir)
              (agent-shell-mermaid-theme "dark")
              (agent-shell-mermaid-custom-css nil)
              (source "graph TD\nA-->B"))
          (let ((path1 (agent-shell-mermaid--cache-file source))
                (path2 (agent-shell-mermaid--cache-file source)))
            (should (equal path1 path2))
            (should (string-prefix-p temp-dir path1))
            (should (string-suffix-p ".svg" path1))))
      (delete-directory temp-dir t))))

(ert-deftest agent-shell-mermaid-test--toggle-source ()
  "Test toggling between rendered diagram image and raw Mermaid code."
  (with-temp-buffer
    (insert "graph TD\nA-->B")
    (let* ((start (point-min))
           (end (point-max))
           (dummy-image '(image :type svg :data "<svg></svg>")))
      ;; Initially apply display image property
      (put-text-property start end 'display dummy-image)
      (goto-char (+ start 2))
      (should (equal (get-text-property (point) 'display) dummy-image))
      (should-not (get-text-property (point) 'agent-shell-mermaid--saved-image))

      ;; First toggle: hide display image, stash in saved-image
      (agent-shell-mermaid-toggle-source)
      (should-not (get-text-property (point) 'display))
      (should (equal (get-text-property (point) 'agent-shell-mermaid--saved-image) dummy-image))

      ;; Second toggle: restore display image, clear saved-image
      (agent-shell-mermaid-toggle-source)
      (should (equal (get-text-property (point) 'display) dummy-image))
      (should-not (get-text-property (point) 'agent-shell-mermaid--saved-image)))))

(ert-deftest agent-shell-mermaid-test--render-context-filtering ()
  "Test context source-block filtering for mermaid language and completion state."
  (with-temp-buffer
    (insert (make-string 120 ?\s))
    (let ((rendered-blocks '())
          (context `((:source-blocks .
                      (;; Valid, complete mermaid block
                       ((:language . "mermaid")
                        (:complete . t)
                        (:block . ((:start . 1) (:end . 25)))
                        (:body . "graph TD\nA-->B"))
                       ;; Incomplete mermaid block (still streaming)
                       ((:language . "mermaid")
                        (:complete . nil)
                        (:block . ((:start . 26) (:end . 40)))
                        (:body . "graph TD\n..."))
                       ;; Different language (elisp)
                       ((:language . "emacs-lisp")
                        (:complete . t)
                        (:block . ((:start . 41) (:end . 60)))
                        (:body . "(message \"hello\")"))
                       ;; Empty mermaid block
                       ((:language . "mermaid")
                        (:complete . t)
                        (:block . ((:start . 61) (:end . 75)))
                        (:body . "   \n  ")))))))
      (cl-letf (((symbol-function 'agent-shell-mermaid--render-fenced-block)
                 (lambda (_buf start end source)
                   (push (list start end source) rendered-blocks))))
        (agent-shell-mermaid-renderer--render-context context)
        ;; Only the first valid, complete mermaid block should be dispatched
        (should (= (length rendered-blocks) 1))
        (let ((first (car rendered-blocks)))
          (should (equal (nth 0 first) 1))
          (should (equal (nth 1 first) 25))
          (should (equal (nth 2 first) "graph TD\nA-->B")))))))

(ert-deftest agent-shell-mermaid-test--apply-image ()
  "Test image overlay application with text properties and keymap."
  (with-temp-buffer
    (insert "```mermaid\ngraph TD\nA-->B\n```")
    (let* ((temp-svg (make-temp-file "agent-shell-test-" nil ".svg" "<svg width=\"100\" height=\"100\"></svg>"))
           (start (point-min))
           (end (point-max))
           (source "graph TD\nA-->B"))
      (unwind-protect
          (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                    ((symbol-function 'create-image)
                     (lambda (_file _type _data-p &rest _props)
                       '(image :type svg :data "<svg></svg>"))))
            (agent-shell-mermaid--apply-image (current-buffer) start end temp-svg source)
            (should (get-text-property start 'display))
            (should (equal (get-text-property start 'keymap) agent-shell-mermaid-image-map))
            (should (equal (get-text-property start 'mouse-face) 'highlight))
            (should (string-match-p "Click or RET to toggle code" (get-text-property start 'help-echo))))
        (delete-file temp-svg)))))

(provide 'agent-shell-mermaid-renderer-tests)
;;; agent-shell-mermaid-renderer-tests.el ends here
