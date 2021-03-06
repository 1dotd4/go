;;;; Git overview - A simple overview of many git repositories.

;; This project is licenced under BSD 3-Clause License which follows.

;; Copyright (c) 2021, 1. d4

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions are met:
;; 
;; 1. Redistributions of source code must retain the above copyright notice, this
;;   list of conditions and the following disclaimer.
;; 
;; 2. Redistributions in binary form must reproduce the above copyright notice,
;;   this list of conditions and the following disclaimer in the documentation
;;   and/or other materials provided with the distribution.
;; 
;; 3. Neither the name of the copyright holder nor the names of its
;;   contributors may be used to endorse or promote products derived from
;;   this software without specific prior written permission.
;; 
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
;; DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
;; FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
;; CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
;; OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;;; 0. Introduction

;;; This project arise from the need of a clear view of what is going on in
;;; a certain project. So the main question we want to answer are:
;;;
;;; - What are the last thing everyone did?
;;; - What is the situation of the project? Where are developers working now?
;;; - What are the latest steps by a developer on the whole project?
;;; 
;;; To answer those question I wish a tool that does those query for me. The
;;; tool should be accessible from anyone so that no one can be excluded or
;;; hide from their responsibilities.
;;;
;;; The user manual (aka README.md) explains the features and requirements
;;; for this project. Here we will discuss the design and implementation.

;;;; 0.1. Index

;;; I. LICENCE
;;; 0. Introduction
;;;   0.1 Index
;;;   0.2 Prelude
;;;   0.3 Known issues
;;; 1. Requirements analysis
;;; 2. Design of the project
;;; 3. Implementation
;;;   3.1. Development and debugging notes
;;;   3.2. Data explaination
;;;   3.3. Import explaination
;;;   3.4. Page rendering
;;;   3.5. Server explaination
;;;   3.6. Command line explaination

;;;; 0.2. Prelue
(define-syntax ??
  (syntax-rules ()
    ((_ param body ...) (lambda param body ...))))

;;;; 0.3 Known issues

;;; - The query that recursively add the branch name to the
;;;   commits is not correctly working.
;;; - The /user page is yet to be finished, the design is
;;;   not clear and need more UX design to choose the
;;;   functionality needed.
;;; - The database is not updated from a coroutine, so for
;;;   now one need to write a cron to update the repositories.

;;;; 1. Requirements analysis

;;; The main part of this project is importing, organizing and displaying
;;; commits in a simple and undestandable way which allows to see the real
;;; history of a project composed of many repositories.
;;;
;;; We will leave out of this revision the OAuth APIs for querying for
;;; information a Cloud SCM like GitHub. We will focus on local repositories
;;; that are easy to maintain.
;;; 
;;; The experince should be linear:
;;; 1. install git-overview;
;;; 2. run `git-overview --import path/to/my-repo/` for each repository;
;;; 3. run `git-overview --serve` to check that everything is working;
;;; 4. setup it as a service and add a basic auth in front of it.
;;;
;;; The service will have a homepage and other two pages that display the
;;; status of the team and the project.

;;;; 2. Design

;;; We will use SQLite3 to store everything from configuration to repository
;;; data. This allow us to perform complex query without effort. There will
;;; be a selector to decide which action should the program perform. The
;;; main two are import and serve.
;;;
;;; The import action will only add the minimum information of the
;;; repository to the database.
;;;
;;; The serve action is composed of different tasks:
;;; - serve the web pages which are rendered from the query to the database;
;;; - periodically fetch the repositories and import latest commits.
;;;
;;; Other action will allow to set and get the configuration, for example
;;; the period of fetching or removing a repository.
;;;
;;; While the query to the database are straightforward, the fetch of the
;;; repository is composed of many steps:
;;;  1. perform `git fetch` on the repository
;;;  2. update branches
;;;  3. fetch latest commits
;;;  4. organize the commits in the database
;;;
;;; Having more tasks reading and writing can be a problem. Luckly SQLite3
;;; is threadsafe and if it happen to be slow it's possible to enable WAL.

;;;; 3. Implementation

;;;; 3.1. Development and debugging notes

;;;; 3.1.1. Running and compiling

;;; chicken-csi -s go.scm <add-options-here>
;;; chicken-csc -static go.scm

;;;; 3.1.2. Database usage

;;; We will use sql-de-lite as library for sqlite3 as the intended sqlite3
;;; is not as egonomic as wanted and need some extra configuration to make
;;; it work on all platforms. In addition sql-de-lite some higher order
;;; functions we can use already. More information can be found here:
;;; https://wiki.call-cc.org/eggref/5/sql-de-lite

