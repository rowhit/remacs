;;; gdb-ui.el --- User Interface for running GDB

;; Author: Nick Roberts <nickrob@gnu.org>
;; Maintainer: FSF
;; Keywords: unix, tools

;; Copyright (C) 2002, 2003, 2004, 2005  Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This mode acts as a graphical user interface to GDB.  You can interact with
;; GDB through the GUD buffer in the usual way, but there are also further
;; buffers which control the execution and describe the state of your program.
;; It separates the input/output of your program from that of GDB, if
;; required, and watches expressions in the speedbar.  It also uses features of
;; Emacs 21 such as the fringe/display margin for breakpoints, and the toolbar
;; (see the GDB Graphical Interface section in the Emacs info manual).

;; By default, M-x gdb will start the debugger. However, if you have customised
;; gud-gdb-command-name, then start it with M-x gdba.

;; This file has evolved from gdba.el that was included with GDB 5.0 and
;; written by Tom Lord and Jim Kingdon.  It uses GDB's annotation interface.
;; You don't need to know about annotations to use this mode as a debugger,
;; but if you are interested developing the mode itself, then see the
;; Annotations section in the GDB info manual.
;;
;; GDB developers plan to make the annotation interface obsolete.  A new
;; interface called GDB/MI (machine interface) has been designed to replace
;; it.  Some GDB/MI commands are used in this file through the CLI command
;; 'interpreter mi <mi-command>'.  A file called gdb-mi.el is included with
;; GDB (6.2 onwards) that uses GDB/MI as the primary interface to GDB.  It is
;; still under development and is part of a process to migrate Emacs from
;; annotations to GDB/MI.
;;
;; Windows Platforms:
;;
;; If you are using Emacs and GDB on Windows you will need to flush the buffer
;; explicitly in your program if you want timely display of I/O in Emacs.
;; Alternatively you can make the output stream unbuffered, for example, by
;; using a macro:
;;
;;           #ifdef UNBUFFERED
;;	     setvbuf (stdout, (char *) NULL, _IONBF, 0);
;;	     #endif
;;
;; and compiling with -DUNBUFFERED while debugging.
;;
;; Known Bugs:
;;
;; TODO:
;; 1) Use MI command -data-read-memory for memory window.
;; 2) Highlight changed register values (use MI commands
;;    -data-list-register-values and -data-list-changed-registers instead
;;    of 'info registers'.
;; 3) Use tree-widget.el instead of the speedbar for watch-expressions?
;; 4) Mark breakpoint locations on scroll-bar of source buffer?
;; 5) After release of 22.1 use '-var-list-children --all-values'
;;    and '-stack-list-locals 2' which need GDB 6.1 onwards.

;;; Code:

