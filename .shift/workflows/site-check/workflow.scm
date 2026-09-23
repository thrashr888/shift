;; Dogfood: the site checker must pass before docs are published.
((workflow "site-check" 1)
 (description "Run the docs site checker and say what it found")
 (budget (rounds 8))
 (step "check"
       "Run python3 scripts/check_site.py and report in one or two sentences whether the site check passed and, if not, which pages or links failed."
       (check (run "python3" "scripts/check_site.py"))
       (check (judge "the answer states the checker's verdict"))))
