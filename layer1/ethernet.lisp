;; Ethernet Implementation
;; Copyright (C) 2007 Dr. John A.R. Williams

;; Author: Dr. John A.R. Williams <J.A.R.Williams@jarw.org.uk>
;; Keywords:

;; This file is part of Lisp Educational Network Simulator (LENS)

;; This is free software released under the GNU General Public License (GPL)
;; See <http://www.gnu.org/copyleft/gpl.html>

;;; Commentary:

;; The Ethernet model has two detail levels:
;;
;; PARTIAL does model collisions and insures only one node is transmitting
;;      at once.  However, collisions are detected instantaneously,
;;      (all nodes can hear the carrier with zero delay).  This is
;;      more realistic than the NONE detail level, at the expense of
;;      slight computational overhead.
;; FULL models collisions and time delay between nodes on the LAN.
;;      When using this model, the nodes MUST specify an X/Y position
;;      (meters) to allow for propogation delay calculations.

;;; Code:

(defpackage :ethernet
  (:nicknames :ethernet)
  (:use :cl :common :address :link :interface :scheduler)
  (:import-from :trace #:write-trace)
  (:import-from :lens.math #:random-value #:uniform)
  (:import-from :packet #:packet #:retx #:peek-pdu #:size)
  (:import-from :interface #:queue #:enque #:deque #:empty-p)
  (:import-from :link #:transmit-helper)
  (:import-from :node
                #:add-interface #:make-location #:location #:distance)
  (:export #:ethernet #:add-node))

(in-package :ethernet)

(defparameter *initial-backoff* 1
  "Initial value for the max contention window")
(defparameter *slot-time* 512 "Slot time in bit times")
(defparameter *backoff-limit* 1024 "maximum allowable contention window")
(defparameter *attempt-limit* 16 "number of retransmit before giving up")
(defparameter *jam-time* 32 "Jam time in bit times")
(defparameter *inter-frame-gap* 96 "Slot time in bit times")

(defclass ethernet-interface(interface timer-manager)
  ((busy-end-time :initform 0 :type time-type :accessor busy-end-time
                  :documentation "Time when the link will be free again")
   (hold-time
    :initform 0 :type time-type :accessor hold-time
    :documentation "Time to hold back all packets when collision occurs")
   (max-back-off :initform *initial-backoff*
                 :type time-type :accessor max-back-off
                 :documentation "Maximum backoff timer")
   (back-off-timer :initform 0 :type time-type :accessor back-off-timer
                   :documentation "Backoff timer")
   (max-wait-time :initform 0 :type time-type :accessor max-wait-time
                  :documentation "maximum delay")
   (busy-count :initform 0 :type counter :accessor busy-count
               :documentation "How many stations are transmitting")
   (last-packet-sent :initform nil :type packet :accessor last-packet-sent
                     :documentation "last packet sent by this interface")
   (tx-finish-time :initform 0 :type time-type :accessor tx-finish-time
                   :documentation "Transmit finish time")
   (collision :initform nil :type boolean :accessor collision)
   (rx-time :initform 0 :type time-type :accessor rx-time
            :documentation "time to retransmit")
   (rng :reader rng :initform `(uniform 0 ,*initial-backoff*)
        :documentation "random number generator")
   (bcast :initform nil :accessor bcast :type boolean
          :documentation "True if the last packet sent was a broadcast")
   (events
    :initform nil :accessor events
    :documentation "List of current events scheduled for this interface"))
  (:documentation "Interface that handles the collision detection
algorithm in the 802.3 standard"))


(defun slot-time(ethernet-interface)
  (/ *slot-time* (bandwidth (link ethernet-interface))))

(defun sense-channel(interface)
  (let ((now (simulation-time)))
    (cond
      ((or (< (tx-finish-time interface) now) ;; we are already transmitting
           (< (hold-time interface) now))
       (setf (rx-time interface)
             (- (max (tx-finish-time interface) (hold-time interface)) now))
       nil)
      ((< now (busy-end-time interface)) ;; link is busy
       (setf (rx-time interface) (- (busy-end-time interface) now))
       nil)
      (t (setf (collision interface) nil)
         t))))

(defun retransmit(interface &optional (packet (deque (queue interface))))
  (when packet
    (when (> (incf (retx packet)) *attempt-limit*)
      ;; reached transmission limit so drop packet
      (write-trace (node interface) nil :drop
                   nil :packet packet :text "L2-QD")
      (unless (empty-p (queue interface))
        (return-from retransmit (retransmit interface))))
    (write-trace (node interface) (layer2:protocol interface) nil nil
                 :packet packet :text (format nil "L2-RA ~A" (retx packet)))
    (when (sense-channel interface)
      (dolist(peer (peer-interfaces (link interface)))
        (unless (eql peer interface)
          (schedule-timer (delay (link interface) interface peer)
                          #'first-bit-received peer (size packet))))
      (setf (bcast interface) nil)
      (let ((txtime (/ (* (size packet) 8) (bandwidth (link interface))))
            (now (simulation-time)))
        (setf (tx-finish-time interface) (+ txtime now))
        (setf (hold-time interface)
              (+ (tx-finish-time interface)
                 (/ *inter-frame-gap* (bandwidth (link interface)))))
        (setf (rx-time interface) (- (hold-time interface) now)))
      (unless (or (find-timer #'retransmit interface)
                  (empty-p (queue interface)))
        (schedule-timer (rx-time interface) #'retransmit interface))
      (layer2:send  (layer2:protocol interface) (copy packet))
      (unless (find-timer #'chan-acq interface)
        (schedule-timer (* 2 (max-wait-time interface)) #'chan-acq interface))
      (return-from retransmit t))
    (unless (find-timer #'retransmit interface)
      (schedule-timer (rx-time interface) #'retransmit interface))
    (decf (retx packet))
    (write-trace (node interface) (layer2:protocol interface) nil nil
                 :packet packet :text "L2-B")
    (enque packet interface)))

(defmethod send((interface ethernet-interface) (packet packet) (dst macaddr)
                &optional llcsnaptype)
  (unless (up-p interface)
     ;; if down down't forward - just trace drop
    (write-trace (node interface)  nil :drop nil :packet packet :text "L2-ID")
    (return-from send nil))
  (layer2:build-pdu (layer2:protocol interface) (macaddr interface)
                    dst packet llcsnaptype)
  (cancel-timer #'retransmit interface)
  (retransmit interface packet))

(defun first-bit-received(interface size)
  (let ((now (simulation-time)))
    (cond
      ((< now (tx-finish-time interface)) ;; collision occured
       (when (collision interface) ;; already experience collision
         (return-from first-bit-received))
       (cancel-timer #'receive interface)
       (write-trace (node interface) nil :drop
                    nil :packet (last-packet-sent interface) :text "L2-C")
       (cancel-timer #'chan-acq interface)
       ;; send clr to all neighbours
       (dolist(peer (peer-interfaces (link interface)))
         (unless (eql peer interface)
           (schedule-timer (delay (link interface) interface peer)
                           #'clr peer)))
       ;; set new time for backoff timer and schedule sensing after backoff
       (setf (tx-finish-time interface) now)
       (setf (max-back-off interface)
             (min (* 2 (max-back-off interface)) *backoff-limit*))
       (setf (back-off-timer interface)
             (* (slot-time interface)
                (ceiling (* (random-value (rng interface))
                            (max-back-off interface)))))
       (setf (hold-time interface)
             (+ (back-off-timer interface)
                (/ *jam-time* (bandwidth (link interface)))
                (tx-finish-time interface)))
       (or (enque (last-packet-sent interface) interface)
           (setf (last-packet-sent interface) nil))
       (cancel-timer #'retransmit interface)
       (schedule-timer (- (hold-time interface) now) #'retransmit interface))
      ((or (not (busy-end-time interface)) (< now (busy-end-time interface)))
       (incf (busy-count interface))
       (setf (busy-end-time interface ) nil))
      (t
       (let ((tx-time (/ (* 8 size) (bandwidth (link interface)))))
         (setf (busy-end-time interface) (+ now tx-time))
         (setf (hold-time interface) (+ (busy-end-time interface)
                                        (/ *inter-frame-gap*
                                           (bandwidth (link interface))))))
         (when (and (not (empty-p (queue interface)))
                    (not (find-timer #'retransmit interface)))
           (schedule (- (hold-time interface) now)
                     #'retransmit interface))))))

(defun clr(interface)
  "wait for all sending stations to send the clear signal then set the
link status to not busy"
  (when (<= 0 (decf (busy-count interface)))
    (setf (busy-count interface) 1
          (busy-end-time interface) (simulation-time))
    (unless (collision interface)
      (setf (hold-time interface)
            (+ (busy-end-time interface)
               (/ *jam-time* (bandwidth (link interface))))))
    (cancel-timer #'retransmit interface)
    (schedule (- (hold-time interface) (simulation-time))
              #'retransmit interface)))

(defun chan-acq(interface)
  "We have succesfully sent the packet so reset the contention window"
  (setf (max-back-off interface) *initial-backoff*))

(defclass ethernet(link)
  ((peer-interfaces :initform nil :type list :accessor peer-interfaces
                    :documentation "List of all interfaces on this link")
   (ipaddr-allocator
    :type ipaddr-allocator :reader ipaddr-allocator
    :documentation "allocation of ipaddresses for this ethernet")
   (default-peer-interface :initform nil :type interface
                           :reader default-peer-interface)
   (gateway :initarg :gateway :initform nil :type interface
            :reader gateway :reader default-peer-interface
            :documentation "The gateway for this ethernet")
   (detail :initarg :detail :initform :parial
           :type (member :full :partial nil)
           :reader detail
           :documentation "Detail to be simulated")
   (rx-own-broadcast
    :initform t :initarg :rx-own-broadcase :reader rx-own-broadcast
    :documentation
    "Return true if interfaces receive their own broadcasts on this link")
   (layer4:protocol :initform nil :initarg :layer4 :reader layer4:protocol
                    :documentation "construction arguments for layer 4
protocol to bind to each node"))
  (:documentation "An ethernet link"))

(defmethod delay((link ethernet) &optional local-interface peer-interface)
  (if (eql (detail link) :full)
      (/ (distance (location local-interface) (location peer-interface))
         +speed-light+)
      (call-next-method)))

(defmethod ipaddr((link ethernet))
  "The ipaddr range for interfaces on this ethernet"
  (ipaddr (ipaddr-allocator link)))

(defmethod ipmask((link ethernet))
  "The ip mask for interfaces on this ethernet"
  (ipmask (ipaddr-allocator link)))

(defmethod make-new-interface((link ethernet) &key ipaddr ipmask)
  (make-instance
   (if (eql (detail link) :full) 'ethernet-interface 'interface)
   :link link
   :ipaddr (or ipaddr (next-ipaddr (ipaddr-allocator link)))
   :ipmask (or ipmask (ipmask link))))

(defmethod initialize-instance :after ((link ethernet)
                                       &key gateway ipaddr ipmask nodes)
  (setf (slot-value link 'ipaddr-allocator)
        (make-instance 'ipaddr-allocator :ipaddr ipaddr :ipmask ipmask))
  (when gateway (add-node gateway link))
  (dolist(n nodes) (add-node n link)))

(defun add-node(node link)
  (when (find node (peer-interfaces link) :key #'node)
    (error "Node ~A is already connected to ~A" node link))
  (let ((interface (make-new-interface link)))
    (add-interface interface node)
    (setf (peer-interfaces link)
          (nconc (peer-interfaces link) (list interface)))
    (when (eql (detail link) :full)
      (setf (location node)
            (make-location :x 0 :y (length (peer-interfaces link)))))
    #+nil(map #'update-nodes (peer-interfaces link))))

(defmethod transmit((link ethernet) packet interface node &optional rate)
  (declare (ignore rate))
  (let ((l2pdu (peek-pdu packet)))
    (if (broadcast-p (dst-address l2pdu))
        ;; if broadcast pass interface of src, not dst
        (transmit-helper
         link packet interface (find-interface (src-address l2pdu) link) t)
        (when-bind (dst (find-interface (dst-address l2pdu) link))
          (transmit-helper link packet interface dst link)))))



