#!/usr/bin/env bash
# Starts the application and opens it in the browser. Run it from anywhere.
cd "$(dirname "$0")" || exit 1
if ! command -v julia >/dev/null 2>&1; then
    echo "Julia was not found. Install it from https://julialang.org/downloads/ and run this again."
    exit 1
fi
julia --project -e 'import Pkg; Pkg.instantiate()' || {
    echo "The packages could not be installed. Check the internet connection and run this again."
    exit 1
}
exec julia --project app/server.jl --open
