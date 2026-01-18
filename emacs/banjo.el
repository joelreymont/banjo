;;; banjo.el --- Claude/Codex agent client -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Banjo Contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (websocket "1.14"))
;; Keywords: ai, tools
;; URL: https://github.com/your-repo/banjo

;;; Commentary:

;; Emacs client for the Banjo ACP agent.
;; Connects via WebSocket to a local daemon.

;;; Code:

(require 'websocket)
(require 'json)
(require 'subr-x)

;; Customization

(defgroup banjo nil
  "Claude/Codex agent client."
  :group 'tools
  :prefix "banjo-")

(defcustom banjo-binary "banjo"
  "Path to the banjo binary."
  :type 'string
  :group 'banjo)

(defcustom banjo-panel-width 50
  "Width of the Banjo panel."
  :type 'integer
  :group 'banjo)

(defcustom banjo-panel-position 'right
  "Position of the Banjo panel."
  :type '(choice (const left) (const right))
  :group 'banjo)

(defcustom banjo-input-height 6
  "Height of the Banjo input window."
  :type 'integer
  :group 'banjo)

(defcustom banjo-input-hints "RET send, C-j newline, / commands"
  "Hints shown in the Banjo input header line."
  :type 'string
  :group 'banjo)

(defcustom banjo-enable-links t
  "Whether to detect and activate file/URL links in output."
  :type 'boolean
  :group 'banjo)

(defcustom banjo-doom-leader-prefix "a"
  "Doom leader prefix for Banjo bindings (e.g. \"a\" -> SPC a ...)."
  :type 'string
  :group 'banjo)

;; Faces

(defface banjo-face-user
  '((t :inherit font-lock-string-face))
  "Face for user prompts."
  :group 'banjo)

(defface banjo-face-assistant
  '((t :inherit default))
  "Face for assistant output."
  :group 'banjo)

(defface banjo-face-thought
  '((t :inherit shadow))
  "Face for assistant thoughts."
  :group 'banjo)

(defface banjo-face-tool
  '((t :inherit font-lock-function-name-face))
  "Face for tool call lines."
  :group 'banjo)

(defface banjo-face-tool-success
  '((t :inherit success))
  "Face for successful tool calls."
  :group 'banjo)

(defface banjo-face-tool-fail
  '((t :inherit error))
  "Face for failed tool calls."
  :group 'banjo)

(defface banjo-face-tool-pending
  '((t :inherit warning))
  "Face for pending tool calls."
  :group 'banjo)

(defface banjo-face-link
  '((t :inherit link))
  "Face for links."
  :group 'banjo)

(defface banjo-face-code
  '((t :inherit font-lock-constant-face))
  "Face for code fences."
  :group 'banjo)

(defface banjo-face-code-block
  '((t :inherit font-lock-constant-face :extend t))
  "Face for code block contents."
  :group 'banjo)

(defface banjo-face-inline-code
  '((t :inherit font-lock-constant-face))
  "Face for inline code."
  :group 'banjo)

(defface banjo-face-header
  '((t :inherit font-lock-keyword-face))
  "Face for markdown headers."
  :group 'banjo)

(defface banjo-face-blockquote
  '((t :inherit shadow))
  "Face for blockquotes."
  :group 'banjo)

(defface banjo-face-list-bullet
  '((t :inherit font-lock-keyword-face))
  "Face for list bullets."
  :group 'banjo)

(defface banjo-face-hr
  '((t :inherit shadow))
  "Face for horizontal rules."
  :group 'banjo)

;; Font-lock

(defconst banjo--font-lock-keywords
  `(
    ("^\\s-*#\\{1,6\\}\\s-+.*$" . 'banjo-face-header)
    ("^\\s-*```.*$" . 'banjo-face-code)
    ("^\\s-*>.*$" . 'banjo-face-blockquote)
    ("`[^`\n]+`" . 'banjo-face-inline-code)
    ("^\\s-*\\([0-9]+\\.\\)\\s-+" (1 'banjo-face-list-bullet))
    ("^\\s-*\\([-*+]\\)\\s-+" (1 'banjo-face-list-bullet))
    ("^\\s-*[-_*]\\{3,\\}\\s-*$" . 'banjo-face-hr)
    ("^\\s-*\\([.vx>]\\)\\s-+.*$" . 'banjo-face-tool)
    ("^\\s-*\\(v\\)\\s-+" (1 'banjo-face-tool-success))
    ("^\\s-*\\(x\\)\\s-+" (1 'banjo-face-tool-fail))
    ("^\\s-*\\([.>]\\)\\s-+" (1 'banjo-face-tool-pending))
    ("\\*\\*[^*\n]+\\*\\*" . 'bold)))

;; Link detection

(defconst banjo--url-regexp
  "\\(https?://[^][(){}<>\"' \t\n]+\\)")

(defconst banjo--file-link-regexp
  "\\b\\([[:alnum:]_./~+-]+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?")

(defconst banjo--file-hash-link-regexp
  "\\b\\([[:alnum:]_./~+-]+\\)#L\\([0-9]+\\)\\(?:C\\([0-9]+\\)\\)?\\(?:-L[0-9]+\\)?")

(defconst banjo--file-path-regexp
  "\\b\\([~./][[:alnum:]_./~+-]+\\|[[:alnum:]_./~+-]+/[[:alnum:]_./~+-]+\\)\\b")

(defconst banjo--code-line-buffer-max 2048
  "Maximum buffered characters for incremental fence detection.")

(defvar-local banjo--code-block-open nil
  "Non-nil when inside a fenced code block.")

(defvar-local banjo--code-line-buffer ""
  "Accumulated partial line for fenced code parsing.")

(defun banjo--resolve-path (path)
  "Resolve PATH against the current buffer default directory."
  (if (file-name-absolute-p path)
      path
    (expand-file-name path default-directory)))

(defun banjo--open-file-link (path line col)
  "Open PATH at LINE and optional COL."
  (let ((file (banjo--resolve-path path)))
    (when (file-exists-p file)
      (find-file-other-window file)
      (goto-char (point-min))
      (forward-line (max 0 (1- line)))
      (when col
        (move-to-column (max 0 (1- col)))))))

(defun banjo--make-link-button (beg end action help)
  "Create a link button from BEG to END."
  (make-text-button
   beg end
   'action action
   'follow-link t
   'help-echo help
   'face 'banjo-face-link
   'banjo-link t))

(defun banjo--apply-buttons (beg end)
  "Create link buttons in region BEG..END."
  (when banjo-enable-links
    (save-excursion
      (save-match-data
        (goto-char beg)
        (while (re-search-forward banjo--url-regexp end t)
          (let* ((url (match-string 1))
                 (b (match-beginning 1))
                 (e (match-end 1)))
            (unless (or (get-text-property b 'banjo-link)
                        (get-text-property b 'banjo-code-block))
              (banjo--make-link-button
               b e
               (lambda (_btn) (browse-url url))
               url))))
        (goto-char beg)
        (while (re-search-forward banjo--file-link-regexp end t)
          (let* ((path (match-string 1))
                 (line (string-to-number (match-string 2)))
                 (col (match-string 3))
                 (b (match-beginning 1))
                 (e (match-end 0))
                 (abs (banjo--resolve-path path)))
            (when (and (file-exists-p abs)
                       (not (get-text-property b 'banjo-link))
                       (not (get-text-property b 'banjo-code-block)))
              (banjo--make-link-button
               b e
               (lambda (_btn)
                 (banjo--open-file-link path line (and col (string-to-number col))))
               (format "Open %s:%d%s" path line (if col (format ":%s" col) ""))))))
        (goto-char beg)
        (while (re-search-forward banjo--file-hash-link-regexp end t)
          (let* ((path (match-string 1))
                 (line (string-to-number (match-string 2)))
                 (col (match-string 3))
                 (b (match-beginning 1))
                 (e (match-end 0))
                 (abs (banjo--resolve-path path)))
            (when (and (file-exists-p abs)
                       (not (get-text-property b 'banjo-link))
                       (not (get-text-property b 'banjo-code-block)))
              (banjo--make-link-button
               b e
               (lambda (_btn)
                 (banjo--open-file-link path line (and col (string-to-number col))))
               (format "Open %s#L%d%s" path line (if col (format "C%s" col) ""))))))
        (goto-char beg)
        (while (re-search-forward banjo--file-path-regexp end t)
          (let* ((path (match-string 1))
                 (b (match-beginning 1))
                 (e (match-end 1))
                 (abs (banjo--resolve-path path)))
            (when (and (file-exists-p abs)
                       (not (get-text-property b 'banjo-link))
                       (not (get-text-property b 'banjo-code-block)))
              (banjo--make-link-button
               b e
               (lambda (_btn) (banjo--open-file-link path 1 nil))
               (format "Open %s" path)))))))))

(defun banjo--apply-code-blocks (beg end start-open)
  "Apply code block faces between BEG and END."
  (let ((open start-open))
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (while (< (point) end)
        (let* ((line-beg (point))
               (line-end (line-end-position))
               (line (buffer-substring-no-properties line-beg line-end)))
          (if (string-match-p "^\\s-*```" line)
              (progn
                (add-face-text-property line-beg line-end 'banjo-face-code t)
                (add-text-properties line-beg line-end '(banjo-code-block t))
                (setq open (not open)))
            (when open
              (add-face-text-property line-beg line-end 'banjo-face-code-block t)
              (add-text-properties line-beg line-end '(banjo-code-block t)))))
        (forward-line 1)))))

(defun banjo--update-code-blocks (text)
  "Update code block state from streamed TEXT."
  (let* ((data (concat banjo--code-line-buffer text)))
    (when (> (length data) banjo--code-line-buffer-max)
      (if (string-match-p "\n" data)
          (setq data (substring data (- (length data) banjo--code-line-buffer-max)))
        (setq data (substring data 0 banjo--code-line-buffer-max))))
    (let* ((parts (split-string data "\n"))
           (line-count (length parts))
           (i 0))
      (while (< i (1- line-count))
        (let ((line (nth i parts)))
          (when (string-match-p "^\\s-*```" line)
            (setq banjo--code-block-open (not banjo--code-block-open))))
        (setq i (1+ i)))
      (setq banjo--code-line-buffer (nth (1- line-count) parts)))))

;; State

(defvar banjo--process nil "Daemon process.")
(defvar banjo--websocket nil "WebSocket connection.")
(defvar banjo--session-id nil "Current session ID.")
(defvar banjo--next-id 1 "Next JSON-RPC request ID.")
(defvar banjo--pending-requests (make-hash-table :test 'equal) "Pending requests.")
(defvar banjo--port nil "Daemon port.")
(defvar banjo--state nil "Current state (engine, model, mode).")
(defvar banjo--streaming nil "Whether we're currently streaming output.")
(defvar banjo--tool-calls (make-hash-table :test 'equal) "Active tool calls.")
(defvar banjo--process-output ""
  "Accumulated output from the Banjo daemon process.")

;; Buffer names

(defvar banjo--output-buffer "*banjo*" "Output buffer name.")
(defvar banjo--input-buffer "*banjo-input*" "Input buffer name.")

(defvar banjo--source-checked nil
  "Non-nil when banjo source refresh check has run.")

(defun banjo--ensure-buffer-vars ()
  "Ensure internal buffer name variables are initialized."
  (unless (boundp 'banjo--output-buffer)
    (setq banjo--output-buffer "*banjo*"))
  (unless (boundp 'banjo--input-buffer)
    (setq banjo--input-buffer "*banjo-input*"))
  (unless (boundp 'banjo-input-mode-map)
    (setq banjo-input-mode-map (make-sparse-keymap))
    (define-key banjo-input-mode-map (kbd "RET") #'banjo-input-send)
    (define-key banjo-input-mode-map (kbd "C-c C-c") #'banjo-input-send)
    (define-key banjo-input-mode-map (kbd "C-c C-k") #'banjo-cancel)
    (define-key banjo-input-mode-map (kbd "C-j") #'newline)))

(defun banjo--refresh-elc-if-needed ()
  "Reload and recompile when source is newer than the loaded .elc."
  (unless banjo--source-checked
    (setq banjo--source-checked t)
    (let* ((loaded (or load-file-name (buffer-file-name)))
           (elc (and loaded (string-match-p "\\.elc\\'" loaded) loaded))
           (el (and elc (concat (file-name-sans-extension elc) ".el"))))
      (when (and el (file-exists-p el) (file-newer-than-file-p el elc))
        (condition-case err
            (progn
              (load el nil t)
              (byte-compile-file el)
              (message "Banjo: refreshed byte-compiled file"))
          (error
           (message "Banjo: failed to refresh byte-compiled file: %s" err)))))))

(banjo--refresh-elc-if-needed)

;; Mode line

(defvar banjo--mode-line-string ""
  "Mode line string for Banjo status.")

(defun banjo--update-mode-line ()
  "Update the mode line with current state."
  (let* ((engine (or (plist-get banjo--state :engine) "claude"))
         (model (or (plist-get banjo--state :model) ""))
         (mode (or (plist-get banjo--state :mode) "default"))
         (connected (and banjo--websocket (websocket-openp banjo--websocket))))
    (setq banjo--mode-line-string
          (if connected
              (format " [%s%s (%s)]"
                      engine
                      (if (string= model "") "" (concat "/" model))
                      mode)
            " [disconnected]"))
    (force-mode-line-update t)))

(defun banjo--input-header ()
  "Build the input header line."
  (let ((engine (or (plist-get banjo--state :engine) "claude"))
        (mode (banjo--display-mode (or (plist-get banjo--state :mode) "default")))
        (hints (or banjo-input-hints "")))
    (if (string= hints "")
        (format "Agent: %s  Auth: %s" engine mode)
      (format "Agent: %s  Auth: %s  %s" engine mode hints))))

(defun banjo--display-mode (mode)
  "Return user-facing MODE name."
  (cond
   ((string= mode "acceptEdits") "accept_edits")
   ((string= mode "bypassPermissions") "auto_approve")
   ((string= mode "plan") "plan_only")
   (t mode)))

;; Output buffer

(define-derived-mode banjo-mode special-mode "Banjo"
  "Major mode for Banjo output."
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local banjo--code-block-open nil)
  (setq-local banjo--code-line-buffer "")
  (setq-local font-lock-defaults '(banjo--font-lock-keywords))
  (setq-local font-lock-multiline t)
  (font-lock-mode 1))

(defvar banjo-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'banjo-input-send)
    (define-key map (kbd "C-c C-c") #'banjo-input-send)
    (define-key map (kbd "C-c C-k") #'banjo-cancel)
    (define-key map (kbd "C-j") #'newline)
    map)
  "Keymap for Banjo input.")

(define-derived-mode banjo-input-mode text-mode "BanjoInput"
  "Major mode for Banjo input."
  (setq-local header-line-format '(:eval (banjo--input-header)))
  (setq-local display-line-numbers nil)
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(define-key banjo-mode-map (kbd "i") #'banjo-focus-input)
(define-key banjo-mode-map (kbd "RET") #'banjo-focus-input)

(defun banjo--get-output-buffer ()
  "Get or create the output buffer."
  (banjo--ensure-buffer-vars)
  (let ((buf (get-buffer-create banjo--output-buffer)))
    (with-current-buffer buf
      (unless (eq major-mode 'banjo-mode)
        (banjo-mode)))
    buf))

(defun banjo--get-input-buffer ()
  "Get or create the input buffer."
  (banjo--ensure-buffer-vars)
  (let ((buf (get-buffer-create banjo--input-buffer)))
    (with-current-buffer buf
      (unless (eq major-mode 'banjo-input-mode)
        (banjo-input-mode)))
    buf))

(defun banjo--append-output (text &optional face)
  "Append TEXT to the output buffer with optional FACE."
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (let ((beg (point)))
          (insert text)
          (let ((end (point))
                (prev-open banjo--code-block-open))
            (banjo--update-code-blocks text)
            (when face
              (add-face-text-property beg end face t))
            (banjo--apply-code-blocks beg end prev-open)
            (banjo--apply-buttons beg end)
            (font-lock-ensure beg end)))
        (goto-char (point-max))))
    ;; Scroll to bottom in all windows showing buffer
    (dolist (win (get-buffer-window-list buf nil t))
      (with-selected-window win
        (goto-char (point-max))
        (recenter -1)))))

(defun banjo--append-user-message (text)
  "Append user TEXT to the output buffer with clear separation."
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (when (> (point-max) (point-min))
          (unless (bolp)
            (insert "\n"))
          (insert "\n"))
        (let ((beg (point)))
          (insert text)
          (let ((end (point)))
            (add-face-text-property beg end 'banjo-face-user t)
            (banjo--apply-buttons beg end)
            (font-lock-ensure beg end)))
        (unless (bolp)
          (insert "\n"))
        (insert "\n")))))

(defun banjo--append-status (text)
  "Append status TEXT to the output buffer."
  (banjo--append-output (concat text "\n") 'banjo-face-tool))

(defun banjo--clear-output ()
  "Clear the output buffer."
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (setq banjo--code-block-open nil)
        (setq banjo--code-line-buffer "")
        (erase-buffer)))))

;; Panel

(defun banjo--show-panel ()
  "Show the Banjo panel."
  (banjo--ensure-buffer-vars)
  (let* ((buf (banjo--get-output-buffer))
         (input-buf (banjo--get-input-buffer))
         (side (if (eq banjo-panel-position 'left) 'left 'right))
         (selected (selected-window))
         (out-win (display-buffer-in-side-window
                   buf
                   `((side . ,side)
                     (slot . 0)
                     (window-width . ,banjo-panel-width)
                     (preserve-size . (t . nil)))))
         (input-win (display-buffer-in-side-window
                     input-buf
                     `((side . ,side)
                       (slot . 1)
                       (window-width . ,banjo-panel-width)
                       (window-height . ,banjo-input-height)
                       (preserve-size . (nil . t))))))
    (when (window-live-p out-win)
      (set-window-parameter out-win 'no-other-window t)
      (set-window-dedicated-p out-win t))
    (when (window-live-p input-win)
      (set-window-parameter input-win 'no-other-window t)
      (set-window-parameter input-win 'window-size-fixed 'height)
      (set-window-dedicated-p input-win t))
    (when (window-live-p selected)
      (select-window selected))))

(defun banjo--hide-panel ()
  "Hide the Banjo panel."
  (let ((input-win (get-buffer-window banjo--input-buffer))
        (out-win (get-buffer-window banjo--output-buffer)))
    (when (window-live-p input-win)
      (delete-window input-win))
    (when (window-live-p out-win)
      (delete-window out-win))))

;;;###autoload
(defun banjo-toggle ()
  "Toggle the Banjo panel."
  (interactive)
  (if (get-buffer-window banjo--output-buffer)
      (banjo--hide-panel)
    (banjo-focus-input)))

;;;###autoload
(defun banjo-focus-input ()
  "Show the Banjo panel and focus the input buffer."
  (interactive)
  (banjo--show-panel)
  (let ((input-win (get-buffer-window banjo--input-buffer)))
    (when (window-live-p input-win)
      (select-window input-win))))

;; WebSocket

(defun banjo--send-request (method params &optional callback)
  "Send a JSON-RPC request with METHOD and PARAMS. Call CALLBACK with result."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (let ((id banjo--next-id))
      (setq banjo--next-id (1+ banjo--next-id))
      (when callback
        (puthash id callback banjo--pending-requests))
      (websocket-send-text
       banjo--websocket
       (json-encode `((jsonrpc . "2.0")
                      (id . ,id)
                      (method . ,method)
                      (params . ,params)))))))

(defun banjo--send-notification (method params)
  "Send a JSON-RPC notification with METHOD and PARAMS."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (websocket-send-text
     banjo--websocket
     (json-encode `((jsonrpc . "2.0")
                    (method . ,method)
                    (params . ,params))))))

(defun banjo--send-response (id result &optional err)
  "Send a JSON-RPC response for request ID with RESULT or ERR."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (let ((msg (if err
                   `((jsonrpc . "2.0") (id . ,id) (error . ,err))
                 `((jsonrpc . "2.0") (id . ,id) (result . ,result)))))
      (websocket-send-text banjo--websocket (json-encode msg)))))

(defun banjo--handle-message (frame)
  "Handle incoming WebSocket FRAME."
  (let* ((payload (websocket-frame-text frame))
         (msg (json-read-from-string payload))
         (id (alist-get 'id msg))
         (method (alist-get 'method msg))
         (result (alist-get 'result msg))
         (err (alist-get 'error msg)))
    (cond
     ;; Response to our request
     ((or result err)
      (let ((callback (gethash id banjo--pending-requests)))
        (when callback
          (remhash id banjo--pending-requests)
          (funcall callback result err))))
     ;; Request from server
     ((and method id)
      (banjo--handle-request msg))
     ;; Notification from server
     (method
      (banjo--handle-notification msg)))))

(defun banjo--handle-request (msg)
  "Handle a JSON-RPC request MSG from the server."
  (let ((id (alist-get 'id msg))
        (method (alist-get 'method msg))
        (params (alist-get 'params msg)))
    (cond
     ((string= method "session/request_permission")
      (banjo--handle-permission-request id params))
     (t
     (banjo--send-response id nil `((code . -32601) (message . "Method not found")))))))

(defconst banjo--default-permission-options
  '(((kind . "allow_once") (name . "Allow once") (optionId . "allow_once"))
    ((kind . "allow_always") (name . "Allow for session") (optionId . "allow_always"))
    ((kind . "reject_once") (name . "Deny") (optionId . "reject_once"))
    ((kind . "reject_always") (name . "Deny for session") (optionId . "reject_always")))
  "Fallback permission options.")

(defun banjo--permission-option-choices (options)
  "Build display choices from permission OPTIONS."
  (let ((i 0)
        (choices nil))
    (dolist (opt options (nreverse choices))
      (setq i (1+ i))
      (let* ((name (or (alist-get 'name opt) (alist-get 'optionId opt) "Option"))
             (kind (alist-get 'kind opt))
             (label (if kind
                        (format "%d) %s (%s)" i name kind)
                      (format "%d) %s" i name))))
        (push (cons label opt) choices)))))

(defun banjo--permission-outcome (option-id)
  "Build response outcome for OPTION-ID."
  (if option-id
      `((outcome . ((outcome . "selected") (optionId . ,option-id))))
    '((outcome . ((outcome . "cancelled"))))))

(defun banjo--handle-permission-request (id params)
  "Handle permission request with ID and PARAMS."
  (let* ((tool-call (alist-get 'toolCall params))
         (title (or (alist-get 'title tool-call) "Unknown tool"))
         (options (or (alist-get 'options params) banjo--default-permission-options))
         (choices (banjo--permission-option-choices options))
         (prompt (format "Allow %s: " title))
         (choice (completing-read prompt (mapcar #'car choices) nil t))
         (option (cdr (assoc choice choices)))
         (option-id (or (alist-get 'optionId option) (alist-get 'id option))))
    (banjo--send-response id (banjo--permission-outcome option-id))))

(defun banjo--handle-notification (msg)
  "Handle a JSON-RPC notification MSG."
  (let ((method (alist-get 'method msg))
        (params (alist-get 'params msg)))
    (cond
     ((string= method "session/update")
      (banjo--handle-session-update params))
     ((string= method "session/end")
      (setq banjo--streaming nil)
      (banjo--append-output "\n\n" 'shadow)))))

(defun banjo--handle-session-update (params)
  "Handle session/update notification with PARAMS."
  (let* ((update (alist-get 'update params))
         (update-type (alist-get 'sessionUpdate update)))
    (cond
     ((string= update-type "agent_message_chunk")
      (let* ((content (alist-get 'content update))
             (text (alist-get 'text content)))
        (when text
          (unless banjo--streaming
            (setq banjo--streaming t)
            (banjo--show-panel))
          (banjo--append-output text 'banjo-face-assistant))))
     ((string= update-type "agent_thought_chunk")
      (let* ((content (alist-get 'content update))
             (text (alist-get 'text content)))
        (when text
          (unless banjo--streaming
            (setq banjo--streaming t)
            (banjo--show-panel))
          (banjo--append-output text 'banjo-face-thought))))
     ((string= update-type "tool_call")
      (let ((tool-id (alist-get 'toolCallId update))
            (title (alist-get 'title update)))
        (puthash tool-id title banjo--tool-calls)
        (banjo--append-output (format "\n%s %s" "." title) 'banjo-face-tool)))
     ((string= update-type "tool_call_update")
      (let* ((tool-id (alist-get 'toolCallId update))
             (status (alist-get 'status update))
             (title (gethash tool-id banjo--tool-calls)))
        (when title
          (let* ((icon (cond
                        ((string= status "completed") "v")
                        ((string= status "failed") "x")
                        ((string= status "running") ">")
                        ((string= status "pending") ".")
                        (t ".")))
                 (face (cond
                        ((string= status "completed") 'banjo-face-tool-success)
                        ((string= status "failed") 'banjo-face-tool-fail)
                        (t 'banjo-face-tool-pending))))
            (banjo--append-output (format " -> %s\n" icon) face)))))
     ((string= update-type "current_mode_update")
      (plist-put banjo--state :mode (alist-get 'currentModeId update))
      (banjo--update-mode-line))
     ((string= update-type "current_model_update")
      (plist-put banjo--state :model (alist-get 'currentModelId update))
      (banjo--update-mode-line)))))

;; Daemon management

(defun banjo--find-lockfile ()
  "Find the lockfile for the current directory."
  (let ((dir (or (locate-dominating-file default-directory ".banjo.lock")
                 default-directory)))
    (expand-file-name ".banjo.lock" dir)))

(defun banjo--read-lockfile ()
  "Read port from lockfile if it exists."
  (let ((lockfile (banjo--find-lockfile)))
    (when (file-exists-p lockfile)
      (with-temp-buffer
        (insert-file-contents lockfile)
        (let ((data (json-read)))
          (alist-get 'port data))))))

(defun banjo--start-daemon ()
  "Start the Banjo daemon."
  (let ((cmd (list banjo-binary "--nvim")))
    (setq banjo--process
          (make-process
           :name "banjo"
           :buffer "*banjo-daemon*"
           :command cmd
           :filter #'banjo--process-filter
           :sentinel #'banjo--process-sentinel))))

(defun banjo--process-filter (_proc output)
  "Process filter for daemon OUTPUT."
  (setq banjo--process-output (concat banjo--process-output output))
  (let* ((buf banjo--process-output)
         (lines (split-string buf "\n"))
         (complete (if (string-suffix-p "\n" buf) lines (butlast lines)))
         (rest (if (string-suffix-p "\n" buf) "" (car (last lines)))))
    (setq banjo--process-output rest)
    (dolist (line complete)
      (let ((trimmed (string-trim line)))
        (when (and trimmed (not (string-empty-p trimmed)))
          (cond
           ((string-match "ready:\\([0-9]+\\)" trimmed)
            (let ((port (string-to-number (match-string 1 trimmed))))
              (setq banjo--port port)
              (banjo--connect port)))
           (t
            (let ((msg (condition-case nil
                           (json-read-from-string trimmed)
                         (error nil))))
              (when msg
                (let ((method (alist-get 'method msg))
                      (params (alist-get 'params msg)))
                  (when (and (stringp method) (string= method "ready"))
                    (let* ((port (or (alist-get 'mcp_port params)
                                     (alist-get 'port params)))
                           (num (and port (if (numberp port) port (string-to-number port)))))
                      (when (and num (> num 0))
                        (setq banjo--port num)
                        (banjo--connect num))))))))))))))
(defun banjo--process-sentinel (_proc event)
  "Process sentinel for daemon PROC, handling EVENT."
  (when (string-match-p "\\(finished\\|exited\\|killed\\)" event)
    (setq banjo--process nil)
    (setq banjo--port nil)
    (message "Banjo daemon stopped")))

(defun banjo--connect (port)
  "Connect to daemon at PORT via WebSocket."
  (setq banjo--websocket
        (websocket-open
         (format "ws://127.0.0.1:%d/acp" port)
         :on-message (lambda (_ws frame) (banjo--handle-message frame))
         :on-open (lambda (_ws) (banjo--on-connect))
         :on-close (lambda (_ws) (banjo--on-disconnect)))))

(defun banjo--on-connect ()
  "Handle WebSocket connection."
  ;; Send initialize request
  (banjo--send-request
   "initialize"
   '((protocolVersion . 1)
     (clientCapabilities . nil)
     (clientInfo . ((name . "banjo-emacs") (version . "0.1.0"))))
   (lambda (result _err)
     (when result
       ;; Store agent info
       (when-let ((agent-info (alist-get 'agentInfo result)))
         (plist-put banjo--state :version (alist-get 'version agent-info)))
       ;; Create session
       (banjo--send-request
        "session/new"
        `((cwd . ,(expand-file-name default-directory)))
        (lambda (sess-result _sess-err)
          (when sess-result
            (setq banjo--session-id (alist-get 'sessionId sess-result))
            (when-let ((modes (alist-get 'modes sess-result)))
              (plist-put banjo--state :mode (alist-get 'currentModeId modes)))
            (banjo--update-mode-line)
            (message "Banjo connected"))))))))

(defun banjo--on-disconnect ()
  "Handle WebSocket disconnection."
  (setq banjo--websocket nil)
  (setq banjo--session-id nil)
  (banjo--update-mode-line)
  (message "Banjo disconnected"))

;; Commands

(defun banjo--send-text (prompt)
  "Send PROMPT to the agent and append to output."
  (unless banjo--session-id
    (user-error "Banjo not connected. Run M-x banjo-start"))
  (banjo--show-panel)
  (banjo--append-user-message prompt)
  (setq banjo--streaming nil)
  (banjo--send-notification
   "session/prompt"
   `((sessionId . ,banjo--session-id)
     (prompt . [((type . "text") (text . ,prompt))]))))

(defvar banjo--command-table (make-hash-table :test 'equal)
  "Slash command handlers.")

(defun banjo--register-command (name fn)
  "Register slash command NAME with handler FN."
  (puthash name fn banjo--command-table))

(defun banjo--parse-command (text)
  "Parse TEXT as a slash command.
Return (cmd . args) or nil."
  (let ((trimmed (string-trim text)))
    (when (string-prefix-p "/" trimmed)
      (let ((rest (string-trim (substring trimmed 1))))
        (if (string-empty-p rest)
            (cons "" "")
          (if (string-match "\\`\\([^ ]+\\)\\(?:\\s-+\\(.*\\)\\)?\\'" rest)
              (cons (match-string 1 rest) (or (match-string 2 rest) ""))
            (cons rest "")))))))

(defun banjo--dispatch-command (cmd args)
  "Dispatch slash command CMD with ARGS.
Return non-nil if handled locally."
  (let ((handler (gethash cmd banjo--command-table)))
    (when handler
      (funcall handler args)
      t)))

(defun banjo--normalize-mode (mode)
  "Normalize MODE to ACP ids."
  (cond
   ((or (string= mode "accept_edits") (string= mode "acceptEdits")) "acceptEdits")
   ((or (string= mode "auto_approve") (string= mode "bypassPermissions")) "bypassPermissions")
   ((or (string= mode "plan_only") (string= mode "plan")) "plan")
   (t mode)))

(defun banjo--command-help (_args)
  "Show slash command help."
  (dolist (line '("Available commands:"
                  "  /help - Show this help"
                  "  /version - Show banjo version"
                  "  /clear - Clear output buffer"
                  "  /new - Start new session"
                  "  /cancel - Cancel current request"
                  "  /model <name> - Set model"
                  "  /mode <name> - Set permission mode (default, accept_edits, auto_approve, plan_only)"
                  "  /claude - Switch to Claude"
                  "  /codex - Switch to Codex"))
    (banjo--append-status line)))

(defun banjo--command-version (_args)
  "Show banjo version."
  (let ((version (plist-get banjo--state :version)))
    (if (and version (not (string-empty-p version)))
        (banjo--append-status (format "Banjo %s" version))
      (banjo--append-status "Banjo version unknown (not connected)"))))

(defun banjo--command-clear (_args)
  "Clear output buffer."
  (banjo--clear-output))

(defun banjo--command-new (_args)
  "Start a new session."
  (if (not (and banjo--websocket (websocket-openp banjo--websocket)))
      (banjo--append-status "Not connected")
    (banjo--clear-output)
    (banjo--append-status "Starting new session...")
    (banjo--send-request
     "session/new"
     `((cwd . ,(expand-file-name default-directory)))
     (lambda (sess-result _sess-err)
       (when sess-result
         (setq banjo--session-id (alist-get 'sessionId sess-result))
         (when-let ((modes (alist-get 'modes sess-result)))
           (plist-put banjo--state :mode (alist-get 'currentModeId modes)))
         (banjo--update-mode-line)
         (banjo--append-status "New session ready"))))))

(defun banjo--command-cancel (_args)
  "Cancel current request."
  (if banjo--session-id
      (progn
        (banjo-cancel)
        (banjo--append-status "Cancelled"))
    (banjo--append-status "Not connected")))

(defun banjo--command-model (args)
  "Set model."
  (if (string-empty-p args)
      (banjo--append-status "Usage: /model <name>")
    (banjo-set-model args)
    (banjo--append-status (format "Model: %s" args))))

(defun banjo--command-mode (args)
  "Set permission mode."
  (if (string-empty-p args)
      (banjo--append-status "Usage: /mode <default|accept_edits|auto_approve|plan_only>")
    (let ((mode (banjo--normalize-mode args)))
      (banjo-set-mode mode)
      (banjo--append-status (format "Mode: %s" (banjo--display-mode mode))))))

(defun banjo--command-claude (_args)
  "Switch to Claude."
  (banjo-set-engine "claude")
  (banjo--append-status "Agent: claude"))

(defun banjo--command-codex (_args)
  "Switch to Codex."
  (banjo-set-engine "codex")
  (banjo--append-status "Agent: codex"))

(banjo--register-command "help" #'banjo--command-help)
(banjo--register-command "version" #'banjo--command-version)
(banjo--register-command "clear" #'banjo--command-clear)
(banjo--register-command "new" #'banjo--command-new)
(banjo--register-command "cancel" #'banjo--command-cancel)
(banjo--register-command "model" #'banjo--command-model)
(banjo--register-command "mode" #'banjo--command-mode)
(banjo--register-command "claude" #'banjo--command-claude)
(banjo--register-command "codex" #'banjo--command-codex)

;;;###autoload
(defun banjo-input-send ()
  "Send the current input buffer contents."
  (interactive)
  (let ((text (string-trim-right
               (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-blank-p text)
      (user-error "Prompt is empty"))
    (let ((cmd (banjo--parse-command text)))
      (if (and cmd (banjo--dispatch-command (car cmd) (cdr cmd)))
          nil
        (banjo--send-text text)))
    (let ((inhibit-read-only t))
      (erase-buffer))))

;;;###autoload
(defun banjo-start ()
  "Start Banjo daemon and connect."
  (interactive)
  (if (and banjo--websocket (websocket-openp banjo--websocket))
      (message "Banjo already connected")
    ;; Check for existing daemon via lockfile
    (let ((port (banjo--read-lockfile)))
      (if port
          (banjo--connect port)
        (banjo--start-daemon))))
  (banjo-focus-input))

;;;###autoload
(defun banjo-stop ()
  "Stop Banjo daemon and disconnect."
  (interactive)
  (when banjo--websocket
    (websocket-close banjo--websocket)
    (setq banjo--websocket nil))
  (when banjo--process
    (kill-process banjo--process)
    (setq banjo--process nil))
  (setq banjo--session-id nil)
  (setq banjo--port nil)
  (banjo--update-mode-line)
  (message "Banjo stopped"))

;;;###autoload
(defun banjo-send (prompt)
  "Send PROMPT to Claude/Codex."
  (interactive "sPrompt: ")
  (banjo--send-text prompt))

;;;###autoload
(defun banjo-send-region (start end prompt)
  "Send region from START to END with PROMPT."
  (interactive "r\nsPrompt: ")
  (let ((content (buffer-substring-no-properties start end))
        (file (or (buffer-file-name) "untitled")))
    (banjo--send-text (format "%s\n\nFile: %s\n```\n%s\n```" prompt file content))))

;;;###autoload
(defun banjo-cancel ()
  "Cancel the current request."
  (interactive)
  (when banjo--session-id
    (setq banjo--streaming nil)
    (banjo--send-notification
     "session/cancel"
     `((sessionId . ,banjo--session-id)))
    (message "Cancelled")))

;;;###autoload
(defun banjo-set-mode (mode)
  "Set permission MODE."
  (interactive
   (list (completing-read "Mode: " '("default" "acceptEdits" "bypassPermissions" "plan") nil t)))
  (when banjo--session-id
    (banjo--send-notification
     "session/set_mode"
     `((sessionId . ,banjo--session-id)
       (modeId . ,mode)))
    (plist-put banjo--state :mode mode)
    (banjo--update-mode-line)))

;;;###autoload
(defun banjo-set-model (model)
  "Set AI MODEL."
  (interactive
   (list (completing-read "Model: " '("sonnet" "opus" "haiku") nil t)))
  (when banjo--session-id
    (banjo--send-notification
     "session/set_model"
     `((sessionId . ,banjo--session-id)
       (modelId . ,model)))
    (plist-put banjo--state :model model)
    (banjo--update-mode-line)))

;;;###autoload
(defun banjo-set-engine (engine)
  "Set ENGINE (claude or codex)."
  (interactive
   (list (completing-read "Engine: " '("claude" "codex") nil t)))
  (when banjo--session-id
    (banjo--send-notification
     "session/set_config_option"
     `((sessionId . ,banjo--session-id)
       (configId . "route")
       (value . ,engine)))
    (plist-put banjo--state :engine engine)
    (banjo--update-mode-line)))

;; Keybindings

(defvar banjo-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "s" #'banjo-start)
    (define-key map "q" #'banjo-stop)
    (define-key map "p" #'banjo-send)
    (define-key map "r" #'banjo-send-region)
    (define-key map "c" #'banjo-cancel)
    (define-key map "i" #'banjo-focus-input)
    (define-key map "t" #'banjo-toggle)
    (define-key map "m" #'banjo-set-mode)
    (define-key map "M" #'banjo-set-model)
    (define-key map "e" #'banjo-set-engine)
    map)
  "Keymap for Banjo commands.")

(defvar banjo--doom-prefix-map nil
  "Keymap for Banjo Doom leader prefix.")

(defun banjo--doom-p ()
  "Return non-nil if running in Doom Emacs."
  (boundp 'doom-version))

(defun banjo--ensure-doom-prefix-map (prefix)
  "Ensure PREFIX is a keymap in `doom-leader-map` and return non-nil on success."
  (when (boundp 'doom-leader-map)
    (let* ((key (kbd prefix))
           (binding (lookup-key doom-leader-map key))
           (orig binding))
      (when (or (null binding) (eq binding 'undefined) (not (keymapp binding)))
        (setq binding (make-sparse-keymap))
        (define-key doom-leader-map key binding)
        (when (and orig (not (keymapp orig)))
          (message "Banjo: rebound leader %s to a keymap" prefix)))
      (when (keymapp binding)
        (setq banjo--doom-prefix-map binding)
        binding))))

(defun banjo--define-doom-leader-keys (prefix)
  "Define Doom leader bindings under PREFIX."
  (let ((map (banjo--ensure-doom-prefix-map prefix)))
    (when map
      (define-key map (kbd "b") #'banjo-toggle)
      (define-key map (kbd "s") #'banjo-send)
      (define-key map (kbd "v") #'banjo-send-region)
      (define-key map (kbd "c") #'banjo-cancel)
      (define-key map (kbd "i") #'banjo-focus-input)
      (define-key map (kbd "m") #'banjo-set-mode)
      (define-key map (kbd "M") #'banjo-set-model)
      (define-key map (kbd "e") #'banjo-set-engine)
      (define-key map (kbd "S") #'banjo-start)
      (define-key map (kbd "q") #'banjo-stop)
      (when (fboundp 'which-key-add-key-based-replacements)
        (let ((leader (if (boundp 'doom-leader-key) doom-leader-key "SPC")))
          (which-key-add-key-based-replacements
           (concat leader " " prefix) "ai agent")))
      t)))

(defun banjo--setup-doom-keybindings ()
  "Set up Doom Emacs keybindings using SPC a prefix."
  (with-eval-after-load 'doom-keybinds
    ;; Leader keybindings: SPC <prefix> ...
    (let ((prefix banjo-doom-leader-prefix))
      (if (banjo--define-doom-leader-keys prefix)
          t
        (message "Banjo: leader prefix %s unavailable; set `banjo-doom-leader-prefix`" prefix))))
  (with-eval-after-load 'evil
    ;; Panel buffer keybindings
    (banjo--evil-define-key 'normal banjo-mode-map
      "q" #'banjo--hide-panel
      "gr" #'banjo-toggle
      (kbd "C-c") #'banjo-cancel)))

(defun banjo--setup-evil-panel-bindings ()
  "Set up evil-mode bindings for the panel buffer."
  (eval-after-load 'evil
    '(banjo--evil-define-key 'normal banjo-mode-map
       "q" #'banjo--hide-panel
       "gr" #'banjo-toggle
       (kbd "C-c") #'banjo-cancel)))

(defun banjo--evil-define-key (state keymap &rest bindings)
  "Define Evil bindings without macro/function load hazards."
  (cond
   ((fboundp 'evil-define-key*)
    (apply #'evil-define-key* state keymap bindings))
   ((fboundp 'evil-define-key)
    (eval (cons 'evil-define-key (cons state (cons keymap bindings)))))
   (t nil)))

;;;###autoload
(defun banjo-setup-keybindings ()
  "Set up Banjo keybindings.
In Doom Emacs: SPC a prefix with nvim-style bindings.
Otherwise: C-c a prefix."
  (if (banjo--doom-p)
      (banjo--setup-doom-keybindings)
    (progn
      (global-set-key (kbd "C-c a") banjo-command-map)
      (banjo--setup-evil-panel-bindings))))

;; Auto-setup when loaded
(banjo-setup-keybindings)

(provide 'banjo)

;;; banjo.el ends here
