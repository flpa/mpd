;;; -*- Mode: Lisp -*-

;;; This software is in the public domain and is
;;; provided with absolutely no warranty.

(in-package :mpd)

(defvar *defualt-host* "localhost")
(defvar *default-port* 6600)

(defun connect (&key (host *defualt-host*) (port *default-port*)
		password)
  "Connect to MPD."
  (let ((connection (socket-connect host port)))
    (prog1 (values connection
		   (read-answer (socket-stream connection)))
      (when password (password connection password)))))

(defun read-answer (stream)
  (loop
     for line = (read-line stream nil)
     until (string= line "OK" :end1 2)
     collect line
     if (string= line "ACK" :end1 3) do
       (handle-error line)))

(defun handle-error (text)
  (let* ((error-id (parse-integer text :start 5 :junk-allowed t))
	 (delimiter (position #\] text))
	 (condition (cdr (assoc error-id +error-ids-alist+))))
    (error condition :text (subseq text (+ delimiter 2)))))

(defmacro with-mpd ((var &rest options) &body body)
  `(let ((,var (connect ,@options)))
     (unwind-protect
	  (progn ,@body)
       (disconnect ,var))))

(defun send-command (command connection)
  "Send command to MPD."
  (let ((stream (socket-stream connection)))
    (if (open-stream-p stream)
	(progn
	  (write-line command stream)
	  (force-output stream)
	  (read-answer stream))
	(error 'mpd-error :text (format nil "The stream ~A is not opened." stream)))))

(defun split-value (string)
  "Split a string 'key: value' into (list :key value)."
  (let* ((column-position (position #\: string))
	 (keyword (make-keyword
		   (string-upcase (subseq string 0 column-position))))
	 (value (subseq string (+ 2 column-position))))
    (list keyword
	  (if (member keyword +integer-keys+)
	      (parse-integer value)
	      value))))

(defun split-values (strings)
  "Transform the list of strings 'key: value' into the plist."
  (mapcan #'split-value strings))

(defun filter-keys (strings)
  "Transform the list of strings 'key: value' into the list of values."
  (mapcar (lambda (entry)
	    (subseq entry (+ 2 (position #\: entry))))
	  strings))

;;; C.f. performance:
;; (apply (lambda (&key foo bar) (make-instance
;; 	    'zot :quux 42 :foo foo :bar bar)) list)
(defun make-track (data type)
  "Make a new instance of the class playlist with initargs from
   the list of strings 'key: value'."
  (apply 'make-instance type (split-values data)))

(defun parse-list (list &optional class)
  "Make a list of new instances of the class `class' with initargs from
   a list of strings `key: value'. Each track is separeted by the `file' key."
  (let (track)
    (flet ((create-track ()
	     (when track
	       (list
		(apply 'make-instance class track)))))
      (nconc
       (mapcan (lambda (x)
		 (let ((pair (split-value x)))
		   (case (car pair)
		     ((:file) (prog1 (create-track)
				(setf track pair)))
		     ((:directory :playlist)
		      (list pair))
		     (t (nconc track pair)
			nil))))
	       list)
       (create-track)))))

(defun process-string (string)
  (when string
    (let ((string
	   (string-trim '(#\Space #\Tab #\Newline) string)))
      (assert (> (length string) 0))
      (if (position #\Space string)
	  (format nil "~s" string)
	  string))))

;;; Macros

(defmacro send (&rest commands)
  `(send-command (format nil "~{~A~^ ~}"
			 (remove nil (list ,@commands)))
		 connection))

(defmacro defcommand (name parameters &body body)
  (multiple-value-bind (forms decl doc) (parse-body body :documentation t)
    `(defun ,name (connection ,@parameters)
       ,@decl ,doc
       ,@forms)))

(defmacro defmethod-command (name parameters &body body)
  (multiple-value-bind (forms decl) (parse-body body)
    `(defmethod ,name (connection ,@parameters)
       ,@decl
       ,@forms)))

(defmacro check-args (type &rest args)
  (if (or (eq type 'string)
	  (equal type '(or string null)))
      `(progn ,@(mapcan
		 (lambda (arg)
		   `((check-type ,arg ,type "a string")
		     (setf ,arg (process-string ,arg))))
		 args))
      `(progn ,@(mapcar
		 (lambda (arg)
		   `(check-type ,arg ,type "an integer"))
		 args))))