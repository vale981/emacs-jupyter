;;; jupyter-monads.el --- Monadic Jupyter I/O -*- lexical-binding: t -*-

;; Copyright (C) 2020 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 11 May 2020

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; TODO: Add a state monad to log state changes of a kernel, client, etc.
;;
;; TODO: Generalize `jupyter-with-io' and `jupyter-do' for any monad,
;; not just the I/O one.
;;
;; TODO: Rename delayed -> io since any monadic value really
;; represents some kind of delayed value.
;;
;; TODO: Implement seq interface?
;;
;; TODO: Test unsubscribing publishers.
;; 
;; TODO: Allow pcase patterns in mlet*
;;
;;     (jupyter-mlet* ((value (jupyter-server-kernel-io kernel)))
;;       (pcase-let ((`(,kernel-sub ,event-pub) value))
;;         ...))
;;
;;     into
;;
;;     (jupyter-mlet* ((`(,kernel-sub ,event-pub)
;;                      (jupyter-server-kernel-io kernel)))
;;       ...)

;; The context of an I/O action is the current I/O publisher.
;;
;; The context of a publisher is its list of subscribers.
;;
;; The context of a subscriber is whether or not it remains subscribed
;; to a publisher.

;; Publisher/subscriber
;;
;; - A value is submitted to a publisher via `jupyter-publish'.
;;
;; - A publishing function takes the value and optionally returns
;;   content (by returning the result of `jupyter-content' on a
;;   value).
;;
;; - If no content is returned, nothing is published to subscribers.
;;
;; - When content is returned, that content is published to
;;   subscribers (the subscriber functions called on the content).
;;
;; - The result of distributing content to a subscriber is the
;;   subscriber's subscription status.
;;
;;   - If a subscriber returns anything other than the result of
;;    `jupyter-unsubscribe', the subscription is kept.

;;; Code:

(defgroup jupyter-monads nil
  "Monadic Jupyter I/O"
  :group 'jupyter)

(cl-defstruct jupyter-delayed value)

(defun jupyter-scalar-p (x)
  (or (symbolp x) (numberp x) (stringp x)
      (and (listp x)
           (memq (car x) '(quote function closure)))))

(defconst jupyter-io-nil (make-jupyter-delayed :value (lambda () nil)))

(defvar jupyter-io-cache (make-hash-table :weakness 'key))

(cl-defgeneric jupyter-io (thing)
  "Return THING's I/O.")

(cl-defmethod jupyter-io :around (thing)
  "Cache the I/O function of THING."
  (or (gethash thing jupyter-io-cache)
      (puthash thing (cl-call-next-method) jupyter-io-cache)))

;; TODO: Any monadic value is really a kind of delayed value in some
;; sense, since it represents some staged computation to be evaluated
;; later.  Change the name to `jupyter-return-io' and also change
;; `jupyter-delayed' to `jupyter-io'.
(defun jupyter-return-delayed (value)
  "Return an I/O value that evaluates BODY in the I/O context.
The result of BODY is the unboxed value of the I/O value.  BODY
is evaluated only once."
  (declare (indent 0))
  (make-jupyter-delayed :value (lambda () value)))

(defvar jupyter-current-io
  (lambda (content)
    (error "Unhandled I/O: %s" content)))

