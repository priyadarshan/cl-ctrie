;;;;; -*- mode: common-lisp;   common-lisp-style: modern;    coding: utf-8; -*-
;;;;;

;;;
;;; A few of the useful atomic innovations  from backports

(defpackage :atom
  (:use :cl :sb-ext :sb-vm)
  (:import-from :sb-ext :get-cas-expansion :define-cas-expander :cas
    :compare-and-swap :atomic-incf :atomic-decf :defcas :defglobal)
  (:export :get-cas-expansion :define-cas-expander :cas
    :compare-and-swap :atomic-incf :atomic-decf :defcas :defglobal
    :compare-and-set! :atomic-updatef :reference :box :deref
    ))
    
(in-package :atom)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Generalized atomic place
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Atomic Update (sbcl src copied over until i update to a more recent release)
;; TODO: unused?

(defmacro atomic-updatef (place update-fn &rest arguments &environment env) 
  "Updates PLACE atomically to the value returned by calling function
  designated by UPDATE-FN with ARGUMENTS and the previous value of PLACE.
  PLACE may be read and UPDATE-FN evaluated and called multiple times before the
  update succeeds: atomicity in this context means that value of place did not
  change between the time it was read, and the time it was replaced with the
  computed value. PLACE can be any place supported by SB-EXT:COMPARE-AND-SWAP.
  EXAMPLE: Conses T to the head of FOO-LIST:
  ;;;   (defstruct foo list)
  ;;;   (defvar *foo* (make-foo))
  ;;;   (atomic-update (foo-list *foo*) #'cons t)"
  (multiple-value-bind (vars vals old new cas-form read-form)
      (get-cas-expansion place env)
    `(let* (,@(mapcar 'list vars vals)
            (,old ,read-form))
       (loop for ,new = (funcall ,update-fn ,@arguments ,old)
             until (eq ,old (setf ,old ,cas-form))
             finally (return ,new)))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; instrumented boxed reference 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defclass reference ()
  ((value
    :reader deref
    :initarg :value)
   (validator
    :reader get-validator
    :initarg :validator)))

(defun validp (ref newval)
  (let ((validator (get-validator ref)))
    (%validp validator newval)))

(defun %validp (validator value)
  (or (not validator) (funcall validator value)))

(defmethod initialize-instance :after ((ref reference) &key value validator &allow-other-keys)
  (assert (%validp validator value)))


(defun set-validator (ref validator)
  "Attempt to set a new VALIDATOR for an AGENT, ATOM, or REF."
  (assert (%validp validator (deref ref)))
  (setf (slot-value ref 'validator) validator))


(defclass box (reference)
  ())


(defmethod pointer:deref ((box box) &optional (k #'identity) &rest args)
  (apply k (deref box) args))

(defmethod (setf pointer:deref) (value (box box) &optional (k #'identity) &rest args)
  (apply k (atomic-setf box value) args)) 

(defun make-box (value &optional validator)
  (make-instance 'box :value value :validator validator))


(defun compare-and-set! (atom oldval newval)
  "Atomically set a new value for an atom."
  (assert (validp atom newval))
  #+sbcl
  (eq (sb-ext:compare-and-swap (slot-value atom 'value) oldval newval) oldval))


(defun atomic-update! (atom f &rest args)
  "Set the value of ATOM to the result of applying F."
  (loop
     for oldval = (deref atom)
     for newval = (apply f oldval args)
     until (compare-and-set! atom oldval newval)
     finally (return newval)))

(defun atomic-setf (atom newval)
  "Set ATOM no NEWVAL, without regard to the previous value of ATOM."
  (atomic-update! atom (constantly newval)))


(defun flip (fn)
  "Return a function that swaps the order of the first two arguments to FN."
  (lambda (x y &rest args)
    (apply fn y x args)))

(defun atomic-adjoinf (atom &rest args)
  "ADJOIN an item to the list held by ATOM.  Accepts :KEY, :TEST, and :TEST-NOT arguments."
  (apply #'atomic-update! atom (flip #'adjoin) args))

(defun atomic-removef (atom &rest args)
  "REMOVE an item from the sequence held by ATOM.
Accepts :FROM-END, :TEST, :TEST-NOT, :START, :END, :COUNT, and :KEY."
  (apply #'atomic-update! atom (flip #'remove) args))

(defun atomic-unionf (atom &rest args)
  "Atomically sets the value of ATOM to the UNION of the previous
value and the provided list.  Accepts :KEY, :TEST, and :TEST-NOT."
  (apply #'atomic-update! atom #'union args))


