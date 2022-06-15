;;; minaduki-lit.el --- Literature note management -*- lexical-binding: t -*-

;;; Commentary:

;; This defines three things:
;;
;; - A format for bibliography files using Org properties
;; - Functions to read entries from that format or from BibTex
;; - A function that takes the parsed entries and formats them for display
;;
;; Additionally, there are also commands that allow the browsing of
;; the stored entries, similar to bibtex-completion. As a goal, I hope
;; to add more commands to manage or add entries without having to
;; edit the bibliography directly.
;;
;; Entries are articles, books, etc., anything one might like to have
;; a literature note for.
;;
;; The entries are extracted and saved in the DB.
;;
;; BibTeX is also (somewhat) supported, but only after parsebib is
;; installed manually.
;;
;; * The bibliography format
;;
;; Each entry is stored as an Org heading; every heading with a
;; CUSTOM_ID (customizable with `minaduki-lit/key-prop') in a
;; bibliography file (ie. a member of `minaduki-lit/bibliography') is
;; a literature entry, analogous to a BibTeX entry.
;;
;; An entry like this:
;;
;;   * エイプリルフールに自殺しようとした女の子の話 :fiction:comic:doujin:yuri:
;;   :PROPERTIES:
;;   :url:      https://booth.pm/ja/items/655505
;;   :author:   純玲
;;   :date:     2019-05-12
;;   :custom_id: sumire2019
;;   :END:
;;
;; is equivalent to the bibtex entry
;;
;;   @book{sumire2019,
;;       author = {純玲},
;;       date = {2019-05-12},
;;       keywords = {{fiction}, {comic}, {doujin}, {yuri}},
;;       title = {エイプリルフールに自殺しようとした女の子の話},
;;       url = {https://booth.pm/ja/items/655505}
;;   }
;;
;; .
;;
;; TODO: support saving entries in JSON, maybe even in CSL-JSON
;; TODO: command to add sources, modify a source, or remove a source

;;; Code:


;; For `eww-parse-headers'
(require 'eww)
(require 'org)
(require 'dash)

(require 'minaduki-utils)
(require 'minaduki-vars)

(declare-function parsebib-find-next-item "parsebib")
(declare-function parsebib-read-entry "parsebib")

;;;; Type definition

(defvar minaduki-lit//cache nil)

(cl-defun minaduki-lit/entry (&key author date type title key sources tags others)
  "Return a hash table representing a source.

AUTHOR: the main entity responsible for the source.
TYPE: the type of the source, like \"book\".
TITLE: the name or title of the source.
KEY: the identifying string, like bibtex's ID.
SOURCES: a list of paths or urls that can be used to visit the
source.
TAGS: a list of tags.

OTHERS: other key -> value pairs."
  (let ((obj (make-hash-table :test #'equal)))
    (when author
      (puthash "author" author obj))
    (when type
      (puthash "type" type obj))
    (when title
      (puthash "title" title obj))
    (when date
      (puthash "date" date obj))
    (when key
      (puthash "key" key obj))
    (when sources
      (puthash "sources" (cl-coerce sources 'vector) obj))
    (when tags
      (puthash "tags" (cl-coerce tags 'vector) obj))
    (map-do
     (lambda (k v)
       (puthash (symbol-name k) v obj))
     others)
    obj))

(defun minaduki-lit/format-entry (entry)
  "Format ENTRY for display."
  (concat
   (minaduki--ensure-width
    (* 0.3 (frame-pixel-width))
    (format "%.4s %s%s %s"
            (or (gethash "date" entry)
                (gethash "year" entry)
                "")
            (or (-some-> (gethash "todo" entry)
                  (concat " "))
                "")
            (or (-some--> (gethash "type" entry)
                  (concat "@" it)
                  (propertize it 'face 'minaduki-type))
                "")
            (gethash "author" entry "")))
   (format "  %s %s"
           (gethash "title" entry "")
           (or (--> (gethash "tags" entry)
                    (--map (concat "#" it) it)
                    (s-join " " it)
                    (propertize it 'face 'minaduki-tag))
               ""))))

;;;; Bibliography

;;;; Reading from Org
(defun minaduki-lit/key-at-point ()
  "Return the key of the literature entry at point."
  (cond ((derived-mode-p 'org-mode)
         (let ((value (org-entry-get nil minaduki-lit/key-prop t)))
           (when (and value
                      (not (string= "" value)))
             value)))
        ((derived-mode-p 'json-mode)
         (save-excursion
           (let (here doc)
             (setq here (point))
             (goto-char (point-min))
             (setq doc (json-read))
             (->> (-> (json-path-to-position here)
                      (plist-get :path)
                      car)
                  (elt doc)
                  (alist-get 'id)))))))

(cl-defun minaduki-lit/generate-key (&key author date)
  "Generate a key from AUTHOR and DATE."
  (let* ((author
          (-some->> author
            (s-replace-all '((" " . "")
                             ("," . "")
                             ("/" . "")
                             ("?" . "")))
            downcase))
         (date
          (-some->> date
            (s-replace "--" "–")
            (s-replace "-" "")
            (s-replace "–" "--")
            ;; this should handle ISO 8601 timestamps
            (replace-regexp-in-string "T[[:digit:]].*" "")))
         (new-id
          (concat author (or date ""))))
    (unless (and author date)
      (setq new-id
            (read-string "The currently generated ID is too general. Make it more specific: " new-id)))
    new-id))

(defun minaduki-lit/generate-key-at-point ()
  "Set a key for the headline at point.

Return the generated key."
  (unless (org-entry-get nil minaduki-lit/key-prop)
    (let ((new-id
           (minaduki-lit/generate-key :author (org-entry-get nil "author")
                                      :date (or (org-entry-get nil "date")
                                                (org-entry-get nil "year")))))
      (org-entry-put nil minaduki-lit/key-prop new-id)
      new-id)))

(defun minaduki-lit/fetch-new-entry-from-url (url)
  "Fetch information from URL for a new entry."
  (let (dom)
    (message "Retrieving entry from %s..." url)
    (when-let ((buf (url-retrieve-synchronously url :silent)))
      ;; Extract the DOM first
      (with-current-buffer buf
        (decode-coding-region (point-min) (point-max) 'utf-8)
        (goto-char (point-min))
        ;; Move cursor after the headers
        (eww-parse-headers)
        (setq dom (libxml-parse-html-region (point) (point-max))))
      (let (title author publishdate)
        ;; Parse information out of it
        (setq title (or
                     ;; <meta name="title" content="...">
                     ;; Youtube puts "- YouTube" in <title>, so I want
                     ;; this first.
                     (-some--> (dom-by-tag dom 'meta)
                       (--first (equal (dom-attr it 'name) "title") it)
                       (dom-attr it 'content))
                     ;; Open Graph
                     ;; Also often without the site suffix
                     (-some--> (dom-by-tag dom 'meta)
                       (--first (equal (dom-attr it 'property) "og:title") it)
                       (dom-attr it 'content))
                     ;; <title>
                     (dom-texts (car (dom-by-tag dom 'title))))
              author (or
                      ;; <meta name="author" content="...">
                      (-some--> (dom-by-tag dom 'meta)
                        (--first (equal "author" (dom-attr it 'name)) it)
                        (dom-attr it 'content))
                      ;; <meta name="cXenseParse:author" content="...">
                      ;; nippon.com uses this
                      (-some--> (dom-by-tag dom 'meta)
                        (--first (equal "cXenseParse:author" (dom-attr it 'name)) it)
                        (dom-attr it 'content))
                      ;; WordPress entry header
                      ;; <body><div class="entry-meta">...<a rel="author" href=...>
                      (-some--> (dom-by-class dom "entry-meta")
                        (dom-by-tag it 'a)
                        (--first (equal "author" (dom-attr it 'rel)) it)
                        (dom-text it))
                      ;; YouTube stores this in a <div> in <body>...
                      ;; And yes, it's in a <span> for some reason
                      ;;
                      ;; Error here from GitHub as we end up with
                      ;; string nodes.
                      (ignore-errors
                        (-some--> (dom-by-tag dom 'span)
                          (--first (equal "author" (dom-attr it 'itemprop)) it)
                          dom-children
                          (--first (equal "name" (dom-attr it 'itemprop)) it)
                          (dom-attr it 'content))))
              publishdate (or
                           ;; Open Graph
                           ;; <meta property="article:published_time"
                           ;;       content="2019-08-29T09:54:00-04:00" />
                           (-some--> (dom-by-tag dom 'meta)
                             (--first (equal "article:published_time"
                                             (dom-attr it 'property))
                                      it)
                             (dom-attr it 'content))
                           ;; WordPress entry header
                           ;; <body><div class="entry-meta">...<time class="entry-date"...>
                           (-some--> (dom-by-class dom "entry-meta")
                             (dom-by-tag it 'time)
                             (--first (equal "entry-date" (dom-attr it 'class)) it)
                             (dom-text it))
                           ;; YouTube
                           (-some--> (dom-by-tag dom 'meta)
                             (--first (equal "datePublished" (dom-attr it 'itemprop)) it)
                             (dom-attr it 'content))
                           ;; Sites using Next.js
                           (-some--> (dom-by-id dom "__NEXT_DATA__")
                             dom-children
                             car
                             ;; Use `json-read-from-string' so it
                             ;; returns an alist, allowing us to use `let-alist'
                             (let-alist (json-read-from-string it)
                               (let-alist .props.pageProps
                                 (or
                                  ;; maggieappleton.com
                                  .frontMatter.startDate
                                  .frontMatter.updated
                                  ;; vercel.com
                                  .post.date))))))
        (message "Retrieving entry from %s...done" url)
        (list
         :author author
         :date publishdate
         :url url
         :title (replace-regexp-in-string "　" "" title))))))

;;;; Parsing

(defun minaduki-lit/parse-entries ()
  "Parse entries in the current buffer into entry objects.

Return a list of cons cells: (POINT . PROPS), where PROPS look
like `minaduki-lit/entry' objects."
  (let ((case-fold-search t))
    (save-excursion
      (goto-char (point-min))
      (cl-loop
       while (re-search-forward (format "^:%s:" minaduki-lit/key-prop) nil t)
       collect
       (let ((props (org-entry-properties)))
         ;; Remove properties that I'm not interested in
         (setq props
               (--remove
                (member (car it)
                        (-difference org-special-properties '("ITEM" "TODO")))
                props))
         (when-let (tags (org-get-tags))
           (push (cons "tags" tags) props))
         (setq props
               (--map
                (let ((key (car it))
                      (value (cdr it)))
                  ;; Downcase all keys
                  (setq key (downcase key))
                  ;; Key replacements
                  ;; (ORG_PROP . KEY)
                  (setq key (or (cdr
                                 (assoc
                                  key
                                  `(("category" . "type")
                                    (,minaduki-lit/key-prop . "key")
                                    ("item" . "title"))))
                                key))
                  (cons key value))
                props))
         ;; FIXME: this overwrites preexisting :sources:... values
         (let (sources)
           (when-let (pair (assoc "link" props))
             (push (cdr pair)
                   sources))
           (when-let (pair (assoc "url" props))
             (push (cdr pair)
                   sources))
           (when-let (pair (assoc "doi" props))
             (push (concat "https://doi.org/" (cdr pair))
                   sources))
           (when sources
             (push (cons "sources" sources) props)))
         (cons (point) (map-into props '(hash-table :test equal))))))))

(defun minaduki-lit/parse-entries/bibtex ()
  "Parse a BIBTEX-FILE into a list of (POINT . PROPS).

POINT is where the entry is in the file. PROPS is a
`minaduki-lit/entry' object."
  (require 'parsebib)
  (save-excursion
    (goto-char (point-min))
    (cl-loop for entry-type = (parsebib-find-next-item)
             while entry-type
             collect (let ((start-position (point))
                           (entry
                            (--map (cons (intern (car it))
                                         (cdr it))
                                   (parsebib-read-entry entry-type))))
                       (let-alist entry
                         (cons start-position
                               (minaduki-lit/entry
                                :author (minaduki//remove-curly .author)
                                :type .=type=
                                :key .=key=
                                :title (minaduki//remove-curly .title)
                                :tags
                                (-some->> .keywords
                                  minaduki//remove-curly
                                  (s-split ",")
                                  (-map #'s-trim))
                                :sources (-non-nil
                                          (mapcar #'minaduki//remove-curly
                                                  (list .link .url)))
                                :others
                                (cl-loop for (k . v) in entry
                                         unless (member k '(author =type= =key= title keywords url link))
                                         collect (cons k (minaduki//remove-curly v))))))))))

(defun minaduki-lit/csl-json/process-author (value)
  "Convert CSL-JSON's author VALUE to our format."
  (s-join " and "
          (--map
           (let-alist it
             (or .literal
                 (concat .family " " .given)))
           value)))

(defun minaduki-lit/csl-json/process-date (value)
  "Convert CSL-JSON's date VALUE to our format."
  ;; CSL-JSON date fields:
  ;; https://citeproc-js.readthedocs.io/en/latest/csl-json/markup.html#date-fields
  ;;
  ;; Possible cases:
  ;;
  ;; "2020-03-15" ;; EDTF*
  ;; {"raw": "2020-03-15"} ;; EDTF under key "raw"
  ;; {"literal": "2020-03-15"} ;; EDTF under key "literal"
  ;; {"date-parts": [[2020, 3, 15]]} ;; one or two arrays of Y, M, D
  ;;
  ;; *EDTF is a standardized extension to ISO 8601:
  ;;  https://en.wikipedia.org/wiki/ISO_8601#EDTF
  (cond ((stringp value)
         value)
        ((consp value)
         (let-alist value
           (or .raw
               .literal
               (->>
                .date-parts
                (--map
                 (-let (((y m d) (cl-coerce it 'list)))
                   (s-join "-" `(,(when y (format "%04d" y))
                                 ,(when m (format "%02d" m))
                                 ,(when d (format "%02d" d))))))
                (s-join "--")))))
        (t (error "Unknown CSL-JSON date format: %S"
                  value))))

(defun minaduki-lit/parse-entries/csl-json ()
  "Parse JSON entries in the current buffer.

Return a list of entries."
  ;; This is not quite correct. The proper way would be to use
  ;; `json-read' or `json-parse-buffer' and iterate over the result.
  ;; But that doesn't allow me to record cursor locations.
  (save-excursion
    (goto-char (point-min))
    (let ((json-object-type 'alist)
          (json-array-type 'vector)
          item ret)
      (while (and (search-forward "{" nil t)
                  (setq item (json-read-object)))
        (setq item (cl-loop
                    for (field . value) in item
                    collect
                    (pcase field
                      ('author (cons "author" (minaduki-lit/csl-json/process-author value)))
                      ('issued (cons "date" (minaduki-lit/csl-json/process-date value)))
                      ('id (cons "key" value))
                      (_ (cons (format "%s" field) value)))))
        (let (sources)
          (when-let (pair (assoc "link" item))
            (push (cdr pair)
                  sources))
          (when-let (pair (assoc "url" item))
            (push (cdr pair)
                  sources))
          (when-let (pair (assoc "doi" item))
            (push (concat "https://doi.org/" (cdr pair))
                  sources))
          (when sources
            (push (cons "sources" sources) item)))
        (-->
         (map-into item '(hash-table :test equal))
         (push (cons (point) it) ret)))
      (nreverse ret))))

(provide 'minaduki-lit)

;;; minaduki-lit.el ends here
