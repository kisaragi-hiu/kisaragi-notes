;;; kisaragi-notes-org-protocol.el --- Org-protocol handler for org-protocol://notes links  -*- lexical-binding: t; -*-

;; Copyright © 2021 Kisaragi Hiu <mail@kisaragi-hiu.com>
;; Copyright © 2020 Jethro Kuan <jethrokuan95@gmail.com>
;;
;; Author: Kisaragi Hiu <mail@kisaragi-hiu.com>
;;         Jethro Kuan <jethrokuan95@gmail.com>
;; URL: https://github.com/kisaragi-hiu/org-roam
;;
;; Keywords: org-mode, convenience, org-protocol
;; Version: 1.2.3
;; Package-Requires: ((emacs "26.1") (org "9.3"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; An org-protocol handler. After loading this file,
;;
;;    emacsclient 'org-protocol://notes?key=banjoazusa2020'
;;
;; will open the file associated the cite key "banjoazusa2020", and
;;
;;    emacsclient 'org-protocol://notes?file=blender.org'
;;
;; will open /path/to/org-directory/blender.org.
;;
;; One way to set up org-protocol:// links on Linux, assuming you
;; always want to use `emacsclient -c':
;;
;; 1. Copy /usr/share/applications/emacs.desktop to
;;    ~/.local/share/applications/emacs.desktop, where it will shadow
;;    the system-wide file
;;
;; 2. Change Exec= from "emacs %F" to "emacsclient -c %U"
;;    - We use %U to get URLs
;;    - It seems to open files just fine, though if the desktop passed
;;      a file:// link to Emacs it will fail
;;
;; 3. Add "x-scheme-handler/org-protocol;" to the end of MimeType
;;
;; 4. Wait a bit for it to take effect
;;
;; 5. Try opening an org-protocol:// link again from, say, Firefox. It
;;    should ask you whether you want to open this link with it.
;;
;;; Code:
(require 'org-protocol)
(require 'org-roam)
(require 'org-roam-bibtex) ; orb-edit-notes

;;;; Functions

;;;###autoload
(cl-defun kisaragi-notes-protocol/open-file ((&key file key))
  "An org-protocol handler to open a note file.

Arguments are passed in as a plist like (:file FILE :key KEY).
This corresponds to the org-protocol URL
\"org-protocol://notes?file=FILE&key=KEY\".

FILE: a path relative to `org-directory'.
KEY: a cite key corresponding to the ROAM_KEY keyword

FILE takes precedence over KEY.

Example:

emacsclient 'org-protocol://notes?file=characters/闇音レンリ.org'
emacsclient 'org-protocol://notes?key=banjoazusa2020'"
  (cond (file
         (find-file (f-join org-directory file)))
        (key
         (orb-edit-notes key))))

;;;###autoload
(with-eval-after-load 'org-protocol
  (cl-pushnew '("kisaragi-notes"
                :protocol "notes"
                :function kisaragi-notes-protocol/open-file)
              org-protocol-protocol-alist
              :test #'equal))

(provide 'kisaragi-notes-org-protocol)

;;; kisaragi-notes-org-protocol.el ends here