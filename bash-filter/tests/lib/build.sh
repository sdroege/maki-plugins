#!/bin/sh
# Builds libtree-sitter-bash.so from the tree-sitter-bash crate in the cargo
# registry (same version maki uses), against the system libtree-sitter.
set -e

src=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/tree-sitter-bash-0.25.1 2>/dev/null | head -1)
if [ -z "$src" ]; then
  echo "tree-sitter-bash crate not found in cargo registry" >&2
  exit 1
fi

gcc -O2 -shared -fPIC -o "$(dirname "$0")/libtree-sitter-bash.so" \
  "$src/src/parser.c" "$src/src/scanner.c" \
  -I "$src/src" -l:libtree-sitter.so.0
