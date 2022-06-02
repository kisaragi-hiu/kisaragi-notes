;;; minaduki-commands.el --- Commands -*- lexical-binding: t -*-

;;; Commentary:

;; Editing commands.

;;; Code:

(require 'org)
(require 'org-element)
(require 'dom)
(require 'dash)
(require 's)

(require 'transient)

(require 'minaduki-diary)
(require 'minaduki-completion)
(require 'minaduki-lit)

(require 'minaduki-utils)
(require 'kisaragi-notes-templates)

(require 'minaduki-extract)
(require 'org-roam-capture)

;;;; Local commands

(cl-defun minaduki/insert (&key entry lowercase? region)
  "Insert a link to a note.

If region is active, the new link uses the selected text as the
description. For example, if the text \"hello world\" is
selected, and the user chooses to insert a link to
./programming.org, the region would be replaced with
\"[[file:programming.org][hello world]]\".

If the note with the provided title does not exist, a new one is created.

ENTRY: the note entry (as returned by `minaduki-completion/read-note')
LOWERCASE?: if non-nil, the link description will be downcased.
REPLACE?: if non-nil, delete active region before inserting the new link."
  (interactive
   (let (region)
     (when (region-active-p)
       (setq region (-> (buffer-substring-no-properties
                         (region-beginning)
                         (region-end))
                        s-trim)))
     (list
      :entry (minaduki-completion//read-note
              :initial-input region
              :prompt "Insert link to note: ")
      :lowercase? current-prefix-arg
      :region region)))
  (let* ((title (plist-get entry :title))
         (path (plist-get entry :path))
         (desc title))
    ;; We avoid creating a new note if the path is a URL.
    ;;
    ;; This also allows inserting references to existing notes whose
    ;; title happens to be a URL without issue.
    (when (and (plist-get entry :new?)
               (not (minaduki//url? path)))
      (setq path
            (minaduki/new-concept-note
             :title title
             :visit? nil))
      (minaduki//message "Created new note \"%s\"" title))
    (when region
      (delete-active-region)
      (setq desc region))
    (when lowercase?
      (setq desc (downcase desc)))
    (insert (minaduki/format-link
             :target path
             :desc desc
             :id? (plist-get entry :id?)))))

;;;###autoload
(defun org-roam-alias-add ()
  "Add an alias.

Return added alias."
  (interactive)
  (let ((alias (read-string "Alias: ")))
    (when (string-empty-p alias)
      (user-error "Alias can't be empty"))
    (org-with-point-at 1
      (let ((case-fold-search t))
        (if (re-search-forward "^\\(#\\+alias:.*\\)" (point-max) t)
            (replace-match (format "#+alias: %s\n\\1" alias)
                           'fixedcase)
          (while (and (not (eobp))
                      (looking-at "^[#:]"))
            (if (save-excursion (end-of-line) (eobp))
                (progn
                  (end-of-line)
                  (insert "\n"))
              (forward-line)
              (beginning-of-line)))
          (insert "#+alias: " alias "\n"))))
    (minaduki-db//update-file (buffer-file-name (buffer-base-buffer)))
    alias))

;;;###autoload
(defun org-roam-alias-delete ()
  "Delete an alias from Org-roam file."
  (interactive)
  (if-let ((aliases (minaduki-extract/aliases)))
      (let ((alias (completing-read "Alias: " aliases nil 'require-match)))
        (org-with-point-at 1
          (let ((case-fold-search t))
            (when (search-forward (concat "#+alias: " alias) (point-max) t)
              (delete-region (line-beginning-position)
                             (1+ (line-end-position))))))
        (minaduki-db//update-file (buffer-file-name (buffer-base-buffer))))
    (user-error "No aliases to delete")))

;;;###autoload
(defun org-roam-tag-add ()
  "Add a tag to Org-roam file.

Return added tag."
  (interactive)
  (let* ((all-tags (minaduki-db//fetch-all-tags))
         (tag (completing-read "Tag: " all-tags))
         (file (buffer-file-name (buffer-base-buffer)))
         (existing-tags (org-roam--extract-tags-prop file)))
    (when (string-empty-p tag)
      (user-error "Tag can't be empty"))
    (org-roam--set-global-prop
     "roam_tags"
     (combine-and-quote-strings (seq-uniq (cons tag existing-tags))))
    (minaduki-db//insert-tags 'update)
    tag))

;;;###autoload
(defun org-roam-tag-delete ()
  "Delete a tag from Org-roam file."
  (interactive)
  (if-let* ((file (buffer-file-name (buffer-base-buffer)))
            (tags (org-roam--extract-tags-prop file)))
      (let ((tag (completing-read "Tag: " tags nil 'require-match)))
        (org-roam--set-global-prop
         "roam_tags"
         (combine-and-quote-strings (delete tag tags)))
        (minaduki-db//insert-tags 'update))
    (user-error "No tag to delete")))

;;;; Global commands

;;;###autoload
(defun org-roam-switch-to-buffer ()
  "Switch to an existing Org-roam buffer."
  (interactive)
  (let* ((roam-buffers (org-roam--get-roam-buffers))
         (names-and-buffers (mapcar (lambda (buffer)
                                      (cons (or (minaduki-db//fetch-title
                                                 (buffer-file-name buffer))
                                                (buffer-name buffer))
                                            buffer))
                                    roam-buffers)))
    (unless roam-buffers
      (user-error "No roam buffers"))
    (when-let ((name (completing-read "Buffer: " names-and-buffers
                                      nil t)))
      (switch-to-buffer (cdr (assoc name names-and-buffers))))))

;;;###autoload
(defun minaduki/fix-broken-links ()
  "List all broken links in a new buffer."
  (interactive)
  (let ((list-buffer (get-buffer-create "*minaduki broken links*"))
        errors)
    ;; Set up the display buffer
    (with-current-buffer list-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (kill-all-local-variables)
        (setq-local buffer-read-only t
                    revert-buffer-function (lambda (&rest _)
                                             (minaduki/fix-broken-links)))))
    ;; Collect missing links
    (let* ((all-files (minaduki//list-all-files))
           (i 0)
           (length (length all-files)))
      (cl-loop
       for f in all-files
       do
       (cl-incf i)
       (minaduki//message "(%s/%s) Looking for broken links in %s"
                          i length f)
       (minaduki//with-temp-buffer f
         (save-excursion
           (goto-char (point-min))
           (let ((ast (org-element-parse-buffer)))
             (org-element-map ast 'link
               (lambda (l)
                 (let ((file (org-element-property :path l)))
                   (when (and (equal "file" (org-element-property :type l))
                              (not (or (file-exists-p file)
                                       (file-remote-p file))))
                     (push
                      `(,f
                        ,(org-element-property :begin l)
                        ,(format
                          (if (org-element-lineage l '(link))
                              "\"%s\" (image in description) does not exist"
                            "\"%s\" does not exist")
                          file))
                      errors))))))))))
    ;; Insert them into the buffer
    (with-current-buffer list-buffer
      (let ((inhibit-read-only t)
            (count-bounds '(nil . nil)))
        (insert "Click the file names to visit the error.\n"
                "Checkboxes are available for keeping track of which ones are fixed.\n\n")
        ;; "100 broken links (100 to go)\n\n"
        ;; We need to capture the second number's bounds.
        (insert (format "%s broken links ("
                        (length errors)))
        (setf (car count-bounds) (point))
        (insert (format "%s" (length errors)))
        (setf (cdr count-bounds) (point))
        (insert " to go):\n\n")
        (insert
         (cl-loop
          for (file point message) in errors
          concat
          (format
           "%s %s: %s\n"
           (let ((enabled nil))
             (make-text-button
              "[ ]" nil
              'face 'button
              'follow-link t
              'action (minaduki//lambda-self (&rest _)
                        (let ((inhibit-read-only t)
                              (bounds
                               (unless (member (char-after) '(?\[ ?\s ?\]))
                                 (error
                                  "This action can only be run on a button"))))
                          (setq enabled (not enabled))
                          ;; Update the count on top first
                          (save-excursion
                            (let (current)
                              (goto-char (car count-bounds))
                              (setq current (number-at-point))
                              (delete-region (car count-bounds)
                                             (cdr count-bounds))
                              (if enabled
                                  (insert (format "%s" (1- current)))
                                (insert (format "%s" (1+ current))))
                              (setf (cdr count-bounds) (point))))
                          ;; Then update the bounds now.
                          ;; `save-excursion' knows to take the
                          ;; insertion into account, but we don't.
                          (setq bounds
                                (cl-case (char-after)
                                  (?\[ (cons (point) (+ (point) 2)))
                                  (?\s (cons (1- (point)) (1+ (point))))
                                  (?\] (cons (- (point) 2) (point)))))
                          (setf (buffer-substring (car bounds)
                                                  (1+ (cdr bounds)))
                                (make-text-button
                                 (if enabled "[X]" "[ ]") nil
                                 'face 'button
                                 'follow-link t
                                 'action self))))))
           ;; This ensures the lambda below gets its own instance of
           ;; `file', instead of sharing with all the other
           ;; iterations. Without this, all instances of this button
           ;; would open the same file.
           (let ((file file))
             (make-text-button
              (format "%s::C%s"
                      (if (f-descendant-of? file org-directory)
                          (f-relative file org-directory)
                        file)
                      point)
              nil
              'face '(font-lock-constant-face underline)
              'follow-link t
              'action (lambda (&rest _)
                        (find-file-other-window file)
                        (goto-char point))))
           message))))
      (goto-char (point-min)))
    (display-buffer list-buffer)))

;;;###autoload
(defun minaduki/literature-sources ()
  "List all sources for browsing interactively."
  (interactive)
  (let ((key->formatted
         ;; Use an alist here so that we can retrieve the key from the
         ;; selected item
         (cl-loop for (s) in (minaduki-db/query [:select [props] :from keys])
                  collect
                  (cons
                   (gethash "key" s)
                   (minaduki-lit/format-entry s))))
        key)
    (let ((selectrum-should-sort nil)
          (ivy-sort-functions-alist nil))
      (setq key (--> (completing-read "Source: "
                                      (mapcar #'cdr key->formatted)
                                      nil t nil nil
                                      (-some->
                                          (minaduki-db//fetch-lit-entry
                                           (minaduki-lit/key-at-point))
                                        minaduki-lit/format-entry))
                     (rassoc it key->formatted)
                     car)))
    (minaduki/literature-note-actions key)))

;;;###autoload
(cl-defun minaduki/new-concept-note (&key title visit?)
  "Create a new concept note with TITLE.

Return the path of the newly created note.

If VISIT? is non-nil, go to the newly created note."
  (interactive
   (list :title (read-string "Title: ")
         :visit? t))
  (let* ((file (-> (minaduki//title-to-slug title)
                   (f-expand org-directory)
                   (concat ".org")))
         (org-capture-templates
          `(("a" "" plain
             (file ,file)
             ,(format "#+title: %s\n" title)
             :jump-to-captured ,visit?
             :immediate-finish t))))
    (org-capture nil "a")
    file))

;;;###autoload
(defun minaduki/new-daily-note (&optional day)
  "Create a new daily note on DAY.

This will create diary/20211129.org on the day 2021-11-29, then
fill it in with the \"daily\" template."
  (interactive)
  (let* ((day (or day (minaduki//today)))
         (now (pcase-let ((`(,y ,m ,d)
                           (mapcar
                            #'string-to-number
                            (cdr (s-match (rx (group (= 4 digit)) "-"
                                              (group (= 2 digit)) "-"
                                              (group (= 2 digit)))
                                          day)))))
                (encode-time `(0 0 0 ,d ,m ,y nil nil nil))))
         (filename (s-replace "-" "" day))
         (ext "org"))
    (find-file (f-join minaduki/diary-directory
                       (concat filename "." ext)))
    (let (;; This is how you pass arguments to org-capture-fill-templates
          ;; It's either this or `org-capture-put'; this is
          ;; less ugly.
          (org-capture-plist (list :default-time now))
          ;; Since we're creating a daily note, this
          ;; variable should not be used.
          (org-extend-today-until 0))
      (insert
       (minaduki-templates//make-note "daily")))))

;;;###autoload
(defun minaduki/new-diary-entry (&optional time)
  "Create a new diary entry in `minaduki/diary-directory'.

The entry will be stored as a file named after the current time
under `minaduki/diary-directory'. Example:

    diary/20211019T233513+0900.org

When TIME is non-nil, create an entry for TIME instead of
`current-time'."
  (interactive
   (list (and current-prefix-arg
              (parse-iso8601-time-string
               (read-string "Create new diary entry at (yyyymmddThhmmssz): ")))))
  (let* ((now (or time (current-time)))
         (filename (format-time-string "%Y%m%dT%H%M%S%z" now))
         (title (format-time-string "%FT%T%z" now))
         ;; Put this here so if we allow different templates later
         ;; it's easier to change
         (ext "org"))
    (find-file (f-join minaduki/diary-directory
                       (concat filename "." ext)))
    (insert (concat "#+title: " title "\n"))))

;;;###autoload
(defun minaduki/open-diary-entry ()
  "Open a diary entry.

By default, open one from today. With a \\[universal-argument],
prompt to select a day first.

When there are multiple diary entries, prompt for selection.

Diary entries are files in `minaduki/diary-directory' that
are named with a YYYYMMDD prefix (optionally with dashes)."
  (declare (interactive-only minaduki-diary//find-entry-for-day))
  (interactive)
  (let ((day
         ;; Why not `cond': if we're in the calendar buffer but our cursor
         ;; is not on a date (so `calendar-cursor-to-date' is nil), we want
         ;; to fall back to the next case. `cond' doesn't do that.
         (or (and (derived-mode-p 'calendar-mode)
                  (-some-> (calendar-cursor-to-date)
                    minaduki//date/calendar.el->ymd))

             (and current-prefix-arg
                  (minaduki//read-date "Visit diary entry from day:"))

             (minaduki//today))))
    (if-let ((file (minaduki//find-entry-for-day day)))
        (find-file file)
      (and (y-or-n-p (format "No entry from %s. Create one? " day))
           (minaduki/new-daily-note day)))))

;;;###autoload
(defun minaduki/open-diary-entry-yesterday ()
  "Open a diary entry from yesterday."
  (interactive)
  (let ((day (minaduki//today -1)))
    (if-let ((file (minaduki//find-entry-for-day day)))
        (find-file file)
      (and (y-or-n-p (format "No entry from %s. Create one? " day))
           (minaduki/new-daily-note day)))))

;;;###autoload
(defun minaduki/open-template ()
  "Open a template in `minaduki/templates-directory' for edit."
  (interactive)
  ;; Setting `default-directory' to (a) skip passing the directory to
  ;; `f-relative' and `f-expand', and (b) make sure each entry points
  ;; to the right file as relative links. Without this, we have to
  ;; settle for not setting the category correctly.
  (minaduki//find-file
   (minaduki-templates//read-template "Open template: ")))

;;;###autoload
(defun minaduki/open-directory ()
  "Open `org-directory'."
  (interactive)
  (find-file org-directory))

;;;###autoload
(defun minaduki/open-random-note ()
  ;; Originally `org-roam-random-note'
  "Open a random note."
  (interactive)
  (find-file (seq-random-elt (minaduki//list-all-files))))

;;;###autoload
(defun minaduki/open-index ()
  ;; originally `org-roam-jump-to-index'
  "Open the index file.

The index file is specified in this order:

- `org-roam-index-file' (a string or function, see its docstring)
- A note with a title of \"Index\" in `org-directory'"
  (interactive)
  (let ((index (cond
                ((functionp org-roam-index-file)
                 (f-expand (funcall org-roam-index-file)
                           org-directory))
                ((stringp org-roam-index-file)
                 (f-expand org-roam-index-file))
                (t
                 (car (minaduki-db//fetch-file :title "Index"))))))
    (if (and index (f-exists? index))
        (minaduki//find-file index)
      (when (y-or-n-p "Index file does not exist.  Would you like to create it? ")
        (minaduki/open "Index")))))

;;;###autoload
(defun minaduki/open (&optional entry)
  ;; Some usages:
  ;; (minaduki/open title)
  ;; (minaduki/open
  ;;   (minaduki-completion//read-note :initial-input initial-input))
  "Find and open the note ENTRY.

ENTRY is a plist (:path PATH :title TITLE). It can also be a
string, in which case it refers to a (maybe non-existent) note
with it as the title.

Interactively, provide a list of notes to search and select from.
If a note with the entered title does not exist, create a new
one."
  (interactive
   (list (minaduki-completion//read-note)))
  (when (stringp entry)
    (setq entry
          (list :path (car (minaduki-db//fetch-file :title entry))
                :title entry)))
  (let ((path (plist-get entry :path))
        (title (plist-get entry :title)))
    (cond ((plist-get entry :new?)
           (minaduki/new-concept-note
            :title title
            :visit? t))
          ((plist-get entry :id?)
           (minaduki/open-id path))
          (t
           (minaduki//find-file path)))))

(defun minaduki/open-id (id)
  "Open an ID.

This assumes ID is present in the cache database."
  (when-let ((marker
              ;; Locate ID's location in FILE
              (let ((file (minaduki-db//fetch-file :id id)))
                (when file
                  (minaduki//with-file file t
                    (org-id-find-id-in-file id file t))))))
    (org-mark-ring-push)
    (org-goto-marker-or-bmk marker)
    (set-marker marker nil)))

(defun minaduki/open-id-at-point ()
  "Open the ID link at point.

This function hooks into `org-open-at-point' via
`org-open-at-point-functions'."
  (let* ((context (org-element-context))
         (type (org-element-property :type context))
         (id (org-element-property :path context)))
    (when (string= type "id")
      ;; `org-open-at-point-functions' expects member functions to
      ;; return t if we visited a link, and nil if we haven't (to move
      ;; onto the next method or onto the default).
      (or (and (minaduki/open-id id)
               t)
          ;; No = stop here = return t
          (and (not (y-or-n-p "ID not found in the cache. Search with `org-id-files' (may be slow)? "))
               t)))))

;;;; Literature note actions

(defun minaduki/copy-citekey (citekey)
  "Save note's citation key to `kill-ring' and copy it to clipboard.
CITEKEY is a list whose car is a citation key."
  (with-temp-buffer
    (insert citekey)
    (copy-region-as-kill (point-min) (point-max))))

(defun minaduki/visit-source (citekey)
  "Visit the source (URL, file path, DOI...) of CITEKEY."
  (let ((entry (caar (minaduki-db/query
                      [:select [props] :from keys
                       :where (= key $s1)]
                      citekey)))
        sources)
    (setq sources (minaduki//resolve-org-links (gethash "sources" entry)))
    (setq minaduki-lit//cache nil)
    (cl-case (length sources)
      (0 (message "%s has no associated source" citekey))
      (1 (browse-url (car sources)))
      (t (browse-url
          (completing-read "Which one: " sources nil t))))))

(defun minaduki/show-entry (citekey)
  "Go to where CITEKEY is defined."
  (-let ((((file point)) ; oh god this destructuring is so ugly
          (minaduki-db/query
           [:select [file point] :from keys
            :where (= key $s1)]
           citekey)))
    (minaduki//find-file file)
    (goto-char point)
    (when (eq major-mode 'org-mode)
      ;; Doing this because for some reason `org-back-to-heading'
      ;; goes to the parent of the current heading
      (org-up-element) ; up to the property drawer
      (org-up-element)))) ; up to the heading

(defun minaduki/insert-note-to-citekey (citekey)
  "Insert a link to the note associated with CITEKEY."
  (-if-let* ((path
              (caar (minaduki-db/query
                     [:select [file] :from refs
                      :where (= ref $s1)]
                     citekey)))
             (title (minaduki-db//fetch-title path)))
      ;; A corresponding note already exists. Insert a link to it.
      (minaduki/insert :entry (list :path path :title title))
    ;; There is no corresponding note. Barf about it for now. Ideally
    ;; we'd create a note as usual, and insert a link after that's
    ;; done. But I don't know how to do that with the current
    ;; templates system.
    (message
     "@%s does not have an associated note file. Please create one first."
     citekey)))

;;;; Managing literature entries

;; Literature entries are like entries in a .bib file.

(defun minaduki-lit/org-set-id ()
  "Make the heading at point a literature entry."
  (interactive)
  (cl-loop for prop in (list minaduki-lit/key-prop "date")
           do (org-entry-put nil prop (org-read-property-value prop))))

(defun minaduki-lit/new-entry ()
  "Add a new literature entry."
  (interactive)
  (let ((target-biblio
         (cond
          ((stringp minaduki-lit/bibliography)
           minaduki-lit/bibliography)
          ((= 1 (length minaduki-lit/bibliography))
           (car minaduki-lit/bibliography))
          (t
           (let ((default-directory org-directory)
                 (maybe-relative
                  (cl-loop
                   for f in minaduki-lit/bibliography
                   collect (if (f-descendant-of? f org-directory)
                               (f-relative f org-directory)
                             f))))
             (-->
              maybe-relative
              (minaduki-completion//mark-category it 'file)
              (completing-read "Which bibliography? " it nil t)
              f-expand))))))
    ;; Use find-file to ensure we save into it
    (find-file target-biblio)
    ;; Go to just before the first heading
    (goto-char (point-min))
    (outline-next-heading)
    (forward-char -1)
    ;; Actually insert the new entry
    (minaduki-lit/insert-new-entry-from-url
     (read-string "Create new literature entry for URL: "))
    ;; Save the buffer
    (basic-save-buffer)))

;;;###autoload
(defun minaduki/new-literature-note ()
  "Create a new literature note.

This first adds an entry for it into a file in
`minaduki-lit/bibliography'."
  (interactive)
  (call-interactively #'minaduki-lit/new-entry)
  (orb-edit-notes (org-entry-get nil minaduki-lit/key-prop)))

;;;; Actions

(defvar minaduki/global-commands
  '(("Open or create a note"              . minaduki/open)
    ("Browse literature sources"          . minaduki/literature-sources)
    ("Open notes directory"               . minaduki/open-directory)
    ("Open or create a template"          . minaduki/open-template)
    ("Create a new diary entry"           . minaduki/new-diary-entry)
    ("Create a new concept note"          . minaduki/new-concept-note)
    ("Create a new note with the \"daily\" template" . minaduki/new-daily-note)
    ("Find broken local links"            . minaduki/fix-broken-links)
    ("Open the index file"                . minaduki/open-index)
    ("Create a new literature"            . minaduki/new-literature-note)
    ("Open a random note"                 . minaduki/open-random-note)
    ("Switch to a buffer visiting a note" . org-roam-switch-to-buffer)
    ("Refresh cache"                      . minaduki-db/build-cache))
  "Global commands shown in `minaduki/command-palette'.

List of (DISPLAY-NAME . COMMAND) pairs.")

(defun minaduki/command-palette ()
  "Command palette."
  (declare (interactive-only command-execute))
  (interactive)
  (let* ((candidates minaduki/global-commands)
         (selection (completing-read "Minaduki Global Command: " candidates))
         (func (cdr (assoc selection candidates)))
         (prefix-arg current-prefix-arg))
    (command-execute func)))

(defvar minaduki/literature-note-actions
  '(("Open URL, DOI, or PDF" . minaduki/visit-source)
    ("Show entry in the bibliography file" . minaduki/show-entry)
    ("Edit notes" . orb-edit-notes)
    ("Copy citekey" . minaduki/copy-citekey)
    ("Insert citekey" . insert)
    ("Insert link to associated notes" . minaduki/insert-note-to-citekey))
  "Commands useful inside a literature note.

List of (DISPLAY-NAME . FUNCTION) pairs. Each function receives
one argument, the citekey.

Equivalent to `orb-note-actions-default'.")

;; TODO: Try the selected action for all keys
(defun minaduki/literature-note-actions (&optional citekey)
  ;; `orb-note-actions'
  "Prompt for note-related actions on CITEKEY.

CITEKEY is, by default, the first ROAM_KEY in the buffer.

Actions are defined in `minaduki/literature-note-actions'."
  (interactive)
  (-if-let* ((citekey (or citekey (cdar (minaduki-extract/refs)))))
      (let* ((prompt (format "Actions for %s: " citekey))
             (candidates minaduki/literature-note-actions)
             (selection (completing-read prompt candidates))
             (func (cdr (assoc selection candidates))))
        (funcall func citekey))
    (user-error "Could not retrieve the citekey, is ROAM_KEY specified?")))

(provide 'minaduki-commands)

;;; minaduki-commands.el ends here
