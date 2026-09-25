#!/bin/sh
# Runs the spec once, on luajit (maki's host dialect). Run from anywhere.
set -e
cd "$(dirname "$0")/.."
luajit tests/notes_spec.lua
luajit tests/main_spec.lua
