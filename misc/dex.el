
(setq dex-highlights
  '(("\\blam\\b\\|\\bfor\\b\\|\\blet\\b\\|\\btype\\b\\|\\bunpack\\b\\|\\bpack\\b\\|\\bin\\b"
     . font-lock-keyword-face)
    ("\\bE\\b\\|\\bA\\b"              . font-lock-builtin-face)
    ("->\\|=>\\|\\.\\|@\\|,\\|\\$\\|=\\|;\\|::" . font-lock-variable-name-face)
    ("\\b[[:upper:]][[:alnum:]]*\\b"  . font-lock-type-face)
    (":t\\|:passes\\|:p\\|:time"      . font-lock-preprocessor-face)))

(setq dex-mode-syntax-table
      (let ((synTable (make-syntax-table)))
        (modify-syntax-entry ?-  ". 12" synTable)
        (modify-syntax-entry ?>  ". 1"  synTable)
        (modify-syntax-entry ?   ". 2"  synTable)
        (modify-syntax-entry ?\n ">"    synTable)
        synTable))

(define-derived-mode dex-mode fundamental-mode "dex"
  (setq font-lock-defaults '(dex-highlights))
  (setq-local comment-start "--")
  (setq-local comment-end "")
  (setq-local syntax-propertize-function
              (syntax-propertize-rules (".>\\( +\\)" (1 "."))))
  (set-syntax-table dex-mode-syntax-table))

(add-to-list 'auto-mode-alist '("\\.dx\\'"  . dex-mode))