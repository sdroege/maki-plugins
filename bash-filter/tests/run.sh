#!/bin/sh
# Runs both specs once, on luajit (maki's host dialect; ffi for the real
# tree-sitter bash grammar). Run from anywhere.
set -e
cd "$(dirname "$0")/.."
luajit tests/git_diff_spec.lua
luajit tests/command_spec.lua
