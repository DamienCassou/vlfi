;;; vlf-base.el --- VLF primitive operations  -*- lexical-binding: t -*-

;; Copyright (C) 2014 Free Software Foundation, Inc.

;; Keywords: large files, chunk
;; Author: Andrey Kotlarski <m00naticus@gmail.com>
;; URL: https://github.com/m00natic/vlfi

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;; This package provides basic chunk operations for VLF,
;; most notable being the `vlf-move-to-chunk' function.

;;; Code:

(defgroup vlf nil "View Large Files in Emacs."
  :prefix "vlf-" :group 'files)

(defcustom vlf-batch-size 1024
  "Defines how large each batch of file data is (in bytes)."
  :group 'vlf :type 'integer)
(put 'vlf-batch-size 'permanent-local t)

;;; Keep track of file position.
(defvar vlf-start-pos 0
  "Absolute position of the visible chunk start.")
(make-variable-buffer-local 'vlf-start-pos)
(put 'vlf-start-pos 'permanent-local t)

(defvar vlf-end-pos 0 "Absolute position of the visible chunk end.")
(make-variable-buffer-local 'vlf-end-pos)
(put 'vlf-end-pos 'permanent-local t)

(defvar vlf-file-size 0 "Total size of presented file.")
(make-variable-buffer-local 'vlf-file-size)
(put 'vlf-file-size 'permanent-local t)

(defconst vlf-sample-size 24
  "Minimal number of bytes that can be properly decoded.")

(defun vlf-get-file-size (file)
  "Get size in bytes of FILE."
  (or (nth 7 (file-attributes file)) 0))

(defun vlf-verify-size (&optional update-visited-time)
  "Update file size information if necessary and visited file time.
If non-nil, UPDATE-VISITED-TIME."
  (unless (verify-visited-file-modtime (current-buffer))
    (setq vlf-file-size (vlf-get-file-size buffer-file-truename))
    (if update-visited-time
        (set-visited-file-modtime))))

(unless (fboundp 'file-size-human-readable)
  (defun file-size-human-readable (file-size)
    "Print FILE-SIZE in MB."
    (format "%.3fMB" (/ file-size 1048576.0))))

(defun vlf-update-buffer-name ()
  "Update the current buffer name."
  (rename-buffer (format "%s(%d/%d)[%s]"
                         (file-name-nondirectory buffer-file-name)
                         (/ vlf-end-pos vlf-batch-size)
                         (/ vlf-file-size vlf-batch-size)
                         (file-size-human-readable vlf-batch-size))
                 t))

(defmacro vlf-with-undo-disabled (&rest body)
  "Execute BODY with temporarily disabled undo."
  `(let ((undo-list buffer-undo-list))
     (setq buffer-undo-list t)
     (unwind-protect (progn ,@body)
       (setq buffer-undo-list undo-list))))

(defun vlf-move-to-chunk (start end &optional minimal)
  "Move to chunk enclosed by START END bytes.
When given MINIMAL flag, skip non important operations.
If same as current chunk is requested, do nothing.
Return number of bytes moved back for proper decoding and number of
bytes added to the end."
  (vlf-verify-size)
  (cond ((or (<= end start) (<= end 0)
             (<= vlf-file-size start))
         (when (or (not (buffer-modified-p))
                   (y-or-n-p "Chunk modified, are you sure? "))
           (erase-buffer)
           (set-buffer-modified-p nil)
           (let ((place (if (<= vlf-file-size start)
                            vlf-file-size
                          0)))
             (setq vlf-start-pos place
                   vlf-end-pos place)
             (if (not minimal)
                 (vlf-update-buffer-name))
             (cons (- start place) (- place end)))))
        ((or (/= start vlf-start-pos)
             (/= end vlf-end-pos))
         (let ((shifts (vlf-move-to-chunk-1 start end)))
           (and shifts (not minimal)
                (vlf-update-buffer-name))
           shifts))))

