;;; kisaragi-notes-embark.el --- Embark actions -*- lexical-binding: t -*-

;;; Commentary:

;; commentary

;;; Code:

(require 'embark)

(defun minaduki-embark/open (entry)
  "Open ENTRY."
  (when-let (metadata (get-text-property 0 :metadata entry))
    (let-alist metadata
      (minaduki/open (list :path .path)))))

(defun minaduki-embark/insert (entry)
  "Insert ENTRY as a link."
  (when-let (metadata (get-text-property 0 :metadata entry))
    (let-alist metadata
      (insert (org-roam-format-link .path entry)))))

(embark-define-keymap minaduki-embark/note-map
                      "Embark keymap for note items."
                      ("RET" minaduki-embark/open)
                      ("i" minaduki-embark/insert))

(add-to-list 'embark-keymap-alist
             '(note . minaduki-embark/note-map))

(provide 'kisaragi-notes-embark)

;;; kisaragi-notes-embark.el ends here