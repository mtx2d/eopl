;;rewrite each of these in continuation-passing style

;; 1. (lambda (x y) (p (+ 8 x) (q y)))
;; ==>
(lambda (x y cont)
  (q y (lambda (val)
	 ((lambda (val2) (p val2 val cont))
	  (+ 8 x)))))

;;2. (lambda (x y u v) (+ 1 (f (g x y) (+ u v))))
;; ==>
(lambda (x y u v cont)
  (g x y (lambda (val)
	   ((lambda (val2)
	      ((lambda (val3) (cont (+ 1 val3)))
	       (f val val2)))
	    (+ u v)))))

;; 3. (+ 1 (f (g x y) (+ u (h v))))
;; =>
(h v (lambda (val)
       (g x y (lambda (val2)
		((lambda (val3)
		   ((lambda (val4)
		      (cont (+ 1 val4)))
		    (f val2 val3)))
		 (+ u val))))))

;; 4. (zero? (if a (p x) (p y)))
;; =>
(p x (lambda (val)
       (p y (lambda (val2)
	      ((lambda (val3)
		 (cont (zero? val3)))
	       (if a val val2))))))

;; 5. (zero? (if (f a) (p x) (p y)))
;; =>
(f a (lambda (val)
       (p x (lambda (val3)
	      (p y (lambda (val4)
		     ((lambda (val5)
			(cont (zero? val5)))
		      (if val val3 val4))))))))

;; 6. (let ((x (let ((y 8)) (p y)))) x)
;; =>
((let ((y 8))
  (p y)) (lambda (val)
	  (let ((x val))
	    (cont x))))


;; 7. (let ((x (if a (p x) (p y)))) x)
;; =>
(p x (lambda (val)
       (p y (lambda (val2)
	      ((lambda (val3)
		 (let (x val3)
		   (cont x)))
	       (if a val val2))))))