(defun vlf-move-to-chunk-1 (start end)
  "Move to chunk enclosed by START END keeping as much edits if any.
Return number of bytes moved back for proper decoding and number of
bytes added to the end."
  (widen)
  (let* ((modified (buffer-modified-p))
         (start (max 0 start))
         (end (min end vlf-file-size))
         (edit-end (if modified
                       (+ vlf-start-pos
                          (length (encode-coding-region
                                   (point-min) (point-max)
                                   buffer-file-coding-system t)))
                     vlf-end-pos)))
    (cond
     ((or (< edit-end start) (< end vlf-start-pos)
          (not (verify-visited-file-modtime (current-buffer))))
      (when (or (not modified)
                (y-or-n-p "Chunk modified, are you sure? ")) ;full chunk renewal
        (set-buffer-modified-p nil)
        (vlf-move-to-chunk-2 start end)))
     ((and (= start vlf-start-pos) (= end edit-end))
      (or modified (vlf-move-to-chunk-2 start end)))
     ((or (and (<= start vlf-start-pos) (<= edit-end end))
          (not modified)
          (y-or-n-p "Chunk modified, are you sure? "))
      (let ((shift-start 0)
            (shift-end 0))
        (let ((pos (+ (position-bytes (point)) vlf-start-pos))
              (inhibit-read-only t))
          (cond ((= end vlf-start-pos)
                 (or (eq buffer-undo-list t)
                     (setq buffer-undo-list nil))
                 (vlf-with-undo-disabled (erase-buffer))
                 (setq modified nil))
                ((< end edit-end)
                 (setq end (car (vlf-delete-region
                                 (point-min) vlf-start-pos edit-end
                                 end (min (or (byte-to-position
                                               (- end vlf-start-pos))
                                              (point-min))
                                          (point-max))
                                 nil))))
                ((< edit-end end)
                 (vlf-with-undo-disabled
                  (setq shift-end (cdr (vlf-insert-file-contents
                                        vlf-end-pos end nil t
                                        (point-max)))))))
          (setq vlf-end-pos (+ end shift-end))
          (cond ((= start edit-end)
                 (or (eq buffer-undo-list t)
                     (setq buffer-undo-list nil))
                 (vlf-with-undo-disabled
                  (delete-region (point-min) (point)))
                 (setq modified nil))
                ((< vlf-start-pos start)
                 (let ((del-info (vlf-delete-region
                                  (point-min) vlf-start-pos
                                  vlf-end-pos start
                                  (min (or (byte-to-position
                                            (- start vlf-start-pos))
                                           (point))
                                       (point-max)) t)))
                   (setq start (car del-info))
                   (vlf-shift-undo-list (- (point-min)
                                           (cdr del-info)))))
                ((< start vlf-start-pos)
                 (let ((edit-end-pos (point-max)))
                   (vlf-with-undo-disabled
                    (setq shift-start (car (vlf-insert-file-contents
                                            start vlf-start-pos t nil
                                            edit-end-pos)))
                    (goto-char (point-min))
                    (insert (delete-and-extract-region
                             edit-end-pos (point-max))))
                   (vlf-shift-undo-list (- (point-max)
                                           edit-end-pos)))))
          (setq start (- start shift-start))
          (goto-char (or (byte-to-position (- pos start))
                         (byte-to-position (- pos vlf-start-pos))
                         (point-max)))
          (setq vlf-start-pos start))
        (set-buffer-modified-p modified)
        (set-visited-file-modtime)
        (cons shift-start shift-end))))))

(defun vlf-move-to-chunk-2 (start end)
  "Unconditionally move to chunk enclosed by START END bytes.
Return number of bytes moved back for proper decoding and number of
bytes added to the end."
  (vlf-verify-size t)
  (setq vlf-start-pos (max 0 start)
        vlf-end-pos (min end vlf-file-size))
  (let (shifts)
    (let ((inhibit-read-only t)
          (pos (position-bytes (point))))
      (vlf-with-undo-disabled
       (erase-buffer)
       (setq shifts (vlf-insert-file-contents vlf-start-pos
                                              vlf-end-pos t t)
             vlf-start-pos (- vlf-start-pos (car shifts))
             vlf-end-pos (+ vlf-end-pos (cdr shifts)))
       (goto-char (or (byte-to-position (+ pos (car shifts)))
                      (point-max)))))
    (set-buffer-modified-p nil)
    (or (eq buffer-undo-list t)
        (setq buffer-undo-list nil))
    shifts))

