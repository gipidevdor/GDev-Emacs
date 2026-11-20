;; SPDX-License-Identifier: GPL-3.0-or-later
(:version 1
 :default "GDev-Emacs"
 :profiles (("GDev-Emacs"
             :configure ("./bin/gdev" "sync")
             :build ("./bin/gdev" "compile" "--native")
             :test ("./bin/gdev" "test"))))
