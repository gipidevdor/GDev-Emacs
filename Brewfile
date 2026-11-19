# Brewfile: tutto ciò che GDev-Emacs prende da Homebrew.
# bin/gdev-bootstrap-macos lo usa con `brew bundle`; rieseguirlo è sicuro.
# Niente npm, niente container: ogni strumento è un eseguibile nativo o la
# catena di strumenti (toolchain) del suo linguaggio.

# Emacs (compilazione nativa e tree-sitter inclusi).  Il carattere, SF Mono,
# è incluso in macOS dentro Terminal.app: lo script di preparazione
# (bootstrap) lo rende disponibile.
cask "emacs-app"

# Ricerca, controllo di versione, firme dei pacchetti di Emacs.
brew "git"
brew "gh"                            # GitHub da riga di comando per HitHub (:tools hithub)
brew "ripgrep"
brew "gnupg"
brew "difftastic"                    # differenze strutturali in Hit

# Ortografia (jinx): la libreria e i suoi dizionari.
brew "enchant"
brew "aspell"
brew "pkgconf"                       # jinx compila il suo modulo con enchant

# C e C++: strumenti dei compilatori, server di linguaggio, compilazione.
brew "llvm"                          # clangd, clang-format, clang-tidy, llvm-cov
brew "cmake"
brew "ninja"
brew "bear"                          # compile_commands.json per i progetti con Makefile
brew "neocmakelsp"

# Profilazione e misura delle prestazioni (benchmark).
brew "samply"
brew "hyperfine"
brew "flamegraph"

# Altri linguaggi.
brew "sbcl"                          # Common Lisp
brew "cpanminus"                     # moduli Perl del cpanfile
brew "deno"                          # JavaScript e TypeScript, formattatore
brew "shellcheck"
brew "shfmt"
brew "python3"                       # interprete e ambienti virtuali
brew "ruff"                          # Python: controllo e formattazione
brew "ty"                            # Python: completamento e controllo dei tipi
brew "taplo"                         # TOML
brew "yamllint"