(defun vlf-insert-file-contents (start end adjust-start adjust-end
                                       &optional position)
  "Adjust chunk at absolute START to END till content can be\
properly decoded.  ADJUST-START determines if trying to prepend bytes
to the beginning, ADJUST-END - append to the end.
Use buffer POSITION as start if given.
Return number of bytes moved back for proper decoding and number of
bytes added to the end."
  (setq adjust-start (and adjust-start (not (zerop start)))
        adjust-end (and adjust-end (< end vlf-file-size))
        position (or position (point-min)))
  (goto-char position)
  (let ((shift-start 0)
        (shift-end 0)
        (safe-end (if adjust-end
                      (min vlf-file-size (+ end 4))
                    end)))
    (if adjust-start
        (setq shift-start (vlf-adjust-start start safe-end position
                                            adjust-end)
              start (- start shift-start))
      (vlf-insert-file-contents-1 start safe-end))
    (if adjust-end
        (setq shift-end (- (car (vlf-delete-region position start
                                                   safe-end end
                                                   (point-max)
                                                   nil 'start))
                           end)))
    (cons shift-start shift-end)))

(defun vlf-insert-file-contents-1 (start end)
  "Extract decoded file bytes START to END."
  (insert-file-contents buffer-file-name nil start end))

(defun vlf-adjust-start (start end position adjust-end)
  "Adjust chunk beginning at absolute START to END till content can\
be properly decoded.  Use buffer POSITION as start.
ADJUST-END is non-nil if end would be adjusted later.
Return number of bytes moved back for proper decoding."
  (let* ((safe-start (max 0 (- start 4)))
         (sample-end (min end (+ safe-start vlf-sample-size)))
         (chunk-size (- sample-end safe-start))
         (strict (or (= sample-end vlf-file-size)
                     (and (not adjust-end) (= sample-end end))))
         (shift 0))
    (while (and (progn (vlf-insert-file-contents-1 safe-start
                                                   sample-end)
                       (not (zerop safe-start)))
                (< shift 3)
                (let ((diff (- chunk-size
                               (length
                                (encode-coding-region
                                 position (point-max)
                                 buffer-file-coding-system t)))))
                  (if strict
                      (not (zerop diff))
                    (or (< diff -3) (< 0 diff)))))
      (setq shift (1+ shift)
            safe-start (1- safe-start)
            chunk-size (1+ chunk-size))
      (delete-region position (point-max)))
    (setq safe-start (car (vlf-delete-region position safe-start
                                             sample-end start
                                             position t 'start)))
    (unless (= sample-end end)
      (delete-region position (point-max))
      (vlf-insert-file-contents-1 safe-start end))
    (- start safe-start)))

(defun vlf-delete-region (position start end border cut-point from-start
                                   &optional encode-direction)
  "Delete from chunk starting at POSITION enclosing absolute file\
positions START to END at absolute position BORDER.  Start search for
best cut at CUT-POINT.  Delete from buffer beginning if FROM-START is
non nil or up to buffer end otherwise.  ENCODE-DIRECTION determines
which side of the region to use to calculate cut position's absolute
file position.  Possible values are: `start' - from the beginning;
`end' - from end; nil - the shorter side.
Return actual absolute position of new border and buffer point at
which deletion was performed."
  (let* ((encode-from-end (if encode-direction
                              (eq encode-direction 'end)
                            (< (- end border) (- border start))))
         (dist (if encode-from-end
                   (- end (length (encode-coding-region
                                   cut-point (point-max)
                                   buffer-file-coding-system t)))
                 (+ start (length (encode-coding-region
                                   position cut-point
                                   buffer-file-coding-system t)))))
         (len 0))
    (if (< border dist)
        (while (< border dist)
          (setq len (length (encode-coding-region
                             cut-point (1- cut-point)
                             buffer-file-coding-system t))
                cut-point (1- cut-point)
                dist (- dist len)))
      (while (< dist border)
        (setq len (length (encode-coding-region
                           cut-point (1+ cut-point)
                           buffer-file-coding-system t))
              cut-point (1+ cut-point)
              dist (+ dist len)))
      (or (= dist border)
          (setq cut-point (1- cut-point)
                dist (- dist len))))
    (and (not from-start) (/= dist border)
         (setq cut-point (1+ cut-point)
               dist (+ dist len)))
    (vlf-with-undo-disabled
     (if from-start (delete-region position cut-point)
       (delete-region cut-point (point-max))))
    (cons dist (1+ cut-point))))

(defun vlf-shift-undo-list (n)
  "Shift undo list element regions by N."
  (or (eq buffer-undo-list t)
      (setq buffer-undo-list
            (nreverse
             (let ((min (point-min))
                   undo-list)
               (catch 'end
                 (dolist (el buffer-undo-list undo-list)
                   (push
                    (cond
                     ((null el) nil)
                     ((numberp el) (let ((pos (+ el n)))
                                     (if (< pos min)
                                         (throw 'end undo-list)
                                       pos)))
                     (t (let ((head (car el)))
                          (cond ((numberp head)
                                 (let ((beg (+ head n)))
                                   (if (< beg min)
                                       (throw 'end undo-list)
                                     (cons beg (+ (cdr el) n)))))
                                ((stringp head)
                                 (let* ((pos (cdr el))
                                        (positive (< 0 pos))
                                        (new (+ (abs pos) n)))
                                   (if (< new min)
                                       (throw 'end undo-list)
                                     (cons head (if positive
                                                    new
                                                  (- new))))))
                                ((null head)
                                 (let ((beg (+ (nth 3 el) n)))
                                   (if (< beg min)
                                       (throw 'end undo-list)
                                     (cons
                                      nil
                                      (cons
                                       (cadr el)
                                       (cons
                                        (nth 2 el)
                                        (cons beg
                                              (+ (cddr
                                                  (cddr el)) n))))))))
                                ((and (eq head 'apply)
                                      (numberp (cadr el)))
                                 (let ((beg (+ (nth 2 el) n)))
                                   (if (< beg min)
                                       (throw 'end undo-list)
                                     (cons
                                      'apply
                                      (cons
                                       (cadr el)
                                       (cons
                                        beg
                                        (cons
                                         (+ (nth 3 el) n)
                                         (cons (nth 4 el)
                                               (cdr (last el))))))))))
                                (t el)))))
                    undo-list))))))))

(provide 'vlf-base)

;;; vlf-base.el ends here