;;;; 3.1.3 Name convention

;;; We will keep the name convention of scheme for names as divided by a
;;; dash. The global variables are stated here and are starred before and
;;; after. Those can be set later from the options.

;; Version of the software
(define VERSION "git-overview 0.1 by 1dotd4")
;; Project name, should be able to edit later
(define *project-name* "git-overview")
;; Database path
(define *data-file* "./data.sqlite3")
;; Selected server port
(define *selected-server-port* 6660)

;;;; 3.2 Data explaination

;; We import here the necessary library we need.
(import sql-de-lite
        srfi-1
        sort-combinators
        (chicken io)
        (chicken file)
        (chicken format)
        (chicken string)
        (chicken process))

;;; We store every commit in a table and for each commit we have a table for
;;; parents. In this way we can keep track of the tree and branches of each
;;; repository.

;;; BranchLabels: **group**, name
;;; GroupedBranches: _**branch**_, _**group**_

(define (check-database)
  ;; We check if the database exists and if not we create it.
  (if (not (file-exists? *data-file*))
    (call-with-database *data-file*
      (?? (db)
        (begin
          ;; The logic implementation of the database is:
          ;; People: **author**, email
          (exec
            (sql
              db
              "create table people(
                email varchar(50) primary key,
                name varchar(50));"))
          ;; Repositories: **name**, path
          (exec
            (sql
              db
              "create table repositories(
                name varchar(50) primary key,
                path varchar(50));"))
          ;; Branches: **branch**, _repository_
          (exec
            (sql
              db
              "create table branches(
                branch varchar(50),
                head varchar(130),
                repository varchar(50),
                primary key (branch, repository),
                foreign key (repository)
                  references repositories (name)
                    on delete cascade
                    on update cascade);"))
          ;; Commits: **hash**, _repository_, _author_, comment, timestamp
          (exec
            (sql
              db
              "create table commits(
                hash varchar(130) primary key,
                repository varchar(50),
                author varchar(50),
                comment varchar(100),
                timestamp integer,
                foreign key (repository)
                  references repositories (name)
                    on delete cascade
                    on update cascade,
                foreign key (author)
                  references people (email)
                    on delete no action
                    on update cascade);"))
          ;; CommitParents: **hash**, **parent**
          (exec
            (sql
              db
              "create table commitParents(
                hash varchar(130),
                parent varchar(130),
                repository varchar(50),
                primary key (hash, repository, parent),
                foreign key (hash)
                  references commits (hash)
                    on update cascade
                    on delete cascade,
                foreign key (parent)
                  references commits (hash)
                    on update cascade
                    on delete cascade);"))
          ;; In case of necessity, add here more tables like
          ;; the BranchLabels(group, name, regex),
          ;; GroupedBranches(branch, group).
          ;; Those may help with grouping the /user view
          ;; Note: **primary keys**, _external keys_.
          (print "Database created."))))))

(define (get-basename path)
  ;; Function that takes the basename of a path
  (with-input-from-pipe (format "basename ~A" path)
    (?? () (read-line))))

(define (get-git-branch path)
  ;; Funciton that takes branches of a repository
  (with-input-from-pipe
    (format "git --no-pager --git-dir=~A branch -r -v --no-abbrev" path)
    (?? ()
      (map
        (?? (line)
          (let
            ((s (string-split line " ")))
            (list
              (car s)
              (cadr s))))
        (read-lines)))))

(define (get-git-log-dump path)
  ;; Funciton that takes logs of a repository
  (with-input-from-pipe
    (format "git --git-dir=~A --no-pager log --branches --tags --remotes --full-history --date-order --format='format:%H%x09%P%x09%at%x09%an%x09%ae%x09%s%x09%D'"
            path)
    (?? ()
      (map
        (?? (a)
          (string-split a "\t" #t))
        (read-lines)))))

;;;; 3.3 Import explaination

(define (import-repository path)
  ;; Function to import a repository from a path.
  ;; Will add only the path as it's the main loop to import the data.
  (call-with-database *data-file* ;; open database
    (?? (db)
      (let* ((basename (get-basename path)))
        (condition-case ;; exceptions handler
            (if (directory-exists? (format "~A.git" path))
              (begin ;; insert repository path
                (exec
                  (sql db "insert into repositories values (?,?);")
                  basename
                  (format "~A.git" path))
                (print "Successfully imported."))
              (print "Could not find .git directory"))
          [(exn sqlite) (print "This repository already exists")]
          [(exn) (print "Somthing else has occurred")]
          [var () (print "Is this the finally?")])))))

(define (commit-line->composed-data repo-name)
  ;; map a line to a list of records
  (?? (line)
    `(
        ;; save list of email and author name
        ,(list  (list-ref line 4)  ; author email
                (list-ref line 3)) ; author name
        ;; the commit to add Commits
        ( ,(car line)         ; hash
          ,repo-name          ; repository name
          ,(list-ref line 4)  ; author email
          ,(list-ref line 5)  ; comment
          ,(list-ref line 2)) ; timestamp
        ;; the parents to add to CommitParents
        ,(map
          (?? (parent)
              (list (car line) parent))
          (string-split (list-ref line 1))))))

(define (keep-unique-email alist)
  ;; Add email only if it does not exists in alist
  (define (keep list-to-be-traversed traversed-list)
    (cond
      ((null? list-to-be-traversed)
        traversed-list)
      ((null? traversed-list)
        (keep (cdr list-to-be-traversed) (list (car list-to-be-traversed))))
      ((member (caar list-to-be-traversed) (map car traversed-list))
        (keep (cdr list-to-be-traversed) traversed-list))
      (else
        (keep (cdr list-to-be-traversed) (cons (car list-to-be-traversed) traversed-list)))))
  (keep alist '()))

(define (composed-data->commits-parents-unique-authors composed-data)
  ;; transpose data
  (if (null? composed-data)
      '()
      (list (keep-unique-email (map car composed-data))
            (map cadr composed-data)
            (join (map caddr composed-data)))))

(define (populate-repository-information repo)
  ;; Function to populate data of a repository, returns a list with
  (let ((repo-name (car repo))
        (repo-path (cadr repo)))
    ;; there will be here data of branches, not for now
    (cons 
      repo-name 
      (cons
        (get-git-branch repo-path)
        (composed-data->commits-parents-unique-authors
          (map (commit-line->composed-data repo-name)
            (get-git-log-dump repo-path)))))))

(define (fetch-repository-data)
  ;; Function to populate data for each repository
  (call-with-database *data-file*
    (?? (db)
      (let* ((repositories (query fetch-all (sql db "select * from repositories;")))
             (data-for-each-repository (map populate-repository-information repositories)))
        (map
          (?? (data-to-insert)
            (begin
              ;; reimport branches
              (condition-case
                (exec
                  (sql db "delete from branches where repository = ?;")
                  (car data-to-insert))
                [(exn sqlite) '()])
              (map
                (?? (d)
                  (condition-case
                    (exec 
                      (sql db "insert into branches values (?, ?, ?);")
                      (car d)
                      (cadr d)
                      (car data-to-insert))
                    [(exn sqlite) '()]))
                (list-ref data-to-insert 1))
              ;; try to add people
              (map
                (?? (d)
                  (condition-case
                    (exec
                      (sql db "insert into people values (?, ?);")
                      (car d)
                      (cadr d))
                    [(exn sqlite) '()]))
                (list-ref data-to-insert 2))
              ;; try to add commits
              (map
                (?? (d)
                  (condition-case
                    (exec
                      (sql db "insert into commits values (?, ?, ?, ?, ?);")
                      (car d)
                      (list-ref d 1)
                      (list-ref d 2)
                      (list-ref d 3)
                      (list-ref d 4))
                    [(exn sqlite) '()]))
                (list-ref data-to-insert 3))
              ;; try to add commit parents
              (map
                (?? (d)
                  (condition-case
                    (exec 
                      (sql db "insert into commitparents values (?, ?, ?);")
                      (car d)
                      (cadr d)
                      (car data-to-insert))
                    [(exn sqlite) '()]))
                (list-ref data-to-insert 4))
              (print
                "Imported "
                (length (cadddr data-to-insert))
                " commits from "
                (car data-to-insert))))
          data-for-each-repository)))))

(define (retrieve-last-people-activity)
  ;; Function that query for last people activity
  (call-with-database *data-file*
    (?? (db)
      (query
        fetch-all
        (sql
          db
          "with recursive commit_tree (hash, parent, head, branch_name, repository) AS (
            select b.head, cp.parent, b.head, b.branch, b.repository
            from branches as b
              join commitParents as cp
                on cp.hash = b.head
                  and b.repository = cp.repository
            UNION
            select cs.hash, cs.parent, ct.head, ct.branch_name, ct.repository
            from commitParents as cs
              join commit_tree as ct
                on cs.repository = ct.repository
                  and ct.parent = cs.hash
                  and ct.parent <> cs.parent
                  and ct.hash <> cs.hash
          ) select p.name, c.repository, t.branch_name, c.timestamp, c.hash
          from (  select author, max(timestamp) as lastTimestamp
                  from commits
                  group by author ) as r
            inner join commits as c
              on r.author = c.author
                and r.lastTimestamp = c.timestamp
            join people as p
              on p.email = c.author
            join commit_tree as t
              on t.hash = c.hash
                and t.repository = c.repository
          group by c.author
          order by c.timestamp desc;")))))

(define (retrieve-last-repository-activity)
  ;; Function that query for last repository activity
  (let*
    ((retrived-data
      (call-with-database
        *data-file*
        (?? (db)
          (query
            fetch-all
            (sql
              db
              "with recursive commit_tree (hash, parent, head, branch_name, repository) AS (
                select b.head, cp.parent, b.head, b.branch, b.repository
                from branches as b
                  join commitParents as cp
                    on cp.hash = b.head
                      and b.repository = cp.repository
                UNION
                select cs.hash, cs.parent, ct.head, ct.branch_name, ct.repository
                from commitParents as cs
                  join commit_tree as ct
                    on cs.repository = ct.repository
                      and ct.parent = cs.hash
                      and ct.parent <> cs.parent
                      and ct.hash <> cs.hash
              ) select p.name, c.repository, t.branch_name, c.timestamp, c.hash
              from (  select author, repository, max(timestamp) as lastTimestamp
                      from commits
                      group by author, repository ) as r
                inner join commits as c
                  on r.author = c.author
                    and r.lastTimestamp = c.timestamp
                    and r.repository = c.repository
                join people as p
                  on p.email = c.author
                join commit_tree as t
                  on t.hash = c.hash
                    and t.repository = c.repository
              order by c.timestamp asc;")))))
      (grouped-by-repository ((group-by (?? (d) (list-ref d 1))) retrived-data))
      (grouped-by-repository-and-branches (map (group-by (?? (d) (list-ref d 2))) grouped-by-repository)))
    grouped-by-repository-and-branches))

;;;; 3.4 Page rendering
(import (chicken time))

(define (format-diff current atime)
  ;; Funciton to format how much ago a thing happened
  (let* ((abs-seconds (- current atime))
         (seconds (modulo abs-seconds 60))
         (minutes (quotient abs-seconds 60))
         (hours (quotient minutes 60))
         (days (quotient hours 24))
         (months (quotient days 30)))
    (cond
      ((> months 0) (format "~A month" months))
      ((> days 0) (format "~A day" days))
      ((> hours 0) (format "~A hour" hours))
      ((> minutes 0) (format "~A minute" minutes))
      (else (format "~A second" seconds)))))

(define (data->sxml-card data current-time)
  `(div (@ (class "col-lg-3 my-3 mx-auto"))
    (div (@ (class "card"))
      (div (@ (class "card-body"))
        (h5 (@ (class "card-title")) ,(car data))
        (h6 (@ (class "card-subtitle")) ,(format "~A/~A" (cadr data) (caddr data))))
      (div
        (@ (class "card-footer"))
        ,(format
          "Last update ~A(s) ago."
          (format-diff current-time (cadddr data)))))))
        ;; Was used to get the commit's first characters (7) just like the compact version is
        ;; (h6 (@ (class "card-subtitle")) ,(format "~A/~A" (cadr data) (car (string-chop (caddr data) 7)))))

(define (data->sxml-compact-card data current-time)
  `(div (@ (class "card my-3"))
    (div (@ (class "card-body"))
      (h5 (@ (class "card-title")) ,(car data)))
    (div (@ (class "card-footer"))
      ,(format "Last update ~A(s) ago."
               (format-diff current-time (cadddr data))))))

(define (activate-nav-button current-page expected)
  (format "nav-link text-~A"
    (if (equal? current-page expected)
      "light active"
      "secondary")))

(define (build-people data current-time)
  ;; Function that build a page for displaying last update for each committer
  `(div (@ (class "container"))
    (p (@ (class "text-center text-muted mt-3 small"))
      "Tests a nice team")
    (div (@ (class "row my-3"))
      ,(map (?? (d) (data->sxml-card d current-time)) data))))

(define (build-repo data current-time)
  ;; Funciton that build a page for displaying for each repository each branch and people on that branch
  `(div (@ (class "container"))
    ,(map (?? (repo)
        `(div
          (h3 (@ (class "mt-3"))
            ,(list-ref (car (car repo)) 1))
          (div (@ (class "table-responsive"))
            (table (@ (class "table table-striped table-hover"))
              (thead
                (tr
                  ,(map
                    (?? (branches)
                      `(td ,(list-ref 
                              (car branches)
                              2)))
                    repo)))
              (tbody
                (tr
                  ,(map
                    (?? (person)
                      `(td
                        ,(map
                          (?? (d)
                            (data->sxml-compact-card d current-time))
                          person)))
                    repo)))))))
      data)))

(define (build-user data)
  ;; TODO: finish frontend for selecting everything
  ;; Function that build a page for searching commits
  `(div (@ (class "container"))
    (form (@ (action "#") (method "POST"))
      (div (@ (class "row my-3"))
        (h2 (@ (class "col my-3")) ,(car data))
        (div (@ (class "col-lg-3 my-3 mx-auto"))
          (div (@ (class "col form-check"))
            (input (@ (class "form-check-input") (type "checkbox") (id "my-fancy-core") (value "selected")))
            (label (@ (class "form-check-label") (for "my-fancy-core")) "my-fancy-core"))
          (div (@ (class "col form-check"))
            (input (@ (class "form-check-input") (type "checkbox") (id "my-fancy-frontend") (value "selected") (checked)))
            (label (@ (class "form-check-label") (for "my-fancy-frontend")) "my-fancy-frontend")))
        (div (@ (class "col-lg-3 my-3 mx-auto"))
          (div (@ (class "col form-check"))
            (input (@ (class "form-check-input") (type "checkbox") (id "stable") (value "selected") (checked)))
            (label (@ (class "form-check-label") (for "stable" )) "stable"))
          (div (@ (class "col form-check"))
            (input (@ (class "form-check-input") (type "checkbox") (id "current") (value "selected")))
            (label (@ (class "form-check-label") (for "current" )) "current"))
          (div (@ (class "col form-check"))
            (input (@ (class "form-check-input") (type "checkbox") (id "add-button") (value "selected") (checked)))
            (label (@ (class "form-check-label") (for "add-button" )) "add-button")))
        (div (@ (class "col-lg my-3 mx-auto"))
          (input (@ (class "btn btn-secondary") (type "submit") (value "Update filter"))))))
    (div (@ (class "table-responsive"))
      (table (@ (class "table table-striped table-hover"))
        (thead
          (tr
            ,(map (?? (x) `(td ,x))
              '("hash" "repository" "branch" "comment" "date"))))
        (tbody
          (tr
            ,(map (?? (x)
                    `(tr ;; Refactor this data->row
                      ,(map (?? (y)
                          `(td ,y))
                        x)))
              (cdr data))))))))

