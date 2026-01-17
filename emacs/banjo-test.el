;;; banjo-test.el --- Tests for banjo.el -*- lexical-binding: t -*-

(require 'ert)
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

(provide 'banjo-test)
;;; banjo-test.el ends here
