(defpackage #:pulseaudio
  (:use #:cl
        #:pulseaudio.cffi
        #:pulseaudio.keyword)
  (:export #:*available-sample-formats*
           #:raw-sample-format
           #:raw-direction
           #:open-stream
           #:close-stream
           #:write-stream
           #:flush-stream
           #:drain-stream
           #:with-audio-stream))
(in-package #:pulseaudio)

(defclass pulseaudio-stream ()
  ((sample-format :initarg :sample-format
                  :accessor pulseaudio-stream-sample-format
                  :initform :u8)
   (channels :initarg :channels
             :accessor pulseaudio-stream-channels
             :initform 1)
   (rate :initarg :rate
         :accessor pulseaudio-stream-rate
         :initform 44100)
   (buffer-size :initarg :buffer-size
                :accessor pulseaudio-stream-buffer-size
                :initform 1024)
   (raw-buffer :initarg :raw-buffer
               :accessor pulseaudio-stream-raw-buffer)))

(defmethod close-stream ((stream pulseaudio-stream))
  (unless (cffi:null-pointer-p (pulseaudio-stream-raw-buffer stream))
    (cffi:foreign-free (pulseaudio-stream-raw-buffer stream)))
  (setf (pulseaudio-stream-raw-buffer stream) nil))

(defclass simple-stream (pulseaudio-stream)
  ((raw-stream :accessor simple-stream-raw-stream)
   (error-code :initarg :error-code
               :accessor simple-stream-error-code)))

(defmethod open-stream ((stream (eql 'simple-stream))
                        appname direction
                        &key device description
                             sample-format channels rate buffer-size
                             channel-map buffer-attributes)
  (let ((stream (make-instance 'simple-stream
                               :sample-format sample-format
                               :channels channels
                               :rate rate
                               :buffer-size buffer-size
                               :raw-buffer (cffi:foreign-alloc :uint8 :count buffer-size)
                               :error-code (cffi:foreign-alloc :uint8 :count 1))))
    (let ((server (cffi:null-pointer))
          (direction (raw-direction direction))
          (device (or device (cffi:null-pointer)))
          (channel-map (or channel-map (cffi:null-pointer)))
          (buffer-attributes (or buffer-attributes (cffi:null-pointer))))
      (cffi:with-foreign-objects ((sample-spec '(:struct pa_sample_spec)))
        (cffi:with-foreign-slots ((pa_sample_spec-format pa_sample_spec-channels pa_sample_spec-rate)
                                  sample-spec (:struct pa_sample_spec))
          (setf pa_sample_spec-format (raw-sample-format sample-format)
                pa_sample_spec-channels channels
                pa_sample_spec-rate rate)
          (setf (simple-stream-raw-stream stream)
                (pa-simple-new server appname direction device description
                               sample-spec channel-map buffer-attributes
                               (simple-stream-error-code stream)))))
      stream)))

(defmethod close-stream ((stream simple-stream))
  (unless (cffi:null-pointer-p (simple-stream-raw-stream stream))
    (pa-simple-free (simple-stream-raw-stream stream)))
  (unless (cffi:null-pointer-p (simple-stream-error-code stream))
    (cffi:foreign-free (simple-stream-error-code stream)))
  (setf (simple-stream-raw-stream stream) nil
        (simple-stream-error-code stream) nil)
  (call-next-method))

(defmethod flush-stream ((stream simple-stream))
  (let ((error-code (simple-stream-error-code stream)))
    (when (minusp (pa-simple-flush (simple-stream-raw-stream stream) error-code))
      (format t "~a~%" (pa-strerror (cffi:mem-aref error-code :int)))
      (error (pa-strerror (cffi:mem-aref error-code :int))))))

(defmethod drain-stream ((stream simple-stream))
  (when (cffi:null-pointer-p (simple-stream-raw-stream stream))
    (return-from drain-stream))
  (let ((error-code (simple-stream-error-code stream)))
    (when (minusp (pa-simple-drain (simple-stream-raw-stream stream) error-code))
      (error (pa-strerror (cffi:mem-aref error-code :int))))))

(defmethod write-stream ((stream simple-stream) (data simple-array))
  (let ((buf (pulseaudio-stream-raw-buffer stream))
        (len (pulseaudio-stream-buffer-size stream))
        (error-code (simple-stream-error-code stream)))
    (cffi:lisp-array-to-foreign data buf (list :array :uint8 len))
    (when (minusp (pa-simple-write (simple-stream-raw-stream stream) buf len error-code))
      (error (pa-strerror (cffi:mem-aref error-code :int))))))

(defmacro with-audio-stream ((stream &key (appname "cl-pulseaudio app")
                                          (direction :output)
                                          (device nil)
                                          (description "cl-pulseudio stream")
                                          (sample-format nil)
                                          (rate 44100)
                                          (buffer-size 1024)
                                          (channels 2)
                                          (channel-map nil)
                                          (buffer-attributes nil))
                             &body body)
  `(let ((,stream (open-stream 'simple-stream
                               ,appname ,direction
                               :device ,device
                               :description ,description
                               :sample-format ,sample-format
                               :channels ,channels
                               :rate ,rate
                               :buffer-size ,buffer-size
                               :channel-map ,channel-map
                               :buffer-attributes ,buffer-attributes)))
     (unwind-protect
          (progn ,@body nil)
       (progn
         (flush-stream ,stream)
         (close-stream ,stream)))))
