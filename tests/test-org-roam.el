;;; test-org-roam.el --- Tests for Org-roam -*- lexical-binding: t; -*-

;; Copyright (C) 2020 Jethro Kuan

;; Author: Jethro Kuan <jethrokuan95@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;; Code:

(require 'buttercup)
(require 'org-roam)
(require 'seq)
(require 'dash)

(defun test-org-roam--abs-path (file-path)
  "Get absolute FILE-PATH from `org-roam-directory'."
  (expand-file-name file-path org-roam-directory))

(defun test-org-roam--find-file (path)
  "PATH."
  (let ((path (test-org-roam--abs-path path)))
    (make-directory (file-name-directory path) t)
    (find-file path)))

(defvar test-org-roam-directory (expand-file-name "tests/roam-files")
  "Directory containing org-roam test org files.")

(defun test-org-roam--init ()
  "."
  (let ((original-dir test-org-roam-directory)
        (new-dir (expand-file-name (make-temp-name "org-roam") temporary-file-directory))
        (org-roam-verbose nil))
    (copy-directory original-dir new-dir)
    (setq org-roam-directory new-dir)
    (org-roam-mode +1)
    (sleep-for 2)))

(defun test-org-roam--teardown ()
  (org-roam-mode -1)
  (delete-file org-roam-db-location)
  (org-roam-db--close))

(describe "Utils"
  (it "converts a title to a slug"
    (expect (kisaragi-notes//title-to-slug "English")
            :to-equal "english")
    (expect (kisaragi-notes//title-to-slug "Text with space と漢字")
            :to-equal "text_with_space_と漢字")
    (expect (kisaragi-notes//title-to-slug "many____underscores")
            :to-equal "many_underscores")
    ;; Keep diacritics
    (expect (kisaragi-notes//title-to-slug "äöü")
            :to-equal "äöü")
    ;; Normalizes to composed from
    (expect (kisaragi-notes//title-to-slug (string ?て #x3099))
            :to-equal (string ?で))
    (expect (kisaragi-notes//title-to-slug "_starting and ending_")
            :to-equal "starting_and_ending")
    (expect (kisaragi-notes//title-to-slug "isn't alpha numeric")
            :to-equal "isn_t_alpha_numeric"))
  (it "removes Org links from a string"
    (expect
     (kisaragi-notes//remove-org-links
      "Abc [[https://gnu.org][Link1]] def [[https://gnu.org][Link2]]")
     :to-equal
     "Abc Link1 def Link2")
    (expect
     (kisaragi-notes//remove-org-links
      "Abc [not a link]")
     :to-equal
     "Abc [not a link]")
    (expect
     (kisaragi-notes//remove-org-links
      "Abc [[https://google.com]]")
     :to-equal
     "Abc https://google.com")
    (expect
     (kisaragi-notes//remove-org-links
      "Abc [[https://google.com][Google]]")
     :to-equal
     "Abc Google")))

(describe "Ref extraction"
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (cl-flet
      ((test (fn file)
             (let* ((fname (test-org-roam--abs-path file))
                    (buf (find-file-noselect fname)))
               (with-current-buffer buf
                 ;; Unlike tag extraction, it doesn't make sense to
                 ;; pass a filename.
                 (funcall fn)))))
    ;; Enable "cite:" link parsing
    (org-link-set-parameters "cite")
    (it "extracts web keys"
      (expect (test #'kisaragi-notes-extract/refs
                    "web_ref.org")
              :to-equal
              '(("website" . "//google.com/"))))
    (it "extracts cite keys"
      (expect (test #'kisaragi-notes-extract/refs
                    "cite_ref.org")
              :to-equal
              '(("cite" . "mitsuha2007")))
      (expect (test #'kisaragi-notes-extract/refs
                    "cite-ref.md")
              :to-equal
              '(("cite" . "sumire2019"))))
    (it "extracts all keys"
      (expect (test #'kisaragi-notes-extract/refs
                    "multiple-refs.org")
              :to-have-same-items-as
              '(("cite" . "orgroam2020")
                ("cite" . "plain-key")
                ("website" . "//www.orgroam.com/"))))))

(describe "Title extraction"
  :var (org-roam-title-sources)
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (cl-flet
      ((test (fn file)
             (let ((buf (find-file-noselect
                         (test-org-roam--abs-path file))))
               (with-current-buffer buf
                 (funcall fn)))))
    (it "extracts title from title property"
      (expect (test #'org-roam--extract-titles-title
                    "titles/title.org")
              :to-equal
              '("Title"))
      (expect (test #'org-roam--extract-titles-title
                    "titles/title.md")
              :to-equal
              '("Title in Markdown"))
      (expect (test #'org-roam--extract-titles-title
                    "titles/aliases.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-title
                    "titles/headline.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-title
                    "titles/combination.org")
              :to-equal
              '("TITLE PROP")))

    (it "extracts alias"
      (expect (test #'org-roam--extract-titles-alias
                    "titles/title.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-alias
                    "titles/aliases.org")
              :to-equal
              '("roam" "alias" "second" "line"))
      (expect (test #'org-roam--extract-titles-alias
                    "titles/headline.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-alias
                    "titles/combination.org")
              :to-equal
              '("roam" "alias")))

    (it "extracts headlines"
      (expect (test #'org-roam--extract-titles-alias
                    "titles/title.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-headline
                    "titles/aliases.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-titles-headline
                    "titles/headline.org")
              :to-equal
              '("Headline"))
      (expect (test #'org-roam--extract-titles-headline
                    "titles/headline.md")
              :to-equal
              '("Headline"))
      (expect (test #'org-roam--extract-titles-headline
                    "titles/combination.org")
              :to-equal
              '("Headline")))

    (describe "uses org-roam-title-sources correctly"
      (it "'((title headline) alias)"
        (expect (let ((org-roam-title-sources '((title headline) alias)))
                  (test #'org-roam--extract-titles
                        "titles/combination.org"))
                :to-equal
                '("TITLE PROP" "roam" "alias")))
      (it "'((headline title) alias)"
        (expect (let ((org-roam-title-sources '((headline title) alias)))
                  (test #'org-roam--extract-titles
                        "titles/combination.org"))
                :to-equal
                '("Headline" "roam" "alias")))
      (it "'(headline alias title)"
        (expect (let ((org-roam-title-sources '(headline alias title)))
                  (test #'org-roam--extract-titles
                        "titles/combination.org"))
                :to-equal
                '("Headline" "roam" "alias" "TITLE PROP"))))))

(describe "Link extraction"
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (cl-flet
      ((test (fn file)
             (let ((buf (find-file-noselect
                         (test-org-roam--abs-path file))))
               (with-current-buffer buf
                 (funcall fn)))))
    (it "extracts links from Markdown files"
      (expect (->> (test #'org-roam--extract-links
                         "baz.md")
                (--map (seq-take it 3)))
              :to-have-same-items-as
              `([,(test-org-roam--abs-path "baz.md")
                 ,(test-org-roam--abs-path "nested/bar.org")
                 "file"]
                [,(test-org-roam--abs-path "baz.md")
                 "乙野四方字20180920"
                 "cite"]
                [,(test-org-roam--abs-path "baz.md")
                 "quro2017"
                 "cite"])))
    (it "extracts links from Org files"
      (expect (->> (test #'org-roam--extract-links
                         "foo.org")
                ;; Drop the link type and properties
                (--map (seq-take it 2)))
              :to-have-same-items-as
              `([,(test-org-roam--abs-path "foo.org")
                 ,(test-org-roam--abs-path "baz.md")]
                [,(test-org-roam--abs-path "foo.org")
                 "foo@john.com"]
                [,(test-org-roam--abs-path "foo.org")
                 "google.com"]
                [,(test-org-roam--abs-path "foo.org")
                 ,(test-org-roam--abs-path "bar.org")])))))

(describe "Tag extraction"
  :var (kisaragi-notes/tag-sources)
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (cl-flet
      ((test (fn file)
             (let* ((fname (test-org-roam--abs-path file))
                    (buf (find-file-noselect fname)))
               (with-current-buffer buf
                 (funcall fn fname)))))
    (it "extracts from #+tags[]"
      (expect (test #'org-roam--extract-tags-prop
                    "tags/hugo-style.org")
              :to-equal
              '("hello" "tag2" "tag3")))
    (it "extracts hashtag style tags, but only from frontmatter"
      (expect (test #'kisaragi-notes-extract/tags-hashtag-frontmatter
                    "tags/tag.md")
              :to-equal
              '("#abc" "#def" "#ghi")))

    (it "extracts hashtag style tags"
      (expect (test #'kisaragi-notes-extract/tags-hashtag
                    "tags/tag.md")
              :to-equal
              '("#abc" "#def" "#ghi" "#not-frontmatter-a" "#not-front-matter-b")))

    (it "extracts from prop"
      (expect (test #'org-roam--extract-tags-prop
                    "tags/tag.org")
              :to-equal
              '("t1" "t2 with space" "t3" "t4 second-line"))
      (expect (test #'org-roam--extract-tags-prop
                    "tags/no_tag.org")
              :to-equal
              nil))

    (it "extracts from all directories"
      (expect (test #'org-roam--extract-tags-all-directories
                    "base.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-tags-all-directories
                    "tags/tag.org")
              :to-equal
              '("tags"))
      (expect (test #'org-roam--extract-tags-all-directories
                    "nested/deeply/deeply_nested_file.org")
              :to-equal
              '("nested" "deeply")))

    (it "extracts from last directory"
      (expect (test #'org-roam--extract-tags-last-directory
                    "base.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-tags-last-directory
                    "tags/tag.org")
              :to-equal
              '("tags"))
      (expect (test #'org-roam--extract-tags-last-directory
                    "nested/deeply/deeply_nested_file.org")
              :to-equal
              '("deeply")))

    (it "extracts from first directory"
      (expect (test #'org-roam--extract-tags-first-directory
                    "base.org")
              :to-equal
              nil)
      (expect (test #'org-roam--extract-tags-first-directory
                    "tags/tag.org")
              :to-equal
              '("tags"))
      (expect (test #'org-roam--extract-tags-first-directory
                    "nested/deeply/deeply_nested_file.org")
              :to-equal
              '("nested")))

    (describe "uses kisaragi-notes/tag-sources correctly"
      (it "'(prop)"
        (expect (let ((kisaragi-notes/tag-sources '(org-roam--extract-tags-prop)))
                  (test #'org-roam--extract-tags
                        "tags/tag.org"))
                :to-equal
                '("t1" "t2 with space" "t3" "t4 second-line")))
      (it "'(prop all-directories)"
        (expect (let ((kisaragi-notes/tag-sources '(org-roam--extract-tags-prop
                                                    org-roam--extract-tags-all-directories)))
                  (test #'org-roam--extract-tags
                        "tags/tag.org"))
                :to-equal
                '("t1" "t2 with space" "t3" "t4 second-line" "tags"))))))

(describe "ID extraction"
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (cl-flet
      ((test (fn file)
             (let* ((fname (test-org-roam--abs-path file))
                    (buf (find-file-noselect fname)))
               (with-current-buffer buf
                 (funcall fn fname)))))
    (it "extracts ids"
      (expect (test #'org-roam--extract-ids
                    "headlines/headline.org")
              :to-have-same-items-as
              `(["e84d0630-efad-4017-9059-5ef917908823" ,(test-org-roam--abs-path "headlines/headline.org") 1]
                ["801b58eb-97e2-435f-a33e-ff59a2f0c213" ,(test-org-roam--abs-path "headlines/headline.org") 1])))))

(describe "Test roam links"
  (it ""
    (expect (org-roam-link--split-path "")
            :to-equal
            '(title "" "" nil)))
  (it "title"
    (expect (org-roam-link--split-path "title")
            :to-equal
            '(title "title" "" nil)))
  (it "title*"
    (expect (org-roam-link--split-path "title*")
            :to-equal
            '(title+headline "title" "" 5)))
  (it "title*headline"
    (expect (org-roam-link--split-path "title*headline")
            :to-equal
            '(title+headline "title" "headline" 5)))
  (it "*headline"
    (expect (org-roam-link--split-path "*headline")
            :to-equal
            '(headline "" "headline" 0))))

(describe "Accessing the DB"
  (before-all
    (test-org-roam--init))

  (after-all
    (test-org-roam--teardown))

  (it "Returns a file from its title"
    (expect (kisaragi-notes//get-files "Foo")
            :to-equal
            (list (test-org-roam--abs-path "foo.org")))
    (expect (kisaragi-notes//get-files "Deeply Nested File")
            :to-equal
            (list (test-org-roam--abs-path "nested/deeply/deeply_nested_file.org")))))

;;; Tests
(xdescribe "org-roam-db-build-cache"
  (before-each
    (test-org-roam--init))

  (after-each
    (test-org-roam--teardown))

  (it "initializes correctly"
    ;; Cache
    (expect (caar (org-roam-db-query [:select (funcall count) :from files])) :to-be 8)
    (expect (caar (org-roam-db-query [:select (funcall count) :from links])) :to-be 5)
    (expect (caar (org-roam-db-query [:select (funcall count) :from titles])) :to-be 8)
    (expect (caar (org-roam-db-query [:select (funcall count) :from titles
                                      :where titles :is-null])) :to-be 1)
    (expect (caar (org-roam-db-query [:select (funcall count) :from refs])) :to-be 1)

    ;; Links
    (expect (caar (org-roam-db-query [:select (funcall count) :from links
                                      :where (= source $s1)]
                                     (test-org-roam--abs-path "foo.org"))) :to-be 1)
    (expect (caar (org-roam-db-query [:select (funcall count) :from links
                                      :where (= source $s1)]
                                     (test-org-roam--abs-path "nested/bar.org"))) :to-be 2)

    ;; Links -- File-to
    (expect (caar (org-roam-db-query [:select (funcall count) :from links
                                      :where (= dest $s1)]
                                     (test-org-roam--abs-path "nested/foo.org"))) :to-be 1)
    (expect (caar (org-roam-db-query [:select (funcall count) :from links
                                      :where (= dest $s1)]
                                     (test-org-roam--abs-path "nested/bar.org"))) :to-be 1)
    (expect (caar (org-roam-db-query [:select (funcall count) :from links
                                      :where (= dest $s1)]
                                     (test-org-roam--abs-path "unlinked.org"))) :to-be 0)
    ;; TODO Test titles
    (expect (org-roam-db-query [:select * :from titles])
            :to-have-same-items-as
            (list (list (test-org-roam--abs-path "alias.org")
                        (list "t1" "a1" "a 2"))
                  (list (test-org-roam--abs-path "bar.org")
                        (list "Bar"))
                  (list (test-org-roam--abs-path "foo.org")
                        (list "Foo"))
                  (list (test-org-roam--abs-path "nested/bar.org")
                        (list "Nested Bar"))
                  (list (test-org-roam--abs-path "nested/foo.org")
                        (list "Nested Foo"))
                  (list (test-org-roam--abs-path "no-title.org")
                        (list "Headline title"))
                  (list (test-org-roam--abs-path "web_ref.org") nil)
                  (list (test-org-roam--abs-path "unlinked.org")
                        (list "Unlinked"))))

    (expect (org-roam-db-query [:select * :from refs])
            :to-have-same-items-as
            (list (list "https://google.com/" (test-org-roam--abs-path "web_ref.org") "website")))

    ;; Expect rebuilds to be really quick (nothing changed)
    (expect (org-roam-db-build-cache)
            :to-equal
            (list :files 0 :links 0 :tags 0 :titles 0 :refs 0 :deleted 0))))

(provide 'test-org-roam)

;;; test-org-roam.el ends here
