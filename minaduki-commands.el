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
(require 'minaduki-vault)
(require 'kisaragi-notes-templates)

(require 'minaduki-extract)
(require 'minaduki-db)
(require 'org-roam-capture)
(require 'minaduki-bibtex)

(defvar ivy-sort-functions-alist)
(defvar selectrum-should-sort)

;;;; Org-specific local commands

(defun minaduki/org-heading-to-file//suffix (&optional dir full? visit?)
  "Write the current heading to a file under DIR.

DIR defaults to current directory (`default-directory').

The name of the created file is based on the heading. By default,
this is the first WORD of the heading; if FULL? is non-nil, this
happens:

- take the entire heading
- dashes and colons are removed,
- then spaces are replaced with dashes,
- and everything is turned into lowercase (except the T in a timestamp).

For example, given a heading \"2020-05-29T00:00:00+0800 my heading\",
when FULL? is non-nil the file name will be
\"20200529T000000+0800-my-heading.org\", otherwise it will be
\"20200529T000000+0800.org\".

When VISIT? is non-nil, visit the new file after creating it.

Interactively, please use the transient command instead."
  (interactive (let ((args (transient-args 'minaduki/org-heading-to-file)))
                 (transient-save)
                 (list (transient-arg-value "--dir=" args)
                       (transient-arg-value "--full" args)
                       (transient-arg-value "--open" args))))
  (let* ((dir (or dir default-directory))
         (title (org-entry-get nil "ITEM"))
         (filename (->> (if full?
                            title
                          (car (s-split " " title)))
                        (replace-regexp-in-string (rx (any "-/,:?\"!'\\")) "")
                        (replace-regexp-in-string " +" "-")
                        downcase
                        (replace-regexp-in-string (rx (group digit) "t" (group digit))
                                                  "\\1T\\2")
                        (format "%s.org")))
         (path (f-join dir filename))
         (content (save-mark-and-excursion
                    (org-mark-subtree)
                    (buffer-substring-no-properties
                     (region-beginning)
                     (region-end)))))
    (with-temp-file path
      (insert content))
    (when visit?
      (find-file path))))

(transient-define-prefix minaduki/org-heading-to-file ()
  "Export heading at point to a file."
  ["Options"
   ("-d" "Directory to export to" "--dir=" transient-read-directory)
   ("-f" "Use the entire heading instead of just the first WORD" "--full")
   ("-v" "Open the exported file" "--open")]
  ["Command"
   ("e" "Export" minaduki/org-heading-to-file//suffix)])

(defun minaduki-org//id-new-advice (&rest _args)
  "Update the database if a new Org ID is created."
  (when (and (minaduki//in-vault?)
             (not (eq minaduki-db/update-method 'immediate))
             (not (minaduki-capture/p)))
    (minaduki-db/update)))

(defun minaduki-org//move-to-row-col (s)
  "Move to row:col if S match the row:col syntax.

To be used with `org-execute-file-search-functions'."
  (when (string-match (rx (group (1+ digit))
                          ":"
                          (group (1+ digit))) s)
    (let ((row (string-to-number (match-string 1 s)))
          (col (string-to-number (match-string 2 s))))
      (org-goto-line row)
      (move-to-column (- col 1))
      t)))

(defun minaduki-cite//follow (datum _)
  "The follow function for Minaduki's Org-cite processor.

This will extract the citation key from DATUM and ask the user
what they want to do with it."
  (let ((key
         ;; Taken from the `basic' processor's follow function
         (if (eq 'citation-reference (org-element-type datum))
             (org-element-property :key datum)
           (pcase (org-cite-get-references datum t)
             (`(,key) key)
             (keys
              (or (completing-read "Select citation key: " keys nil t)
                  (user-error "Aborted")))))))
    (minaduki/local-commands key)))

;;;; Markdown-specific local commands

(defun minaduki-markdown-follow (&optional other)
  "Follow thing at point.

Like `markdown-follow-thing-at-point', but has support for:

- Obsidian links,
- ID links (written as [text](#<ID>), ie. a path starting with a hash)

When OTHER is non-nil (with a \\[universal-argument]),
open in another window instead of in the current one."
  (interactive "P")
  (let ((markdown-enable-wiki-links t))
    (when other (other-window 1))
    (cond ((markdown-wiki-link-p)
           (minaduki//find-file (minaduki-obsidian-path (match-string 3))))
          ((markdown-link-p)
           (let ((url (markdown-link-url)))
             (if (s-prefix? "#" url)
                 (minaduki/open-id (substring url 1))
               (markdown-follow-thing-at-point other))))
          (t (markdown-follow-thing-at-point other)))))


;;;; Local commands

;; TODO: Specify what you want with a C-u; reject existing IDs
(defun minaduki/id ()
  "Assign an ID to the current heading."
  (interactive)
  (pcase (minaduki--file-type)
   ('markdown
    (unless (minaduki-extract::markdown-heading-id)
      (save-excursion
        (outline-back-to-heading)
        (end-of-line)
        (insert (format " {#%s}" (org-id-new))))))
   ('org
    (org-id-get-create))))

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
REGION: the selected text."
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
  (let* ((title (oref entry title))
         (path (oref entry path))
         (path (setq path (minaduki::ensure-not-file:// path)))
         (desc title))
    ;; We avoid creating a new note if the path is a URL or it refers
    ;; to an existing file.
    ;;
    ;; This also allows inserting references to existing notes whose
    ;; title happens to be a URL without issue.
    (when (and (oref entry new?)
               (not (minaduki//url? path))
               (not (f-exists? path)))
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
             :target (or (oref entry id)
                         (oref entry path))
             :desc desc
             :id? (oref entry id)))))

;;;###autoload
(defun minaduki-add-alias ()
  "Add an alias."
  (interactive)
  (let ((alias (read-string "Alias: ")))
    (when (string-empty-p alias)
      (user-error "Alias can't be empty"))
    (org-with-point-at 1
      (let ((case-fold-search t))
        (if (re-search-forward "^#\\+alias: .*" nil t)
            (insert "\n")
          ;; Skip past the first block of keywords and property drawer
          (while (and (not (eobp))
                      (looking-at "^[#:]"))
            (if (> (line-end-position) (1- (buffer-size)))
                (progn
                  (end-of-line)
                  (insert "\n"))
              (forward-line)
              (beginning-of-line))))
        (insert "#+alias: " alias)))
    (when (minaduki//in-vault?)
      (minaduki-db//insert-meta 'update))
    alias))

;;;###autoload
(defun minaduki-delete-alias ()
  "Delete an alias."
  (interactive)
  (if-let ((aliases (minaduki-extract/aliases)))
      (let ((alias (completing-read "Alias: " aliases nil 'require-match)))
        (org-with-point-at 1
          (let ((case-fold-search t))
            (when (search-forward (concat "#+alias: " alias) (point-max) t)
              (delete-region (line-beginning-position)
                             (1+ (line-end-position))))))
        (when (minaduki//in-vault?)
          (minaduki-db//insert-meta 'update)))
    (user-error "No aliases to delete")))

(defun minaduki//current-file-name ()
  "Return current file name in a consistent way."
  (or minaduki//file-name
      (buffer-file-name (buffer-base-buffer))))

;;;###autoload
(defun minaduki-add-tag ()
  "Add a tag."
  (interactive)
  (let* ((all-tags (minaduki-db//fetch-all-tags))
         (tag (completing-read "Tag: " all-tags))
         (existing-tags (minaduki-extract//tags/org-prop)))
    (when (string-empty-p tag)
      (user-error "Tag can't be empty"))
    (org-roam--set-global-prop
     "tags[]"
     (combine-and-quote-strings (seq-uniq (cons tag existing-tags))))
    (when (minaduki//in-vault?)
      (minaduki-db//insert-meta 'update))
    tag))

;;;###autoload
(defun minaduki-delete-tag ()
  "Delete a tag from Org-roam file."
  (interactive)
  (if-let* ((tags (minaduki-extract//tags/org-prop)))
      (let ((tag (completing-read "Tag: " tags nil 'require-match)))
        (org-roam--set-global-prop
         "tags[]"
         (combine-and-quote-strings (delete tag tags)))
        (when (minaduki//in-vault?)
          (minaduki-db//insert-meta 'update)))
    (user-error "No tag to delete")))

;;;; Global commands

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
(defun minaduki/literature-entries ()
  "List all sources for browsing interactively."
  (interactive)
  (let ((minaduki-completion//read-lit-entry//citekey
         (minaduki-extract/key-at-point)))
    (minaduki/local-commands
     (car (minaduki-completion//read-lit-entry nil :prompt "Entry: ")))))

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
(cl-defun minaduki/diary-next (&optional (n 1))
  "Go to the Nth next diary entry."
  (interactive "p")
  (let* ((current-file (minaduki//current-file-name))
         (siblings (directory-files (f-dirname current-file))))
    (--> (cl-position (f-filename current-file)
                      siblings
                      :test #'equal)
         (+ it n)
         (% it (length siblings))
         (nth it siblings)
         minaduki//find-file)))

;;;###autoload
(cl-defun minaduki/diary-prev (&optional (n 1))
  "Go to the Nth previous diary entry."
  (interactive "p")
  (minaduki/diary-next (- n)))

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
          (minaduki-node
           :path (car (minaduki-db//fetch-file :title entry))
           :title entry)))
  (let ((path (oref entry path))
        (title (oref entry title)))
    (cond ((oref entry new?)
           (minaduki/new-concept-note
            :title title
            :visit? t))
          ((oref entry id)
           (minaduki/open-id (oref entry id)))
          (t
           (minaduki//find-file path)))))

(defun minaduki/open-id (id &optional other?)
  "Open an ID.

This assumes ID is present in the cache database.

If OTHER? is non-nil, open it in another window, otherwise in the
current window."
  ;; Locate ID's location in FILE
  (when-let (file (minaduki-db//fetch-file :id id))
    (minaduki//find-file file other?)
    ;; FIXME: This is wrong.
    ;; TODO: Please store point location of IDs.
    (goto-char (point-min))
    (search-forward id)))

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

(defun orb-edit-notes (citekey)
  "Open a note associated with the CITEKEY or create a new one.

CITEKEY's information is extracted from files listed in
`minaduki-lit/bibliography' during Minaduki's cache build
process."
  (let* ((file (minaduki-db//fetch-file :key citekey))
         (title (minaduki-db//fetch-title file)))
    (cond
     (file (minaduki//find-file file))
     (t (let ((props (or (-some-> (minaduki-db//fetch-lit-entry citekey)
                           (oref props))
                         (minaduki//warn
                          :warning
                          "Could not find the literature entry %s" citekey))))
          (puthash "=key=" (gethash "key" props) props)
          (remhash "key" props)
          (puthash "=type=" (gethash "type" props) props)
          (remhash "type" props)
          (setq props (map-into props 'alist))
          (if-let* (;; Depending on the templates used: run
                    ;; `minaduki-capture//capture' or call `org-roam-find-file'
                    (org-capture-templates
                     (or orb-templates minaduki-capture/templates
                         (minaduki//warn
                          :warning
                          "Could not find the requested templates")))
                    ;; hijack org-capture-templates
                    ;; entry is our bibtex entry, it just happens that
                    ;; `org-capture' calls a single template entry "entry";
                    (template (--> (if (null (cdr org-capture-templates))
                                       ;; if only one template is defined, use it
                                       (car org-capture-templates)
                                     (org-capture-select-template))
                                   (copy-tree it)
                                   ;; optionally preformat templates
                                   ;; TODO: the template system needs
                                   ;; a rebuild.
                                   (if orb-preformat-templates
                                       (orb--preformat-template it props)
                                     it)))
                    ;; pretend we had only one template
                    ;; `minaduki-capture//capture' behaves specially in this case
                    ;; NOTE: this circumvents using functions other than
                    ;; `org-capture', see `minaduki-capture/function'.
                    ;; If the users start complaining, we may revert previous
                    ;; implementation
                    (minaduki-capture/templates (list template))
                    ;; Org-roam coverts the templates to its own syntax;
                    ;; since we are telling `org-capture' to use the template entry
                    ;; (by setting `org-capture-entry'), and Org-roam converts the
                    ;; whole template list, we must do the conversion of the entry
                    ;; ourselves
                    (org-capture-entry
                     (minaduki-capture//convert-template template))
                    (citekey-formatted (format (or orb-citekey-format "%s") citekey))
                    (title
                     (or (cdr (assoc "title" props))
                         (minaduki//warn
                          :warning
                          "Title not found for this entry")
                         ;; this is not critical, the user may input their own
                         ;; title
                         "Title not found")))
              (progn
                ;; fix some Org-ref related stuff
                (orb--store-link-functions-advice 'add)
                (unwind-protect
                    ;; data collection hooks functions: remove themselves once run
                    (progn
                      ;; Depending on the templates used: run
                      ;; `minaduki-capture//capture' with ORB-predefined
                      ;; settings or call vanilla `org-roam-find-file'
                      (if orb-templates
                          (let* ((minaduki-capture//context 'ref)
                                 (slug-source (cl-case orb-slug-source
                                                (citekey citekey)
                                                (title title)
                                                (t (user-error "Only `citekey' \
or `title' should be used for slug: %s not supported" orb-slug-source))))
                                 (minaduki-capture//info
                                  `((title . ,title)
                                    (ref . ,citekey-formatted)
                                    ,@(when-let (url (cdr (assoc "url" props)))
                                        `((url . ,url)))
                                    (slug . ,(minaduki//title-to-slug slug-source)))))
                            (setq minaduki-capture/additional-template-props
                                  (list :finalize 'find-file))
                            (minaduki-capture//capture))
                        (minaduki/open title)))
                  (orb--store-link-functions-advice 'remove)))
            (message "ORB: Something went wrong. Check the *Warnings* buffer")))))))

(defun minaduki/insert-citation (citekey)
  "Insert a citation to CITEKEY."
  (pcase (minaduki--file-type)
    ('org
     (let ((minaduki-completion//read-lit-entry//citekey citekey))
       (org-cite-insert nil)))
    (_ (insert "@" citekey))))

(defun minaduki/copy-citekey (citekey)
  "Save note's citation key to `kill-ring' and copy it to clipboard.
CITEKEY is a list whose car is a citation key."
  (with-temp-buffer
    (insert citekey)
    (copy-region-as-kill (point-min) (point-max)))
  (message "Copied \"%s\"" citekey))

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

;;;###autoload
(defun minaduki/new-literature-note ()
  "Create a new literature note.

This first adds an entry for it into a file in
`minaduki-lit/bibliography'."
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
              f-expand)))))
        (info (minaduki-lit/fetch-new-entry-from-url
               (read-string "Create new literature entry for URL: "))))
    ;; Use find-file to ensure we save into it
    (find-file target-biblio)
    (pcase (minaduki--file-type)
      ('org
       ;; Go to just before the first heading
       (goto-char (point-min))
       (outline-next-heading)
       (forward-char -1)
       (unless (eq ?\n (char-before))
         (insert "\n"))
       (insert (format "%s %s\n"
                       (make-string (1+ (or (org-current-level)
                                            0))
                                    ?*)
                       (plist-get info :title)))
       (org-entry-put nil "url"    (plist-get info :url))
       (org-entry-put nil "author" (plist-get info :author))
       (org-entry-put nil "date"   (plist-get info :date))
       (dolist (prop '("url" "author" "date"))
         (let ((value (org-read-property-value prop)))
           (unless (or (null value)
                       (string= value ""))
             (org-entry-put nil prop value)
             (setq info (plist-put info prop value)))))
       (setq info (plist-put info
                             :citekey (minaduki-lit/generate-key-at-point))))
      ('json
       (goto-char (point-min))
       (let ((v (json-read)))
         (dolist (prop '(:author :date))
           (let ((value (read-string (substring (format "%s: " prop) 1)
                                     (plist-get info prop))))
             (unless (or (null value)
                         (string= value ""))
               (setq info (plist-put info prop value)))))
         (setq info (plist-put info :citekey (minaduki-lit/generate-key
                                              :author (plist-get info :author)
                                              :date (plist-get info :date))))
         (replace-region-contents
          (point-min) (point-max)
          (lambda ()
            (let ((json-encoding-pretty-print t))
              (json-encode
               (vconcat
                (list `((author . ,(->> (plist-get info :author)
                                        (s-split " and ")
                                        (--map `((literal . ,it)))
                                        vconcat))
                        (date . ,(plist-get info :date))
                        (url . ,(plist-get info :url))
                        (type . ,(f-base target-biblio))
                        (id . ,(plist-get info :citekey))
                        (title . ,(plist-get info :title))))
                v))))))))
    ;; Save the buffer
    (basic-save-buffer)
    (-when-let (citekey (plist-get info :citekey))
      (orb-edit-notes citekey))))

;;;; Actions

(defvar minaduki/global-commands
  '(("Open or create a note"              . minaduki/open)
    ("Browse literature entries"          . minaduki/literature-entries)
    ("Open notes directory"               . minaduki/open-directory)
    ("Open or create a template"          . minaduki/open-template)
    ("Create a new diary entry"           . minaduki/new-diary-entry)
    ("Create a new concept note"          . minaduki/new-concept-note)
    ("Create a new note with the \"daily\" template" . minaduki/new-daily-note)
    ("Find broken local links"            . minaduki/fix-broken-links)
    ("Open the index file"                . minaduki/open-index)
    ("Create a new literature"            . minaduki/new-literature-note)
    ("Open a random note"                 . minaduki/open-random-note)
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
    ("Insert citation" . minaduki/insert-citation)
    ("Insert link to associated notes" . minaduki/insert-note-to-citekey))
  "Commands useful inside a literature note.

List of (DISPLAY-NAME . FUNCTION) pairs. Each function receives
one argument, the citekey.

Equivalent to `orb-note-actions-default'.")

(defvar minaduki::local-commands
  '(("Create ID for current heading" . minaduki/id)
    ("Insert a link"                 . minaduki/insert)
    ("Add an alias"                  . minaduki-add-alias)
    ("Delete an alias"               . minaduki-delete-alias)
    ("Add a tag"                     . minaduki-add-tag)
    ("Delete a tag"                  . minaduki-delete-tag))
  "Local commands that act on the current file or heading.")

;; TODO: Try the selected action for all keys
(defun minaduki/local-commands (&optional citekey)
  "Prompt for note-related actions.

CITEKEY defaults to the first ROAM_KEY in the buffer.

Actions are defined in `minaduki::local-commands'. If CITEKEY is
given or can be retrieved, actions from
`minaduki/literature-note-actions' are also used."
  (interactive)
  (let* ((citekey (or citekey (cdar (minaduki-extract/refs))))
         (prompt (format "Actions for %s: "
                         (or citekey
                             (minaduki-extract/main-title))))
         (candidates (-sort
                      (-on #'string< #'car)
                      `(,@minaduki::local-commands
                        ,@(when citekey
                            minaduki/literature-note-actions))))
         (selection (completing-read prompt candidates))
         (func (cdr (assoc selection candidates))))
    (if (= (car (func-arity func))
           1)
        (funcall func citekey)
      (funcall func))))

(provide 'minaduki-commands)

;;; minaduki-commands.el ends here
