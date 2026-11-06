#!/bin/zsh
set -euo pipefail
cd "${0:a:h}/.."
mkdir -p .tools/bin
export GOBIN="$PWD/.tools/bin"
go install golang.org/x/tools/gopls@v0.24.0
go install github.com/go-delve/delve/cmd/dlv@v1.27.2
