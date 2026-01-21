;;; banjo-test.el --- Tests for banjo.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

(setq load-prefer-newer t)

(defun banjo-test--ensure-websocket ()
  (unless (require 'websocket nil t)
    (let ((candidates (list
                       (expand-file-name "~/.config/emacs/.local/straight/build-*/websocket")
                       (expand-file-name "~/.config/emacs/.local/straight/repos/emacs-websocket"))))
      (dolist (pattern candidates)
        (dolist (path (file-expand-wildcards pattern))
          (when (file-directory-p path)
            (add-to-list 'load-path path)))))
    (unless (require 'websocket nil t)
      (error "websocket.el not found; install emacs-websocket"))))

(banjo-test--ensure-websocket)
(require 'banjo)

(defun banjo-test--wait-until (pred timeout)
  (let ((deadline (+ (float-time) timeout))
        (done nil))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (setq done (funcall pred)))
    done))

(defun banjo-test--flush-render ()
  (let ((buf (banjo--get-output-buffer)))
    (banjo--flush-render buf)))

(defun banjo-test--assistant-output-p ()
  (with-current-buffer (banjo--get-output-buffer)
    (save-excursion
      (goto-char (point-min))
      (when (search-forward "\n\n" nil t)
        (re-search-forward "\\S-" nil t)))))

(defun banjo-test--exec-command (command &optional input)
  (let ((keys (if input
                  (vconcat (kbd (format "M-x %s RET" command)) input (kbd "RET"))
                (kbd (format "M-x %s RET" command)))))
    (execute-kbd-macro keys)
    (accept-process-output nil 0.05)))

(defun banjo-test--send-from-input (text)
  (banjo-test--exec-command "banjo-focus-input")
  (let ((input (banjo--get-input-buffer)))
    (with-current-buffer input
      (let ((inhibit-read-only t))
        (erase-buffer))))
  (execute-kbd-macro (vconcat text (kbd "RET")))
  (accept-process-output nil 0.05))

(defun banjo-test--e2e-run (engine prompt)
  (let* ((lib (locate-library "banjo"))
         (emacs-dir (and lib (file-name-directory lib)))
         (root (and emacs-dir (file-name-directory (directory-file-name emacs-dir))))
         (root-ok (and root (not (string-match-p "/\\.local/straight/build-" root))))
         (repo-root (and (getenv "BANJO_REPO_ROOT")
                         (file-name-as-directory (getenv "BANJO_REPO_ROOT"))))
         (banjo-bin (or (and banjo-binary (file-executable-p banjo-binary) banjo-binary)
                        (executable-find (or banjo-binary "banjo"))
                        (and repo-root (expand-file-name "zig-out/bin/banjo" repo-root))
                        (and root-ok (expand-file-name "zig-out/bin/banjo" root))))
         (temp-dir (make-temp-file "banjo-emacs-e2e-" t))
         (default-directory (file-name-as-directory temp-dir))
         (banjo--output-buffer (format "*banjo-test-e2e-%s*" engine))
         (banjo-binary banjo-bin)
         (process-environment (copy-sequence process-environment))
         (exec-path (append exec-path (parse-colon-path (or (getenv "PATH") ""))))
         (codex (executable-find "codex"))
         (claude (executable-find "claude")))
    (should (and banjo-bin (file-executable-p banjo-bin)))
    (pcase engine
      ('codex
       (should codex)
       (setenv "CODEX_EXECUTABLE" codex)
       (setenv "BANJO_ROUTE" "codex")
       (setenv "BANJO_PRIMARY_AGENT" "codex"))
      ('claude
       (should claude)
       (setenv "CLAUDE_CODE_EXECUTABLE" claude)
       (setenv "BANJO_ROUTE" "claude")
       (setenv "BANJO_PRIMARY_AGENT" "claude")))
    (setenv "BANJO_AUTO_RESUME" "false")
    ;; Mock interactive prompts to auto-approve in batch mode
    (let ((orig-completing-read (symbol-function 'completing-read)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt choices &rest args)
                   (if (string-match-p "\\`Allow " prompt)
                       (car choices)
                     (apply orig-completing-read prompt choices args))))
                ((symbol-function 'read-char-choice)
                 (lambda (prompt _choices)
                   (if (string-match-p "\\`Allow " prompt) ?y ?y)))
                ((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
        (unwind-protect
            (progn
              (banjo-test--exec-command "banjo-stop")
              (setq banjo--process-output "")
              (banjo-test--exec-command "banjo-start")
              (should (banjo-test--wait-until (lambda () banjo--session-id) 15.0))
              (banjo-test--send-from-input prompt)
              (should (banjo-test--wait-until #'banjo-test--assistant-output-p 20.0)))
          (banjo-test--exec-command "banjo-stop")
          (delete-directory temp-dir t))))))

(ert-deftest banjo-test-split-fence-chunks ()
  (let ((banjo--output-buffer "*banjo-test*"))
    (banjo--clear-output)
    (banjo--append-output "``")
    (banjo--append-output "`\ncode\n")
    (banjo--append-output "```\nplain\n")
    (banjo-test--flush-render)
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (search-forward "code")
      (should (get-text-property (match-beginning 0) 'banjo-code-block))
      (search-forward "plain")
      (should-not (get-text-property (match-beginning 0) 'banjo-code-block)))))

(ert-deftest banjo-test-link-skipped-in-code-block ()
  (let* ((banjo--output-buffer "*banjo-test*")
         (tmp (make-temp-file "banjo-link-")))
    (unwind-protect
        (progn
          (banjo--clear-output)
          (banjo--append-output (format "```\n%s\n```\n" tmp))
          (banjo-test--flush-render)
          (with-current-buffer (banjo--get-output-buffer)
            (goto-char (point-min))
            (search-forward tmp)
            (should (get-text-property (match-beginning 0) 'banjo-code-block))
            (should-not (get-text-property (match-beginning 0) 'banjo-link))))
      (delete-file tmp))))

(ert-deftest banjo-test-panel-layout ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--input-buffer "*banjo-test-input*"))
    (banjo-test--exec-command "banjo-focus-input")
    (let ((out-win (get-buffer-window (banjo--get-output-buffer)))
          (in-win (get-buffer-window (banjo--get-input-buffer))))
      (should out-win)
      (should in-win)
      (let* ((out-edges (window-edges out-win))
             (in-edges (window-edges in-win)))
        (should (< (nth 1 out-edges) (nth 1 in-edges)))))))

(ert-deftest banjo-test-buffer-vars-reinit ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--input-buffer "*banjo-test-input*"))
    (makunbound 'banjo--output-buffer)
    (makunbound 'banjo--input-buffer)
    (banjo-test--exec-command "banjo-focus-input")
    (should (string= banjo--output-buffer "*banjo*"))
    (should (string= banjo--input-buffer "*banjo-input*"))))

(ert-deftest banjo-test-input-map-reinit ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--input-buffer "*banjo-test-input*"))
    (when (boundp 'banjo-input-mode-map)
      (makunbound 'banjo-input-mode-map))
    (banjo-test--exec-command "banjo-focus-input")
    (should (keymapp banjo-input-mode-map))))

(ert-deftest banjo-test-input-no-line-numbers ()
  (let ((banjo--input-buffer "*banjo-test-input*"))
    (with-current-buffer (banjo--get-input-buffer)
      (should (bound-and-true-p doom-disable-line-numbers))
      (should (null display-line-numbers))
      (when (boundp 'display-line-numbers-type)
        (should (null display-line-numbers-type)))
      (when (boundp 'display-line-numbers-mode)
        (should (not display-line-numbers-mode))))))

(ert-deftest banjo-test-user-message-separation ()
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (banjo--append-output "Assistant\n" 'banjo-face-assistant)
    (banjo--append-user-message "hello")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Assistant\n\nhello\n\n" (buffer-string))))))

(ert-deftest banjo-test-make-request-jsonrpc ()
  (let* ((json-object-type 'alist)
         (json-key-type 'symbol)
         (json-array-type 'vector)
         (params '((text . "hello") (files . []) (cwd . "/tmp")))
         (request-json (json-encode (banjo--make-request "prompt" params 7)))
         (request (json-read-from-string request-json))
         (note-params '((text . "Ready")))
         (note-json (json-encode (banjo--make-request "status" note-params)))
         (note (json-read-from-string note-json)))
    (should (equal (alist-get 'jsonrpc request) "2.0"))
    (should (equal (alist-get 'id request) 7))
    (should (equal (alist-get 'method request) "prompt"))
    (should (equal (alist-get 'params request) params))
    (should (equal (alist-get 'jsonrpc note) "2.0"))
    (should (equal (alist-get 'method note) "status"))
    (should (equal (alist-get 'params note) note-params))
    (should-not (string-match-p "\"id\"" note-json))))

(ert-deftest banjo-test-slash-command-help ()
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (should (banjo--dispatch-command "help" ""))
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (should (search-forward "Available commands:" nil t)))))

(ert-deftest banjo-test-input-face-remap ()
  (let ((banjo--input-buffer "*banjo-test-input*"))
    (banjo--get-input-buffer)
    (with-current-buffer (banjo--get-input-buffer)
      (should (or (assq 'default face-remapping-alist)
                  (bound-and-true-p buffer-face-mode))))))

(ert-deftest banjo-test-evil-slash-binding-setup ()
  (let ((features (cons 'evil features)))
    (eval '(defmacro evil-define-key (&rest _args) nil))
    (banjo--setup-evil-panel-bindings)
    (should (keymapp banjo-input-mode-map))))

(ert-deftest banjo-test-history-nav ()
  (let ((banjo-history-dir (make-temp-file "banjo-hist-" t))
        (banjo--history nil)
        (banjo--history-index 0)
        (banjo--history-temp nil)
        (banjo--history-key nil)
        (banjo--input-buffer "*banjo-test-input*"))
    (unwind-protect
        (progn
          (banjo--history-ensure default-directory)
          (banjo--history-add "first")
          (banjo--history-add "second")
          (with-current-buffer (banjo--get-input-buffer)
            (banjo--set-input-text "draft")
            (banjo-history-prev)
            (should (string= (buffer-string) "second"))
            (banjo-history-prev)
            (should (string= (buffer-string) "first"))
            (banjo-history-next)
            (should (string= (buffer-string) "second"))
            (banjo-history-next)
            (should (string= (buffer-string) "draft"))))
      (delete-directory banjo-history-dir t))))

(ert-deftest banjo-test-command-completion ()
  (let ((banjo--input-buffer "*banjo-test-input*"))
    (with-current-buffer (banjo--get-input-buffer)
      (banjo--set-input-text "/he")
      (goto-char (point-max))
      (let ((capf (banjo--completion-at-point)))
        (should capf)
        (should (member "help" (nth 2 capf)))))))

(ert-deftest banjo-test-normalize-mode-variants ()
  (should (string= (banjo--normalize-mode "accept-edits") "acceptEdits"))
  (should (string= (banjo--normalize-mode "accept edits") "acceptEdits"))
  (should (string= (banjo--normalize-mode "auto-approve") "bypassPermissions"))
  (should (string= (banjo--normalize-mode "plan-only") "plan"))
  (should (string= (banjo--normalize-mode "default") "default")))

(ert-deftest banjo-test-command-mode-sends-notification ()
  (let ((banjo--session-id "sess-1")
        (banjo--websocket t)
        (sent nil))
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_ws text) (setq sent text))))
      (banjo--command-mode "accept-edits")
      (should sent)
      (should (string-match-p "\"session/set_mode\"" sent))
      (should (string-match-p "\"modeId\":\"acceptEdits\"" sent)))))

(ert-deftest banjo-test-command-mode-not-connected ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id nil)
        (banjo--websocket nil))
    (banjo--clear-output)
    (banjo--command-mode "accept-edits")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Not connected" (buffer-string))))))

(ert-deftest banjo-test-command-model-sends-notification ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id "sess-1")
        (banjo--websocket t)
        (sent nil))
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_ws text) (setq sent text))))
      (banjo--clear-output)
      (banjo--command-model "sonnet")
      (should sent)
      (should (string-match-p "\"session/set_model\"" sent))
      (should (string-match-p "\"modelId\":\"sonnet\"" sent))
      (with-current-buffer (banjo--get-output-buffer)
        (should (string-match-p "Model: sonnet" (buffer-string)))))))

(ert-deftest banjo-test-command-model-not-connected ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id nil)
        (banjo--websocket nil))
    (banjo--clear-output)
    (banjo--command-model "sonnet")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Model: sonnet" (buffer-string))))))

(ert-deftest banjo-test-command-version-known ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--state (list :version "1.2.3")))
    (banjo--clear-output)
    (banjo--command-version "")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Banjo 1.2.3" (buffer-string))))))

(ert-deftest banjo-test-command-version-unknown ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--state (list :version nil)))
    (banjo--clear-output)
    (banjo--command-version "")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Banjo version unknown" (buffer-string))))))

(ert-deftest banjo-test-command-clear ()
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (banjo--append-output "hello\n")
    (banjo--command-clear "")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string= "" (buffer-string))))))

(ert-deftest banjo-test-command-new-not-connected ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--websocket nil))
    (banjo--clear-output)
    (banjo--command-new "")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Not connected" (buffer-string))))))

(ert-deftest banjo-test-command-new-sends-request ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--websocket t)
        (banjo--session-id "sess-old")
        (banjo--state (list :mode "default"))
        (default-directory "/tmp/banjo-test/"))
    (let (sent-method sent-params sent-callback)
      (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
                ((symbol-function 'banjo--send-request)
                 (lambda (method params callback)
                   (setq sent-method method
                         sent-params params
                         sent-callback callback))))
        (banjo--clear-output)
        (banjo--command-new "")
        (should (string= sent-method "session/new"))
        (should (equal sent-params `((cwd . ,(expand-file-name default-directory)))))
        (should sent-callback)
        (funcall sent-callback
                 '((sessionId . "sess-new")
                   (modes . ((currentModeId . "plan"))))
                 nil)
        (should (string= banjo--session-id "sess-new"))
        (should (string= (plist-get banjo--state :mode) "plan"))
        (with-current-buffer (banjo--get-output-buffer)
          (should (string-match-p "Starting new session" (buffer-string)))
          (should (string-match-p "New session ready" (buffer-string))))))))

(ert-deftest banjo-test-command-cancel-connected ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id "sess-1")
        (called nil))
    (cl-letf (((symbol-function 'banjo-cancel)
               (lambda () (setq called t))))
      (banjo--clear-output)
      (banjo--command-cancel "")
      (should called)
      (with-current-buffer (banjo--get-output-buffer)
        (should (string-match-p "Cancelled" (buffer-string)))))))

(ert-deftest banjo-test-command-cancel-not-connected ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id nil))
    (banjo--clear-output)
    (banjo--command-cancel "")
    (with-current-buffer (banjo--get-output-buffer)
      (should (string-match-p "Not connected" (buffer-string))))))

(ert-deftest banjo-test-command-claude-sends-notification ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id "sess-1")
        (banjo--websocket t)
        (banjo--state (list :engine "codex"))
        (sent nil))
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_ws text) (setq sent text))))
      (banjo--clear-output)
      (banjo--command-claude "")
      (should sent)
      (should (string-match-p "\"session/set_config_option\"" sent))
      (should (string-match-p "\"configId\":\"route\"" sent))
      (should (string-match-p "\"value\":\"claude\"" sent))
      (should (string= (plist-get banjo--state :engine) "claude"))
      (with-current-buffer (banjo--get-output-buffer)
        (should (string-match-p "Agent: claude" (buffer-string)))))))

(ert-deftest banjo-test-command-codex-sends-notification ()
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--session-id "sess-1")
        (banjo--websocket t)
        (banjo--state (list :engine "claude"))
        (sent nil))
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_ws text) (setq sent text))))
      (banjo--clear-output)
      (banjo--command-codex "")
      (should sent)
      (should (string-match-p "\"session/set_config_option\"" sent))
      (should (string-match-p "\"configId\":\"route\"" sent))
      (should (string-match-p "\"value\":\"codex\"" sent))
      (should (string= (plist-get banjo--state :engine) "codex"))
      (with-current-buffer (banjo--get-output-buffer)
        (should (string-match-p "Agent: codex" (buffer-string)))))))

(ert-deftest banjo-test-autoscroll-toggle ()
  (let ((banjo-autoscroll t))
    (banjo--toggle-autoscroll)
    (should (not banjo-autoscroll))))

(ert-deftest banjo-test-code-fold ()
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (banjo--append-output "```\ncode\n```\n")
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (search-forward "code")
      (banjo-toggle-code-fold)
      (should (banjo--find-fold-overlay (point)))
      (banjo-toggle-code-fold)
      (should-not (banjo--find-fold-overlay (point))))))

(ert-deftest banjo-test-mode-line-status ()
  (let ((banjo--state (list :engine "codex" :model "x" :mode "acceptEdits"))
        (banjo--websocket 'test)
        (banjo--stream-start-time (- (float-time) 5)))
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_ws) t)))
      (banjo--update-mode-line)
      (should (string-match-p "codex/x" banjo--mode-line-left))
      (should (string-match-p "(accept_edits)" banjo--mode-line-left))
      (should (string= "5s" banjo--mode-line-timer)))))

(ert-deftest banjo-test-faces-defined ()
  "Verify all banjo faces are defined with proper inheritance."
  (dolist (face '(banjo-face-user
                  banjo-face-input
                  banjo-face-assistant
                  banjo-face-thought
                  banjo-face-tool
                  banjo-face-tool-success
                  banjo-face-tool-fail
                  banjo-face-tool-pending
                  banjo-face-link
                  banjo-face-code
                  banjo-face-code-block
                  banjo-face-inline-code
                  banjo-face-header
                  banjo-face-blockquote
                  banjo-face-list-bullet
                  banjo-face-hr))
    (should (facep face))))

(ert-deftest banjo-test-face-applied ()
  "Verify faces are actually applied to output text."
  (let ((banjo--output-buffer "*banjo-test-faces*"))
    (banjo--clear-output)
    (banjo--append-output "tool line\n" 'banjo-face-tool)
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (should (eq major-mode 'banjo-mode))
      ;; font-lock-face property should be applied
      (let ((face-at (get-text-property (point) 'font-lock-face)))
        (should face-at)
        (should (or (eq face-at 'banjo-face-tool)
                    (memq 'banjo-face-tool (if (listp face-at) face-at nil))))))))

(ert-deftest banjo-test-doom-prefix-availability ()
  (let ((orig-bound (boundp 'doom-leader-map))
        (orig (and (boundp 'doom-leader-map) doom-leader-map)))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (should (banjo--ensure-doom-prefix-map "a"))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (should (banjo--ensure-doom-prefix-map "a"))
          (should (keymapp (lookup-key doom-leader-map (kbd "a")))))
      (if orig-bound
          (setq doom-leader-map orig)
        (makunbound 'doom-leader-map)))))

(ert-deftest banjo-test-doom-keybindings-skip-non-prefix ()
  (let ((orig-bound (boundp 'doom-leader-map))
        (orig (and (boundp 'doom-leader-map) doom-leader-map))
        (features (cons 'doom-keybinds features))
        (banjo-doom-leader-prefix "a"))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (should (banjo--define-doom-leader-keys "a"))
          (let ((map (lookup-key doom-leader-map (kbd "a"))))
            (should (keymapp map))
            (should (eq (lookup-key map (kbd "b")) #'banjo-toggle))))
      (if orig-bound
          (setq doom-leader-map orig)
        (makunbound 'doom-leader-map)))))

(ert-deftest banjo-test-evil-define-key-missing ()
  (let ((orig-bound (boundp 'doom-leader-map))
        (orig (and (boundp 'doom-leader-map) doom-leader-map))
        (features (cons 'evil (cons 'doom-keybinds features)))
        (banjo-doom-leader-prefix "a")
        (orig-fn (and (fboundp 'evil-define-key) (symbol-function 'evil-define-key))))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (when (fboundp 'evil-define-key)
            (fmakunbound 'evil-define-key))
          (should (condition-case nil
                      (progn (banjo--setup-doom-keybindings) t)
                    (error nil))))
      (when orig-fn
        (fset 'evil-define-key orig-fn))
      (if orig-bound
          (setq doom-leader-map orig)
        (makunbound 'doom-leader-map)))))

(ert-deftest banjo-test-byte-compile-evil-macro ()
  (let* ((lib (locate-library "banjo"))
         (src (cond
               ((and lib (string-match-p "\\.el\\'" lib)) lib)
               ((and lib (string-match-p "\\.elc\\'" lib))
                (let ((el (concat (file-name-sans-extension lib) ".el")))
                  (if (file-exists-p el) el lib)))
               (t lib)))
         (tmp-dir (make-temp-file "banjo-compile-" t))
         (tmp-src (expand-file-name "banjo.el" tmp-dir))
         (tmp-elc (expand-file-name "banjo.elc" tmp-dir))
         (features (cons 'evil features))
         (byte-compile-dest-file-function
          (lambda (_src) tmp-elc)))
    (unwind-protect
        (progn
          (should src)
          (copy-file src tmp-src t)
          ;; Compile with warnings enabled and capture them
          (let ((byte-compile-warnings t)
                (warning-minimum-level :warning)
                (warnings nil))
            (cl-letf (((symbol-function 'byte-compile-warn)
                       (lambda (fmt &rest args)
                         (push (apply #'format fmt args) warnings))))
              (should (byte-compile-file tmp-src)))
            (should-not warnings))
          (eval '(defmacro evil-define-key (&rest _args) nil))
          (should (condition-case nil
                      (load tmp-elc nil t)
                    (error nil))))
      (delete-directory tmp-dir t))))

(ert-deftest banjo-test-permission-options-vector ()
  "Verify permission options work with JSON vector input."
  (let* ((vec-options [((kind . "allow_once") (name . "Allow") (optionId . "allow_once"))
                       ((kind . "reject_once") (name . "Deny") (optionId . "reject_once"))])
         (list-options '(((kind . "allow_once") (name . "Allow") (optionId . "allow_once"))
                         ((kind . "reject_once") (name . "Deny") (optionId . "reject_once"))))
         (vec-choices (banjo--permission-option-choices vec-options))
         (list-choices (banjo--permission-option-choices list-options)))
    (should (= (length vec-choices) 2))
    (should (= (length list-choices) 2))
    (should (string-match-p "Allow" (caar vec-choices)))
    (should (string-match-p "Allow" (caar list-choices)))))

(ert-deftest banjo-test-handle-message-invalid-json ()
  "Verify invalid JSON doesn't crash message handler."
  (let ((frame (make-websocket-frame :opcode 'text :payload "not valid json")))
    (should (condition-case nil
                (progn (banjo--handle-message frame) t)
              (error nil)))))

(ert-deftest banjo-test-emacs-end-to-end ()
  :tags '(:e2e)
  (banjo-test--e2e-run 'codex "Reply with a short greeting.")
  (banjo-test--e2e-run 'claude "Reply with a short greeting."))

;; WebSocket message simulation helpers

(defun banjo-test--simulate-notification (method params)
  "Simulate receiving a JSON-RPC notification."
  (let ((frame (make-websocket-frame
                :opcode 'text
                :payload (json-encode `((method . ,method) (params . ,params))))))
    (banjo--handle-message frame)))

(defun banjo-test--simulate-request (id method params)
  "Simulate receiving a JSON-RPC request with ID."
  (let ((frame (make-websocket-frame
                :opcode 'text
                :payload (json-encode `((id . ,id) (method . ,method) (params . ,params))))))
    (banjo--handle-message frame)))

;; Tool call output tests

(ert-deftest banjo-test-tool-call-update-shows-output ()
  "Tool call updates with content should display in output buffer."
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--tool-calls (make-hash-table :test 'equal)))
    (banjo--clear-output)
    ;; First simulate tool_call to set up markers
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call")
                  (toolCallId . "tool-123")
                  (title . "Bash: ls")))))
    ;; Then simulate tool_call_update with content
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call_update")
                  (toolCallId . "tool-123")
                  (content . [((type . "content")
                               (content . ((type . "text") (text . "file1.txt\nfile2.txt"))))])))))
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (should (search-forward "file1.txt" nil t))
      (should (search-forward "file2.txt" nil t)))))

(ert-deftest banjo-test-tool-output-has-face ()
  "Tool output should have banjo-face-tool-output applied."
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--tool-calls (make-hash-table :test 'equal)))
    (banjo--clear-output)
    ;; First simulate tool_call to set up markers
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call")
                  (toolCallId . "tool-123")
                  (title . "Bash: ls")))))
    ;; Then simulate tool_call_update with content
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call_update")
                  (toolCallId . "tool-123")
                  (content . [((type . "content")
                               (content . ((type . "text") (text . "output"))))])))))
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (search-forward "output")
      (should (eq (get-text-property (1- (point)) 'font-lock-face) 'banjo-face-tool-output)))))

(ert-deftest banjo-test-tool-completion-updates-header ()
  "Tool completion should update header to ✓/✗."
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--tool-calls (make-hash-table :test 'equal))
        (errors nil))
    (banjo--clear-output)
    ;; Override message to catch errors
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when (string-match-p "parse error" fmt)
                   (push (apply #'format fmt args) errors)))))
      ;; 1. tool_call
      (banjo-test--simulate-notification
       "session/update"
       '((update . ((sessionUpdate . "tool_call")
                    (toolCallId . "tool-fold-test")
                    (title . "Bash: echo test")))))
      ;; 2. tool_call_update with content
      (banjo-test--simulate-notification
       "session/update"
       '((update . ((sessionUpdate . "tool_call_update")
                    (toolCallId . "tool-fold-test")
                    (content . [((type . "content")
                                 (content . ((type . "text") (text . "line1\nline2\nline3"))))])))))
      ;; 3. tool_call_update with status=completed
      (banjo-test--simulate-notification
       "session/update"
       '((update . ((sessionUpdate . "tool_call_update")
                    (toolCallId . "tool-fold-test")
                    (status . "completed"))))))
    ;; Fail if any parse errors occurred
    (should-not errors)
    ;; Verify header updated to completed
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (should (search-forward "○ Bash: echo test → ✓" nil t))
      ;; Fold overlay created and invisible
      (let ((ov (car (seq-filter (lambda (o) (overlay-get o 'banjo-tool-fold))
                                 (overlays-in (point-min) (point-max))))))
        (should ov)
        (should (overlay-get ov 'invisible)))))

(ert-deftest banjo-test-tool-fold-toggle-from-output ()
  "Tool folding should toggle when point is on output."
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--tool-calls (make-hash-table :test 'equal)))
    (banjo--clear-output)
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call")
                  (toolCallId . "tool-fold-test")
                  (title . "Bash: echo test")))))
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "tool_call_update")
                  (toolCallId . "tool-fold-test")
                  (content . [((type . "content")
                               (content . ((type . "text") (text . "line1\nline2"))))])
                  (status . "completed"))))))
    (with-current-buffer (banjo--get-output-buffer)
      (let ((ov (banjo--find-tool-overlay-by-id "tool-fold-test")))
        (should ov)
        (should (overlay-get ov 'invisible)))
      (goto-char (point-min))
      (search-forward "line1")
      (banjo-toggle-fold)
      (let ((ov (banjo--find-tool-overlay-by-id "tool-fold-test")))
        (should ov)
        (should-not (overlay-get ov 'invisible)))
      (banjo-toggle-fold)
      (let ((ov (banjo--find-tool-overlay-by-id "tool-fold-test")))
        (should ov)
        (should (overlay-get ov 'invisible))))))

;; Agent message coloring tests

(ert-deftest banjo-test-agent-message-has-face ()
  "Agent message chunks should have banjo-face-assistant applied."
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (banjo-test--simulate-notification
     "session/update"
     '((update . ((sessionUpdate . "agent_message_chunk")
                  (content . ((type . "text") (text . "Hello there")))))))
    (with-current-buffer (banjo--get-output-buffer)
      (goto-char (point-min))
      (search-forward "Hello")
      (should (eq (get-text-property (1- (point)) 'font-lock-face) 'banjo-face-assistant)))))

;; Slash completion tests

(ert-deftest banjo-test-slash-triggers-completion ()
  "Pressing / in input buffer should trigger completion."
  (let ((banjo--input-buffer "*banjo-test-input*")
        (completion-triggered nil))
    (with-current-buffer (banjo--get-input-buffer)
      (erase-buffer)
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda () (setq completion-triggered t))))
        (call-interactively 'banjo-input-maybe-complete))
      (should (string= (buffer-string) "/"))
      (should completion-triggered))))

(ert-deftest banjo-test-slash-completion-returns-commands ()
  "Slash completion should return registered commands."
  (let ((banjo--input-buffer "*banjo-test-input*"))
    (with-current-buffer (banjo--get-input-buffer)
      (erase-buffer)
      (insert "/he")
      (goto-char (point-max))
      (let ((capf (banjo--completion-at-point)))
        (should capf)
        (should (member "help" (nth 2 capf)))
        ;; Should have exit function for auto-send
        (should (plist-get (nthcdr 3 capf) :exit-function))))))

(ert-deftest banjo-test-slash-completion-auto-sends ()
  "Completing a slash command should auto-send it."
  (let ((banjo--input-buffer "*banjo-test-input*")
        (banjo--output-buffer "*banjo-test-output*")
        (send-called nil))
    (banjo--clear-output)
    (with-current-buffer (banjo--get-input-buffer)
      (erase-buffer)
      (insert "/help")
      (cl-letf (((symbol-function 'banjo-input-send)
                 (lambda () (interactive) (setq send-called t))))
        ;; Simulate completion finishing
        (banjo--completion-exit "help" 'finished)
        ;; Allow the timer to run
        (sleep-for 0.05))
      (should send-called))))

;; Permission request tests

(ert-deftest banjo-test-permission-request-flow ()
  "Permission requests should show prompt and send response."
  (let ((banjo--output-buffer "*banjo-test-output*")
        (banjo--websocket t)
        (sent-response nil))
    ;; Mock websocket-openp BEFORE clear-output (which calls update-mode-line)
    (cl-letf (((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_ws text) (setq sent-response text)))
              ((symbol-function 'read-char-choice)
               (lambda (_prompt _choices) ?y))
              ((symbol-function 'raise-frame) #'ignore))
      (banjo--clear-output)
      (banjo-test--simulate-request
       42
       "session/request_permission"
       '((toolCall . ((title . "Bash: rm -rf")
                      (toolCallId . "tc-1")))
         (options . [((kind . "allow_once") (name . "Allow") (optionId . "allow"))])))
      (with-current-buffer (banjo--get-output-buffer)
        (goto-char (point-min))
        (should (search-forward "[?] Bash: rm -rf" nil t)))
      (should sent-response)
      (should (string-match-p "\"id\":42" sent-response)))))

;; Error handling tests

(ert-deftest banjo-test-malformed-session-update ()
  "Malformed session/update should not crash."
  (let ((banjo--output-buffer "*banjo-test-output*"))
    (banjo--clear-output)
    (should-not (condition-case nil
                    (progn
                      (banjo-test--simulate-notification
                       "session/update"
                       '((update . ((toolCallId . "bad")))))
                      nil)
                  (error t)))))

(ert-deftest banjo-test-disconnect-during-stream ()
  "Disconnect during streaming should clean up state."
  (let ((banjo--streaming t)
        (banjo--websocket t)
        (banjo--session-id "test"))
    (banjo--on-disconnect)
    (should-not banjo--streaming)
    (should-not banjo--websocket)
    (should-not banjo--session-id)))

;; History navigation edge case tests

(ert-deftest banjo-test-history-empty ()
  "History navigation with empty history should not error."
  (let ((banjo-history-dir (make-temp-file "banjo-hist-" t))
        (banjo--history nil)
        (banjo--history-index 0)
        (banjo--history-temp nil)
        (banjo--history-key nil)
        (banjo--input-buffer "*banjo-test-input*"))
    (unwind-protect
        (with-current-buffer (banjo--get-input-buffer)
          (erase-buffer)
          (insert "current")
          ;; With empty history, should signal user-error
          (should (condition-case nil
                      (progn (banjo-history-prev) nil)
                    (user-error t)))
          ;; Should preserve current text
          (should (string= (buffer-string) "current")))
      (delete-directory banjo-history-dir t))))

(ert-deftest banjo-test-history-boundary ()
  "History navigation at boundaries should stop gracefully."
  (let ((banjo-history-dir (make-temp-file "banjo-hist-" t))
        (banjo--history nil)
        (banjo--history-index 0)
        (banjo--history-temp nil)
        (banjo--history-key nil)
        (banjo--input-buffer "*banjo-test-input*"))
    (unwind-protect
        (progn
          (banjo--history-ensure default-directory)
          (banjo--history-add "first")
          (with-current-buffer (banjo--get-input-buffer)
            (erase-buffer)
            (banjo-history-prev)
            (should (string= (buffer-string) "first"))
            ;; Going prev again should signal user-error (oldest entry)
            (should (condition-case nil
                        (progn (banjo-history-prev) nil)
                      (user-error t)))))
      (delete-directory banjo-history-dir t))))


(provide 'banjo-test)
;;; banjo-test.el ends here
