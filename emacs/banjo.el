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
(require 'seq)
(require 'subr-x)
(require 'cl-lib)

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

(defcustom banjo-render-idle-delay 0.05
  "Delay in seconds before rendering new output."
  :type 'number
  :group 'banjo)

(defcustom banjo-history-max 100
  "Maximum number of input history items to keep."
  :type 'integer
  :group 'banjo)

(defcustom banjo-history-dir (locate-user-emacs-file "banjo-history/")
  "Directory for per-project input history."
  :type 'directory
  :group 'banjo)

(defcustom banjo-autoscroll t
  "Whether to auto-scroll the output buffer."
  :type 'boolean
  :group 'banjo)

(defcustom banjo-enable-links t
  "Whether to detect and activate file/URL links in output."
  :type 'boolean
  :group 'banjo)

(defcustom banjo-tool-call-max nil
  "Maximum number of tool calls to retain, or nil for unlimited."
  :type '(choice (const nil) integer)
  :group 'banjo)

(defcustom banjo-link-check-exists t
  "Whether to check file existence before creating file links."
  :type 'boolean
  :group 'banjo)

(defcustom banjo-link-cache-ttl nil
  "Seconds to cache file-exists results, or nil for no expiry."
  :type '(choice (const nil) number)
  :group 'banjo)

(defcustom banjo-doom-leader-prefix "a"
  "Doom leader prefix for Banjo bindings (e.g. \"a\" -> SPC a ...)."
  :type 'string
  :group 'banjo)

(defcustom banjo-debug-log-file "/tmp/banjo-emacs.log"
  "File for debug logging. Set to nil to disable."
  :type '(choice (const nil) string)
  :group 'banjo)

(defcustom banjo-permission-auto-approve 'auto
  "Whether to auto-approve permission prompts.
When set to \\='auto, only auto-approve in batch/noninteractive mode."
  :type '(choice (const auto) (const t) (const nil))
  :group 'banjo)

(defcustom banjo-auto-recompile t
  "Auto-recompile banjo.el when the .el is newer than the loaded .elc."
  :type 'boolean
  :group 'banjo)

;; Debug logging

(defvar banjo--debug-log-buffer nil
  "Ring buffer for recent log entries.")

(defvar banjo--source-checked nil
  "Non-nil if source/bytecode freshness has been checked.")

(defun banjo--refresh-elc-if-needed ()
  "Reload and recompile if the .el is newer than the loaded .elc."
  (when (and banjo-auto-recompile (not banjo--source-checked))
    (setq banjo--source-checked t)
    (let* ((loaded (or load-file-name (buffer-file-name)))
           (el (cond
                ((and loaded (string-match-p "\\.elc\\'" loaded))
                 (concat (file-name-sans-extension loaded) ".el"))
                (loaded)))
           (elc (and el (concat (file-name-sans-extension el) ".elc"))))
      (when (and el (file-exists-p el) elc)
        (when (or (not (file-exists-p elc))
                  (file-newer-than-file-p el elc))
          (condition-case err
              (progn
                (load el nil t)
                (byte-compile-file el)
                (message "Banjo: refreshed byte-compiled file"))
            (error
             (message "Banjo: failed to refresh byte-compiled file: %s" err))))))))

(banjo--refresh-elc-if-needed)

(defun banjo--log (fmt &rest args)
  "Log FMT with ARGS to debug file if enabled."
  (when banjo-debug-log-file
    (let ((msg (format "[%s] %s\n"
                       (format-time-string "%H:%M:%S")
                       (apply #'format fmt args))))
      (append-to-file msg nil banjo-debug-log-file))))

(defun banjo--log-send (method params)
  "Log outgoing METHOD with PARAMS."
  (banjo--log ">>> %s %S" method (if (> (length (format "%S" params)) 200)
                                     (substring (format "%S" params) 0 200)
                                   params)))

(defun banjo--log-recv (msg)
  "Log incoming MSG."
  (let* ((method (alist-get 'method msg))
         (id (alist-get 'id msg))
         (result (alist-get 'result msg))
         (err (alist-get 'error msg)))
    (cond
     (method (banjo--log "<<< %s %S" method
                         (let ((p (format "%S" (alist-get 'params msg))))
                           (if (> (length p) 200) (substring p 0 200) p))))
     (result (banjo--log "<<< response id=%s result=%S" id
                         (let ((r (format "%S" result)))
                           (if (> (length r) 200) (substring r 0 200) r))))
     (err (banjo--log "<<< error id=%s %S" id err)))))

;; Forward declarations (defined later, used by banjo-dump-state)
(defvar banjo--websocket)
(defvar banjo--session-id)
(defvar banjo--streaming)
(defvar banjo--stream-start-time)
(defvar banjo--state)
(defvar banjo--pending-requests)
(defvar banjo--tool-calls)
(defvar banjo--process)
(defvar banjo--port)
(defvar banjo--command-table)
(defvar banjo-input-mode-map)

(defun banjo-dump-state ()
  "Dump current banjo state to log file for debugging."
  (interactive)
  (let ((state `((connected . ,(not (null banjo--websocket)))
                 (session-id . ,banjo--session-id)
                 (streaming . ,banjo--streaming)
                 (stream-start . ,banjo--stream-start-time)
                 (state . ,banjo--state)
                 (pending-requests . ,(hash-table-count banjo--pending-requests))
                 (tool-calls . ,(hash-table-count banjo--tool-calls))
                 (process . ,(and banjo--process (process-status banjo--process)))
                 (port . ,banjo--port))))
    (banjo--log "=== STATE DUMP ===\n%s" (pp-to-string state))
    (message "State dumped to %s" banjo-debug-log-file)))

;; Faces

(defface banjo-face-user
  '((t :inherit font-lock-string-face))
  "Face for user prompts."
  :group 'banjo)

(defface banjo-face-input
  '((t :inherit font-lock-string-face :slant italic))
  "Face for input buffer text."
  :group 'banjo)

(defface banjo-face-assistant
  '((t :inherit font-lock-doc-face :slant italic))
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

(defface banjo-face-timer
  '((t :inherit warning :weight bold))
  "Face for streaming timer in mode line."
  :group 'banjo)

(defface banjo-face-tool-output
  '((t :inherit font-lock-string-face))
  "Face for tool output content."
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
    ("^\\s-*○\\s-+.*→\\s-*\\(✓\\)\\s-*$" (1 'banjo-face-tool-success))
    ("^\\s-*○\\s-+.*→\\s-*\\(✗\\)\\s-*$" (1 'banjo-face-tool-fail))
    ("^\\s-*○\\s-+.*$" . 'banjo-face-tool)
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

(defvar-local banjo--code-block-open nil
  "Non-nil when inside a fenced code block.")

(defvar-local banjo--render-pos nil
  "Last rendered position in the output buffer.")

(defvar-local banjo--render-timer nil
  "Idle timer for deferred rendering.")

(defvar-local banjo--path-exists-cache (make-hash-table :test 'equal)
  "Cache of file existence checks.")

(defun banjo--resolve-path (path)
  "Resolve PATH against the current buffer default directory."
  (if (file-name-absolute-p path)
      path
    (expand-file-name path default-directory)))

(defun banjo--open-file-link (path line col)
  "Open PATH at LINE and optional COL."
  (let ((file (banjo--resolve-path path))
        (line-num (and (numberp line) line))
        (col-num (and (numberp col) col)))
    (when (file-exists-p file)
      (find-file-other-window file)
      (goto-char (point-min))
      (when line-num
        (forward-line (max 0 (1- line-num))))
      (when col-num
        (move-to-column (max 0 (1- col-num)))))))

(defun banjo--make-link-button (beg end action help)
  "Create a link button from BEG to END."
  (make-text-button
   beg end
   'action action
   'follow-link t
   'help-echo help
   'face 'banjo-face-link
   'banjo-link t))

(defun banjo--file-exists-cached (path)
  "Return cached file existence for PATH."
  (let* ((cache banjo--path-exists-cache)
         (entry (gethash path cache)))
    (if entry
        (let ((ts (car entry))
              (val (cdr entry)))
          (if (and banjo-link-cache-ttl ts
                   (> (- (float-time) ts) banjo-link-cache-ttl))
              (let ((fresh (file-exists-p path)))
                (puthash path (cons (float-time) fresh) cache)
                fresh)
            val))
      (let ((val (file-exists-p path)))
        (puthash path (cons (float-time) val) cache)
        val))))

(defun banjo--check-exists-p (path)
  "Return non-nil if PATH should be checked for existence."
  (and banjo-link-check-exists
       (not (file-remote-p default-directory))
       (not (file-remote-p path))))

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
            (when (and (or (not (banjo--check-exists-p abs))
                           (banjo--file-exists-cached abs))
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
            (when (and (or (not (banjo--check-exists-p abs))
                           (banjo--file-exists-cached abs))
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
            (when (and (or (not (banjo--check-exists-p abs))
                           (banjo--file-exists-cached abs))
                       (not (get-text-property b 'banjo-link))
                       (not (get-text-property b 'banjo-code-block)))
              (banjo--make-link-button
               b e
               (lambda (_btn) (banjo--open-file-link path 1 nil))
               (format "Open %s" path)))))))))

(defun banjo--apply-code-blocks (beg end start-open)
  "Apply code block faces between BEG and END.
Return final open state."
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
        (forward-line 1)))
    open))

(defun banjo--cancel-render-timer ()
  "Cancel deferred render timer for current buffer."
  (when banjo--render-timer
    (cancel-timer banjo--render-timer)
    (setq banjo--render-timer nil)))

(defun banjo--flush-render (buf)
  "Apply deferred rendering for BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq banjo--render-timer nil)
      (let ((beg (or banjo--render-pos (point-min)))
            (end (point-max)))
        (when (< beg end)
          (let ((inhibit-read-only t))
            (let ((open (banjo--apply-code-blocks beg end banjo--code-block-open)))
              (setq banjo--code-block-open open))
            (banjo--apply-buttons beg end)
            (font-lock-ensure beg end)
            (setq banjo--render-pos end)))))))

(defun banjo--queue-render ()
  "Queue deferred rendering for the output buffer."
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (unless banjo--render-pos
        (setq banjo--render-pos (point-min)))
      (unless banjo--render-timer
        (setq banjo--render-timer
              (if banjo--streaming
                  (run-with-timer banjo-render-idle-delay nil
                                  #'banjo--flush-render buf)
                (run-with-idle-timer banjo-render-idle-delay nil
                                     #'banjo--flush-render buf)))))))

;; State

(defvar banjo--process nil "Daemon process.")
(defvar banjo--websocket nil "WebSocket connection.")
(defvar banjo--session-id nil "Current session ID.")
(defvar banjo--next-id 1 "Next JSON-RPC request ID.")
(defvar banjo--pending-requests (make-hash-table :test 'equal) "Pending requests.")
(defvar banjo--port nil "Daemon port.")
(defvar banjo--state '(:engine nil :model nil :mode nil)
  "Current state (engine, model, mode).")
(defvar banjo--streaming nil "Whether we're currently streaming output.")
(defvar banjo--tool-calls (make-hash-table :test 'equal)
  "Active tool calls. Maps tool-id to plist with markers and status.")
(defvar banjo--tool-call-order nil
  "Tool call IDs in creation order (oldest first).")
(defvar banjo--process-output ""
  "Accumulated output from the Banjo daemon process.")
(defvar banjo--last-cwd nil "Last working directory for input/history.")

;; Buffer names

(defvar banjo--output-buffer "*banjo*" "Output buffer name.")
(defvar banjo--input-buffer "*banjo-input*" "Input buffer name.")

(defun banjo--ensure-buffer-vars ()
  "Ensure internal buffer name variables are initialized."
  (unless (boundp 'banjo--output-buffer)
    (setq banjo--output-buffer "*banjo*"))
  (unless (boundp 'banjo--input-buffer)
    (setq banjo--input-buffer "*banjo-input*"))
  (unless (boundp 'banjo-input-mode-map)
    (setq banjo-input-mode-map (banjo--make-input-keymap))))

;; Mode line

(defvar banjo--mode-line-left ""
  "Left-side mode line string for Banjo status.")

(defvar banjo--mode-line-timer ""
  "Right-side mode line timer string.")

(defconst banjo--mode-line-hints "RET send, C-j newline, / cmds"
  "Input hints shown in the Banjo input mode line.")

(defun banjo--mode-line-align-right (left right)
  "Return a mode line with LEFT text and RIGHT text aligned right."
  (if (string-empty-p right)
      left
    (list left
          (propertize " " 'display
                      `(space :align-to (- right ,(string-width right))))
          right)))

(defun banjo--output-mode-line ()
  "Return mode line for the output buffer."
  (let* ((hints banjo--mode-line-hints)
         (win (or (and (boundp 'mode-line-window) mode-line-window)
                  (get-buffer-window (current-buffer) t)))
         (width (if win (window-total-width win) 0)))
    (truncate-string-to-width hints width nil nil "...")))

(defun banjo--input-mode-line ()
  "Return mode line for the input buffer."
  (banjo--mode-line-align-right banjo--mode-line-left banjo--mode-line-timer))

(defun banjo--update-mode-line ()
  "Update the mode line with current state."
  (let* ((engine (or (plist-get banjo--state :engine) "claude"))
         (model (or (plist-get banjo--state :model) ""))
         (mode (or (plist-get banjo--state :mode) "default"))
         (connected (and banjo--websocket (websocket-openp banjo--websocket)))
         (elapsed (and banjo--stream-start-time
                       (floor (- (float-time) banjo--stream-start-time)))))
    (setq banjo--mode-line-left
          (if connected
              (format " [%s%s (%s)]"
                      engine
                      (if (string= model "") "" (concat "/" model))
                      (banjo--display-mode mode))
            " [disconnected]"))
    (setq banjo--mode-line-timer (if elapsed (format "%ds" elapsed) ""))
    (force-mode-line-update t)))

(defvar banjo--stream-start-time nil
  "Stream start time in seconds, or nil when idle.")

(defvar banjo--stream-timer nil
  "Timer for streaming status updates.")

(defun banjo--ensure-stream-timer ()
  (unless banjo--stream-timer
    (setq banjo--stream-timer
          (run-with-timer 1 1 #'banjo--update-mode-line))))

(defun banjo--stop-stream-timer ()
  (when banjo--stream-timer
    (cancel-timer banjo--stream-timer)
    (setq banjo--stream-timer nil)))

(defun banjo--start-streaming ()
  (setq banjo--streaming t)
  (setq banjo--stream-start-time (float-time))
  (banjo--ensure-stream-timer)
  (banjo--update-mode-line))

(defun banjo--stop-streaming ()
  (setq banjo--streaming nil)
  (setq banjo--stream-start-time nil)
  (banjo--stop-stream-timer)
  (banjo--update-mode-line))

(defvar banjo--history nil
  "Input history list, newest first.")

(defvar banjo--history-index 0
  "Current history navigation index.")

(defvar banjo--history-temp nil
  "Temporary input text saved before history navigation.")

(defvar banjo--history-key nil
  "Current history key for the active project.")

(defun banjo--history-key-for-dir (dir)
  (secure-hash 'sha1 (expand-file-name dir)))

(defun banjo--history-file (dir)
  (expand-file-name (concat (banjo--history-key-for-dir dir) ".el")
                    banjo-history-dir))

(defun banjo--history-load (dir)
  (let ((file (banjo--history-file dir)))
    (setq banjo--history nil
          banjo--history-index 0
          banjo--history-temp nil)
    (when (file-exists-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (let ((data (read (current-buffer))))
              (when (and (listp data) (cl-every #'stringp data))
                (setq banjo--history data))))
        (error nil)))))

(defun banjo--history-save (dir)
  (let ((file (banjo--history-file dir)))
    (make-directory banjo-history-dir t)
    (with-temp-file file
      (prin1 banjo--history (current-buffer)))))

(defun banjo--history-ensure (dir)
  (let ((key (banjo--history-key-for-dir dir)))
    (unless (and banjo--history-key (string= banjo--history-key key))
      (setq banjo--history-key key)
      (banjo--history-load dir))))

(defun banjo--history-add (text)
  (let* ((trimmed (string-trim text))
         (latest (car banjo--history)))
    (when (and (not (string-empty-p trimmed))
               (not (and latest (string= latest trimmed))))
      (setq banjo--history (cons trimmed banjo--history))
      (when (> (length banjo--history) banjo-history-max)
        (setcdr (nthcdr (1- banjo-history-max) banjo--history) nil))
      (setq banjo--history-index 0
            banjo--history-temp nil)
      (when banjo--history-key
        (banjo--history-save default-directory)))))

(defun banjo--set-input-text (text)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (when text
      (insert text))))

(defun banjo-history-prev ()
  "Replace input with previous history item."
  (interactive)
  (banjo--history-ensure default-directory)
  (when (null banjo--history)
    (user-error "No history"))
  (when (= banjo--history-index 0)
    (setq banjo--history-temp (buffer-string)))
  (let ((next (1+ banjo--history-index)))
    (when (> next (length banjo--history))
      (user-error "Oldest history entry"))
    (setq banjo--history-index next)
    (banjo--set-input-text (nth (1- banjo--history-index) banjo--history))))

(defun banjo-history-next ()
  "Replace input with next history item."
  (interactive)
  (banjo--history-ensure default-directory)
  (when (= banjo--history-index 0)
    (user-error "Newest history entry"))
  (let ((next (1- banjo--history-index)))
    (setq banjo--history-index next)
    (if (= banjo--history-index 0)
        (banjo--set-input-text banjo--history-temp)
      (banjo--set-input-text (nth (1- banjo--history-index) banjo--history)))))

(defun banjo--display-mode (mode)
  "Return user-facing MODE name."
  (cond
   ((string= mode "acceptEdits") "accept_edits")
   ((string= mode "bypassPermissions") "auto_approve")
   ((string= mode "plan") "plan_only")
   (t mode)))

;; Output buffer

(defvar banjo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "z" #'banjo-toggle-fold)
    (define-key map (kbd "TAB") #'banjo-toggle-fold)
    (define-key map [double-mouse-1] #'banjo-toggle-fold-at-event)
    map)
  "Keymap for `banjo-mode'.")

(define-derived-mode banjo-mode special-mode "Banjo"
  "Major mode for Banjo output."
  :keymap banjo-mode-map
  (setq-local buffer-read-only t)
  (setq-local mode-line-format '(:eval (banjo--output-mode-line)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local banjo--code-block-open nil)
  (setq-local banjo--render-pos nil)
  (setq-local banjo--path-exists-cache (make-hash-table :test 'equal))
  (setq-local font-lock-defaults '(banjo--font-lock-keywords))
  (setq-local font-lock-multiline t)
  (add-to-invisibility-spec '(banjo-fold . t))
  (font-lock-mode 1))

(defun banjo-input-maybe-complete ()
  "Insert / and trigger completion if at start of line."
  (interactive)
  (insert "/")
  (when (string-prefix-p "/" (buffer-substring-no-properties
                               (line-beginning-position) (point)))
    (completion-at-point)))

(defun banjo--make-input-keymap ()
  "Create keymap for `banjo-input-mode'."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'banjo-input-send)
    (define-key map (kbd "C-c C-c") #'banjo-input-send)
    (define-key map (kbd "C-c C-k") #'banjo-cancel)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "M-p") #'banjo-history-prev)
    (define-key map (kbd "M-n") #'banjo-history-next)
    (define-key map (kbd "<up>") #'banjo-history-prev)
    (define-key map (kbd "<down>") #'banjo-history-next)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "/") #'banjo-input-maybe-complete)
    map))

(defvar banjo-input-mode-map
  (banjo--make-input-keymap)
  "Keymap for Banjo input.")

(define-derived-mode banjo-input-mode text-mode "BanjoInput"
  "Major mode for Banjo input."
  (setq-local header-line-format nil)
  (setq-local mode-line-format '(:eval (banjo--input-mode-line)))
  (banjo--disable-line-numbers)
  (banjo--apply-input-style)
  (setq-local completion-at-point-functions '(banjo--completion-at-point))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(define-key banjo-mode-map (kbd "i") #'banjo-focus-input)
(define-key banjo-mode-map (kbd "RET") #'banjo-focus-input)
(define-key banjo-mode-map (kbd "/") #'banjo-input-slash)

(defun banjo--maybe-evil-insert ()
  (when (fboundp 'evil-insert-state)
    (evil-insert-state)))

(defun banjo-input-slash ()
  "Focus input and insert a slash, then show completions."
  (interactive)
  (banjo-focus-input)
  (insert "/")
  (completion-at-point))

(defun banjo--current-cwd ()
  (let ((buf (window-buffer (selected-window))))
    (with-current-buffer buf
      default-directory)))

(defun banjo--disable-line-numbers ()
  "Disable line numbers in the current buffer."
  (setq-local doom-disable-line-numbers t)
  (setq-local display-line-numbers nil)
  (when (boundp 'display-line-numbers-type)
    (setq-local display-line-numbers-type nil))
  (when (boundp 'line-number-display-limit-width)
    (setq-local line-number-display-limit-width 0))
  (when (fboundp 'display-line-numbers-mode)
    (display-line-numbers-mode -1)))

(defun banjo--apply-input-style ()
  "Apply input buffer styling."
  (setq-local font-lock-defaults nil)
  (setq-local face-remapping-alist '((default banjo-face-input)))
  (when (fboundp 'buffer-face-set)
    (buffer-face-set 'banjo-face-input))
  (font-lock-mode -1))

(defun banjo--command-names ()
  (let (names)
    (maphash (lambda (k _v) (push k names)) banjo--command-table)
    (sort names #'string<)))

(defun banjo--completion-at-point ()
  (let* ((bol (line-beginning-position))
         (text (buffer-substring-no-properties bol (point))))
    (when (and (string-prefix-p "/" text)
               (not (string-match-p "\\s-" (substring text 1))))
      (let ((start (+ bol 1))
            (end (point))
            (cmds (banjo--command-names)))
        (list start end cmds
              :exit-function #'banjo--completion-exit)))))

(defun banjo--completion-exit (_candidate status)
  "Handle completion with STATUS. Auto-send if finished."
  (when (eq status 'finished)
    ;; Small delay to let completion UI close, then send
    (run-at-time 0.01 nil #'banjo-input-send)))

(defun banjo--code-block-range ()
  (save-excursion
    (let ((start (progn
                   (beginning-of-line)
                   (re-search-backward "^\\s-*```" nil t))))
      (when start
        (goto-char start)
        (forward-line 1)
        (let ((beg (point))
              (end (re-search-forward "^\\s-*```" nil t)))
          (when end
            (let ((fin (progn (beginning-of-line) (point))))
              (when (< beg fin)
                (cons beg fin)))))))))

(defun banjo--find-fold-overlay (pos)
  (let ((found nil))
    (dolist (ov (overlays-at pos) found)
      (when (overlay-get ov 'banjo-fold)
        (setq found ov)))))

(defun banjo-toggle-code-fold ()
  "Toggle fold for the code block at point."
  (interactive)
  (let ((ov (banjo--find-fold-overlay (point))))
    (if ov
        (delete-overlay ov)
      (let ((range (banjo--code-block-range)))
        (unless range
          (user-error "No code block at point"))
        (let ((fold (make-overlay (car range) (cdr range))))
          (overlay-put fold 'banjo-fold t)
          (overlay-put fold 'invisible 'banjo-fold)
          (overlay-put fold 'isearch-open-invisible #'delete-overlay))))))

(defun banjo-toggle-fold ()
  "Toggle fold for code block or tool section at point."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (cond
     ;; Tool section header or output
     ((banjo--tool-id-at-point)
      (banjo-toggle-tool-fold))
     ;; Inside tool output - find overlay and toggle
     ((banjo--find-tool-overlay (point))
      (banjo-toggle-tool-fold))
     ;; Code block
     ((banjo--code-block-range)
      (banjo-toggle-code-fold))
     ;; Existing code fold overlay
     ((banjo--find-fold-overlay (point))
      (banjo-toggle-code-fold))
     (t
      (user-error "No foldable content at point")))))

;; Tool output folding

(defun banjo-toggle-fold-at-event (event)
  "Toggle fold at mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (banjo-toggle-fold))

(defun banjo--find-tool-overlay (pos)
  "Find tool fold overlay at POS."
  (let ((found nil))
    (dolist (ov (overlays-at pos) found)
      (when (overlay-get ov 'banjo-tool-fold)
        (setq found ov)))))

(defun banjo--tool-id-at-point ()
  "Return tool-id for the tool section at point, or nil."
  (or (get-text-property (point) 'banjo-tool-id)
      (when-let ((ov (banjo--find-tool-overlay (point))))
        (overlay-get ov 'banjo-tool-id))
      (let ((pos (point))
            (buf (current-buffer)))
        (catch 'found
          (maphash
           (lambda (id info)
             (let ((header-marker (plist-get info :header-marker))
                   (output-marker (plist-get info :output-marker)))
               (when (and header-marker output-marker
                          (eq (marker-buffer header-marker) buf)
                          (eq (marker-buffer output-marker) buf))
                 (let ((header-pos (marker-position header-marker))
                       (output-pos (marker-position output-marker)))
                   (when (and (<= header-pos pos) (<= pos output-pos))
                     (throw 'found id))))))
           banjo--tool-calls)
          nil))))

(defun banjo--tool-header-text (title status)
  "Build tool header line from TITLE and STATUS."
  (cond
   ((and status (string= status "completed"))
    (format "○ %s → ✓" title))
   ((and status (string= status "failed"))
    (format "○ %s → ✗" title))
   (t
    (format "○ %s" title))))

(defun banjo--update-tool-header (tool-id)
  "Update tool header line for TOOL-ID."
  (let* ((info (gethash tool-id banjo--tool-calls))
         (header-marker (plist-get info :header-marker))
         (title (plist-get info :title))
         (status (plist-get info :status)))
    (when (and header-marker (marker-buffer header-marker))
      (with-current-buffer (marker-buffer header-marker)
        (let ((pos (marker-position header-marker)))
          (when (<= pos (point-max))
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char pos)
                (let ((line-end (line-end-position)))
                  (delete-region (point) line-end)
                  (insert (banjo--tool-header-text title status))
                  (put-text-property pos (point) 'banjo-tool-id tool-id))))))))))

(defun banjo--create-tool-fold (tool-id &optional hidden)
  "Create fold overlay for TOOL-ID output."
  (let* ((info (gethash tool-id banjo--tool-calls))
         (header-marker (plist-get info :header-marker))
         (output-marker (plist-get info :output-marker)))
    (when (and header-marker output-marker
               (marker-buffer header-marker)
               (marker-buffer output-marker)
               (eq (marker-buffer header-marker) (marker-buffer output-marker)))
      (with-current-buffer (marker-buffer output-marker)
        (when-let ((existing (banjo--find-tool-overlay-by-id tool-id)))
          (delete-overlay existing))
        (let ((header-pos (marker-position header-marker))
              (output-pos (marker-position output-marker)))
          ;; Validate positions are within buffer
          (when (and (<= header-pos (point-max))
                     (<= output-pos (point-max)))
            ;; Output starts after header line, ends at output-marker
            (let* ((output-start (save-excursion
                                   (goto-char header-pos)
                                   (forward-line 1)
                                   (point)))
                   (output-end output-pos))
              (when (< output-start output-end)
                (let ((fold (make-overlay output-start output-end)))
                  (overlay-put fold 'banjo-tool-fold t)
                  (overlay-put fold 'banjo-tool-id tool-id)
                  (overlay-put fold 'evaporate t)
                  (overlay-put fold 'rear-advance t)
                  (overlay-put fold 'isearch-open-invisible #'delete-overlay)
                  (when hidden
                    (overlay-put fold 'invisible 'banjo-fold))
                  fold)))))))))

(defun banjo-toggle-tool-fold ()
  "Toggle fold for tool output at point."
  (interactive)
  (let ((tool-id (banjo--tool-id-at-point)))
    (if tool-id
        (when-let ((ov (or (banjo--find-tool-overlay-by-id tool-id)
                           (banjo--create-tool-fold tool-id t))))
          (banjo-toggle-tool-fold-overlay ov))
      (when-let ((ov (banjo--find-tool-overlay (point))))
        (banjo-toggle-tool-fold-overlay ov)))))

(defun banjo--find-tool-overlay-by-id (tool-id)
  "Find tool fold overlay by TOOL-ID."
  (with-current-buffer (banjo--get-output-buffer)
    (let ((found nil))
      (dolist (ov (overlays-in (point-min) (point-max)) found)
        (when (and (overlay-get ov 'banjo-tool-fold)
                   (string= (overlay-get ov 'banjo-tool-id) tool-id))
          (setq found ov))))))

(defun banjo-toggle-tool-fold-overlay (ov)
  "Toggle visibility of tool fold overlay OV."
  (let ((currently-hidden (overlay-get ov 'invisible)))
    (if currently-hidden
        (overlay-put ov 'invisible nil)
      (overlay-put ov 'invisible 'banjo-fold))))

(defun banjo--get-output-buffer ()
  "Get or create the output buffer."
  (banjo--ensure-buffer-vars)
  (let ((buf (get-buffer-create banjo--output-buffer)))
    (with-current-buffer buf
      (unless (eq major-mode 'banjo-mode)
        (banjo-mode))
      (setq-local mode-line-format '(:eval (banjo--output-mode-line)))
      (banjo--update-mode-line))
    buf))

(defun banjo--get-input-buffer ()
  "Get or create the input buffer."
  (banjo--ensure-buffer-vars)
  (let ((buf (get-buffer-create banjo--input-buffer)))
    (with-current-buffer buf
      (unless (eq major-mode 'banjo-input-mode)
        (banjo-input-mode)))
    (with-current-buffer buf
      (setq-local header-line-format nil)
      (setq-local mode-line-format '(:eval (banjo--input-mode-line)))
      (banjo--disable-line-numbers)
      (banjo--apply-input-style)
      (banjo--history-ensure default-directory))
    buf))

(defvar banjo--scroll-win-cache nil
  "Cached windows displaying the output buffer.")

(defvar banjo--scroll-win-cache-dirty t
  "Non-nil when scroll window cache needs refresh.")

(defvar banjo--scroll-win-cache-buf nil
  "Buffer associated with `banjo--scroll-win-cache'.")

(defun banjo--mark-scroll-win-cache-dirty (&rest _)
  (setq banjo--scroll-win-cache-dirty t))

(add-hook 'window-configuration-change-hook #'banjo--mark-scroll-win-cache-dirty)
(add-hook 'window-size-change-functions #'banjo--mark-scroll-win-cache-dirty)

(defun banjo--window-at-bottom-p (win)
  (with-selected-window win
    (>= (window-end win t) (point-max))))

(defun banjo--collect-scroll-windows (buf)
  (when banjo-autoscroll
    (let ((wins nil))
      (when (or banjo--scroll-win-cache-dirty
                (not (eq banjo--scroll-win-cache-buf buf)))
        (setq banjo--scroll-win-cache (get-buffer-window-list buf nil t))
        (setq banjo--scroll-win-cache-buf buf)
        (setq banjo--scroll-win-cache-dirty nil))
      (dolist (win banjo--scroll-win-cache wins)
        (when (and (window-live-p win)
                   (banjo--window-at-bottom-p win))
          (push win wins))))))

(defun banjo--scroll-windows-to-bottom (wins)
  (dolist (win wins)
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-max))
        (recenter -1)))))

(defun banjo--toggle-autoscroll ()
  "Toggle autoscroll in the output buffer."
  (setq banjo-autoscroll (not banjo-autoscroll))
  (banjo--update-mode-line)
  (message "Banjo autoscroll: %s" (if banjo-autoscroll "on" "off")))

(defun banjo--append-output (text &optional face)
  "Append TEXT to the output buffer with optional FACE."
  (let ((buf (banjo--get-output-buffer)))
    (let ((scroll-wins (banjo--collect-scroll-windows buf)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (let ((beg (point)))
            (insert text)
            (let ((end (point)))
              (when face
                (put-text-property beg end 'font-lock-face face))
              (banjo--queue-render)))
          (goto-char (point-max))))
      (banjo--scroll-windows-to-bottom scroll-wins))))

(defun banjo--append-user-message (text)
  "Append user TEXT to the output buffer with clear separation."
  (let ((buf (banjo--get-output-buffer)))
    (let ((scroll-wins (banjo--collect-scroll-windows buf)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (when (> (point-max) (point-min))
            (unless (bolp)
              (insert "\n"))
            (insert "\n"))
          (insert text)
          (banjo--queue-render)
          (unless (bolp)
            (insert "\n"))
          (insert "\n")))
      (banjo--scroll-windows-to-bottom scroll-wins))))

(defun banjo--append-status (text)
  "Append status TEXT to the output buffer."
  (banjo--append-output (concat text "\n") 'banjo-face-tool))

(defun banjo--ensure-blank-line ()
  "Ensure output buffer ends with a blank line for separation."
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (or (= (point) (point-min))
                    (looking-back "\n\n" (max (point-min) (- (point) 2))))
          (unless (bolp) (insert "\n"))
          (insert "\n"))))))

(defun banjo--cleanup-tool-calls ()
  "Free all markers in tool-calls hash table."
  (maphash (lambda (_id info)
             (let ((header-marker (plist-get info :header-marker))
                   (output-marker (plist-get info :output-marker)))
               (when header-marker (set-marker header-marker nil))
               (when output-marker (set-marker output-marker nil))))
           banjo--tool-calls)
  (clrhash banjo--tool-calls)
  (setq banjo--tool-call-order nil))

(defun banjo--drop-tool-call (tool-id info)
  "Remove TOOL-ID from tracking and free markers."
  (let ((header-marker (plist-get info :header-marker))
        (output-marker (plist-get info :output-marker)))
    (when header-marker (set-marker header-marker nil))
    (when output-marker (set-marker output-marker nil)))
  (remhash tool-id banjo--tool-calls))

(defun banjo--maybe-prune-tool-calls ()
  "Prune completed tool calls if above `banjo-tool-call-max`."
  (when (and banjo-tool-call-max
             (> (hash-table-count banjo--tool-calls) banjo-tool-call-max))
    (let ((max banjo-tool-call-max)
          (count (hash-table-count banjo--tool-calls))
          (pruned t))
      (while (and (> count max) pruned)
        (setq pruned nil)
        (let ((prev nil)
              (cur banjo--tool-call-order))
          (while cur
            (let* ((tool-id (car cur))
                   (info (gethash tool-id banjo--tool-calls))
                   (status (and info (plist-get info :status))))
              (cond
               ((null info)
                (if prev
                    (setcdr prev (cdr cur))
                  (setq banjo--tool-call-order (cdr cur)))
                (setq cur (if prev (cdr prev) banjo--tool-call-order)))
               ((or (string= status "completed")
                    (string= status "failed"))
                (banjo--drop-tool-call tool-id info)
                (setq count (1- count))
                (if prev
                    (setcdr prev (cdr cur))
                  (setq banjo--tool-call-order (cdr cur)))
                (setq pruned t)
                (setq cur nil))
               (t
                (setq prev cur)
                (setq cur (cdr cur)))))))))))

(defun banjo--clear-output ()
  "Clear the output buffer."
  (banjo--cleanup-tool-calls)
  (let ((buf (banjo--get-output-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (setq banjo--code-block-open nil)
        (setq banjo--render-pos nil)
        (clrhash banjo--path-exists-cache)
        (banjo--cancel-render-timer)
        (remove-overlays (point-min) (point-max) 'banjo-fold t)
        (remove-overlays (point-min) (point-max) 'banjo-tool-fold t)
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
      (set-window-parameter out-win 'mode-line-format '(:eval (banjo--output-mode-line)))
      (set-window-dedicated-p out-win t))
    (when (window-live-p input-win)
      (set-window-parameter input-win 'no-other-window t)
      (set-window-parameter input-win 'window-size-fixed 'height)
      (set-window-parameter input-win 'mode-line-format '(:eval (banjo--input-mode-line)))
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
  (setq banjo--last-cwd (banjo--current-cwd))
  (banjo--show-panel)
  (let ((input-win (get-buffer-window banjo--input-buffer)))
    (when (window-live-p input-win)
      (select-window input-win)
      (setq default-directory (or banjo--last-cwd default-directory))
      (banjo--history-ensure default-directory)
      (banjo--maybe-evil-insert))))

;; WebSocket

(defun banjo--make-request (method params &optional id)
  "Build a JSON-RPC message for METHOD and PARAMS.
Include ID when provided."
  (if id
      `((jsonrpc . "2.0")
        (id . ,id)
        (method . ,method)
        (params . ,params))
    `((jsonrpc . "2.0")
      (method . ,method)
      (params . ,params))))

(defun banjo--send-request (method params &optional callback)
  "Send a JSON-RPC request with METHOD and PARAMS. Call CALLBACK with result."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (let ((id banjo--next-id))
      (setq banjo--next-id (1+ banjo--next-id))
      (when callback
        (puthash id callback banjo--pending-requests))
      (banjo--log-send method params)
      (websocket-send-text
       banjo--websocket
       (json-encode (banjo--make-request method params id))))))

(defun banjo--send-notification (method params)
  "Send a JSON-RPC notification with METHOD and PARAMS."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (banjo--log-send method params)
    (websocket-send-text
     banjo--websocket
     (json-encode (banjo--make-request method params)))))

(defun banjo--send-response (id result &optional err)
  "Send a JSON-RPC response for request ID with RESULT or ERR."
  (when (and banjo--websocket (websocket-openp banjo--websocket))
    (let ((msg (if err
                   `((jsonrpc . "2.0") (id . ,id) (error . ,err))
                 `((jsonrpc . "2.0") (id . ,id) (result . ,result)))))
      (websocket-send-text banjo--websocket (json-encode msg)))))

(defun banjo--handle-message (frame)
  "Handle incoming WebSocket FRAME."
  (condition-case parse-err
      (let* ((payload (websocket-frame-text frame))
             (json-object-type 'alist)
             (json-array-type 'vector)
             (json-key-type 'symbol)
             (msg (json-read-from-string payload))
             (id (alist-get 'id msg))
             (method (alist-get 'method msg))
             (has-result (assoc 'result msg))
             (has-error (assoc 'error msg))
             (result (cdr has-result))
             (err (cdr has-error)))
        (banjo--log-recv msg)
        (cond
         ;; Response to our request (check key presence, not truthiness)
         ((or has-result has-error)
          (let ((callback (gethash id banjo--pending-requests)))
            (when callback
              (remhash id banjo--pending-requests)
              (funcall callback result err))))
         ;; Request from server
         ((and method id)
          (banjo--handle-request msg))
         ;; Notification from server
         (method
          (banjo--handle-notification msg))))
    (error
     (banjo--log "!!! parse error: %s" parse-err)
     (message "Banjo: message parse error: %s" parse-err))))

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
  "Build display choices from permission OPTIONS (list or vector)."
  (let ((i 0)
        (choices nil))
    (seq-doseq (opt options)
      (setq i (1+ i))
      (let* ((name (or (alist-get 'name opt) (alist-get 'optionId opt) "Option"))
             (kind (alist-get 'kind opt))
             (label (if kind
                        (format "%d) %s (%s)" i name kind)
                      (format "%d) %s" i name))))
        (push (cons label opt) choices)))
    (nreverse choices)))

(defun banjo--find-permission-option (options kinds)
  "Return first option whose kind or optionId is in KINDS."
  (seq-find
   (lambda (opt)
     (let* ((kind (alist-get 'kind opt))
            (opt-id (alist-get 'optionId opt))
            (kind-str (and kind (if (symbolp kind) (symbol-name kind) kind)))
            (id-str (and opt-id (if (symbolp opt-id) (symbol-name opt-id) opt-id))))
       (or (and kind-str (member kind-str kinds))
           (and id-str (member id-str kinds)))))
   options))

(defun banjo--permission-outcome (option-id)
  "Build response outcome for OPTION-ID."
  (if option-id
      `((outcome . ((outcome . "selected") (optionId . ,option-id))))
    '((outcome . ((outcome . "cancelled"))))))

(defvar banjo--pending-permission nil
  "Pending permission request plist (:id :tool-call :options).")

(defvar banjo--permission-prompt-timer nil
  "Timer used to prompt for permissions.")

(defun banjo--permission-active-p ()
  (and banjo--pending-permission t))

(defun banjo--permission-clear ()
  (setq banjo--pending-permission nil)
  (when banjo--permission-prompt-timer
    (cancel-timer banjo--permission-prompt-timer)
    (setq banjo--permission-prompt-timer nil))
  (message nil))

(defun banjo--permission-choose (kind)
  (interactive)
  (when-let* ((pending banjo--pending-permission)
              (id (plist-get pending :id))
              (options (plist-get pending :options))
              (opt (pcase kind
                     ('allow_once (banjo--find-permission-option options '("allow_once")))
                     ('allow_always (or (banjo--find-permission-option options '("allow_always"))
                                        (banjo--find-permission-option options '("allow_once"))))
                     ('reject_once (or (banjo--find-permission-option options '("reject_once"))
                                       (banjo--find-permission-option options '("reject_always"))))
                     (_ nil))))
    (if opt
        (banjo--send-response id (banjo--permission-outcome (or (alist-get 'optionId opt)
                                                                (alist-get 'id opt))))
      (banjo--send-response id nil `((code . -32602)
                                     (message . ,(format "Missing permission option for %s" kind)))))
    (banjo--permission-clear)))

(defun banjo--permission-cancel ()
  (interactive)
  (when-let ((pending banjo--pending-permission))
    (let ((id (plist-get pending :id)))
      (banjo--permission-clear)
      (banjo--send-response id (banjo--permission-outcome nil))
      (banjo--append-output "[cancelled]\n" 'banjo-face-tool))))

(defun banjo--permission-prompt ()
  "Prompt user to decide on a pending permission request."
  (setq banjo--permission-prompt-timer nil)
  (when-let* ((pending banjo--pending-permission)
              (tool-call (plist-get pending :tool-call))
              (title (or (alist-get 'title tool-call) "Unknown tool")))
    (if (active-minibuffer-window)
        (setq banjo--permission-prompt-timer
              (run-at-time 0.2 nil #'banjo--permission-prompt))
      (condition-case nil
          (let ((choice (read-char-choice
                         (format "Allow %s? (y=yes, a=always, n=no): " title)
                         '(?y ?a ?n ?\r ?\n))))
            (pcase choice
              ((or ?y ?\r ?\n) (banjo--permission-choose 'allow_once))
              (?a (banjo--permission-choose 'allow_always))
              (?n (banjo--permission-choose 'reject_once))))
        (quit (banjo--permission-cancel))))))

(defun banjo--permission-schedule-prompt ()
  "Schedule a permission prompt outside the websocket handler."
  (unless noninteractive
    (when banjo--permission-prompt-timer
      (cancel-timer banjo--permission-prompt-timer)
      (setq banjo--permission-prompt-timer nil))
    (setq banjo--permission-prompt-timer
          (run-with-idle-timer 0 nil #'banjo--permission-prompt))))

(defun banjo--permission-auto-approve-p ()
  (pcase banjo-permission-auto-approve
    ('auto noninteractive)
    ('t t)
    (_ nil)))

(defun banjo--handle-permission-request (id params)
  "Handle permission request with ID and PARAMS."
  (let* ((tool-call (alist-get 'toolCall params))
         (title (or (alist-get 'title tool-call) "Unknown tool"))
         (options (or (alist-get 'options params) banjo--default-permission-options)))
    ;; Show in output buffer
    (banjo--append-output (format "\n[?] %s\n" title) 'banjo-face-tool-pending)
    (if (banjo--permission-auto-approve-p)
        (let ((opt (banjo--find-permission-option options '("allow_once"))))
          (banjo--send-response id (banjo--permission-outcome (and opt (or (alist-get 'optionId opt)
                                                                           (alist-get 'id opt))))))
      (when banjo--pending-permission
        (banjo--permission-cancel))
      (setq banjo--pending-permission (list :id id :tool-call tool-call :options options))
      (raise-frame)
      (when (fboundp 'select-frame-set-input-focus)
        (select-frame-set-input-focus (selected-frame)))
      (banjo--permission-schedule-prompt))))

(defun banjo--handle-notification (msg)
  "Handle a JSON-RPC notification MSG."
  (let ((method (alist-get 'method msg))
        (params (alist-get 'params msg)))
    (cond
     ((string= method "session/update")
      (banjo--handle-session-update params))
     ((string= method "session/end")
      (banjo--stop-streaming)
      (banjo--append-output "\n\n" 'shadow))))
)

(defun banjo--handle-session-update (params)
  "Handle session/update notification with PARAMS."
  (let* ((update (alist-get 'update params))
         (update-type (alist-get 'sessionUpdate update)))
    (cond
     ((string= update-type "agent_message_chunk")
      (let* ((content (alist-get 'content update))
             (text (alist-get 'text content)))
        (when text
          (when (not banjo--streaming)
            (banjo--start-streaming)
            (banjo--show-panel)
            (banjo--ensure-blank-line))
          (banjo--append-output text 'banjo-face-assistant))))
     ((string= update-type "agent_thought_chunk")
      (let* ((content (alist-get 'content update))
             (text (alist-get 'text content)))
        (when text
          (unless banjo--streaming
            (banjo--start-streaming)
            (banjo--show-panel))
          (banjo--append-output text 'banjo-face-thought))))
     ((string= update-type "tool_call")
      (let ((tool-id (alist-get 'toolCallId update))
            (title (alist-get 'title update)))
        (unless banjo--streaming
          (banjo--start-streaming))
        (with-current-buffer (banjo--get-output-buffer)
          (let ((inhibit-read-only t)
                (header-marker (make-marker))
                (output-marker (make-marker)))
            (goto-char (point-max))
            (insert "\n")
            (set-marker header-marker (point))
            (insert (format "%s\n" (banjo--tool-header-text title "running")))
            (put-text-property (marker-position header-marker) (1- (point)) 'banjo-tool-id tool-id)
            (set-marker output-marker (point))
            ;; Make output-marker advance when text is inserted at it
            (set-marker-insertion-type output-marker t)
            (puthash tool-id
                     (list :title title
                           :header-marker header-marker
                           :output-marker output-marker
                           :status "running")
                     banjo--tool-calls)
            (setq banjo--tool-call-order
                  (nconc banjo--tool-call-order (list tool-id)))))))
     ((string= update-type "tool_call_update")
      (let* ((tool-id (alist-get 'toolCallId update))
             (status (alist-get 'status update))
             (content-arr (alist-get 'content update))
             (info (gethash tool-id banjo--tool-calls)))
        ;; Show tool output content if present
        (when (and content-arr info)
          (let ((output-marker (plist-get info :output-marker)))
            (when (and output-marker (marker-buffer output-marker))
              (with-current-buffer (marker-buffer output-marker)
                (let ((inhibit-read-only t)
                      (pos (marker-position output-marker)))
                  ;; Validate marker position is within buffer
                  (when (<= pos (point-max))
                    (goto-char pos)
                    (let ((did-insert nil))
                      (seq-doseq (item content-arr)
                        (when-let* ((inner (alist-get 'content item))
                                    (text (alist-get 'text inner)))
                          (let ((beg (point)))
                            (insert text)
                            (unless (string-suffix-p "\n" text)
                              (insert "\n"))
                            (put-text-property beg (point) 'font-lock-face 'banjo-face-tool-output)
                            (put-text-property beg (point) 'banjo-tool-id tool-id)
                            (setq did-insert t))))
                      (when did-insert
                        (when (and (member (plist-get info :status) '("completed" "failed"))
                                   (not (banjo--find-tool-overlay-by-id tool-id)))
                          (banjo--create-tool-fold tool-id t))
                        (banjo--queue-render)))))))))
        ;; Handle status change
        (when (and info status)
          (puthash tool-id (plist-put info :status status) banjo--tool-calls)
          (banjo--update-tool-header tool-id)
          (when (or (string= status "completed") (string= status "failed"))
            (banjo--create-tool-fold tool-id t)))
        (banjo--maybe-prune-tool-calls)))
     ((string= update-type "current_mode_update")
      (setq banjo--state (plist-put banjo--state :mode (alist-get 'currentModeId update)))
      (banjo--update-mode-line))
     ((string= update-type "current_model_update")
      (setq banjo--state (plist-put banjo--state :model (alist-get 'currentModelId update)))
      (banjo--update-mode-line)))
  ))

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
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents lockfile)
            (let* ((json-object-type 'alist)
                   (json-key-type 'symbol)
                   (data (json-read)))
              (alist-get 'port data)))
        (error nil)))))

(defun banjo--start-daemon ()
  "Start the Banjo daemon."
  (let ((cmd (list banjo-binary "--daemon")))
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
            (let* ((json-object-type 'alist)
                   (json-array-type 'vector)
                   (json-key-type 'symbol)
                   (msg (condition-case nil
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
  (banjo--log "=== CONNECTED to port %s ===" banjo--port)
  ;; Send initialize request
  (banjo--send-request
   "initialize"
   '((protocolVersion . 1)
     (clientCapabilities . nil)
     (clientInfo . ((name . "banjo-emacs") (version . "0.1.0"))))
   (lambda (result err)
     (if err
         (message "Banjo: init error: %s" (alist-get 'message err))
       (when result
         (when-let ((agent-info (alist-get 'agentInfo result)))
           (setq banjo--state (plist-put banjo--state :version (alist-get 'version agent-info))))
         (banjo--send-request
        "session/new"
        `((cwd . ,(expand-file-name default-directory)))
        (lambda (sess-result sess-err)
          (if sess-err
              (message "Banjo: session error: %s" (alist-get 'message sess-err))
            (when sess-result
              (setq banjo--session-id (alist-get 'sessionId sess-result))
              (when-let ((modes (alist-get 'modes sess-result)))
                (setq banjo--state (plist-put banjo--state :mode (alist-get 'currentModeId modes))))
              (banjo--update-mode-line)
              (message "Banjo connected"))))))))))

(defun banjo--on-disconnect ()
  "Handle WebSocket disconnection."
  (banjo--log "=== DISCONNECTED ===")
  (setq banjo--websocket nil)
  (setq banjo--session-id nil)
  (setq banjo--next-id 1)
  (clrhash banjo--pending-requests)
  (banjo--cleanup-tool-calls)
  (banjo--stop-streaming)
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
  (banjo--send-request
   "session/prompt"
   `((sessionId . ,banjo--session-id)
     (prompt . [((type . "text") (text . ,prompt))]))
   (lambda (result _err)
     (banjo--stop-streaming)
     (when-let ((reason (alist-get 'stopReason result)))
       (unless (string= reason "end_turn")
         (banjo--append-output (format "\n[%s]\n" reason) 'shadow))))))

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
  (let* ((raw (string-trim (downcase (or mode ""))))
         (norm (replace-regexp-in-string "[- ]" "_" raw)))
    (cond
     ((or (string= norm "accept_edits") (string= norm "acceptedits")) "acceptEdits")
     ((or (string= norm "auto_approve") (string= norm "bypasspermissions")
          (string= norm "bypass_permissions")) "bypassPermissions")
     ((or (string= norm "plan_only") (string= norm "plan")) "plan")
     ((string= norm "default") "default")
     (t mode))))

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
    (setq banjo--history-index 0)
    (setq banjo--history-temp nil)
    (banjo--append-status "Starting new session...")
    (banjo--send-request
     "session/new"
     `((cwd . ,(expand-file-name default-directory)))
     (lambda (sess-result sess-err)
       (if sess-err
           (banjo--append-status (format "Error: %s" (alist-get 'message sess-err)))
         (when sess-result
           (setq banjo--session-id (alist-get 'sessionId sess-result))
           (when-let ((modes (alist-get 'modes sess-result)))
             (setq banjo--state (plist-put banjo--state :mode (alist-get 'currentModeId modes))))
           (banjo--update-mode-line)
           (banjo--append-status "New session ready")))))))

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
    (if (not (and banjo--session-id banjo--websocket (websocket-openp banjo--websocket)))
        (banjo--append-status "Not connected")
      (let ((mode (banjo--normalize-mode args)))
        (banjo-set-mode mode)
        (banjo--append-status (format "Mode: %s" (banjo--display-mode mode)))))))

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
  (if banjo--pending-permission
      (message "Banjo: permission prompt active")
    (let ((text (string-trim-right
                 (buffer-substring-no-properties (point-min) (point-max)))))
      (when (string-blank-p text)
        (user-error "Prompt is empty"))
      (banjo--history-ensure default-directory)
      (banjo--history-add text)
      (let ((cmd (banjo--parse-command text)))
        (if (and cmd (banjo--dispatch-command (car cmd) (cdr cmd)))
            nil
          (banjo--send-text text)))
      (let ((inhibit-read-only t))
        (erase-buffer)))))

;;;###autoload
(defun banjo-start ()
  "Start Banjo daemon and connect."
  (interactive)
  (setq banjo--last-cwd (banjo--current-cwd))
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
    (condition-case nil
        (websocket-close banjo--websocket)
      (error nil))
    (setq banjo--websocket nil))
  (when banjo--process
    (kill-process banjo--process)
    (setq banjo--process nil))
  (when-let ((buf (get-buffer "*banjo-daemon*")))
    (kill-buffer buf))
  (clrhash banjo--pending-requests)
  (banjo--cleanup-tool-calls)
  (banjo--stop-streaming)
  (setq banjo--session-id nil)
  (setq banjo--port nil)
  (banjo--update-mode-line)
  (message "Banjo stopped"))

;;;###autoload
(defun banjo-recompile ()
  "Byte-compile banjo.el."
  (interactive)
  (let* ((lib (locate-library "banjo"))
         (src (cond
               ((and lib (string-match-p "\\.el\\'" lib)) lib)
               ((and lib (string-match-p "\\.elc\\'" lib))
                (let ((el (concat (file-name-sans-extension lib) ".el")))
                  (and (file-exists-p el) el)))
               (t nil))))
    (unless src
      (user-error "banjo.el not found"))
    (byte-compile-file src)
    (message "Banjo: recompiled %s" src)))

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
    (banjo--stop-streaming)
    (banjo--send-notification
     "session/cancel"
     `((sessionId . ,banjo--session-id)))
    (message "Cancelled")))

;;;###autoload
(defun banjo-set-mode (mode)
  "Set permission MODE."
  (interactive
   (list (completing-read "Mode: " '("default" "acceptEdits" "bypassPermissions" "plan") nil t)))
  (unless banjo--session-id
    (user-error "Banjo not connected. Run M-x banjo-start"))
  (banjo--send-notification
   "session/set_mode"
   `((sessionId . ,banjo--session-id)
     (modeId . ,mode)))
  (setq banjo--state (plist-put banjo--state :mode mode))
  (banjo--update-mode-line))

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
    (setq banjo--state (plist-put banjo--state :model model))
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
    (setq banjo--state (plist-put banjo--state :engine engine))
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
      "z" #'banjo-toggle-fold
      (kbd "TAB") #'banjo-toggle-fold
      "/" #'banjo-input-slash
      (kbd "C-c") #'banjo-cancel)
    (banjo--evil-define-key 'normal banjo-input-mode-map
      "/" #'banjo-input-slash)))

(defun banjo--setup-evil-panel-bindings ()
  "Set up evil-mode bindings for the panel buffer."
  (eval-after-load 'evil
    '(progn
       (banjo--evil-define-key 'normal banjo-mode-map
         "q" #'banjo--hide-panel
         "gr" #'banjo-toggle
         "z" #'banjo-toggle-fold
         (kbd "TAB") #'banjo-toggle-fold
         "/" #'banjo-input-slash
         (kbd "C-c") #'banjo-cancel)
       (banjo--evil-define-key 'normal banjo-input-mode-map
         "/" #'banjo-input-slash))))

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
