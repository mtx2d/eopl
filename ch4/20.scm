(load-relative "../libs/init.scm")
(load-relative "./base/store.scm")
(load-relative "./base/test.scm")
(load-relative "./base/implicit-cases.scm")

;; add a mutable property for var
;; add two testcases.


(define the-lexical-spec
  '((whitespace (whitespace) skip)
    (comment ("%" (arbno (not #\newline))) skip)
    (identifier
     (letter (arbno (or letter digit "_" "-" "?")))
     symbol)
    (number (digit (arbno digit)) number)
    (number ("-" digit (arbno digit)) number)
    ))

(define the-grammar
  '((program (expression) a-program)

    (expression (number) const-exp)
    (expression
     ("-" "(" expression "," expression ")")
     diff-exp)

    (expression
     ("zero?" "(" expression ")")
     zero?-exp)

    (expression
     ("if" expression "then" expression "else" expression)
     if-exp)

    (expression (identifier) var-exp)

    (expression
     ("let" (arbno identifier "=" expression) "in" expression)
     let-exp)

    (expression
     ("letmutable" (arbno identifier "=" expression) "in" expression)
     letmutable-exp)

    (expression
     ("proc" "(" (arbno identifier) ")" expression)
     proc-exp)

    (expression
     ("(" expression (arbno expression) ")")
     call-exp)

    (expression
     ("letrec"
      (arbno identifier "(" (arbno identifier) ")" "=" expression)
      "in" expression)
     letrec-exp)

    (expression
     ("begin" expression (arbno ";" expression) "end")
     begin-exp)

    (expression
     ("set" identifier "=" expression)
     assign-exp)

    ))

;;;;;;;;;;;;;;;;; sllgen boilerplate ;;;;;;;;;;;;;;;;
(sllgen:make-define-datatypes the-lexical-spec the-grammar)

(define show-the-datatypes
  (lambda () (sllgen:list-define-datatypes the-lexical-spec the-grammar)))

(define scan&parse
  (sllgen:make-string-parser the-lexical-spec the-grammar))

(define-datatype expval expval?
  (num-val
   (value number?))
  (bool-val
   (boolean boolean?))
  (proc-val
   (proc proc?))
  (ref-val
   (ref reference?))
  )

;;; extractors:
(define expval->num
  (lambda (v)
    (cases expval v
           (num-val (num) num)
           (else (expval-extractor-error 'num v)))))

(define expval->bool
  (lambda (v)
    (cases expval v
           (bool-val (bool) bool)
           (else (expval-extractor-error 'bool v)))))

(define expval->proc
  (lambda (v)
    (cases expval v
           (proc-val (proc) proc)
           (else (expval-extractor-error 'proc v)))))

(define expval->ref
  (lambda (v)
    (cases expval v
           (ref-val (ref) ref)
           (else (expval-extractor-error 'reference v)))))

(define expval-extractor-error
  (lambda (variant value)
    (error 'expval-extractors "Looking for a ~s, found ~s"
           variant value)))

;;;;;;;;;;;;;;;; procedures ;;;;;;;;;;;;;;;;
(define-datatype proc proc?
  (procedure
   (bvar (list-of symbol?))
   (body expression?)
   (env environment?)))

(define-datatype environment environment?
  (empty-env)
  (extend-env
   (bvar symbol?)
   (bmutale boolean?)
   (bval reference?)                 ; new for implicit-refs
   (saved-env environment?))
  (extend-env-rec*
   (proc-names (list-of symbol?))
   (b-vars (list-of (list-of symbol?)))
   (proc-bodies (list-of expression?))
   (saved-env environment?)))

;; env->list : Env -> List
;; used for pretty-printing and debugging
(define env->list
  (lambda (env)
    (cases environment env
           (empty-env () '())
           (extend-env(sym mutable val saved-env)
                       (cons
                        (list sym val)              ; val is a denoted value-- a
                                        ; reference.
                        (env->list saved-env)))
           (extend-env-rec* (p-names b-vars p-bodies saved-env)
                            (cons
                             (list 'letrec p-names '...)
                             (env->list saved-env))))))

;; expval->printable : ExpVal -> List
;; returns a value like its argument, except procedures get cleaned
;; up with env->list
(define expval->printable
  (lambda (val)
    (cases expval val
           (proc-val (p)
                     (cases proc p
                            (procedure (var body saved-env)
                                       (list 'procedure var '... (env->list saved-env)))))
           (else val))))

(define init-env
  (lambda ()
    (extend-env
     'i #t (newref (num-val 1))
     (extend-env
      'v #t (newref (num-val 5))
      (extend-env
       'x #t (newref (num-val 10))
       (empty-env))))))

;;;;;;;;;;;;;;;; environment constructors and observers ;;;;;;;;;;;;;;;;
(define apply-env
  (lambda (env search-var write)
    (cases environment env
           (empty-env ()
                      (error 'apply-env "No binding for ~s" search-var))
           (extend-env (bvar mutable bval saved-env)
                       (if (eqv? search-var bvar)
			   (if write
			       (if mutable
				   bval
				   (error "write can not be done"))
			       bval)
                           (apply-env saved-env search-var write)))
           (extend-env-rec* (p-names b-vars p-bodies saved-env)
                            (let ((n (location search-var p-names)))
                              ;; n : (maybe int)
                              (if n
                                  (newref
                                   (proc-val
                                    (procedure
                                     (list-ref b-vars n)
                                     (list-ref p-bodies n)
                                     env)))
                                  (apply-env saved-env search-var write)))))))

;; location : Sym * Listof(Sym) -> Maybe(Int)
;; (location sym syms) returns the location of sym in syms or #f is
;; sym is not in syms.  We can specify this as follows:
;; if (memv sym syms)
;;   then (list-ref syms (location sym syms)) = sym
;;   else (location sym syms) = #f
(define location
  (lambda (sym syms)
    (cond
     ((null? syms) #f)
     ((eqv? sym (car syms)) 0)
     ((location sym (cdr syms))
      => (lambda (n)
           (+ n 1)))
     (else #f))))

;; new stuff
(define extend-env*
  (lambda (vars mutable vals env)
    (if (null? vars)
        env
        (extend-env (car vars) mutable (newref (car vals))
                    (extend-env* (cdr vars) mutable (cdr vals) env)))))


(define instrument-let (make-parameter #f))

;; say (instrument-let #t) to turn instrumentation on.
;;     (instrument-let #f) to turn it off again.

;;;;;;;;;;;;;;;; the interpreter ;;;;;;;;;;;;;;;;

;; value-of-program : Program -> ExpVal
(define value-of-program
  (lambda (pgm)
    (initialize-store!)
    (cases program pgm
           (a-program (exp1)
                      (value-of exp1 (init-env))))))

;; value-of : Exp * Env -> ExpVal
;; Page: 118, 119
(define value-of
  (lambda (exp env)
    (cases expression exp
           (const-exp (num) (num-val num))
           (var-exp (var) (deref (apply-env env var #f)))
           (diff-exp (exp1 exp2)
                     (let ((val1 (value-of exp1 env))
                           (val2 (value-of exp2 env)))
                       (let ((num1 (expval->num val1))
                             (num2 (expval->num val2)))
                         (num-val
                          (- num1 num2)))))

           (zero?-exp (exp1)
                      (let ((val1 (value-of exp1 env)))
                        (let ((num1 (expval->num val1)))
                          (if (zero? num1)
                              (bool-val #t)
                              (bool-val #f)))))

           (if-exp (exp1 exp2 exp3)
                   (let ((val1 (value-of exp1 env)))
                     (if (expval->bool val1)
                         (value-of exp2 env)
                         (value-of exp3 env))))

           (let-exp (vars exps body)
                    (value-of body
                              (extend-env* vars #f (map (lambda(x)
							  (value-of x env))
							exps) env)))
	   (letmutable-exp (vars exps body)
			   (value-of body
				     (extend-env* vars #t (map (lambda(x)
								 (value-of x env))
							       exps) env)))
           (proc-exp (vars body)
                     (proc-val (procedure vars body env)))

           (call-exp (rator rands)
                     (let ((proc (expval->proc (value-of rator env)))
                           (args (map (lambda(x)
                                        (value-of x env)) rands)))
                       (apply-procedure proc args)))

           (letrec-exp (p-names b-vars p-bodies letrec-body)
                       (value-of letrec-body
                                 (extend-env-rec* p-names b-vars p-bodies env)))

           (begin-exp (exp1 exps)
                      (letrec
                          ((value-of-begins
                            (lambda (e1 es)
                              (let ((v1 (value-of e1 env)))
                                (if (null? es)
                                    v1
                                    (value-of-begins (car es) (cdr es)))))))
                        (value-of-begins exp1 exps)))

           (assign-exp (var exp1)
                       (begin
                         (setref!
                          (apply-env env var #t)
                          (value-of exp1 env))
                         (num-val 27)))

           )))


;; apply-procedure : Proc * ExpVal -> ExpVal
(define apply-procedure
  (lambda (proc1 args)
    (cases proc proc1
           (procedure (vars body saved-env)
                      (let ((new-env (extend-env* vars #t args saved-env)))
                        (value-of body new-env))))))

;; store->readable : Listof(List(Ref,Expval))
(define store->readable
  (lambda (l)
    (map
     (lambda (p)
       (list
        (car p)
        (expval->printable (cadr p))))
     l)))

(define run
  (lambda (string)
    (value-of-program (scan&parse string))))


(add-test! '(multi-rect "letrec times4(x) = if zero?(x) then 0
                          else -((times4 -(x, 1)), -4)
             times3(x) = if zero?(x) then 0
                          else -((times3 -(x, 1)), -3)
          in -((times4 3), (times3 3))" 3))


(clear-test!)
(add-test! '(letmutable
 "letmutable x = 4 in
        begin
        set x = 5;
        -(1, x) end" -4))


(add-test! '(let-error
            "let x = 4 in begin
               set x = 5;
               -(1, x) end" error))

(run-all)
