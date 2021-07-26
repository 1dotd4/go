;; Git overview - A simple overview of many git repositories.
;;
;; This project is licenced under BSD 3-Clause License which follows.
;;
;; Copyright (c) 2021, 1. d4
;; All rights reserved.
;; 
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

;; ==[ 0. Introduction ]== 
;; 
;; This project arise from the need of a clear view of what is going on in
;; a certain project. So the main question we want to answer are:
;;
;; - What are the last thing everyone did?
;; - What is the situation of the project? Where are developers working now?
;; - What are the latest steps by a developer on the whole project?
;; 
;; To answer those question I wish a tool that does those query for me. The
;; tool should be accessible from anyone so that no one can be excluded or
;; hide from their responsibilities.
;;
;; The user manual (aka README.md) explains the features and requirements
;; for this project. Here we will discuss the design and implementation.
;;
;; --< 0.1. Index >--
;; 
;; 1. Requirements analysis
;; 2. Design of the project
;; 3. Implementation
;;   3.1. Development and debugging notes
;;   3.2. Data explaination
;;   3.3. Import explaination
;;   3.4. External webhook explaination
;;   3.5. Server explaination
;;   3.6. Command line explaination
;;
;; --< 0.2. Prelue >--
;;
;; Here we redefine lambda as λ.
(define-syntax λ
  (syntax-rules ()
    ((_ param body ...) (lambda param body ...))))

;; ==[ 1. Requirements analysis ]==
;;
;; The main part of this project is importing, organizing and displaying
;; commits in a simple and undestandable way which allows to see the real
;; history of a project composed of many repositories.
;;
;; We will leave out of this revision the OAuth APIs for querying for
;; information a Cloud SCM like GitHub. We will focus on local repositories
;; that are easy to maintain.
;; 
;; The experince should be linear:
;; 1. install git-overview;
;; 2. run `git-overview --import path/to/my-repo/` for each repository;
;; 3. run `git-overview --serve` to check that everything is working;
;; 4. setup it as a service and add a basic auth in front of it.
;;
;; The service will have a homepage and other two pages that display the
;; status of the team and the project.

;; ==[ 2. Design ]==
;;
;; We will use SQLite3 to store everything from configuration to repository
;; data. This allow us to perform complex query without effort. There will
;; be a selector to decide which action should the program perform. The
;; main two are import and serve.
;;
;; The import action will only add the minimum information of the
;; repository to the database.
;;
;; The serve action is composed of different tasks:
;; - serve the web pages which are rendered from the query to the database;
;; - periodically fetch the repositories and import latest commits.
;;
;; Other action will allow to set and get the configuration, for example
;; the period of fetching or removing a repository.
;;
;; While the query to the database are straightforward, the fetch of the
;; repository is composed of many steps:
;;  1. perform `git fetch` on the repository
;;  2. update branches
;;  3. fetch latest commits
;;  4. organize the commits in the database
;;
;; Having more tasks reading and writing can be a problem. Luckly SQLite3
;; is threadsafe and if it happen to be slow it's possible to enable WAL.

;; ==[ 3. Implementation ]==
;; 
;; --< 3.1. Development and debugging notes >--
;;
;; -.-. 3.1.1. Running and compiling
;; 
;; chicken-csi -s go.scm <add-here-options>
;; chicken-csc -static go.scm
;;
;; -.-. 3.1.2. Database usage
;;
;; We will use sql-de-lite as library for sqlite3 as the intended sqlite3
;; is not as egonomic as wanted and need some extra configuration to make
;; it work on all platforms. In addition sql-de-lite some higher order
;; functions we can use already. More information can be found here:
;; https://wiki.call-cc.org/eggref/5/sql-de-lite
;;
;; -.-. 3.1.3 Name convention
;;
;; We will keep the name convention of scheme for names as divided by a
;; dash. The global variables are stated here and are starred before and
;; after. Those can be set later from the options.
;;
;; - Version of the software
(define *version* "git-overview 0.0 by 1dotd4")
;; - Database path
(define *data-file* "./data.sqlite3")
;; - Selected server port
(define *selected-server-port* 6660)

;; --< 3.2 Data explaination >--
;; 
;; We import here the necessary library we need.
(import sql-de-lite
        srfi-1
        (chicken io)
        (chicken file)
        (chicken format)
        (chicken string)
        (chicken process))
