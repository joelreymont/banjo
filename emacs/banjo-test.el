;;; banjo-test.el --- Tests for banjo.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'banjo)

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
  (let ((orig (and (boundp 'doom-leader-map) doom-leader-map)))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (should-not (banjo--doom-prefix-available-p "a"))
          (define-key doom-leader-map (kbd "a") (make-sparse-keymap))
          (should (banjo--doom-prefix-available-p "a"))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (should-not (banjo--doom-prefix-available-p "a")))
      (if orig
          (setq doom-leader-map orig)
        (makunbound 'doom-leader-map)))))

(ert-deftest banjo-test-doom-keybindings-skip-non-prefix ()
  (let ((orig (and (boundp 'doom-leader-map) doom-leader-map))
        (features (cons 'doom-keybinds features))
        (banjo-doom-leader-prefix "a"))
    (unwind-protect
        (progn
          (setq doom-leader-map (make-sparse-keymap))
          (define-key doom-leader-map (kbd "a") #'ignore)
          (let ((called nil))
            (cl-letf (((symbol-function 'map!) (lambda (&rest _) (setq called t))))
              (banjo--setup-doom-keybindings)
              (should-not called))))
      (if orig
          (setq doom-leader-map orig)
        (makunbound 'doom-leader-map)))))

(provide 'banjo-test)
;;; banjo-test.el ends here
