;;; banjo-test.el --- Tests for banjo.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

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

(defun banjo-test--e2e-run (engine prompt)
  (let* ((lib (locate-library "banjo"))
         (emacs-dir (and lib (file-name-directory lib)))
         (root (and emacs-dir (file-name-directory (directory-file-name emacs-dir))))
         (banjo-bin (and root (expand-file-name "zig-out/bin/banjo" root)))
         (temp-dir (make-temp-file "banjo-emacs-e2e-" t))
         (default-directory (file-name-as-directory temp-dir))
         (banjo--output-buffer (format "*banjo-test-e2e-%s*" engine))
         (banjo-binary banjo-bin)
         (process-environment (copy-sequence process-environment))
         (exec-path (append exec-path (parse-colon-path (or (getenv "PATH") ""))))
         (codex (executable-find "codex"))
         (claude (executable-find "claude")))
    (should root)
    (should (file-executable-p banjo-bin))
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
    (unwind-protect
        (progn
          (banjo-test--exec-command "banjo-stop")
          (setq banjo--process-output "")
          (banjo-test--exec-command "banjo-start")
          (should (banjo-test--wait-until (lambda () banjo--session-id) 15.0))
          (banjo-test--exec-command "banjo-send" prompt)
          (should (banjo-test--wait-until #'banjo-test--assistant-output-p 20.0)))
      (banjo-test--exec-command "banjo-stop")
      (delete-directory temp-dir t))))

(ert-deftest banjo-test-split-fence-chunks ()
  (let ((banjo--output-buffer "*banjo-test*"))
    (banjo--clear-output)
    (banjo--append-output "``")
    (banjo--append-output "`\ncode\n")
    (banjo--append-output "```\nplain\n")
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
          (with-current-buffer (banjo--get-output-buffer)
            (goto-char (point-min))
            (search-forward tmp)
            (should (get-text-property (match-beginning 0) 'banjo-code-block))
            (should-not (get-text-property (match-beginning 0) 'banjo-link))))
      (delete-file tmp))))

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
        (banjo-doom-leader-prefix "a"))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (should (condition-case nil
                      (progn (banjo--setup-doom-keybindings) t)
                    (error nil))))
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
         (features (cons 'evil features)))
    (unwind-protect
        (progn
          (should src)
          (copy-file src tmp-src t)
          (let ((byte-compile-warnings nil))
            (byte-compile-file tmp-src))
          (eval '(defmacro evil-define-key (&rest _args) nil))
          (should (condition-case nil
                      (load tmp-elc nil t)
                    (error nil))))
      (delete-directory tmp-dir t))))

(ert-deftest banjo-test-emacs-end-to-end ()
  (banjo-test--e2e-run 'codex "Reply with a short greeting.")
  (banjo-test--e2e-run 'claude "Reply with a short greeting."))

(provide 'banjo-test)
;;; banjo-test.el ends here
