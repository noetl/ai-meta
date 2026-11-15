# cargo-queue: put the build-queue `cargo` wrapper first on PATH (idempotent).
# Sourced from ~/.zshenv (all zsh, incl. non-interactive agent shells),
# end of ~/.zshrc (after its many PATH prepends), ~/.bashrc and ~/.profile.
_cq="$HOME/.cargo-queue/bin"
PATH=":$PATH:"; PATH="${PATH//:$_cq:/:}"; PATH="${PATH#:}"; PATH="${PATH%:}"
export PATH="$_cq:$PATH"; unset _cq