(require 'gud)

(defvar tool-bar-map)

(defvar gdb-frame-address "main" "Initialization for Assembler buffer.")
(defvar gdb-previous-frame-address nil)
(defvar gdb-memory-address "main")
(defvar gdb-previous-frame nil)
(defvar gdb-selected-frame nil)
(defvar gdb-frame-number nil)
(defvar gdb-current-language nil)
(defvar gdb-var-list nil "List of variables in watch window.")
(defvar gdb-var-changed nil "Non-nil means that `gdb-var-list' has changed.")
(defvar gdb-main-file nil "Source file from which program execution begins.")
(defvar gdb-buffer-type nil)
(defvar gdb-overlay-arrow-position nil)
(defvar gdb-server-prefix nil)
(defvar gdb-flush-pending-output nil)
(defvar gdb-location-alist nil
  "Alist of breakpoint numbers and full filenames.")
(defvar gdb-find-file-unhook nil)
(defvar gdb-active-process nil "GUD tooltips display variable values when t, \
and #define directives otherwise.")
(defvar gdb-error "Non-nil when GDB is reporting an error.")
(defvar gdb-macro-info nil
  "Non-nil if GDB knows that the inferior includes preprocessor macro info.")

(defvar gdb-buffer-type nil
  "One of the symbols bound in `gdb-buffer-rules'.")

(defvar gdb-input-queue ()
  "A list of gdb command objects.")

(defvar gdb-prompting nil
  "True when gdb is idle with no pending input.")

(defvar gdb-output-sink 'user
  "The disposition of the output of the current gdb command.
Possible values are these symbols:

    `user' -- gdb output should be copied to the GUD buffer
              for the user to see.

    `inferior' -- gdb output should be copied to the inferior-io buffer.

    `pre-emacs' -- output should be ignored util the post-prompt
                   annotation is received.  Then the output-sink
		   becomes:...
    `emacs' -- output should be collected in the partial-output-buffer
	       for subsequent processing by a command.  This is the
	       disposition of output generated by commands that
	       gdb mode sends to gdb on its own behalf.
    `post-emacs' -- ignore output until the prompt annotation is
		    received, then go to USER disposition.

gdba (gdb-ui.el) uses all five values, gdbmi (gdb-mi.el) only two
\(`user' and `emacs').")

(defvar gdb-current-item nil
  "The most recent command item sent to gdb.")

(defvar gdb-pending-triggers '()
  "A list of trigger functions that have run later than their output
handlers.")

;; end of gdb variables

;;;###autoload
(defun gdba (command-line)
  "Run gdb on program FILE in buffer *gud-FILE*.
The directory containing FILE becomes the initial working directory
and source-file directory for your debugger.

If `gdb-many-windows' is nil (the default value) then gdb just
pops up the GUD buffer unless `gdb-show-main' is t.  In this case
it starts with two windows: one displaying the GUD buffer and the
other with the source file with the main routine of the inferior.

If `gdb-many-windows' is t, regardless of the value of
`gdb-show-main', the layout below will appear unless
`gdb-use-inferior-io-buffer' is nil when the source buffer
occupies the full width of the frame.  Keybindings are given in
relevant buffer.

Watch expressions appear in the speedbar/slowbar.

The following commands help control operation :

`gdb-many-windows'    - Toggle the number of windows gdb uses.
`gdb-restore-windows' - To restore the window layout.

See Info node `(emacs)GDB Graphical Interface' for a more
detailed description of this mode.


---------------------------------------------------------------------
                               GDB Toolbar
---------------------------------------------------------------------
 GUD buffer (I/O of GDB)          | Locals buffer
                                  |
                                  |
                                  |
---------------------------------------------------------------------
 Source buffer                    | Input/Output (of inferior) buffer
                                  | (comint-mode)
                                  |
                                  |
                                  |
                                  |
                                  |
                                  |
---------------------------------------------------------------------
 Stack buffer                     | Breakpoints buffer
 RET      gdb-frames-select       | SPC    gdb-toggle-breakpoint
                                  | RET    gdb-goto-breakpoint
                                  |   d    gdb-delete-breakpoint
---------------------------------------------------------------------"
  ;;
  (interactive (list (gud-query-cmdline 'gdba)))
  ;;
  ;; Let's start with a basic gud-gdb buffer and then modify it a bit.
  (gdb command-line)
  (gdb-ann3))

(defvar gdb-debug-log nil)

;;;###autoload
(defcustom gdb-enable-debug-log nil
  "Non-nil means record the process input and output in `gdb-debug-log'."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defcustom gdb-use-inferior-io-buffer nil
  "Non-nil means display output from the inferior in a separate buffer."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defcustom gdb-cpp-define-alist-program "gcc -E -dM -"
  "Shell command for generating a list of defined macros in a source file.
This list is used to display the #define directive associated
with an identifier as a tooltip.  It works in a debug session with
GDB, when gud-tooltip-mode is t.

Set `gdb-cpp-define-alist-flags' for any include paths or
predefined macros."
  :type 'string
  :group 'gud
  :version "22.1")

(defcustom gdb-cpp-define-alist-flags ""
  "Preprocessor flags for `gdb-cpp-define-alist-program'."
  :type 'string
  :group 'gud
  :version "22.1")

(defcustom gdb-show-main nil
  "Non-nil means display source file containing the main routine at startup.
Also display the main routine in the disassembly buffer if present."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defvar gdb-define-alist nil "Alist of #define directives for GUD tooltips.")

(defun gdb-create-define-alist ()
  "Create an alist of #define directives for GUD tooltips."
  (let* ((file (buffer-file-name))
	 (output
	  (with-output-to-string
	    (with-current-buffer standard-output
	      (call-process shell-file-name
			    (if (file-exists-p file) file nil)
			    (list t nil) nil "-c"
			    (concat gdb-cpp-define-alist-program " "
				    gdb-cpp-define-alist-flags)))))
	(define-list (split-string output "\n" t))
	(name))
    (setq gdb-define-alist nil)
    (dolist (define define-list)
      (setq name (nth 1 (split-string define "[( ]")))
      (push (cons name define) gdb-define-alist))))

(defun gdb-tooltip-print ()
  (tooltip-show
   (with-current-buffer (gdb-get-buffer 'gdb-partial-output-buffer)
     (let ((string (buffer-string)))
       ;; remove newline for gud-tooltip-echo-area
       (substring string 0 (- (length string) 1))))
   (or gud-tooltip-echo-area tooltip-use-echo-area)))

;; If expr is a macro for a function don't print because of possible dangerous
;; side-effects. Also printing a function within a tooltip generates an
;; unexpected starting annotation (phase error).
(defun gdb-tooltip-print-1 (expr)
  (with-current-buffer (gdb-get-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (if (search-forward "expands to: " nil t)
	(unless (looking-at "\\S+.*(.*).*")
	  (gdb-enqueue-input
	   (list  (concat gdb-server-prefix "print " expr "\n")
		  'gdb-tooltip-print))))))

(defun gdb-set-gud-minor-mode (buffer)
  "Set `gud-minor-mode' from find-file if appropriate."
  (goto-char (point-min))
  (unless (search-forward "No source file named " nil t)
    (condition-case nil
	(gdb-enqueue-input
	 (list (concat gdb-server-prefix "info source\n")
	       `(lambda () (gdb-set-gud-minor-mode-1 ,buffer))))
      (error (setq gdb-find-file-unhook t)))))

(defun gdb-set-gud-minor-mode-1 (buffer)
  (goto-char (point-min))
  (when (and (search-forward "Located in " nil t)
	     (looking-at "\\S-+")
	     (string-equal (buffer-file-name buffer)
			   (match-string 0)))
    (with-current-buffer buffer
      (set (make-local-variable 'gud-minor-mode) 'gdba)
      (set (make-local-variable 'tool-bar-map) gud-tool-bar-map)
      (when gud-tooltip-mode
	(make-local-variable 'gdb-define-alist)
	(gdb-create-define-alist)
	(add-hook 'after-save-hook 'gdb-create-define-alist nil t)))))

(defun gdb-set-gud-minor-mode-existing-buffers ()
  (dolist (buffer (buffer-list))
    (let ((file (buffer-file-name buffer)))
      (if file
	(progn
	  (gdb-enqueue-input
	   (list (concat gdb-server-prefix "list "
			 (file-name-nondirectory file) ":1\n")
		 `(lambda () (gdb-set-gud-minor-mode ,buffer)))))))))

(defun gdb-ann3 ()
  (setq gdb-debug-log nil)
  (set (make-local-variable 'gud-minor-mode) 'gdba)
  (set (make-local-variable 'gud-marker-filter) 'gud-gdba-marker-filter)
  ;;
  (gud-def gud-break (if (not (string-match "Machine" mode-name))
			 (gud-call "break %f:%l" arg)
		       (save-excursion
			 (beginning-of-line)
			 (forward-char 2)
			 (gud-call "break *%a" arg)))
	   "\C-b" "Set breakpoint at current line or address.")
  ;;
  (gud-def gud-remove (if (not (string-match "Machine" mode-name))
			  (gud-call "clear %f:%l" arg)
			(save-excursion
			  (beginning-of-line)
			  (forward-char 2)
			  (gud-call "clear *%a" arg)))
	   "\C-d" "Remove breakpoint at current line or address.")
  ;;
  (gud-def gud-until  (if (not (string-match "Machine" mode-name))
			  (gud-call "until %f:%l" arg)
			(save-excursion
			  (beginning-of-line)
			  (forward-char 2)
			  (gud-call "until *%a" arg)))
	   "\C-u" "Continue to current line or address.")

  (define-key gud-minor-mode-map [left-margin mouse-1]
    'gdb-mouse-set-clear-breakpoint)
  (define-key gud-minor-mode-map [left-fringe mouse-1]
    'gdb-mouse-set-clear-breakpoint)
  (define-key gud-minor-mode-map [left-margin mouse-3]
    'gdb-mouse-toggle-breakpoint)
;  Currently only works in margin.
;  (define-key gud-minor-mode-map [left-fringe mouse-3]
;    'gdb-mouse-toggle-breakpoint)

  (setq comint-input-sender 'gdb-send)
  ;;
  ;; (re-)initialize
  (setq gdb-frame-address (if gdb-show-main "main" nil))
  (setq gdb-previous-frame-address nil
	gdb-memory-address "main"
	gdb-previous-frame nil
	gdb-selected-frame nil
	gdb-current-language nil
	gdb-frame-number nil
	gdb-var-list nil
	gdb-var-changed nil
	gdb-first-prompt nil
	gdb-prompting nil
	gdb-input-queue nil
	gdb-current-item nil
	gdb-pending-triggers nil
	gdb-output-sink 'user
	gdb-server-prefix "server "
	gdb-flush-pending-output nil
	gdb-location-alist nil
	gdb-find-file-unhook nil
	gdb-error nil
	gdb-macro-info nil)
  ;;
  (setq gdb-buffer-type 'gdba)
  ;;
  (if gdb-use-inferior-io-buffer (gdb-clear-inferior-io))
  ;;
  (if (eq window-system 'w32)
      (gdb-enqueue-input (list "set new-console off\n" 'ignore)))
  (gdb-enqueue-input (list "set height 0\n" 'ignore))
  (gdb-enqueue-input (list "set width 0\n" 'ignore))
  ;; find source file and compilation directory here
  (gdb-enqueue-input (list "server list main\n"   'ignore))   ; C program
  (gdb-enqueue-input (list "server list MAIN__\n" 'ignore))   ; Fortran program
  (gdb-enqueue-input (list "server info source\n" 'gdb-source-info))
  ;;
  (gdb-set-gud-minor-mode-existing-buffers)
  (run-hooks 'gdba-mode-hook))

(defcustom gdb-use-colon-colon-notation nil
  "If non-nil use FUN::VAR format to display variables in the speedbar."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defun gud-watch ()
  "Watch expression at point."
  (interactive)
  (require 'tooltip)
  (let ((expr (tooltip-identifier-from-point (point))))
    (if (and (string-equal gdb-current-language "c")
	     gdb-use-colon-colon-notation gdb-selected-frame)
	(setq expr (concat gdb-selected-frame "::" expr)))
    (catch 'already-watched
      (dolist (var gdb-var-list)
	(if (string-equal expr (car var)) (throw 'already-watched nil)))
      (set-text-properties 0 (length expr) nil expr)
      (gdb-enqueue-input
       (list
	(if (eq gud-minor-mode 'gdba)
	    (concat "server interpreter mi \"-var-create - * "  expr "\"\n")
	  (concat"-var-create - * "  expr "\n"))
	     `(lambda () (gdb-var-create-handler ,expr))))))
  (select-window (get-buffer-window gud-comint-buffer 0)))

(defconst gdb-var-create-regexp
  "name=\"\\(.*?\\)\",numchild=\"\\(.*?\\)\",type=\"\\(.*?\\)\"")

(defun gdb-var-create-handler (expr)
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (if (re-search-forward gdb-var-create-regexp nil t)
	(let ((var (list expr
			 (match-string 1)
			 (match-string 2)
			 (match-string 3)
			 nil nil)))
	  (push var gdb-var-list)
	  (speedbar 1)
	  (if (equal (nth 2 var) "0")
	      (gdb-enqueue-input
	       (list
		(if (with-current-buffer
			gud-comint-buffer (eq gud-minor-mode 'gdba))
		    (concat "server interpreter mi \"-var-evaluate-expression "
			    (nth 1 var) "\"\n")
		  (concat "-var-evaluate-expression " (nth 1 var) "\n"))
		     `(lambda () (gdb-var-evaluate-expression-handler
				  ,(nth 1 var) nil))))
	    (setq gdb-var-changed t)))
      (if (re-search-forward "Undefined command" nil t)
	  (message-box "Watching expressions requires gdb 6.0 onwards")
	(message "No symbol \"%s\" in current context." expr)))))

(defun gdb-var-evaluate-expression-handler (varnum changed)
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (re-search-forward ".*value=\"\\(.*?\\)\"" nil t)
    (catch 'var-found
      (let ((num 0))
	(dolist (var gdb-var-list)
	  (if (string-equal varnum (cadr var))
	      (progn
		(if changed (setcar (nthcdr 5 var) t))
		(setcar (nthcdr 4 var) (match-string 1))
		(setcar (nthcdr num gdb-var-list) var)
		(throw 'var-found nil)))
	  (setq num (+ num 1))))))
  (setq gdb-var-changed t))

(defun gdb-var-list-children (varnum)
  (gdb-enqueue-input
   (list (concat "server interpreter mi \"-var-list-children " varnum "\"\n")
	 `(lambda () (gdb-var-list-children-handler ,varnum)))))

(defconst gdb-var-list-children-regexp
  "name=\"\\(.*?\\)\",exp=\"\\(.*?\\)\",numchild=\"\\(.*?\\)\"")

(defun gdb-var-list-children-handler (varnum)
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (let ((var-list nil))
     (catch 'child-already-watched
       (dolist (var gdb-var-list)
	 (if (string-equal varnum (cadr var))
	     (progn
	       (push var var-list)
	       (while (re-search-forward gdb-var-list-children-regexp nil t)
		 (let ((varchild (list (match-string 2)
				       (match-string 1)
				       (match-string 3)
				       nil nil nil)))
		   (if (looking-at ",type=\"\\(.*?\\)\"")
		       (setcar (nthcdr 3 varchild) (match-string 1)))
		   (dolist (var1 gdb-var-list)
		     (if (string-equal (cadr var1) (cadr varchild))
			 (throw 'child-already-watched nil)))
		   (push varchild var-list)
		   (if (equal (nth 2 varchild) "0")
		       (gdb-enqueue-input
			(list
			 (concat
			  "server interpreter mi \"-var-evaluate-expression "
				 (nth 1 varchild) "\"\n")
			 `(lambda () (gdb-var-evaluate-expression-handler
				      ,(nth 1 varchild) nil))))))))
	   (push var var-list)))
       (setq gdb-var-list (nreverse var-list))))))

(defun gdb-var-update ()
  (when (not (member 'gdb-var-update gdb-pending-triggers))
    (gdb-enqueue-input
     (list "server interpreter mi \"-var-update *\"\n"
	   'gdb-var-update-handler))
    (push 'gdb-var-update gdb-pending-triggers)))

(defconst gdb-var-update-regexp "name=\"\\(.*?\\)\"")

(defun gdb-var-update-handler ()
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (while (re-search-forward gdb-var-update-regexp nil t)
	(let ((varnum (match-string 1)))
	  (gdb-enqueue-input
	   (list
	    (concat "server interpreter mi \"-var-evaluate-expression "
		    varnum "\"\n")
	    `(lambda () (gdb-var-evaluate-expression-handler ,varnum t)))))))
  (setq gdb-pending-triggers
   (delq 'gdb-var-update gdb-pending-triggers))
  (when (and (boundp 'speedbar-frame) (frame-live-p speedbar-frame))
    ;; Dummy command to update speedbar at right time.
    (gdb-enqueue-input (list "server pwd\n" 'gdb-speedbar-timer-fn))
    ;; Keep gdb-pending-triggers non-nil till end.
    (push 'gdb-speedbar-timer gdb-pending-triggers)))

(defun gdb-speedbar-timer-fn ()
  (setq gdb-pending-triggers
	(delq 'gdb-speedbar-timer gdb-pending-triggers))
  (with-current-buffer gud-comint-buffer
    (speedbar-timer-fn)))

(defun gdb-var-delete ()
  "Delete watch expression at point from the speedbar."
  (interactive)
  (if (with-current-buffer
	  gud-comint-buffer (memq gud-minor-mode '(gdbmi gdba)))
      (let ((text (speedbar-line-text)))
	(string-match "\\(\\S-+\\)" text)
	(let* ((expr (match-string 1 text))
	       (var (assoc expr gdb-var-list))
	       (varnum (cadr var)))
	  (unless (string-match "\\." varnum)
	    (gdb-enqueue-input
	     (list
	      (if (with-current-buffer gud-comint-buffer
		    (eq gud-minor-mode 'gdba))
		  (concat "server interpreter mi \"-var-delete " varnum "\"\n")
		(concat "-var-delete " varnum "\n"))
		   'ignore))
	    (setq gdb-var-list (delq var gdb-var-list))
	    (dolist (varchild gdb-var-list)
	      (if (string-match (concat (nth 1 var) "\\.") (nth 1 varchild))
		  (setq gdb-var-list (delq varchild gdb-var-list))))
	    (setq gdb-var-changed t))))))

(defun gdb-edit-value (text token indent)
  "Assign a value to a variable displayed in the speedbar."
  (let* ((var (nth (- (count-lines (point-min) (point)) 2) gdb-var-list))
	 (varnum (cadr var)) (value))
    (setq value (read-string "New value: "))
    (gdb-enqueue-input
     (list
      (if (with-current-buffer gud-comint-buffer
	    (eq gud-minor-mode 'gdba))
	  (concat "server interpreter mi \"-var-assign "
		  varnum " " value "\"\n")
	(concat "-var-assign " varnum " " value "\n"))
	   'ignore))))

(defcustom gdb-show-changed-values t
  "If non-nil highlight values that have recently changed in the speedbar.
The highlighting is done with `font-lock-warning-face'."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defun gdb-speedbar-expand-node (text token indent)
  "Expand the node the user clicked on.
TEXT is the text of the button we clicked on, a + or - item.
TOKEN is data related to this node.
INDENT is the current indentation depth."
  (cond ((string-match "+" text)        ;expand this node
	 (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
	     (gdb-var-list-children token)
	   (progn
	     (gdbmi-var-update)
	     (gdbmi-var-list-children token))))
	((string-match "-" text)	;contract this node
	 (dolist (var gdb-var-list)
	   (if (string-match (concat token "\\.") (nth 1 var))
	       (setq gdb-var-list (delq var gdb-var-list))))
	 (setq gdb-var-changed t))))

(defun gdb-get-target-string ()
  (with-current-buffer gud-comint-buffer
    gud-target-name))


;;
;; gdb buffers.
;;
;; Each buffer has a TYPE -- a symbol that identifies the function
;; of that particular buffer.
;;
;; The usual gdb interaction buffer is given the type `gdba' and
;; is constructed specially.
;;
;; Others are constructed by gdb-get-create-buffer and
;; named according to the rules set forth in the gdb-buffer-rules-assoc

(defvar gdb-buffer-rules-assoc '())

(defun gdb-get-buffer (key)
  "Return the gdb buffer tagged with type KEY.
The key should be one of the cars in `gdb-buffer-rules-assoc'."
  (save-excursion
    (gdb-look-for-tagged-buffer key (buffer-list))))

(defun gdb-get-create-buffer (key)
  "Create a new gdb  buffer of the type specified by KEY.
The key should be one of the cars in `gdb-buffer-rules-assoc'."
  (or (gdb-get-buffer key)
      (let* ((rules (assoc key gdb-buffer-rules-assoc))
	     (name (funcall (gdb-rules-name-maker rules)))
	     (new (get-buffer-create name)))
	(with-current-buffer new
	  (let ((trigger))
	    (if (cdr (cdr rules))
		(setq trigger (funcall (car (cdr (cdr rules))))))
	    (set (make-local-variable 'gdb-buffer-type) key)
	    (set (make-local-variable 'gud-minor-mode)
		 (with-current-buffer gud-comint-buffer gud-minor-mode))
	    (set (make-local-variable 'tool-bar-map) gud-tool-bar-map)
	    (if trigger (funcall trigger)))
	  new))))

(defun gdb-rules-name-maker (rules) (car (cdr rules)))

(defun gdb-look-for-tagged-buffer (key bufs)
  (let ((retval nil))
    (while (and (not retval) bufs)
      (set-buffer (car bufs))
      (if (eq gdb-buffer-type key)
	  (setq retval (car bufs)))
      (setq bufs (cdr bufs)))
    retval))

;;
;; This assoc maps buffer type symbols to rules.  Each rule is a list of
;; at least one and possible more functions.  The functions have these
;; roles in defining a buffer type:
;;
;;     NAME - Return a name for this  buffer type.
;;
;; The remaining function(s) are optional:
;;
;;     MODE - called in a new buffer with no arguments, should establish
;;	      the proper mode for the buffer.
;;

(defun gdb-set-buffer-rules (buffer-type &rest rules)
  (let ((binding (assoc buffer-type gdb-buffer-rules-assoc)))
    (if binding
	(setcdr binding rules)
      (push (cons buffer-type rules)
	    gdb-buffer-rules-assoc))))

;; GUD buffers are an exception to the rules
(gdb-set-buffer-rules 'gdba 'error)

;;
;; Partial-output buffer : This accumulates output from a command executed on
;; behalf of emacs (rather than the user).
;;
(gdb-set-buffer-rules 'gdb-partial-output-buffer
		      'gdb-partial-output-name)

(defun gdb-partial-output-name ()
  (concat "*partial-output-"
	  (gdb-get-target-string)
	  "*"))


(gdb-set-buffer-rules 'gdb-inferior-io
		      'gdb-inferior-io-name
		      'gdb-inferior-io-mode)

(defun gdb-inferior-io-name ()
  (concat "*input/output of "
	  (gdb-get-target-string)
	  "*"))

(defun gdb-display-inferior-io-buffer ()
  "Display IO of inferior in a separate window."
  (interactive)
  (if gdb-use-inferior-io-buffer
      (gdb-display-buffer
       (gdb-get-create-buffer 'gdb-inferior-io))))

(defconst gdb-frame-parameters
  '((height . 14) (width . 80)
    (unsplittable . t)
    (tool-bar-lines . nil)
    (menu-bar-lines . nil)
    (minibuffer . nil)))

(defun gdb-frame-inferior-io-buffer ()
  "Display IO of inferior in a new frame."
  (interactive)
  (if gdb-use-inferior-io-buffer
      (let ((special-display-regexps (append special-display-regexps '(".*")))
	    (special-display-frame-alist gdb-frame-parameters))
	(display-buffer (gdb-get-create-buffer 'gdb-inferior-io)))))

(defvar gdb-inferior-io-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-c" 'gdb-inferior-io-interrupt)
    (define-key map "\C-c\C-z" 'gdb-inferior-io-stop)
    (define-key map "\C-c\C-\\" 'gdb-inferior-io-quit)
    (define-key map "\C-c\C-d" 'gdb-inferior-io-eof)
    (define-key map "\C-d" 'gdb-inferior-io-eof)
    map))

(define-derived-mode gdb-inferior-io-mode comint-mode "Inferior I/O"
  "Major mode for gdb inferior-io."
  :syntax-table nil :abbrev-table nil
  ;; We want to use comint because it has various nifty and familiar
  ;; features.  We don't need a process, but comint wants one, so create
  ;; a dummy one.
  (make-comint-in-buffer
   (substring (buffer-name) 1 (- (length (buffer-name)) 1))
   (current-buffer) "hexl")
  (setq comint-input-sender 'gdb-inferior-io-sender))

(defun gdb-inferior-io-sender (proc string)
  ;; PROC is the pseudo-process created to satisfy comint.
  (with-current-buffer (process-buffer proc)
    (setq proc (get-buffer-process gud-comint-buffer))
    (process-send-string proc string)
    (process-send-string proc "\n")))

(defun gdb-inferior-io-interrupt ()
  "Interrupt the program being debugged."
  (interactive)
  (interrupt-process
   (get-buffer-process gud-comint-buffer) comint-ptyp))

(defun gdb-inferior-io-quit ()
  "Send quit signal to the program being debugged."
  (interactive)
  (quit-process
   (get-buffer-process gud-comint-buffer) comint-ptyp))

(defun gdb-inferior-io-stop ()
  "Stop the program being debugged."
  (interactive)
  (stop-process
   (get-buffer-process gud-comint-buffer) comint-ptyp))

(defun gdb-inferior-io-eof ()
  "Send end-of-file to the program being debugged."
  (interactive)
  (process-send-eof
   (get-buffer-process gud-comint-buffer)))


;;
;; gdb communications
;;

;; INPUT: things sent to gdb
;;
;; The queues are lists.  Each element is either a string (indicating user or
;; user-like input) or a list of the form:
;;
;;    (INPUT-STRING  HANDLER-FN)
;;
;; The handler function will be called from the partial-output buffer when the
;; command completes.  This is the way to write commands which invoke gdb
;; commands autonomously.
;;
;; These lists are consumed tail first.
;;

(defun gdb-send (proc string)
  "A comint send filter for gdb.
This filter may simply queue input for a later time."
  (with-current-buffer gud-comint-buffer
    (remove-text-properties (point-min) (point-max) '(face)))
  (let ((item (concat string "\n")))
    (if gud-running
      (progn
	(if gdb-enable-debug-log (push (cons 'send item) gdb-debug-log))
	(process-send-string proc item))
      (gdb-enqueue-input item))))

;; Note: Stuff enqueued here will be sent to the next prompt, even if it
;; is a query, or other non-top-level prompt.

(defun gdb-enqueue-input (item)
  (if gdb-prompting
      (progn
	(gdb-send-item item)
	(setq gdb-prompting nil))
    (push item gdb-input-queue)))

(defun gdb-dequeue-input ()
  (let ((queue gdb-input-queue))
    (and queue
	 (let ((last (car (last queue))))
	   (unless (nbutlast queue) (setq gdb-input-queue '()))
	   last))))

(defun gdb-send-item (item)
  (setq gdb-flush-pending-output nil)
  (if gdb-enable-debug-log (push (cons 'send-item item) gdb-debug-log))
  (setq gdb-current-item item)
  (with-current-buffer gud-comint-buffer
    (if (eq gud-minor-mode 'gdba)
	(if (stringp item)
	    (progn
	      (setq gdb-output-sink 'user)
	      (process-send-string (get-buffer-process gud-comint-buffer) item))
	  (progn
	    (gdb-clear-partial-output)
	    (setq gdb-output-sink 'pre-emacs)
	    (process-send-string (get-buffer-process gud-comint-buffer)
				 (car item))))
      ;; case: eq gud-minor-mode 'gdbmi
      (gdb-clear-partial-output)
      (setq gdb-output-sink 'emacs)
      (process-send-string (get-buffer-process gud-comint-buffer)
			   (car item)))))

;;
;; output -- things gdb prints to emacs
;;
;; GDB output is a stream interrupted by annotations.
;; Annotations can be recognized by their beginning
;; with \C-j\C-z\C-z<tag><opt>\C-j
;;
;; The tag is a string obeying symbol syntax.
;;
;; The optional part `<opt>' can be either the empty string
;; or a space followed by more data relating to the annotation.
;; For example, the SOURCE annotation is followed by a filename,
;; line number and various useless goo.  This data must not include
;; any newlines.
;;

(defcustom gud-gdba-command-name "gdb -annotate=3"
  "Default command to execute an executable under the GDB-UI debugger."
  :type 'string
  :group 'gud
  :version "22.1")

(defvar gdb-annotation-rules
  '(("pre-prompt" gdb-pre-prompt)
    ("prompt" gdb-prompt)
    ("commands" gdb-subprompt)
    ("overload-choice" gdb-subprompt)
    ("query" gdb-subprompt)
    ;; Need this prompt for GDB 6.1
    ("nquery" gdb-subprompt)
    ("prompt-for-continue" gdb-subprompt)
    ("post-prompt" gdb-post-prompt)
    ("source" gdb-source)
    ("starting" gdb-starting)
    ("exited" gdb-exited)
    ("signalled" gdb-exited)
    ("signal" gdb-stopping)
    ("breakpoint" gdb-stopping)
    ("watchpoint" gdb-stopping)
    ("frame-begin" gdb-frame-begin)
    ("stopped" gdb-stopped)
    ("error-begin" gdb-error)
    ("error" gdb-error)
    ) "An assoc mapping annotation tags to functions which process them.")

(defun gdb-resync()
  (setq gdb-flush-pending-output t)
  (setq gud-running nil)
  (setq gdb-output-sink 'user)
  (setq gdb-input-queue nil)
  (setq gdb-pending-triggers nil)
  (setq gdb-prompting t))

(defconst gdb-source-spec-regexp
  "\\(.*\\):\\([0-9]*\\):[0-9]*:[a-z]*:0x0*\\([a-f0-9]*\\)")

;; Do not use this except as an annotation handler.
(defun gdb-source (args)
  (string-match gdb-source-spec-regexp args)
  ;; Extract the frame position from the marker.
  (setq gud-last-frame
	(cons
	 (match-string 1 args)
	 (string-to-number (match-string 2 args))))
  (setq gdb-frame-address (match-string 3 args))
  ;; cover for auto-display output which comes *before*
  ;; stopped annotation
  (if (eq gdb-output-sink 'inferior) (setq gdb-output-sink 'user)))

(defun gdb-pre-prompt (ignored)
  "An annotation handler for `pre-prompt'.
This terminates the collection of output from a previous command if that
happens to be in effect."
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'user) t)
     ((eq sink 'emacs)
      (setq gdb-output-sink 'post-emacs))
     (t
      (gdb-resync)
      (error "Phase error in gdb-pre-prompt (got %s)" sink)))))

(defun gdb-prompt (ignored)
  "An annotation handler for `prompt'.
This sends the next command (if any) to gdb."
  (when gdb-first-prompt (gdb-ann3))
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'user) t)
     ((eq sink 'post-emacs)
      (setq gdb-output-sink 'user)
      (let ((handler
	     (car (cdr gdb-current-item))))
	(with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
	  (funcall handler))))
     (t
      (gdb-resync)
      (error "Phase error in gdb-prompt (got %s)" sink))))
  (let ((input (gdb-dequeue-input)))
    (if input
	(gdb-send-item input)
      (progn
	(setq gdb-prompting t)
	(gud-display-frame)))))

(defun gdb-subprompt (ignored)
  "An annotation handler for non-top-level prompts."
  (setq gdb-prompting t))

(defun gdb-starting (ignored)
  "An annotation handler for `starting'.
This says that I/O for the subprocess is now the program being debugged,
not GDB."
  (setq gdb-active-process t)
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'user)
      (progn
	(setq gud-running t)
	(if gdb-use-inferior-io-buffer
	    (setq gdb-output-sink 'inferior))))
     (t
      (gdb-resync)
      (error "Unexpected `starting' annotation")))))

(defun gdb-stopping (ignored)
  "An annotation handler for `breakpoint' and other annotations.
They say that I/O for the subprocess is now GDB, not the program
being debugged."
  (if gdb-use-inferior-io-buffer
      (let ((sink gdb-output-sink))
	(cond
	 ((eq sink 'inferior)
	  (setq gdb-output-sink 'user))
	 (t
	  (gdb-resync)
	  (error "Unexpected stopping annotation"))))))

(defun gdb-exited (ignored)
  "An annotation handler for `exited' and `signalled'.
They say that I/O for the subprocess is now GDB, not the program
being debugged and that the program is no longer running.  This
function is used to change the focus of GUD tooltips to #define
directives."
  (setq gdb-active-process nil)
  (gdb-stopping ignored))

(defun gdb-frame-begin (ignored)
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'inferior)
      (setq gdb-output-sink 'user))
     ((eq sink 'user) t)
     ((eq sink 'emacs) t)
     (t
      (gdb-resync)
      (error "Unexpected frame-begin annotation (%S)" sink)))))

(defun gdb-stopped (ignored)
  "An annotation handler for `stopped'.
It is just like `gdb-stopping', except that if we already set the output
sink to `user' in `gdb-stopping', that is fine."
  (setq gud-running nil)
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'inferior)
      (setq gdb-output-sink 'user))
     ((eq sink 'user) t)
     (t
      (gdb-resync)
      (error "Unexpected stopped annotation")))))

(defun gdb-error (ignored)
  (setq gdb-error (not gdb-error)))

(defun gdb-post-prompt (ignored)
  "An annotation handler for `post-prompt'.
This begins the collection of output from the current command if that
happens to be appropriate."
  (unless gdb-pending-triggers
    (gdb-get-selected-frame)
    (gdb-invalidate-frames)
    (gdb-invalidate-breakpoints)
    ;; Do this through gdb-get-selected-frame -> gdb-frame-handler
    ;; so gdb-frame-address is updated.
    ;; (gdb-invalidate-assembler)
    (gdb-invalidate-registers)
    (gdb-invalidate-memory)
    (gdb-invalidate-locals)
    (gdb-invalidate-threads)
    (unless (eq system-type 'darwin) ;Breaks on Darwin's GDB-5.3.
      ;; FIXME: with GDB-6 on Darwin, this might very well work.
      ;; Only needed/used with speedbar/watch expressions.
      (when (and (boundp 'speedbar-frame) (frame-live-p speedbar-frame))
	(setq gdb-var-changed t)    ; force update
	(dolist (var gdb-var-list)
	  (setcar (nthcdr 5 var) nil))
	(gdb-var-update))))
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'user) t)
     ((eq sink 'pre-emacs)
      (setq gdb-output-sink 'emacs))
     (t
      (gdb-resync)
      (error "Phase error in gdb-post-prompt (got %s)" sink)))))

(defun gud-gdba-marker-filter (string)
  "A gud marker filter for gdb.  Handle a burst of output from GDB."
  (if gdb-flush-pending-output
      nil
    (if gdb-enable-debug-log (push (cons 'recv string) gdb-debug-log))
    ;; Recall the left over gud-marker-acc from last time.
    (setq gud-marker-acc (concat gud-marker-acc string))
    ;; Start accumulating output for the GUD buffer.
    (let ((output ""))
      ;;
      ;; Process all the complete markers in this chunk.
      (while (string-match "\n\032\032\\(.*\\)\n" gud-marker-acc)
	(let ((annotation (match-string 1 gud-marker-acc)))
	  ;;
	  ;; Stuff prior to the match is just ordinary output.
	  ;; It is either concatenated to OUTPUT or directed
	  ;; elsewhere.
	  (setq output
		(gdb-concat-output
		 output
		 (substring gud-marker-acc 0 (match-beginning 0))))
	  ;;
	  ;; Take that stuff off the gud-marker-acc.
	  (setq gud-marker-acc (substring gud-marker-acc (match-end 0)))
	  ;;
	  ;; Parse the tag from the annotation, and maybe its arguments.
	  (string-match "\\(\\S-*\\) ?\\(.*\\)" annotation)
	  (let* ((annotation-type (match-string 1 annotation))
		 (annotation-arguments (match-string 2 annotation))
		 (annotation-rule (assoc annotation-type
					 gdb-annotation-rules)))
	    ;; Call the handler for this annotation.
	    (if annotation-rule
		(funcall (car (cdr annotation-rule))
			 annotation-arguments)
	      ;; Else the annotation is not recognized.  Ignore it silently,
	      ;; so that GDB can add new annotations without causing
	      ;; us to blow up.
	      ))))
      ;;
      ;; Does the remaining text end in a partial line?
      ;; If it does, then keep part of the gud-marker-acc until we get more.
      (if (string-match "\n\\'\\|\n\032\\'\\|\n\032\032.*\\'"
			gud-marker-acc)
	  (progn
	    ;; Everything before the potential marker start can be output.
	    (setq output
		  (gdb-concat-output output
				     (substring gud-marker-acc 0
						(match-beginning 0))))
	    ;;
	    ;; Everything after, we save, to combine with later input.
	    (setq gud-marker-acc (substring gud-marker-acc
					    (match-beginning 0))))
	;;
	;; In case we know the gud-marker-acc contains no partial annotations:
	(progn
	  (setq output (gdb-concat-output output gud-marker-acc))
	  (setq gud-marker-acc "")))
      output)))

(defun gdb-concat-output (so-far new)
  (if gdb-error
      (put-text-property 0 (length new) 'face font-lock-warning-face new))
  (let ((sink gdb-output-sink))
    (cond
     ((eq sink 'user) (concat so-far new))
     ((or (eq sink 'pre-emacs) (eq sink 'post-emacs)) so-far)
     ((eq sink 'emacs)
      (gdb-append-to-partial-output new)
      so-far)
     ((eq sink 'inferior)
      (gdb-append-to-inferior-io new)
      so-far)
     (t
      (gdb-resync)
      (error "Bogon output sink %S" sink)))))

(defun gdb-append-to-partial-output (string)
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-max))
    (insert string)))

(defun gdb-clear-partial-output ()
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (erase-buffer)))

(defun gdb-append-to-inferior-io (string)
  (with-current-buffer (gdb-get-create-buffer 'gdb-inferior-io)
    (goto-char (point-max))
    (insert-before-markers string))
  (if (not (string-equal string ""))
      (gdb-display-buffer (gdb-get-create-buffer 'gdb-inferior-io))))

(defun gdb-clear-inferior-io ()
  (with-current-buffer (gdb-get-create-buffer 'gdb-inferior-io)
    (erase-buffer)))


;; One trick is to have a command who's output is always available in a buffer
;; of it's own, and is always up to date.  We build several buffers of this
;; type.
;;
;; There are two aspects to this: gdb has to tell us when the output for that
;; command might have changed, and we have to be able to run the command
;; behind the user's back.
;;
;; The output phasing associated with the variable gdb-output-sink
;; help us to run commands behind the user's back.
;;
;; Below is the code for specificly managing buffers of output from one
;; command.
;;

;; The trigger function is suitable for use in the assoc GDB-ANNOTATION-RULES
;; It adds an input for the command we are tracking.  It should be the
;; annotation rule binding of whatever gdb sends to tell us this command
;; might have changed it's output.
;;
;; NAME is the function name. DEMAND-PREDICATE tests if output is really needed.
;; GDB-COMMAND is a string of such.  OUTPUT-HANDLER is the function bound to the
;; input in the input queue (see comment about ``gdb communications'' above).

(defmacro def-gdb-auto-update-trigger (name demand-predicate gdb-command
					    output-handler)
  `(defun ,name (&optional ignored)
     (if (and (,demand-predicate)
	      (not (member ',name
			   gdb-pending-triggers)))
	 (progn
	   (gdb-enqueue-input
	    (list ,gdb-command ',output-handler))
	   (push ',name gdb-pending-triggers)))))

(defmacro def-gdb-auto-update-handler (name trigger buf-key custom-defun)
  `(defun ,name ()
     (setq gdb-pending-triggers
      (delq ',trigger
	    gdb-pending-triggers))
     (let ((buf (gdb-get-buffer ',buf-key)))
       (and buf
	    (with-current-buffer buf
	      (let ((p (window-point (get-buffer-window buf 0)))
		    (buffer-read-only nil))
		(erase-buffer)
		(insert-buffer-substring (gdb-get-create-buffer
					  'gdb-partial-output-buffer))
		(set-window-point (get-buffer-window buf 0) p)))))
     ;; put customisation here
     (,custom-defun)))

(defmacro def-gdb-auto-updated-buffer (buffer-key
				       trigger-name gdb-command
				       output-handler-name custom-defun)
  `(progn
     (def-gdb-auto-update-trigger ,trigger-name
       ;; The demand predicate:
       (lambda () (gdb-get-buffer ',buffer-key))
       ,gdb-command
       ,output-handler-name)
     (def-gdb-auto-update-handler ,output-handler-name
       ,trigger-name ,buffer-key ,custom-defun)))


;;
;; Breakpoint buffer : This displays the output of `info breakpoints'.
;;
(gdb-set-buffer-rules 'gdb-breakpoints-buffer
		      'gdb-breakpoints-buffer-name
		      'gdb-breakpoints-mode)

(def-gdb-auto-updated-buffer gdb-breakpoints-buffer
  ;; This defines the auto update rule for buffers of type
  ;; `gdb-breakpoints-buffer'.
  ;;
  ;; It defines a function to serve as the annotation handler that
  ;; handles the `foo-invalidated' message.  That function is called:
  gdb-invalidate-breakpoints
  ;;
  ;; To update the buffer, this command is sent to gdb.
  "server info breakpoints\n"
  ;;
  ;; This also defines a function to be the handler for the output
  ;; from the command above.  That function will copy the output into
  ;; the appropriately typed buffer.  That function will be called:
  gdb-info-breakpoints-handler
  ;; buffer specific functions
  gdb-info-breakpoints-custom)

(defconst breakpoint-xpm-data
  "/* XPM */
static char *magick[] = {
/* columns rows colors chars-per-pixel */
\"10 10 2 1\",
\"  c red\",
\"+ c None\",
/* pixels */
\"+++    +++\",
\"++      ++\",
\"+        +\",
\"          \",
\"          \",
\"          \",
\"          \",
\"+        +\",
\"++      ++\",
\"+++    +++\",
};"
  "XPM data used for breakpoint icon.")

(defconst breakpoint-enabled-pbm-data
  "P1
10 10\",
0 0 0 0 1 1 1 1 0 0 0 0
0 0 0 1 1 1 1 1 1 0 0 0
0 0 1 1 1 1 1 1 1 1 0 0
0 1 1 1 1 1 1 1 1 1 1 0
0 1 1 1 1 1 1 1 1 1 1 0
0 1 1 1 1 1 1 1 1 1 1 0
0 1 1 1 1 1 1 1 1 1 1 0
0 0 1 1 1 1 1 1 1 1 0 0
0 0 0 1 1 1 1 1 1 0 0 0
0 0 0 0 1 1 1 1 0 0 0 0"
  "PBM data used for enabled breakpoint icon.")

(defconst breakpoint-disabled-pbm-data
  "P1
10 10\",
0 0 1 0 1 0 1 0 0 0
0 1 0 1 0 1 0 1 0 0
1 0 1 0 1 0 1 0 1 0
0 1 0 1 0 1 0 1 0 1
1 0 1 0 1 0 1 0 1 0
0 1 0 1 0 1 0 1 0 1
1 0 1 0 1 0 1 0 1 0
0 1 0 1 0 1 0 1 0 1
0 0 1 0 1 0 1 0 1 0
0 0 0 1 0 1 0 1 0 0"
  "PBM data used for disabled breakpoint icon.")

(defvar breakpoint-enabled-icon nil
  "Icon for enabled breakpoint in display margin.")

(defvar breakpoint-disabled-icon nil
  "Icon for disabled breakpoint in display margin.")

;; Bitmap for breakpoint in fringe
(and (display-images-p)
     (define-fringe-bitmap 'breakpoint
       "\x3c\x7e\xff\xff\xff\xff\x7e\x3c"))

(defface breakpoint-enabled
  '((t
     :foreground "red"
     :weight bold))
  "Face for enabled breakpoint icon in fringe."
  :group 'gud)
;; Compatibility alias for old name.
(put 'breakpoint-enabled-bitmap-face 'face-alias 'breakpoint-enabled)

(defface breakpoint-disabled
  ;; We use different values of grey for different background types,
  ;; so that on low-color displays it will end up as something visible
  ;; if it has to be approximated.
  '((((background dark))  :foreground "grey60")
    (((background light)) :foreground "grey40"))
  "Face for disabled breakpoint icon in fringe."
  :group 'gud)

;; Put breakpoint icons in relevant margins (even those set in the GUD buffer).
(defun gdb-info-breakpoints-custom ()
  (let ((flag) (bptno))
    ;; Remove all breakpoint-icons in source buffers but not assembler buffer.
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
	(if (and (eq gud-minor-mode 'gdba)
		 (not (string-match "\\`\\*.+\\*\\'" (buffer-name))))
	    (gdb-remove-breakpoint-icons (point-min) (point-max)))))
    (with-current-buffer (gdb-get-buffer 'gdb-breakpoints-buffer)
      (save-excursion
	(goto-char (point-min))
	(while (< (point) (- (point-max) 1))
	  (forward-line 1)
	  (if (looking-at "[^\t].*?breakpoint")
	      (progn
		(looking-at "\\([0-9]+\\)\\s-+\\S-+\\s-+\\S-+\\s-+\\(.\\)")
		(setq bptno (match-string 1))
		(setq flag (char-after (match-beginning 2)))
		(beginning-of-line)
		(if (re-search-forward " in .* at\\s-+" nil t)
		    (progn
		      (looking-at "\\(\\S-+\\):\\([0-9]+\\)")
		      (let ((line (match-string 2)) (buffer-read-only nil)
			    (file (match-string 1)))
			(add-text-properties (line-beginning-position)
					     (line-end-position)
			 '(mouse-face highlight
			   help-echo "mouse-2, RET: visit breakpoint"))
			(unless (file-exists-p file)
			   (setq file (cdr (assoc bptno gdb-location-alist))))
			(if (and file
				 (not (string-equal file "File not found")))
			    (with-current-buffer
				(find-file-noselect file 'nowarn)
			      (set (make-local-variable 'gud-minor-mode)
				   'gdba)
			      (set (make-local-variable 'tool-bar-map)
				   gud-tool-bar-map)
			      ;; Only want one breakpoint icon at each
			      ;; location.
			      (save-excursion
				(goto-line (string-to-number line))
				(gdb-put-breakpoint-icon (eq flag ?y) bptno)))
			  (gdb-enqueue-input
			   (list
			    (concat "list "
				    (match-string-no-properties 1) ":1\n")
			    'ignore))
			  (gdb-enqueue-input
			   (list "info source\n"
				 `(lambda () (gdb-get-location
					      ,bptno ,line ,flag))))))))))
	  (end-of-line)))))
  (if (gdb-get-buffer 'gdb-assembler-buffer) (gdb-assembler-custom)))

(defun gdb-mouse-set-clear-breakpoint (event)
  "Set/clear breakpoint in left fringe/margin with mouse click."
  (interactive "e")
  (mouse-minibuffer-check event)
  (let ((posn (event-end event)))
    (if (numberp (posn-point posn))
	(with-selected-window (posn-window posn)
	  (save-excursion
	    (goto-char (posn-point posn))
	    (if (or (posn-object posn)
		    (eq (car (fringe-bitmaps-at-pos (posn-point posn)))
			'breakpoint))
		(gud-remove nil)
	      (gud-break nil)))))))

(defun gdb-mouse-toggle-breakpoint (event)
  "Enable/disable breakpoint in left fringe/margin with mouse click."
  (interactive "e")
  (mouse-minibuffer-check event)
  (let ((posn (event-end event)))
    (if (numberp (posn-point posn))
	(with-selected-window (posn-window posn)
	  (save-excursion
	    (goto-char (posn-point posn))
	    (if	(posn-object posn)
		(gdb-enqueue-input
		 (list
		  (let ((bptno (get-text-property
				0 'gdb-bptno (car (posn-string posn)))))
		    (concat
			    (if (get-text-property
				 0 'gdb-enabled (car (posn-string posn)))
				"disable "
			      "enable ")
			    bptno "\n")) 'ignore))))))))

(defun gdb-breakpoints-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*breakpoints of " (gdb-get-target-string) "*")))

(defun gdb-display-breakpoints-buffer ()
  "Display status of user-settable breakpoints."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-breakpoints-buffer)))

(defun gdb-frame-breakpoints-buffer ()
  "Display status of user-settable breakpoints in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-breakpoints-buffer))))

(defvar gdb-breakpoints-mode-map
  (let ((map (make-sparse-keymap))
	(menu (make-sparse-keymap "Breakpoints")))
    (define-key menu [quit] '("Quit"   . kill-this-buffer))
    (define-key menu [goto] '("Goto"   . gdb-goto-breakpoint))
    (define-key menu [delete] '("Delete" . gdb-delete-breakpoint))
    (define-key menu [toggle] '("Toggle" . gdb-toggle-breakpoint))
    (suppress-keymap map)
    (define-key map [menu-bar breakpoints] (cons "Breakpoints" menu))
    (define-key map " " 'gdb-toggle-breakpoint)
    (define-key map "d" 'gdb-delete-breakpoint)
    (define-key map "q" 'kill-this-buffer)
    (define-key map "\r" 'gdb-goto-breakpoint)
    (define-key map [mouse-2] 'gdb-goto-breakpoint)
    (define-key map [follow-link] 'mouse-face)
    map))

(defun gdb-breakpoints-mode ()
  "Major mode for gdb breakpoints.

\\{gdb-breakpoints-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-breakpoints-mode)
  (setq mode-name "Breakpoints")
  (use-local-map gdb-breakpoints-mode-map)
  (setq buffer-read-only t)
  (run-mode-hooks 'gdb-breakpoints-mode-hook)
  (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
      'gdb-invalidate-breakpoints
    'gdbmi-invalidate-breakpoints))

(defun gdb-toggle-breakpoint ()
  "Enable/disable breakpoint at current line."
  (interactive)
  (save-excursion
    (beginning-of-line 1)
    (if (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
	    (looking-at "\\([0-9]+\\).*?point\\s-+\\S-+\\s-+\\(.\\)\\s-+")
	  (looking-at
     "\\([0-9]+\\)\\s-+\\S-+\\s-+\\S-+\\s-+\\(.\\)\\s-+\\S-+\\s-+\\S-+:[0-9]+"))
	(gdb-enqueue-input
	 (list
	  (concat gdb-server-prefix
		  (if (eq ?y (char-after (match-beginning 2)))
		      "disable "
		    "enable ")
		  (match-string 1) "\n") 'ignore))
      (error "Not recognized as break/watchpoint line"))))

(defun gdb-delete-breakpoint ()
  "Delete the breakpoint at current line."
  (interactive)
  (beginning-of-line 1)
  (if (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
	  (looking-at "\\([0-9]+\\).*?point\\s-+\\S-+\\s-+\\(.\\)")
	(looking-at
	 "\\([0-9]+\\)\\s-+\\S-+\\s-+\\S-+\\s-+\\s-+\\S-+\\s-+\\S-+:[0-9]+"))
      (gdb-enqueue-input
       (list
	(concat gdb-server-prefix "delete " (match-string 1) "\n") 'ignore))
    (error "Not recognized as break/watchpoint line")))

(defun gdb-goto-breakpoint (&optional event)
  "Display the breakpoint location specified at current line."
  (interactive (list last-input-event))
  (if event (mouse-set-point event))
  (save-excursion
    (beginning-of-line 1)
    (if (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
	    (looking-at "\\([0-9]+\\) .+ in .+ at\\s-+\\(\\S-+\\):\\([0-9]+\\)")
	  (looking-at
	   "\\([0-9]+\\)\\s-+\\S-+\\s-+\\S-+\\s-+.\\s-+\\S-+\\s-+\
\\(\\S-+\\):\\([0-9]+\\)"))
	(let ((bptno (match-string 1))
	      (file  (match-string 2))
	      (line  (match-string 3)))
	  (save-selected-window
	    (let* ((buf (find-file-noselect
			 (if (file-exists-p file) file
			   (cdr (assoc bptno gdb-location-alist)))))
		   (window (display-buffer buf)))
	      (with-current-buffer buf
		(goto-line (string-to-number line))
		(set-window-point window (point))))))
      (error "Not recognized as break/watchpoint line"))))


;; Frames buffer.  This displays a perpetually correct bactracktrace
;; (from the command `where').
;;
;; Alas, if your stack is deep, it is costly.
;;
(gdb-set-buffer-rules 'gdb-stack-buffer
		      'gdb-stack-buffer-name
		      'gdb-frames-mode)

(def-gdb-auto-updated-buffer gdb-stack-buffer
  gdb-invalidate-frames
  "server where\n"
  gdb-info-frames-handler
  gdb-info-frames-custom)

(defun gdb-info-frames-custom ()
  (with-current-buffer (gdb-get-buffer 'gdb-stack-buffer)
    (save-excursion
      (let ((buffer-read-only nil))
	(goto-char (point-min))
	(while (< (point) (point-max))
	  (add-text-properties (line-beginning-position) (line-end-position)
			     '(mouse-face highlight
			       help-echo "mouse-2, RET: Select frame"))
	  (beginning-of-line)
	  (when (and (looking-at "^#\\([0-9]+\\)")
		     (equal (match-string 1) gdb-frame-number))
	    (put-text-property (line-beginning-position) (line-end-position)
			       'face '(:inverse-video t)))
	  (forward-line 1))))))

(defun gdb-stack-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*stack frames of " (gdb-get-target-string) "*")))

(defun gdb-display-stack-buffer ()
  "Display backtrace of current stack."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-stack-buffer)))

(defun gdb-frame-stack-buffer ()
  "Display backtrace of current stack in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-stack-buffer))))

(defvar gdb-frames-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" 'kill-this-buffer)
    (define-key map "\r" 'gdb-frames-select)
    (define-key map [mouse-2] 'gdb-frames-select)
    (define-key map [follow-link] 'mouse-face)
    map))

(defun gdb-frames-mode ()
  "Major mode for gdb frames.

\\{gdb-frames-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-frames-mode)
  (setq mode-name "Frames")
  (setq buffer-read-only t)
  (use-local-map gdb-frames-mode-map)
  (font-lock-mode -1)
  (run-mode-hooks 'gdb-frames-mode-hook)
  (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
      'gdb-invalidate-frames
    'gdbmi-invalidate-frames))

(defun gdb-get-frame-number ()
  (save-excursion
    (let* ((pos (re-search-backward "^#*\\([0-9]*\\)" nil t))
	   (n (or (and pos (match-string-no-properties 1)) "0")))
      n)))

(defun gdb-frames-select (&optional event)
  "Select the frame and display the relevant source."
  (interactive (list last-input-event))
  (if event (mouse-set-point event))
  (gdb-enqueue-input
   (list (concat gdb-server-prefix "frame "
		 (gdb-get-frame-number) "\n") 'ignore))
  (gud-display-frame))


;; Threads buffer.  This displays a selectable thread list.
;;
(gdb-set-buffer-rules 'gdb-threads-buffer
		      'gdb-threads-buffer-name
		      'gdb-threads-mode)

(def-gdb-auto-updated-buffer gdb-threads-buffer
  gdb-invalidate-threads
  (concat gdb-server-prefix "info threads\n")
  gdb-info-threads-handler
  gdb-info-threads-custom)

(defun gdb-info-threads-custom ()
  (with-current-buffer (gdb-get-buffer 'gdb-threads-buffer)
    (let ((buffer-read-only nil))
      (goto-char (point-min))
      (while (< (point) (point-max))
	(add-text-properties (line-beginning-position) (line-end-position)
			     '(mouse-face highlight
			       help-echo "mouse-2, RET: select thread"))
	(forward-line 1)))))

(defun gdb-threads-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*threads of " (gdb-get-target-string) "*")))

(defun gdb-display-threads-buffer ()
  "Display IDs of currently known threads."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-threads-buffer)))

(defun gdb-frame-threads-buffer ()
  "Display IDs of currently known threads in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-threads-buffer))))

(defvar gdb-threads-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" 'kill-this-buffer)
    (define-key map "\r" 'gdb-threads-select)
    (define-key map [mouse-2] 'gdb-threads-select)
    map))

(defun gdb-threads-mode ()
  "Major mode for gdb frames.

\\{gdb-threads-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-threads-mode)
  (setq mode-name "Threads")
  (setq buffer-read-only t)
  (use-local-map gdb-threads-mode-map)
  (run-mode-hooks 'gdb-threads-mode-hook)
  'gdb-invalidate-threads)

(defun gdb-get-thread-number ()
  (save-excursion
    (re-search-backward "^\\s-*\\([0-9]*\\)" nil t)
    (match-string-no-properties 1)))

(defun gdb-threads-select (&optional event)
  "Select the thread and display the relevant source."
  (interactive (list last-input-event))
  (if event (mouse-set-point event))
  (gdb-enqueue-input
   (list (concat "thread " (gdb-get-thread-number) "\n") 'ignore))
  (gud-display-frame))


;; Registers buffer.
;;
(defcustom gdb-all-registers nil
  "Non-nil means include floating-point registers."
  :type 'boolean
  :group 'gud
  :version "22.1")

(gdb-set-buffer-rules 'gdb-registers-buffer
		      'gdb-registers-buffer-name
		      'gdb-registers-mode)

(def-gdb-auto-updated-buffer gdb-registers-buffer
  gdb-invalidate-registers
  (concat
   gdb-server-prefix "info " (if gdb-all-registers "all-") "registers\n")
  gdb-info-registers-handler
  gdb-info-registers-custom)

(defun gdb-info-registers-custom ())

(defvar gdb-registers-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map " " 'toggle-gdb-all-registers)
    (define-key map "q" 'kill-this-buffer)
     map))

(defun gdb-registers-mode ()
  "Major mode for gdb registers.

\\{gdb-registers-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-registers-mode)
  (setq mode-name "Registers:")
  (setq buffer-read-only t)
  (use-local-map gdb-registers-mode-map)
  (run-mode-hooks 'gdb-registers-mode-hook)
  (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
      'gdb-invalidate-registers
    'gdbmi-invalidate-registers))

(defun gdb-registers-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*registers of " (gdb-get-target-string) "*")))

(defun gdb-display-registers-buffer ()
  "Display integer register contents."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-registers-buffer)))

(defun gdb-frame-registers-buffer ()
  "Display integer register contents in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-registers-buffer))))

(defun toggle-gdb-all-registers ()
  "Toggle the display of floating-point registers."
  (interactive)
  (if gdb-all-registers
      (progn
	(setq gdb-all-registers nil)
	(with-current-buffer (gdb-get-buffer 'gdb-registers-buffer)
	  (setq mode-name "Registers:")))
	(setq gdb-all-registers t)
	(with-current-buffer (gdb-get-buffer 'gdb-registers-buffer)
	  (setq mode-name "Registers:All")))
  (gdb-invalidate-registers))


;; Memory buffer.
;;
(defcustom gdb-memory-repeat-count 32
  "Number of data items in memory window."
  :type 'integer
  :group 'gud
  :version "22.1")

(defcustom gdb-memory-format "x"
  "Display format of data items in memory window."
  :type '(choice (const :tag "Hexadecimal" "x")
	 	 (const :tag "Signed decimal" "d")
	 	 (const :tag "Unsigned decimal" "u")
		 (const :tag "Octal" "o")
		 (const :tag "Binary" "t"))
  :group 'gud
  :version "22.1")

(defcustom gdb-memory-unit "w"
  "Unit size of data items in memory window."
  :type '(choice (const :tag "Byte" "b")
		 (const :tag "Halfword" "h")
		 (const :tag "Word" "w")
		 (const :tag "Giant word" "g"))
  :group 'gud
  :version "22.1")

(gdb-set-buffer-rules 'gdb-memory-buffer
		      'gdb-memory-buffer-name
		      'gdb-memory-mode)

(def-gdb-auto-updated-buffer gdb-memory-buffer
  gdb-invalidate-memory
  (concat gdb-server-prefix "x/" (number-to-string gdb-memory-repeat-count)
	  gdb-memory-format gdb-memory-unit " " gdb-memory-address "\n")
  gdb-read-memory-handler
  gdb-read-memory-custom)

(defun gdb-read-memory-custom ()
  (save-excursion
    (goto-char (point-min))
    (if (looking-at "0x[[:xdigit:]]+")
	(setq gdb-memory-address (match-string 0)))))

(defvar gdb-memory-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" 'kill-this-buffer)
     map))

(defun gdb-memory-set-address (event)
  "Set the start memory address."
  (interactive "e")
  (save-selected-window
    (select-window (posn-window (event-start event)))
    (let ((arg (read-from-minibuffer "Memory address: ")))
      (setq gdb-memory-address arg))
    (gdb-invalidate-memory)))

(defun gdb-memory-set-repeat-count (event)
  "Set the number of data items in memory window."
  (interactive "e")
  (save-selected-window
    (select-window (posn-window (event-start event)))
    (let* ((arg (read-from-minibuffer "Repeat count: "))
	  (count (string-to-number arg)))
      (if (<= count 0)
	  (error "Positive numbers only")
	(customize-set-variable 'gdb-memory-repeat-count count)
	(gdb-invalidate-memory)))))

(defun gdb-memory-format-binary ()
  "Set the display format to binary."
  (interactive)
  (customize-set-variable 'gdb-memory-format "t")
  (gdb-invalidate-memory))

(defun gdb-memory-format-octal ()
  "Set the display format to octal."
  (interactive)
  (customize-set-variable 'gdb-memory-format "o")
  (gdb-invalidate-memory))

(defun gdb-memory-format-unsigned ()
  "Set the display format to unsigned decimal."
  (interactive)
  (customize-set-variable 'gdb-memory-format "u")
  (gdb-invalidate-memory))

(defun gdb-memory-format-signed ()
  "Set the display format to decimal."
  (interactive)
  (customize-set-variable 'gdb-memory-format "d")
  (gdb-invalidate-memory))

(defun gdb-memory-format-hexadecimal ()
  "Set the display format to hexadecimal."
  (interactive)
  (customize-set-variable 'gdb-memory-format "x")
  (gdb-invalidate-memory))

(defvar gdb-memory-format-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-3] 'gdb-memory-format-menu-1)
    map)
 "Keymap to select format in the header line.")

(defvar gdb-memory-format-menu (make-sparse-keymap "Format")
 "Menu of display formats in the header line.")

(define-key gdb-memory-format-menu [binary]
  '(menu-item "Binary" gdb-memory-format-binary
	      :button (:radio . (equal gdb-memory-format "t"))))
(define-key gdb-memory-format-menu [octal]
  '(menu-item "Octal" gdb-memory-format-octal
	      :button (:radio . (equal gdb-memory-format "o"))))
(define-key gdb-memory-format-menu [unsigned]
  '(menu-item "Unsigned Decimal" gdb-memory-format-unsigned
	      :button (:radio . (equal gdb-memory-format "u"))))
(define-key gdb-memory-format-menu [signed]
  '(menu-item "Signed Decimal" gdb-memory-format-signed
	      :button (:radio . (equal gdb-memory-format "d"))))
(define-key gdb-memory-format-menu [hexadecimal]
  '(menu-item "Hexadecimal" gdb-memory-format-hexadecimal
	      :button (:radio . (equal gdb-memory-format "x"))))

(defun gdb-memory-format-menu (event)
  (interactive "@e")
  (x-popup-menu event gdb-memory-format-menu))

(defun gdb-memory-format-menu-1 (event)
  (interactive "e")
  (save-selected-window
    (select-window (posn-window (event-start event)))
    (let* ((selection (gdb-memory-format-menu event))
	   (binding (and selection (lookup-key gdb-memory-format-menu
					       (vector (car selection))))))
      (if binding (call-interactively binding)))))

(defun gdb-memory-unit-giant ()
  "Set the unit size to giant words (eight bytes)."
  (interactive)
  (customize-set-variable 'gdb-memory-unit "g")
  (gdb-invalidate-memory))

(defun gdb-memory-unit-word ()
  "Set the unit size to words (four bytes)."
  (interactive)
  (customize-set-variable 'gdb-memory-unit "w")
  (gdb-invalidate-memory))

(defun gdb-memory-unit-halfword ()
  "Set the unit size to halfwords (two bytes)."
  (interactive)
  (customize-set-variable 'gdb-memory-unit "h")
  (gdb-invalidate-memory))

(defun gdb-memory-unit-byte ()
  "Set the unit size to bytes."
  (interactive)
  (customize-set-variable 'gdb-memory-unit "b")
  (gdb-invalidate-memory))

(defvar gdb-memory-unit-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-3] 'gdb-memory-unit-menu-1)
    map)
 "Keymap to select units in the header line.")

(defvar gdb-memory-unit-menu (make-sparse-keymap "Unit")
 "Menu of units in the header line.")

(define-key gdb-memory-unit-menu [giantwords]
  '(menu-item "Giant words" gdb-memory-unit-giant
	      :button (:radio . (equal gdb-memory-unit "g"))))
(define-key gdb-memory-unit-menu [words]
  '(menu-item "Words" gdb-memory-unit-word
	      :button (:radio . (equal gdb-memory-unit "w"))))
(define-key gdb-memory-unit-menu [halfwords]
  '(menu-item "Halfwords" gdb-memory-unit-halfword
	      :button (:radio . (equal gdb-memory-unit "h"))))
(define-key gdb-memory-unit-menu [bytes]
  '(menu-item "Bytes" gdb-memory-unit-byte
	      :button (:radio . (equal gdb-memory-unit "b"))))

(defun gdb-memory-unit-menu (event)
  (interactive "@e")
  (x-popup-menu event gdb-memory-unit-menu))

(defun gdb-memory-unit-menu-1 (event)
  (interactive "e")
  (save-selected-window
    (select-window (posn-window (event-start event)))
    (let* ((selection (gdb-memory-unit-menu event))
	   (binding (and selection (lookup-key gdb-memory-unit-menu
					       (vector (car selection))))))
      (if binding (call-interactively binding)))))

;;from make-mode-line-mouse-map
(defun gdb-make-header-line-mouse-map (mouse function) "\
Return a keymap with single entry for mouse key MOUSE on the header line.
MOUSE is defined to run function FUNCTION with no args in the buffer
corresponding to the mode line clicked."
  (let ((map (make-sparse-keymap)))
    (define-key map (vector 'header-line mouse) function)
    (define-key map (vector 'header-line 'down-mouse-1) 'ignore)
    map))

(defun gdb-memory-mode ()
  "Major mode for examining memory.

\\{gdb-memory-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-memory-mode)
  (setq mode-name "Memory")
  (setq buffer-read-only t)
  (use-local-map gdb-memory-mode-map)
  (setq header-line-format
	'(:eval
	  (concat
	   "Read address["
	   (propertize
	    "-"
	    'face font-lock-warning-face
	    'help-echo "mouse-1: Decrement address"
	    'mouse-face 'mode-line-highlight
	    'local-map
	    (gdb-make-header-line-mouse-map
	     'mouse-1
	     #'(lambda () (interactive)
		 (let ((gdb-memory-address
			;; Let GDB do the arithmetic.
			(concat
			 gdb-memory-address " - "
			 (number-to-string
			  (* gdb-memory-repeat-count
			     (cond ((string= gdb-memory-unit "b") 1)
				   ((string= gdb-memory-unit "h") 2)
				   ((string= gdb-memory-unit "w") 4)
				   ((string= gdb-memory-unit "g") 8)))))))
		       (gdb-invalidate-memory)))))
	   "|"
	   (propertize "+"
		       'face font-lock-warning-face
		       'help-echo "mouse-1: Increment address"
		       'mouse-face 'mode-line-highlight
		       'local-map (gdb-make-header-line-mouse-map
				   'mouse-1
				   #'(lambda () (interactive)
				       (let ((gdb-memory-address nil))
					 (gdb-invalidate-memory)))))
	   "]: "
	   (propertize gdb-memory-address
		       'face font-lock-warning-face
		       'help-echo "mouse-1: Set memory address"
		       'mouse-face 'mode-line-highlight
		       'local-map (gdb-make-header-line-mouse-map
				   'mouse-1
				   #'gdb-memory-set-address))
	   "  Repeat Count: "
	   (propertize (number-to-string gdb-memory-repeat-count)
		       'face font-lock-warning-face
		       'help-echo "mouse-1: Set repeat count"
		       'mouse-face 'mode-line-highlight
		       'local-map (gdb-make-header-line-mouse-map
				   'mouse-1
				   #'gdb-memory-set-repeat-count))
	   "  Display Format: "
	   (propertize gdb-memory-format
		       'face font-lock-warning-face
		       'help-echo "mouse-3: Select display format"
		       'mouse-face 'mode-line-highlight
		       'local-map gdb-memory-format-keymap)
	   "  Unit Size: "
	   (propertize gdb-memory-unit
		       'face font-lock-warning-face
		       'help-echo "mouse-3: Select unit size"
		       'mouse-face 'mode-line-highlight
		       'local-map gdb-memory-unit-keymap))))
  (run-mode-hooks 'gdb-memory-mode-hook)
  'gdb-invalidate-memory)

(defun gdb-memory-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*memory of " (gdb-get-target-string) "*")))

(defun gdb-display-memory-buffer ()
  "Display memory contents."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-memory-buffer)))

(defun gdb-frame-memory-buffer ()
  "Display memory contents in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-memory-buffer))))


;; Locals buffer.
;;
(gdb-set-buffer-rules 'gdb-locals-buffer
		      'gdb-locals-buffer-name
		      'gdb-locals-mode)

(def-gdb-auto-updated-buffer gdb-locals-buffer
  gdb-invalidate-locals
  "server info locals\n"
  gdb-info-locals-handler
  gdb-info-locals-custom)

;; Abbreviate for arrays and structures.
;; These can be expanded using gud-display.
(defun gdb-info-locals-handler nil
  (setq gdb-pending-triggers (delq 'gdb-invalidate-locals
				  gdb-pending-triggers))
  (let ((buf (gdb-get-buffer 'gdb-partial-output-buffer)))
    (with-current-buffer buf
      (goto-char (point-min))
      (while (re-search-forward "^[ }].*\n" nil t)
	(replace-match "" nil nil))
      (goto-char (point-min))
      (while (re-search-forward "{\\(.*=.*\n\\|\n\\)" nil t)
	(replace-match "(structure);\n" nil nil))
      (goto-char (point-min))
      (while (re-search-forward "\\s-*{.*\n" nil t)
	(replace-match " (array);\n" nil nil))))
  (let ((buf (gdb-get-buffer 'gdb-locals-buffer)))
    (and buf (with-current-buffer buf
	       (let ((p (window-point (get-buffer-window buf 0)))
		     (buffer-read-only nil))
		 (erase-buffer)
		 (insert-buffer-substring (gdb-get-create-buffer
					   'gdb-partial-output-buffer))
		(set-window-point (get-buffer-window buf 0) p)))))
  (run-hooks 'gdb-info-locals-hook))

(defun gdb-info-locals-custom ()
  nil)

(defvar gdb-locals-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" 'kill-this-buffer)
     map))

(defun gdb-locals-mode ()
  "Major mode for gdb locals.

\\{gdb-locals-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-locals-mode)
  (setq mode-name (concat "Locals:" gdb-selected-frame))
  (setq buffer-read-only t)
  (use-local-map gdb-locals-mode-map)
  (run-mode-hooks 'gdb-locals-mode-hook)
  (if (with-current-buffer gud-comint-buffer (eq gud-minor-mode 'gdba))
      'gdb-invalidate-locals
    'gdbmi-invalidate-locals))

(defun gdb-locals-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*locals of " (gdb-get-target-string) "*")))

(defun gdb-display-locals-buffer ()
  "Display local variables of current stack and their values."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-locals-buffer)))

(defun gdb-frame-locals-buffer ()
  "Display local variables of current stack and their values in a new frame."
  (interactive)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-locals-buffer))))


;;;; Window management
(defun gdb-display-buffer (buf &optional size)
  (let ((answer (get-buffer-window buf 0))
	(must-split nil))
    (if answer
	(display-buffer buf nil 0)	;Raise the frame if necessary.
      ;; The buffer is not yet displayed.
      (pop-to-buffer gud-comint-buffer)	;Select the right frame.
      (let ((window (get-lru-window)))
	(if (and window
	    (not (eq window (get-buffer-window gud-comint-buffer))))
	    (progn
	      (set-window-buffer window buf)
	      (setq answer window))
	  (setq must-split t)))
      (if must-split
	  (let* ((largest (get-largest-window))
		 (cur-size (window-height largest))
		 (new-size (and size (< size cur-size) (- cur-size size))))
	    (setq answer (split-window largest new-size))
	    (set-window-buffer answer buf)
	    (set-window-dedicated-p answer t)))
      answer)))


;;; Shared keymap initialization:

(let ((menu (make-sparse-keymap "GDB-Windows")))
  (define-key gud-menu-map [displays]
    `(menu-item "GDB-Windows" ,menu
		:visible (memq gud-minor-mode '(gdbmi gdba))))
  (define-key menu [gdb] '("Gdb" . gdb-display-gdb-buffer))
  (define-key menu [threads] '("Threads" . gdb-display-threads-buffer))
  (define-key menu [memory] '("Memory" . gdb-display-memory-buffer))
  (define-key menu [disassembly]
    '("Disassembly" . gdb-display-assembler-buffer))
  (define-key menu [registers] '("Registers" . gdb-display-registers-buffer))
  (define-key menu [inferior]
    '(menu-item "Inferior IO" gdb-display-inferior-io-buffer
		:enable gdb-use-inferior-io-buffer))
  (define-key menu [locals] '("Locals" . gdb-display-locals-buffer))
  (define-key menu [frames] '("Stack" . gdb-display-stack-buffer))
  (define-key menu [breakpoints]
    '("Breakpoints" . gdb-display-breakpoints-buffer)))

(let ((menu (make-sparse-keymap "GDB-Frames")))
  (define-key gud-menu-map [frames]
    `(menu-item "GDB-Frames" ,menu
		:visible (memq gud-minor-mode '(gdbmi gdba))))
  (define-key menu [gdb] '("Gdb" . gdb-frame-gdb-buffer))
  (define-key menu [threads] '("Threads" . gdb-frame-threads-buffer))
  (define-key menu [memory] '("Memory" . gdb-frame-memory-buffer))
  (define-key menu [disassembly] '("Disassembiy" . gdb-frame-assembler-buffer))
  (define-key menu [registers] '("Registers" . gdb-frame-registers-buffer))
  (define-key menu [inferior]
    '(menu-item "Inferior IO" gdb-frame-inferior-io-buffer
		:enable gdb-use-inferior-io-buffer))
  (define-key menu [locals] '("Locals" . gdb-frame-locals-buffer))
  (define-key menu [frames] '("Stack" . gdb-frame-stack-buffer))
  (define-key menu [breakpoints]
    '("Breakpoints" . gdb-frame-breakpoints-buffer)))

(let ((menu (make-sparse-keymap "GDB-UI")))
  (define-key gud-menu-map [ui]
    `(menu-item "GDB-UI" ,menu :visible (eq gud-minor-mode 'gdba)))
  (define-key menu [gdb-use-inferior-io]
    ;; See defadvice below.
    (menu-bar-make-toggle toggle-gdb-use-inferior-io-buffer
			  gdb-use-inferior-io-buffer
     "Separate inferior IO" "Use separate IO %s"
     "Toggle separate IO for inferior."))
  (define-key menu [gdb-many-windows]
  '(menu-item "Display Other Windows" gdb-many-windows
	      :help "Toggle display of locals, stack and breakpoint information"
	      :button (:toggle . gdb-many-windows)))
  (define-key menu [gdb-restore-windows]
  '(menu-item "Restore Window Layout" gdb-restore-windows
	      :help "Restore standard layout for debug session.")))

;; This function is defined above through a macro.
(defadvice toggle-gdb-use-inferior-io-buffer (after gdb-kill-io-buffer activate)
  (unless gdb-use-inferior-io-buffer
    (kill-buffer (gdb-inferior-io-name))))

(defun gdb-frame-gdb-buffer ()
  "Display GUD buffer in a new frame."
  (interactive)
  (select-frame (make-frame gdb-frame-parameters))
  (switch-to-buffer (gdb-get-create-buffer 'gdba))
  (set-window-dedicated-p (selected-window) t))

(defun gdb-display-gdb-buffer ()
  "Display GUD buffer."
  (interactive)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdba)))

(defun gdb-set-window-buffer (name)
  (set-window-buffer (selected-window) (get-buffer name))
  (set-window-dedicated-p (selected-window) t))

(defun gdb-setup-windows ()
  "Layout the window pattern for `gdb-many-windows'."
  (gdb-display-locals-buffer)
  (gdb-display-stack-buffer)
  (delete-other-windows)
  (gdb-display-breakpoints-buffer)
  (delete-other-windows)
  ; Don't dedicate.
  (pop-to-buffer gud-comint-buffer)
  (split-window nil ( / ( * (window-height) 3) 4))
  (split-window nil ( / (window-height) 3))
  (split-window-horizontally)
  (other-window 1)
  (gdb-set-window-buffer (gdb-locals-buffer-name))
  (other-window 1)
  (switch-to-buffer
       (if gud-last-last-frame
	   (gud-find-file (car gud-last-last-frame))
	 (gud-find-file gdb-main-file)))
  (when gdb-use-inferior-io-buffer
    (split-window-horizontally)
    (other-window 1)
    (gdb-set-window-buffer
     (gdb-get-create-buffer 'gdb-inferior-io)))
  (other-window 1)
  (gdb-set-window-buffer (gdb-stack-buffer-name))
  (split-window-horizontally)
  (other-window 1)
  (gdb-set-window-buffer (gdb-breakpoints-buffer-name))
  (other-window 1))

(defcustom gdb-many-windows nil
  "Nil means just pop up the GUD buffer unless `gdb-show-main' is t.
In this case it starts with two windows: one displaying the GUD
buffer and the other with the source file with the main routine
of the inferior.  Non-nil means display the layout shown for
`gdba'."
  :type 'boolean
  :group 'gud
  :version "22.1")

(defun gdb-many-windows (arg)
  "Toggle the number of windows in the basic arrangement."
  (interactive "P")
  (setq gdb-many-windows
	(if (null arg)
	    (not gdb-many-windows)
	  (> (prefix-numeric-value arg) 0)))
  (condition-case nil
      (gdb-restore-windows)
    (error nil)))

(defun gdb-restore-windows ()
  "Restore the basic arrangement of windows used by gdba.
This arrangement depends on the value of `gdb-many-windows'."
  (interactive)
  (pop-to-buffer gud-comint-buffer)	;Select the right window and frame.
    (delete-other-windows)
  (if gdb-many-windows
      (gdb-setup-windows)
    (split-window)
    (other-window 1)
    (switch-to-buffer
	 (if gud-last-last-frame
	     (gud-find-file (car gud-last-last-frame))
	   (gud-find-file gdb-main-file)))
    (other-window 1)))

(defun gdb-reset ()
  "Exit a debugging session cleanly.
Kills the gdb buffers and resets the source buffers."
  (dolist (buffer (buffer-list))
    (unless (eq buffer gud-comint-buffer)
      (with-current-buffer buffer
	(if (memq gud-minor-mode '(gdbmi gdba))
	    (if (string-match "\\`\\*.+\\*\\'" (buffer-name))
		(kill-buffer nil)
	      (gdb-remove-breakpoint-icons (point-min) (point-max) t)
	      (setq gud-minor-mode nil)
	      (kill-local-variable 'tool-bar-map)
	      (kill-local-variable 'gdb-define-alist))))))
  (when (markerp gdb-overlay-arrow-position)
    (move-marker gdb-overlay-arrow-position nil)
    (setq gdb-overlay-arrow-position nil))
  (setq overlay-arrow-variable-list
	(delq 'gdb-overlay-arrow-position overlay-arrow-variable-list))
  (setq gud-running nil)
  (setq gdb-active-process nil)
  (remove-hook 'after-save-hook 'gdb-create-define-alist t))

(defun gdb-source-info ()
  "Find the source file where the program starts and displays it with related
buffers."
  (goto-char (point-min))
  (if (and (search-forward "Located in " nil t)
	   (looking-at "\\S-+"))
      (setq gdb-main-file (match-string 0)))
  (goto-char (point-min))
  (if (search-forward "Includes preprocessor macro info." nil t)
      (setq gdb-macro-info t))
 (if gdb-many-windows
      (gdb-setup-windows)
   (gdb-get-create-buffer 'gdb-breakpoints-buffer)
   (if gdb-show-main
       (let ((pop-up-windows t))
	 (display-buffer (gud-find-file gdb-main-file))))))

(defun gdb-get-location (bptno line flag)
  "Find the directory containing the relevant source file.
Put in buffer and place breakpoint icon."
  (goto-char (point-min))
  (catch 'file-not-found
    (if (search-forward "Located in " nil t)
	(when (looking-at "\\S-+")
	  (delete (cons bptno "File not found") gdb-location-alist)
	  (push (cons bptno (match-string 0)) gdb-location-alist))
      (gdb-resync)
      (unless (assoc bptno gdb-location-alist)
	(push (cons bptno "File not found") gdb-location-alist)
	(message-box "Cannot find source file for breakpoint location.\n\
Add directory to search path for source files using the GDB command, dir."))
      (throw 'file-not-found nil))
    (with-current-buffer
	(find-file-noselect (match-string 0))
      (save-current-buffer
	(set (make-local-variable 'gud-minor-mode) 'gdba)
	(set (make-local-variable 'tool-bar-map) gud-tool-bar-map))
      ;; only want one breakpoint icon at each location
      (save-excursion
	(goto-line (string-to-number line))
	(gdb-put-breakpoint-icon (eq flag ?y) bptno)))))

(add-hook 'find-file-hook 'gdb-find-file-hook)

(defun gdb-find-file-hook ()
"Set up buffer for debugging if file is part of the source code
of the current session."
  (if (and (not gdb-find-file-unhook)
	   ;; in case gud or gdb-ui is just loaded
	   gud-comint-buffer
	   (buffer-name gud-comint-buffer)
	   (with-current-buffer gud-comint-buffer
	     (eq gud-minor-mode 'gdba)))
      (condition-case nil
	(gdb-enqueue-input
	 (list (concat gdb-server-prefix "list "
		       (file-name-nondirectory buffer-file-name)
		       ":1\n")
	       `(lambda () (gdb-set-gud-minor-mode ,(current-buffer)))))
	(error (setq gdb-find-file-unhook t)))))

;;from put-image
(defun gdb-put-string (putstring pos &optional dprop)
  "Put string PUTSTRING in front of POS in the current buffer.
PUTSTRING is displayed by putting an overlay into the current buffer with a
`before-string' string that has a `display' property whose value is
PUTSTRING."
  (let ((string (make-string 1 ?x))
	(buffer (current-buffer)))
    (setq putstring (copy-sequence putstring))
    (let ((overlay (make-overlay pos pos buffer))
	  (prop (or dprop
		    (list (list 'margin 'left-margin) putstring))))
      (put-text-property 0 (length string) 'display prop string)
      (overlay-put overlay 'put-break t)
      (overlay-put overlay 'before-string string))))

;;from remove-images
(defun gdb-remove-strings (start end &optional buffer)
  "Remove strings between START and END in BUFFER.
Remove only strings that were put in BUFFER with calls to `gdb-put-string'.
BUFFER nil or omitted means use the current buffer."
  (unless buffer
    (setq buffer (current-buffer)))
  (dolist (overlay (overlays-in start end))
    (when (overlay-get overlay 'put-break)
	  (delete-overlay overlay))))

(defun gdb-put-breakpoint-icon (enabled bptno)
  (let ((start (- (line-beginning-position) 1))
	(end (+ (line-end-position) 1))
	(putstring (if enabled "B" "b")))
    (add-text-properties
     0 1 '(help-echo "mouse-1: set/clear bkpt, mouse-3: enable/disable bkpt")
     putstring)
    (if enabled (add-text-properties
		 0 1 `(gdb-bptno ,bptno gdb-enabled t) putstring)
      (add-text-properties
       0 1 `(gdb-bptno ,bptno gdb-enabled nil) putstring))
    (gdb-remove-breakpoint-icons start end)
    (if (display-images-p)
	(if (>= (car (window-fringes)) 8)
	    (gdb-put-string
	     nil (1+ start)
	     `(left-fringe breakpoint
			   ,(if enabled
				'breakpoint-enabled
			      'breakpoint-disabled)))
	  (when (< left-margin-width 2)
	    (save-current-buffer
	      (setq left-margin-width 2)
	      (if (get-buffer-window (current-buffer) 0)
		  (set-window-margins
		   (get-buffer-window (current-buffer) 0)
		   left-margin-width right-margin-width))))
	  (put-image
	   (if enabled
	       (or breakpoint-enabled-icon
		   (setq breakpoint-enabled-icon
			 (find-image `((:type xpm :data
					      ,breakpoint-xpm-data
					      :ascent 100 :pointer hand)
				       (:type pbm :data
					      ,breakpoint-enabled-pbm-data
					      :ascent 100 :pointer hand)))))
	     (or breakpoint-disabled-icon
		 (setq breakpoint-disabled-icon
		       (find-image `((:type xpm :data
					    ,breakpoint-xpm-data
					    :conversion disabled
					    :ascent 100)
				     (:type pbm :data
					    ,breakpoint-disabled-pbm-data
					    :ascent 100))))))
	   (+ start 1)
	   putstring
	   'left-margin))
      (when (< left-margin-width 2)
	(save-current-buffer
	  (setq left-margin-width 2)
	  (if (get-buffer-window (current-buffer) 0)
	      (set-window-margins
	       (get-buffer-window (current-buffer) 0)
	       left-margin-width right-margin-width))))
      (gdb-put-string
       (propertize putstring
		   'face (if enabled 'breakpoint-enabled 'breakpoint-disabled))
       (1+ start)))))

(defun gdb-remove-breakpoint-icons (start end &optional remove-margin)
  (gdb-remove-strings start end)
  (if (display-images-p)
      (remove-images start end))
  (when remove-margin
    (setq left-margin-width 0)
    (if (get-buffer-window (current-buffer) 0)
	(set-window-margins
	 (get-buffer-window (current-buffer) 0)
	 left-margin-width right-margin-width))))


;;
;; Assembler buffer.
;;
(gdb-set-buffer-rules 'gdb-assembler-buffer
		      'gdb-assembler-buffer-name
		      'gdb-assembler-mode)

(def-gdb-auto-updated-buffer gdb-assembler-buffer
  gdb-invalidate-assembler
  (concat gdb-server-prefix "disassemble "
	  (if (member gdb-frame-address '(nil "main")) nil "0x")
	  gdb-frame-address "\n")
  gdb-assembler-handler
  gdb-assembler-custom)

(defun gdb-assembler-custom ()
  (let ((buffer (gdb-get-buffer 'gdb-assembler-buffer))
	(pos 1) (address) (flag) (bptno))
    (with-current-buffer buffer
      (save-excursion
	(if (not (equal gdb-frame-address "main"))
	    (progn
	      (goto-char (point-min))
	      (if (and gdb-frame-address
		       (re-search-forward gdb-frame-address nil t))
		  (progn
		    (setq pos (point))
		    (beginning-of-line)
		    (or gdb-overlay-arrow-position
			(setq gdb-overlay-arrow-position (make-marker)))
		    (set-marker gdb-overlay-arrow-position
				(point) (current-buffer))))))
	;; remove all breakpoint-icons in assembler buffer before updating.
	(gdb-remove-breakpoint-icons (point-min) (point-max))))
    (with-current-buffer (gdb-get-buffer 'gdb-breakpoints-buffer)
      (goto-char (point-min))
      (while (< (point) (- (point-max) 1))
	(forward-line 1)
	(if (looking-at "[^\t].*?breakpoint")
	    (progn
	      (looking-at
	    "\\([0-9]+\\)\\s-+\\S-+\\s-+\\S-+\\s-+\\(.\\)\\s-+0x0*\\(\\S-+\\)")
	      (setq bptno (match-string 1))
	      (setq flag (char-after (match-beginning 2)))
	      (setq address (match-string 3))
	      (with-current-buffer buffer
		(save-excursion
		  (goto-char (point-min))
		  (if (re-search-forward address nil t)
		      (gdb-put-breakpoint-icon (eq flag ?y) bptno))))))))
    (if (not (equal gdb-frame-address "main"))
	(set-window-point (get-buffer-window buffer 0) pos))))

(defvar gdb-assembler-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" 'kill-this-buffer)
     map))

(defvar gdb-assembler-font-lock-keywords
  '(;; <__function.name+n>
    ("<\\(\\(\\sw\\|[_.]\\)+\\)\\(\\+[0-9]+\\)?>"
     (1 font-lock-function-name-face))
    ;; 0xNNNNNNNN <__function.name+n>: opcode
    ("^0x[0-9a-f]+ \\(<\\(\\(\\sw\\|[_.]\\)+\\)\\+[0-9]+>\\)?:[ \t]+\\(\\sw+\\)"
     (4 font-lock-keyword-face))
    ;; %register(at least i386)
    ("%\\sw+" . font-lock-variable-name-face)
    ("^\\(Dump of assembler code for function\\) \\(.+\\):"
     (1 font-lock-comment-face)
     (2 font-lock-function-name-face))
    ("^\\(End of assembler dump\\.\\)" . font-lock-comment-face))
  "Font lock keywords used in `gdb-assembler-mode'.")

(defun gdb-assembler-mode ()
  "Major mode for viewing code assembler.

\\{gdb-assembler-mode-map}"
  (kill-all-local-variables)
  (setq major-mode 'gdb-assembler-mode)
  (setq mode-name (concat "Machine:" gdb-selected-frame))
  (setq gdb-overlay-arrow-position nil)
  (add-to-list 'overlay-arrow-variable-list 'gdb-overlay-arrow-position)
  (setq fringes-outside-margins t)
  (setq buffer-read-only t)
  (use-local-map gdb-assembler-mode-map)
  (gdb-invalidate-assembler)
  (set (make-local-variable 'font-lock-defaults)
       '(gdb-assembler-font-lock-keywords))
  (run-mode-hooks 'gdb-assembler-mode-hook)
  'gdb-invalidate-assembler)

(defun gdb-assembler-buffer-name ()
  (with-current-buffer gud-comint-buffer
    (concat "*Disassembly of " (gdb-get-target-string) "*")))

(defun gdb-display-assembler-buffer ()
  "Display disassembly view."
  (interactive)
  (setq gdb-previous-frame nil)
  (gdb-display-buffer
   (gdb-get-create-buffer 'gdb-assembler-buffer)))

(defun gdb-frame-assembler-buffer ()
  "Display disassembly view in a new frame."
  (interactive)
  (setq gdb-previous-frame nil)
  (let ((special-display-regexps (append special-display-regexps '(".*")))
	(special-display-frame-alist gdb-frame-parameters))
    (display-buffer (gdb-get-create-buffer 'gdb-assembler-buffer))))

;; modified because if gdb-frame-address has changed value a new command
;; must be enqueued to update the buffer with the new output
(defun gdb-invalidate-assembler (&optional ignored)
  (if (gdb-get-buffer 'gdb-assembler-buffer)
      (progn
	(unless (and gdb-selected-frame
		     (string-equal gdb-selected-frame gdb-previous-frame))
	  (if (or (not (member 'gdb-invalidate-assembler
			       gdb-pending-triggers))
		  (not (string-equal gdb-frame-address
				     gdb-previous-frame-address)))
	  (progn
	    ;; take previous disassemble command, if any, off the queue
	    (with-current-buffer gud-comint-buffer
	      (let ((queue gdb-input-queue))
		(dolist (item queue)
		  (if (equal (cdr item) '(gdb-assembler-handler))
		      (setq gdb-input-queue
			    (delete item gdb-input-queue))))))
	    (gdb-enqueue-input
	     (list
	      (concat gdb-server-prefix "disassemble "
		      (if (member gdb-frame-address '(nil "main")) nil "0x")
			   gdb-frame-address "\n")
		   'gdb-assembler-handler))
	    (push 'gdb-invalidate-assembler gdb-pending-triggers)
	    (setq gdb-previous-frame-address gdb-frame-address)
	    (setq gdb-previous-frame gdb-selected-frame)))))))

(defun gdb-get-selected-frame ()
  (if (not (member 'gdb-get-selected-frame gdb-pending-triggers))
      (progn
	(gdb-enqueue-input
	 (list (concat gdb-server-prefix "info frame\n") 'gdb-frame-handler))
	(push 'gdb-get-selected-frame
	       gdb-pending-triggers))))

(defun gdb-frame-handler ()
  (setq gdb-pending-triggers
	(delq 'gdb-get-selected-frame gdb-pending-triggers))
  (with-current-buffer (gdb-get-create-buffer 'gdb-partial-output-buffer)
    (goto-char (point-min))
    (if (re-search-forward  "Stack level \\([0-9]+\\)" nil t)
	(setq gdb-frame-number (match-string 1)))
    (goto-char (point-min))
    (if (re-search-forward
	 ".*=\\s-+0x0*\\(\\S-*\\)\\s-+in\\s-+\\(\\S-*?\\);? " nil t)
	(progn
	  (setq gdb-selected-frame (match-string 2))
	  (if (gdb-get-buffer 'gdb-locals-buffer)
	      (with-current-buffer (gdb-get-buffer 'gdb-locals-buffer)
		(setq mode-name (concat "Locals:" gdb-selected-frame))))
	  (if (gdb-get-buffer 'gdb-assembler-buffer)
	      (with-current-buffer (gdb-get-buffer 'gdb-assembler-buffer)
		(setq mode-name (concat "Machine:" gdb-selected-frame))))
	  (setq gdb-frame-address (match-string 1))))
    (goto-char (point-min))
    (if (re-search-forward " source language \\(\\S-*\\)\." nil t)
	(setq gdb-current-language (match-string 1))))
    (gdb-invalidate-assembler))

(provide 'gdb-ui)

;; arch-tag: e9fb00c5-74ef-469f-a088-37384caae352
;;; gdb-ui.el ends here