(defun jupyter-bind-delayed (io-value io-fn)
  "Bind IO-VALUE to IO-FN.
Binding causes the evaluation of a delayed value, IO-VALUE (a
closure), in the current I/O context.  The unwrapped
value (result of evaluating the closure) is then passed to IO-FN
which returns another delayed value.  Thus binding involves
unwrapping a value by evaluating a closure and giving the result
to IO-FN which returns another delayed value to be bound at some
future time.  Before, between, and after the two calls to
IO-VALUE and IO-FN, the I/O context is maintained."
  (declare (indent 1))
  (pcase (funcall (jupyter-delayed-value io-value))
	((and req (cl-struct jupyter-request client))
     ;; TODO: If the delayed value is bound and its a request, doesn't
     ;; that mean the request was sent and so the client will already
     ;; be `jupyter-current-client'.
     (let ((jupyter-current-client client))
	   (funcall io-fn req)))
	(`(timeout ,(and req (cl-struct jupyter-request)))
	 (error "Timed out: %s" (cl-prin1-to-string req)))
	(`,value (funcall io-fn value))))

(defmacro jupyter-mlet* (varlist &rest body)
  "Bind the I/O values in VARLIST, evaluate BODY.
Return the result of evaluating BODY, which should be another I/O
value."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  ;; FIXME: The below doesn't work
  ;;
  ;; (jupyter-mlet* ((io io))
  ;;   (jupyter-run-with-io io
  ;;      ...))
  (letrec ((vars (delq '_ (mapcar #'car varlist)))
           (value (make-symbol "value"))
           (binder
            (lambda (vars)
              (if (zerop (length vars))
                  (if (zerop (length body)) 'jupyter-io-nil
                    `(progn ,@body))
                (pcase-let ((`(,name ,io-value) (car vars)))
                  `(jupyter-bind-delayed ,io-value
                     (lambda (,value)
                       ,(if (eq name '_)
                            ;; FIXME: Avoid this.
                            `(ignore ,value)
                          `(setq ,name ,value))
                       ,(funcall binder (cdr vars)))))))))
    `(let (,@vars)
       ,(funcall binder varlist))))

(defmacro jupyter-with-io (io &rest body)
  "Return an I/O action evaluating BODY in IO's I/O context.
The result of the returned action is the result of the I/O action
BODY evaluates to."
  (declare (indent 1) (debug (form body)))
  `(make-jupyter-delayed
    :value (lambda ()
             (let ((jupyter-current-io ,io))
               (jupyter-mlet* ((result (progn ,@body)))
                 result)))))

(defmacro jupyter-run-with-io (io &rest body)
  "Return the result of evaluating the I/O value BODY evaluates to.
All I/O operations are done in the context of IO."
  (declare (indent 1) (debug (form body)))
  `(jupyter-mlet* ((result (jupyter-with-io ,io
                             ,@body)))
     result))

;; do (for the IO monad) takes IO actions (IO values), which are
;; closures of zero argument wrapped in the `jupyter-delay' type, and
;; evaluates them in sequence one after the other.  In the IO monad,
;; composition is equivalent to one IO action being performed after
;; the other.
;;
;; Based on explanations at
;; https://wiki.haskell.org/Introduction_to_Haskell_IO/Actions
(defmacro jupyter-do (&rest io-actions)
  "Return an I/O action that performs all actions in IO-ACTIONS.
The actions are evaluated in the order given.  The result of the
returned action is the result of the last action in IO-ACTIONS."
  (declare (indent 0) (debug (body)))
  (if (zerop (length io-actions)) 'jupyter-io-nil
    (letrec ((before
              (lambda (io-actions)
                (if (= (length io-actions) 1) (car io-actions)
                  `(jupyter-then ,(funcall before (cdr io-actions))
                     ,(car io-actions))))))
      (funcall before (reverse io-actions)))))

(defun jupyter-then (io-a io-b)
  "Return an I/O action that performs IO-A then IO-B.
The result of the returned action is the result of IO-B."
  (declare (indent 1))
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-mlet* ((_ io-a)
                            (result io-b))
              result))))

;;; Kernel
;;
;; I/O actions that manage a kernel's lifetime.

;; TODO: Swap definitions with `jupyter-launch', same for the others.
;; (jupyter-launch :kernel "python")
;; (jupyter-launch :spec "python")
(defun jupyter-kernel-launch (kernel)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-launch kernel)
            kernel)))

(defun jupyter-kernel-interrupt (kernel)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-interrupt kernel)
            kernel)))

(defun jupyter-kernel-shutdown (kernel)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-shutdown kernel)
            kernel)))