;;
;; We store every commit in a table and for each commit we have a table for
;; parents. In this way we can keep track of the tree and branches of each
;; repository.
;;
;;
;; BranchLabels: **group**, name
;; GroupedBranches: _**branch**_, _**group**_
;;
;;
;; We check if the database exists and if not we create it.
(define (check-database)
  (if (not (file-exists? *data-file*)) ;; Here check if the database does not exists
    (call-with-database *data-file*
      (λ (db)
        (begin
          ;; The logic implementation of the database is:
          ;; People: **author**, email
          (exec (sql db "create table people(
                           email varchar(50) primary key,
                           name varchar(50));"))
          ;; Repositories: **name**, path
          (exec (sql db "create table repositories(
                           name varchar(50) primary key,
                           path varchar(50));"))
          ;; Branches: **branch**, _repository_
          (exec (sql db "create table branches(
                           branch varchar(50),
                           head varchar(130),
                           repository varchar(50),
                           primary key (branch, repository),
                           foreign key (repository)
                             references repositories (name)
                               on delete cascade
                               on update cascade);"))
          ;; Commits: **hash**, _repository_, _author_, comment, timestamp
          (exec (sql db "create table commits(
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
          (exec (sql db "create table commitParents(
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
          ;; Others that will be added (maybe?)
          ;; BranchLabels: group, name
          ;; GroupedBranches: branch, group
          ;; Those should help with grouping the table view
          ;; Note: **primary keys**, _external keys_.
          (print "Database created."))))))
;; Function that takes the basename of a path
(define (get-basename path)
  (with-input-from-pipe (format "basename ~A" path)
    (λ () (read-line))))
;; Funciton that takes branches of a repository
(define (get-git-branch path)
  (with-input-from-pipe
    (format "git --no-pager --git-dir=~A branch -v --no-abbrev" path)
    (λ () (map
            (λ (line)
              (let ((s (string-split line " " #t)))
                (list
                  (cadr s)
                  (caddr s))))
            (read-lines)))))
;; Funciton that takes logs of a repository
(define (get-git-log-dump path)
  (with-input-from-pipe (format "git --git-dir=~A --no-pager log --branches --tags --remotes --full-history --date-order --format='format:%H%x09%P%x09%at%x09%an%x09%ae%x09%s%x09%D'" path)
    (λ () (map (λ (a) (string-split a "\t" #t))
               (read-lines)))))
;; Function to import a repository from a path.
;; Will add only the path as it's the main loop to import the data.
(define (import-repository path)
  (call-with-database *data-file* ;; open database
    (λ (db)
      (let* ((basename (get-basename path)))
        (condition-case ;; exceptions handler
            (if (directory-exists? (format "~A.git" path))
              (begin ;; insert repository path
                (exec (sql db "insert into repositories values (?,?);")
                      basename
                      (format "~A.git" path))
                (print "Successfully imported."))
              (print "Could not find .git directory"))
          [(exn sqlite) (print "This repository already exists")]
          [(exn) (print "Somthing else has occurred")]
          [var () (print "Is this the finally?")])))))
;; map a line to a list of records
(define (commit-line->composed-data repo-name)
  (λ (line)
    `(
        ;; save list of email and author name
        ,(list  (list-ref line 4)  ;; author email
                (list-ref line 3)) ;; author name
        ;; the commit to add Commits
        ( ,(car line)         ;; hash
          ,repo-name          ;; repository name
          ,(list-ref line 4)  ;; author email
          ,(list-ref line 5)  ;; comment
          ,(list-ref line 2)) ;; timestamp
        ;; the parents to add to CommitParents
        ,(map
          (λ (parent)
              (list (car line) parent))
          (string-split (list-ref line 1))))))
;; Add email only if it does not exists in alist
(define (keep-unique-email alist)
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
;; transpose data
(define (composed-data->commits-parents-unique-authors composed-data)
  (if (null? composed-data)
      '()
      (list (keep-unique-email (map car composed-data))
            (map cadr composed-data)
            (join (map caddr composed-data)))))
;; Function to populate data of a repository, returns a list with
(define (populate-repository-information repo)
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
;; Function to populate data for each repository
(define (fetch-repository-data)
  (call-with-database *data-file*
    (λ (db)
      (let* ((repositories (query fetch-all (sql db "select * from repositories;")))
             (data-for-each-repository (map populate-repository-information repositories)))
        (map
          (λ (data-to-insert)
            (begin
              ;; reimport branches
              (condition-case
                (exec (sql db "delete from branches where repository = ?;")
                      (car data-to-insert))
                [(exn sqlite) '()])
              (map (λ (d)
                    (condition-case
                      (exec (sql db "insert into branches values (?, ?, ?);")
                            (car d)
                            (cadr d)
                            (car data-to-insert))
                      [(exn sqlite) '()]))
                (list-ref data-to-insert 1))
              ;; try to add people
              (map (λ (d)
                    (condition-case
                      (exec (sql db "insert into people values (?, ?);")
                            (car d)
                            (cadr d))
                      [(exn sqlite) '()]))
                (list-ref data-to-insert 2))
              ;; try to add commits
              (map (λ (d)
                    (condition-case
                      (exec (sql db "insert into commits values (?, ?, ?, ?, ?);")
                            (car d)
                            (list-ref d 1)
                            (list-ref d 2)
                            (list-ref d 3)
                            (list-ref d 4))
                      [(exn sqlite) '()]))
                (list-ref data-to-insert 3))
              ;; try to add commit parents
              (map (λ (d)
                    (condition-case
                      (exec (sql db "insert into commitparents values (?, ?, ?);")
                            (car d)
                            (cadr d)
                            (car data-to-insert))
                      [(exn sqlite) '()]))
                (list-ref data-to-insert 4))
              (print "Imported "
                     (length (cadddr data-to-insert))
                     " commits from "
                     (car data-to-insert))))
          data-for-each-repository)))))
(define (retrieve-last-people-activity)
  (call-with-database *data-file*
    (λ (db)
      (query fetch-all (sql db "select p.name, c.repository, c.hash, c.timestamp
  from ( select author, max(timestamp) as lastTimestamp
         from commits
         group by author ) as r
    inner join commits as c
      on r.author = c.author and r.lastTimestamp = c.timestamp
    join people as p
      on p.email = c.author;")))))
;; TODO: get branches
;; Import branches.
;; Recursive search
;; WITH RECURSIVE commit_tree (hash, parent, head, branch_name, repository) AS (
;;     SELECT branch_head, 0, branch_head, branch_name, repository
;;     FROM branches
;;   UNION ALL
;;     SELECT cs.hash, cs.parent, ct.head, ct.branch_name, ct.repository
;;     FROM commitParents cs, commit_tree ct
;;     WHERE cs.parent = ct.hash AND ct.repository = cs.repository
;; )
;; SELECT ... ;; put here the needed select
;; FROM ... INNER JOIN commit_tree as ct
;;      on hash = ct.hash AND repository = ct.repository
;; ...
(define (retrieve-last-repository-activity)
  (call-with-database *data-file*
    (λ (db)
      (query fetch-all (sql db "select p.name, c.repository, c.hash, c.timestamp
  from ( select author, repository, max(timestamp) as lastTimestamp
         from commits
         group by author, repository ) as r
  inner join commits as c
    on r.author = c.author and r.lastTimestamp = c.timestamp and r.repository = c.repository
  join people as p
    on p.email = c.author;")))))
(define (retrieve-last-people-activity2)
  (call-with-database *data-file*
    (λ (db)
      ;; TODO This is not enough
      ;; 1. Branches forks (not merges) generate overhead and UNION vs UNION ALL doesn't help
      ;; 2. Some people is missing for some reason
      ;; 3. Why do I need to group by
      (query fetch-all (sql db "
      with recursive commit_tree (hash, parent, head, branch_name, repository, depth) AS (
      select b.head, cp.parent, b.head, b.branch, b.repository, 0
        from branches as b
          join commitParents as cp
            on cp.hash = b.head and b.repository = cp.repository
      UNION
      select cs.hash, cs.parent, ct.head, ct.branch_name, ct.repository, ct.depth + 1
      from commitParents as cs
        join commit_tree as ct
          on cs.repository = ct.repository and ct.parent = cs.hash
      ) select p.name, c.repository, t.branch_name, c.timestamp
      from (  select author, max(timestamp) as lastTimestamp
              from commits
              group by author ) as r
        inner join commits as c
          on r.author = c.author and r.lastTimestamp = c.timestamp
        join people as p
          on p.email = c.author
        join commit_tree as t
          on t.hash = c.hash and t.repository = c.repository
      group by c.author;
      ")))))
  

;; --< 3.x Page rendering >--
(define (a-sample-data)
  '("@1dotd4" "feature/new-button" "5 minutes ago."))
(define (data->sxml-card data)
  `(div (@ (class "col-lg-3 my-3 mx-auto"))
    (div (@ (class "card"))
      (div (@ (class "card-body"))
        (h5 (@ (class "card-title")) ,(car data))
        (h6 (@ (class "card-subtitle")) ,(cadr data)))
      (div (@ (class "card-footer")) (format "Last update "
                                             ,(caddr data))))))
(define (data->sxml-card2 data)
  `(div (@ (class "col-lg-3 my-3 mx-auto"))
    (div (@ (class "card"))
      (div (@ (class "card-body"))
        (h5 (@ (class "card-title")) ,(car data))
        (h6 (@ (class "card-subtitle")) ,(format "~A/~A" (cadr data) (caddr data))))
      (div (@ (class "card-footer")) (format "Last update "
                                             ,(cadddr data))))))
        ;; (h6 (@ (class "card-subtitle")) ,(format "~A/~A" (cadr data) (car (string-chop (caddr data) 7)))))
(define (data->sxml-compact-card data)
  `(div (@ (class "card my-3"))
    (div (@ (class "card-body"))
      (h5 (@ (class "card-title")) ,(car data)))
    (div (@ (class "card-footer"))
      (format "Last update "
              ,(caddr data)))))
;; TODO: duplicate this and make it generate a table as wanted below.
(define (activate-nav-button current-page expected)
  (format "nav-link text-~A"
    (if (equal? current-page expected)
      "light active"
      "secondary")))
(define (build-people data)
  `(div (@ (class "container"))
    (p (@ (class "text-center text-muted mt-3 small"))
      "Tests a nice team")
    (div (@ (class "row my-3"))
      ,(map data->sxml-card2 data))))
(define (build-repo data)
  `(div (@ (class "container"))
    (p (@ (class "text-center text-muted mt-3 small"))
      "Tests a busy project")
    (div (@ (class "table-responsive"))
      (table (@ (class "table table-striped table-hover"))
        (thead
          (tr
            ,(map (λ (x) `(td ,x))
              (car data))))
        (tbody
          ,(map (λ (x)
                  `(tr 
                      (td ,(car x))
                      ,(map (λ (y)
                              `(td ,(map data->sxml-compact-card y)))
                            (cdr x))))
            (cdr data)))
          ))))
(define (build-user data)
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
            ,(map (λ (x) `(td ,x))
              '("hash" "repository" "branch" "comment" "date"))))
        (tbody
          (tr
            ,(map (λ (x)
                    `(tr ;; Refactor this data->row
                      ,(map (λ (y)
                          `(td ,y))
                        x)))
              (cdr data))))))))
(define (build-page current-page)
  `(html
      (head
        (meta (@ (charset "utf-8")))
        (title ,(cond ((equal? current-page 'people) "People - Project X")
                      ((equal? current-page 'repo) "Repositories - Project X")
                      ((equal? current-page 'user) "User - Project X")
                      (else "404 - Project X")))
        (meta (@ (name "viewport") (content "width=device-width, initial-scale=1, shrink-to-fit=no")))
        (meta (@ (name "author") (content "1dotd4")))
        (link (@ (href "https://cdn.jsdelivr.net/npm/bootstrap@5.0.2/dist/css/bootstrap.min.css") (rel "stylesheet") (integrity "sha384-EVSTQN3/azprG1Anm3QDgpJLIm9Nao0Yz1ztcQTwFspd3yD65VohhpuuCOmLASjC") (crossorigin "anonymous"))))
      (body
        (div (@ (class "navbar navbar-expand-lg navbar-dark bg-dark static-top mb-3"))
          (div (@ (class "container"))
            (a (@ (class "navbar-brand") (href "/"))
              "Git overview - Project X")
            (ul (@ (class "nav ml-auto"))
              (li (@ (class "nav-item"))
                (a (@ (class ,(activate-nav-button current-page 'people))
                      (href "/"))
                  "People"))
              (li (@ (class "nav-item"))
                (a (@ (class ,(activate-nav-button current-page 'repo))
                      (href "repo"))
                  "Repositories"))
              (li (@ (class "nav-item"))
                (a (@ (class ,(activate-nav-button current-page 'user))
                      (href "/user"))
                  "User")))))
        ,(cond ((equal? current-page 'people)
                  (build-people (retrieve-last-people-activity2)))
                ((equal? current-page 'repo)
                  (build-repo `(
                    ("Repository" "stable" "feature/new-button" "feature/new-panel")
                    ("our-fancy-core"
                      ( ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data))
                      ( ,(a-sample-data)
                        ,(a-sample-data))
                      ( ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data)))
                    ("our-fancy-frontend"
                      ( ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data))
                      ( ,(a-sample-data)
                        ,(a-sample-data))
                      ( ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data)
                        ,(a-sample-data)))
                    )))
                ((equal? current-page 'user)
                  (build-user '("@1dotd4"
                      ("c0ff33" "my-fancy-frontend" "stable" "release 1.2" "2021-05-13 1037")
                      ("c0ff33" "my-fancy-frontend" "add-button" "finalize button" "2021-05-10 1137")
                      ("c0ff33" "my-fancy-frontend" "add-button" "change color" "2021-05-05 1237")
                      ("c0ff33" "my-fancy-frontend" "add-button" "add button" "2021-05-03 0937")
                      ("c0ff33" "my-fancy-frontend" "stable" "release 1.1" "2021-04-25 1137")
                      ("c0ff33" "my-fancy-frontend" "stable" "release 1.0" "2021-04-01 1537")
                    )))
              ;; '("hash" "repository" "branch" "comment" "date"))))
                (else `(div (@ (class "container"))
                        (p (@ (class "text-center text-muted mt-3 small"))
                            "Page not found."))))
                                                      
        (div (@ (class "container text-secondary text-center my-4 small"))
          (a (@ (class "text-info") (href "https://github.com/1dotd4/go"))
            ,*version*))
      ;; - end body -
      )))

;; --< 3.x Webserver >--
(import spiffy
        intarweb
        uri-common
        sxml-serializer)
;; Function to serialize and send SXML as HTML
(define (send-sxml-response sxml)
    (with-headers `((connection close))
                  (λ ()
                    (write-logged-response)))
    (serialize-sxml sxml
                    output: (response-port (current-response))))
;; Function that handles an HTTP requsest in spiffy
(define (handle-request continue)
  (let* ((uri (request-uri (current-request))))
    (cond ((equal? (uri-path uri) '(/ ""))
            (send-sxml-response (build-page 'people)))
          ((equal? (uri-path uri) '(/ "repo"))
            (send-sxml-response (build-page 'repo)))
          ((equal? (uri-path uri) '(/ "user"))
            (send-sxml-response (build-page 'user)))
          ((equal? (uri-path uri) '(/ "greet"))
            (send-response status: 'ok body: "<h1>Hello world</h1>"))
          (else
            (send-response status: 'not-found body: )))))
;; Map a any vhost to the main handler
(vhost-map `((".*" . ,handle-request)))

;; --< 3.6 Command line implementation >--
;; We are going to use the module `args`
(import args
        (chicken port)
        (chicken process-context))
;; This is used to choose an operation by options
(define (operation) 'none)
;; This is the list passed to args:parse to choose which option will be
;; selected and validated.
(define opts
  (list (args:make-option (i import) (required: "REPOPATH") "Import from repository at path REPOPATH"
          (set! operation 'import))
        (args:make-option (s serve) #:none "Serve the database"
          (set! operation 'serve))
        (args:make-option (v V version) #:none "Display version"
          (print *version*)
          (exit))
        (args:make-option (h help) #:none "Display this text" (usage))))
;; This is a simple function that will show the usage in case 'help is
;; selected or in the default case
(define (usage)
  (with-output-to-port (current-error-port)
    (λ ()
      (print "Usage: " (car (argv)) " [options...] [files...]")
      (newline)
      (print (args:usage opts))
      (print *version*)))
  (exit 1))
;; This is the main part of the program where it's decided which operation
;; will be executed.
(receive (options operands)
    (args:parse (command-line-arguments) opts)
  (cond ((equal? operation 'import)
          (print "Will import from `" (alist-ref 'import options) ".git`.")
          (check-database)
          (import-repository (alist-ref 'import options)))
        ((equal? operation 'serve)
          (print "Will serve the database")
          (check-database)
          ;; Fetch data from database
          ;; TODO: this should be a coroutine
          (fetch-repository-data)
          ;; Set server port in spiffy
          (server-port *selected-server-port*)
          (print "The server is starting")
          ;; Start spiffy web server as seen in §3.x
          (start-server))
        (else
          ;; This is to update the database will not be here
          (check-database)
          (fetch-repository-data)
          (print (retrieve-last-repository-activity))))) 

;; ==[ Notes for next revision ]==
;;
;; - use the same pages
;; - add authentication
;; - add oauth
;; - add api calls
;;
;; ==[ Notes on data ]==
;; 
;; We would like to structure our database as follow:
;;
;;
;;
;; TODO: explain all the details of issues found here.

