# Moduli Perl usati da GDev-Emacs, installati nel perl attivo
# (perlbrew, plenv o di sistema) con: cpanm --installdeps --notest .

requires 'Perl::LanguageServer';    # server di linguaggio e adattatore di debug
requires 'Perl::Tidy';              # formattatore
requires 'Perl::Critic';            # controllo dello stile (linter)
requires 'Devel::NYTProf';          # profilatore (profiler)
requires 'Devel::Cover';            # copertura dei test (coverage)

recommends 'Reply';                 # un REPL più comodo di perl -de0