(define (build-page current-page)
  ;; Function that build the appropriate page
  (let ((current-time (current-seconds)))
    `(html
        (head
          (meta (@ (charset "utf-8")))
          (title
            ,(string-append 
                (cond 
                  ((equal? current-page 'people) "People")
                  ((equal? current-page 'repo) "Repositories")
                  ((equal? current-page 'user) "User")
                  (else "Page not found"))
                " - "
                *project-name*))
          (meta (@ (name "viewport") (content "width=device-width, initial-scale=1, shrink-to-fit=no")))
          (meta (@ (name "author") (content "1dotd4")))
          (link (@
                  (href "https://cdn.jsdelivr.net/npm/bootstrap@5.0.2/dist/css/bootstrap.min.css")
                  (rel "stylesheet")
                  (integrity "sha384-EVSTQN3/azprG1Anm3QDgpJLIm9Nao0Yz1ztcQTwFspd3yD65VohhpuuCOmLASjC")
                  (crossorigin "anonymous"))))
        (body
          (div (@ (class "navbar navbar-expand-lg navbar-dark bg-dark static-top mb-3"))
            (div (@ (class "container"))
              (a (@ (class "navbar-brand") (href "./"))
                ,(format
                    "Git overview - ~A"
                    *project-name*))
              (ul (@ (class "nav ml-auto"))
                (li (@ (class "nav-item"))
                  (a (@ (class ,(activate-nav-button current-page 'people))
                        (href "./"))
                    "People"))
                (li (@ (class "nav-item"))
                  (a (@ (class ,(activate-nav-button current-page 'repo))
                        (href "repo"))
                    "Repositories"))
                (li (@ (class "nav-item"))
                  (a (@ (class ,(activate-nav-button current-page 'user))
                        (href "#")) ; (href "user")) ; disabled
                    "User")))))
          ,(cond ((equal? current-page 'people)
                    (build-people (retrieve-last-people-activity) current-time))
                  ((equal? current-page 'repo)
                    (build-repo (retrieve-last-repository-activity) current-time))
                  ;((equal? current-page 'user)
                  ;  (build-user '("@1dotd4"
                  ;      ("c0ff33" "my-fancy-frontend" "stable" "release 1.2" "2021-05-13 1037")
                  ;      ("c0ff33" "my-fancy-frontend" "add-button" "finalize button" "2021-05-10 1137")
                  ;      ("c0ff33" "my-fancy-frontend" "add-button" "change color" "2021-05-05 1237")
                  ;      ("c0ff33" "my-fancy-frontend" "add-button" "add button" "2021-05-03 0937")
                  ;      ("c0ff33" "my-fancy-frontend" "stable" "release 1.1" "2021-04-25 1137")
                  ;      ("c0ff33" "my-fancy-frontend" "stable" "release 1.0" "2021-04-01 1537")
                  ;    )))
                ;; '("hash" "repository" "branch" "comment" "date"))))
                  (else
                    `(div (@ (class "container"))
                      (p (@ (class "text-center text-muted mt-3 small"))
                          "Page not found."))))
          (div (@ (class "container text-secondary text-center my-4 small"))
            (a (@ (class "text-info") (href "https://github.com/1dotd4/go"))
              ,VERSION)))))) ;; - end body -