;;; Publisher/subscriber
;;
;; TODO: Wrap the subscriber functions in a struct
;; (cl-defstruct jupyter-subscriber id io ...)
;;
;; TODO: Verify monadic laws.

(define-error 'jupyter-subscribed-subscriber
  "A subscriber cannot be subscribed to.")

(defun jupyter-subscriber (sub-fn)
  "Return a subscriber evaluating SUB-FN on published content.
SUB-FN should return the result of evaluating
`jupyter-unsubscribe' if a subscription should be canceled.

Ex. Unsubscribe after consuming one message

    (jupyter-subscriber
      (lambda (value)
        (message \"The published content: %s\" value)
        (jupyter-unsubscribe)))

    Used like this, where sub is the above subscriber:

    (jupyter-run-with-io (jupyter-publisher)
      (jupyter-subscribe sub)
      (jupyter-publish (list 'topic \"today's news\")))"
  (declare (indent 0))
  (lambda (sub-content)
    (pcase sub-content
      (`(content ,content) (funcall sub-fn content))
      (`(subscribe ,_) (signal 'jupyter-subscribed-subscriber nil))
      (_ (error "Unhandled subscriber content: %s" sub-content)))))

(defun jupyter-content (value)
  "Arrange for VALUE to be sent to subscribers of a publisher."
  (list 'content value))

(defsubst jupyter-unsubscribe ()
  "Arrange for the current subscription to be canceled.
A subscriber (or publisher with a subscription) can return the
result of this function to cancel its subscription with the
publisher providing content."
  (list 'unsubscribe))

;; PUB-FN is a monadic function of a publisher's Content monad.  They
;; take normal values and produce content to send to a publisher's
;; subscribers.  The context of the Content monad is the set of
;; publishers/subscribers that the content is filtered through.
;;
;; When a publisher function is called, it takes submitted content,
;; binds it to PUB-FN to produce content to send, and distributes the
;; content to subscribers.  When a publisher is a subscriber of
;; another publisher, the subscribed publisher is called to repeat the
;; process on the sent content.  In this way, the initial submitted
;; content (submitted via `jupyter-publish') gets transformed by each
;; subscribed publisher, via PUB-FN, to publish to their subscribers.
;;
;; TODO: Verify if this is a real bind and if not, add to the above
;; paragraph why it isn't.
(defun jupyter-pseudo-bind-content (pub-fn content subs)
  "Apply PUB-FN on submitted CONTENT to produce published content.
Call each subscriber in SUBS on the published content, remove
those subscribers that cancel their subscription."
  (pcase (funcall pub-fn content)
    ((and `(content ,_) sub-content)
     (while subs
       ;; NOTE: The first element of SUBS is ignored here so that
       ;; the pointer to the subscriber list remains the same for
       ;; each publisher, even when subscribers are being
       ;; destructively removed.
       (when (cadr subs)
         (with-demoted-errors "Jupyter: I/O subscriber error: %S"
           ;; This recursion may be a problem if
           ;; there is a lot of content filtering (by
           ;; subscribing publishers to publishers).
           (pcase (funcall (cadr subs) sub-content)
             ('(unsubscribe) (setcdr subs (cddr subs))))))
       (pop subs))
     nil)
    ;; Cancel a publisher's subscription to another publisher.
    ('(unsubscribe) '(unsubscribe))
    (_ nil)))

;; In the context external to a publisher, i.e. in the context where a
;; message was published, the content is built up and then published.
;; In the context of a publisher, that content is filtered through
;; PUB-FN before being passed along to subscribers.  So PUB-FN is a
;; filter of content.  Subscribers receive filtered content or no
;; content at all depending on the return value of PUB-FN, in
;; particular if it returns a value wrapped by `jupyter-content'.
;;
;; PUB-FN is a monadic function in the Publisher monad.  It takes a
;; value and produces content to send to subscribers.  The monadic
;; value is the content, created by `jupyter-content'.
(defun jupyter-publisher (&optional pub-fn)
  "Return a publisher function.
A publisher function is a closure, function with a local scope,
that maintains a list of subscribers and distributes the content
that PUB-FN returns to each of them.

PUB-FN is a function that optionally returns content to
publish (by returning the result of `jupyter-content' on a
value).  It's called when a value is submitted for publishing
using `jupyter-publish', like this:

    (let ((pub (jupyter-publisher
                 (lambda (submitted-value)
                   (message \"Publishing %s to subscribers\" submitted-value)
                   (jupyter-content submitted-value)))))
      (jupyter-run-with-io pub
        (jupyter-publish (list 1 2 3))))

The default for PUB-FN is `jupyter-content'.

If no content is returned by PUB-FN, no content is sent to
subscribers.

A publisher can also be a subscriber of another publisher.  In
this case, if PUB-FN returns the result of `jupyter-unsubscribe'
its subscription is canceled.

Ex. Publish the value 1 regardless of what is given to PUB-FN.

    (jupyter-publisher
      (lambda (_)
        (jupyter-content 1)))

Ex. Publish 'app if 'app is given to a publisher, nothing is sent
    to subscribers otherwise.  In this case, a publisher is a
    filter of the value given to it for publishing.

    (jupyter-publisher
      (lambda (value)
        (if (eq value 'app)
          (jupyter-content value))))"
  (declare (indent 0))
  (let ((subs (list 'subscribers))
        (pub-fn (or pub-fn #'jupyter-content)))
    ;; A publisher value is either a value representing a subscriber
    ;; or a value representing content to send to subscribers.
    (lambda (pub-value)
      (pcase (car-safe pub-value)
        ('content (jupyter-pseudo-bind-content pub-fn (cadr pub-value) subs))
        ('subscribe (cl-pushnew (cadr pub-value) (cdr subs)))
        (_ (error "Unhandled publisher content: %s" pub-value))))))

(defun jupyter-filter-content (pub pub-fn)
  "Return an I/O action subscribing a publisher to PUB's content.
The subscribed publisher filters the content it publishes through
PUB-FN.  The result of the I/O action is the subscribed
publisher.

This is the bind operation of a publisher embedded in an I/O
context."
  (declare (indent 1))
  (jupyter-filter pub (jupyter-publisher pub-fn)))

(defun jupyter-filter (pub-a pub-b)
  "Return an I/O action filtering PUB-A's content through PUB-B."
  (declare (indent 1))
  (jupyter-with-io pub-a
    (jupyter-do
      (jupyter-subscribe pub-b)
      ;; TODO: How can this be a different publisher?  Composing
      ;; publishers should return a new publisher of the filtered
      ;; content.
      (jupyter-return-delayed pub-b))))

(defun jupyter-consume-content (pub sub-fn)
  "Return a subscriber subscribed to PUB's content.
The subscriber evaluates SUB-FN on the published content."
  (declare (indent 1))
  (let ((sub (jupyter-subscriber sub-fn)))
    (jupyter-run-with-io pub
      (jupyter-subscribe sub))
    sub))

(defsubst jupyter--subscribe (sub)
  (list 'subscribe sub))

(defun jupyter-subscribe (sub)
  "Return an I/O action that subscribes SUB to published content.
If a subscriber (or a publisher with a subscription to another
publisher) returns the result of `jupyter-unsubscribe', its
subscription is canceled.

Ex. Subscribe to a publisher and unsubscribe after receiving two
    messages.

    (let* ((msgs '())
           (pub (jupyter-publisher))
           (sub (jupyter-subscriber
                  (lambda (n)
                    (if (> n 2) (jupyter-unsubscribe)
                      (push n msgs))))))
      (jupyter-run-with-io pub
        (jupyter-subscribe sub))
      (cl-loop
       for x in '(1 2 3)
       do (jupyter-run-with-io pub
            (jupyter-publish x)))
      (reverse msgs)) ; => '(1 2)"
  (declare (indent 0))
  (make-jupyter-delayed
   :value (lambda ()
            (funcall jupyter-current-io (jupyter--subscribe sub))
            nil)))

(defun jupyter-publish (value)
  "Return an I/O action that submits VALUE to publish as content."
  (declare (indent 0))
  (make-jupyter-delayed
   :value (lambda ()
            (funcall jupyter-current-io (jupyter-content value))
            nil)))

;;; Request

(defsubst jupyter-timeout (req)
  (list 'timeout req))

(defun jupyter-idle (io-req)
  (make-jupyter-delayed
   :value (lambda ()
            (jupyter-mlet* ((req io-req))
              (if (jupyter-wait-until-idle req) req
                (jupyter-timeout req))))))

;; When a request is bound it returns a list containing the request.
;; FIXME: A client monad.  What would be bound to it?  A request
;; message?  What would be a values of the client monad?  Requests?
(cl-defun jupyter-request (type &rest content)
  "Return an IO action that sends a `jupyter-request'.
TYPE is the message type of the message that CONTENT, a property
list, represents.

See `jupyter-io' for more information on IO actions."
  (declare (indent 1))
  ;; TODO: Get rid of having to do this conversion.
  (unless (symbolp type)
    (setq type (intern (format ":%s-request"
                               (replace-regexp-in-string "_" "-" type)))))
  ;; Build up a request and return an I/O action that sends it.
  (let* ((msgs '())
         (ch (if (memq type '(:input-reply :input-request))
                 :stdin
               :shell))
         (req-complete-pub (jupyter-publisher))
         (req (make-jupyter-request
               :type type
               :content content))
         (id (jupyter-request-id req))
         (req-msgs-pub
          (jupyter-publisher
            (lambda (msg)
              (cond
               ((and (jupyter-request-idle-p req)
                     ;; A status message after a request goes idle
                     ;; means there is a new request and there will,
                     ;; theoretically, be no more messages for the
                     ;; idle one.
                     ;;
                     ;; FIXME: Is that true? Figure out the difference
                     ;; between a status: busy and a status: idle
                     ;; message.
                     (eq (jupyter-message-type msg) :status))
                (setf (jupyter-request-messages req) (nreverse msgs))
                ;; What happens to the subscriber references of this
                ;; publisher after it unsubscribes?  They remain until
                ;; the publisher itself is no longer accessible.
                (jupyter-unsubscribe))
               ;; TODO: `jupyter-message-parent-id' -> `jupyter-parent-id'
               ;; and the like.
               ((string= id (jupyter-message-parent-id msg))
                (push msg msgs)
                (when (or (jupyter-message-status-idle-p msg)
                          ;; Jupyter protocol 5.1, IPython
                          ;; implementation 7.5.0 doesn't give
                          ;; status: busy or status: idle messages
                          ;; on kernel-info-requests.  Whereas
                          ;; IPython implementation 6.5.0 does.
                          ;; Seen on Appveyor tests.
                          ;;
                          ;; TODO: May be related
                          ;; jupyter/notebook#3705 as the problem
                          ;; does happen after a kernel restart
                          ;; when testing.
                          (eq (jupyter-message-type msg) :kernel-info-reply)
                          ;; No idle message is received after a
                          ;; shutdown reply so consider REQ as
                          ;; having received an idle message in
                          ;; this case.
                          (eq (jupyter-message-type msg) :shutdown-reply))
                  (setf (jupyter-request-idle-p req) t))
                (jupyter-content msg)))))))
    ;; Anything sent to stdin is a reply not a request so consider the
    ;; "request" completed.
    (setf (jupyter-request-idle-p req) (eq ch :stdin))
    ;; TODO: Don't initiate the request before req-msgs-pub is
    ;; subscribed to.
    (jupyter-do
      (jupyter-subscribe req-msgs-pub)
      (jupyter-publish (list 'send ch type content id))
      ;; FIXME: Return the request for now, but use req-complete-pub
      ;; (or something better) later on so that an incomplete request
      ;; isn't accessible until it is completed.
      (jupyter-return-delayed (list req-msgs-pub req)))))

(provide 'jupyter-monads)

;;; jupyter-monads.el ends here