;;;; 3.5 Webserver
(import spiffy
        intarweb
        uri-common
        sxml-serializer)

(define (send-sxml-response sxml)
  ;; Function to serialize and send SXML as HTML
  (with-headers
    `((connection close))
     (?? () (write-logged-response)))
  (serialize-sxml
    sxml
    output: (response-port (current-response))))

(define (handle-request continue)
  ;; Function that handles an HTTP requsest in spiffy
  (let* ((uri (request-uri (current-request))))
    (cond ((equal? (uri-path uri) '(/ ""))
            (send-sxml-response (build-page 'people)))
          ((equal? (uri-path uri) '(/ "repo"))
            (send-sxml-response (build-page 'repo)))
          ((equal? (uri-path uri) '(/ "user"))
            (send-sxml-response (build-page 'user)))
          (else
            (send-sxml-response (build-page 'not-found))))))

;; Map a any vhost to the main handler
(vhost-map `((".*" . ,handle-request)))

;;;; 3.6 Command line implementation
(import args
        (chicken port)
        (chicken process-context))

;; This is used to choose an operation by options
(define (operation) 'none)

(define opts
  ;; List passed to args:parse to choose which option will be selected and validated.
  (list (args:make-option (i import) (required: "REPOPATH") "Import from repository at path REPOPATH"
          (set! operation 'import))
        (args:make-option (n name) (required: "PROJECTNAME") "Set project name"
          (set! *project-name* arg))
        (args:make-option (s serve) #:none "Serve the database"
          (set! operation 'serve))
        (args:make-option (v V version) #:none "Display version"
          (print VERSION)
          (exit))
        (args:make-option (h help) #:none "Display this text" (usage))))

(define (usage)
  ;; Function that will show the usage in case 'help is selected or in the
  ;; default case
  (with-output-to-port
    (current-error-port)
    (?? ()
      (print "Usage: " (car (argv)) " [options...] [files...]")
      (newline)
      (print (args:usage opts))
      (print VERSION)))
  (exit 1))

(receive
  ;; This is the main part of the program where it's decided which operation
  ;; will be executed.
  (options operands)
  (args:parse (command-line-arguments) opts)
  (cond ((equal? operation 'import)
          (print "Will import from `" (alist-ref 'import options) ".git`.")
          (check-database)
          (import-repository (alist-ref 'import options)))
        ((equal? operation 'serve)
          (print "Will serve the database for project " *project-name*)
          (check-database)
          ;; Fetch data from database
          ;; TODO: this should be a coroutine
          (fetch-repository-data)
          ;; Set server port in spiffy
          (server-port *selected-server-port*)
          (print "The server is starting")
          ;; Start spiffy web server as seen in ??3.5
          (start-server))
        (else
          ;; This is to update the database will not be here
          (check-database)
          (fetch-repository-data)))) 

