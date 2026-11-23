#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if command -v podman >/dev/null 2>&1; then
    engine=podman
elif command -v docker >/dev/null 2>&1; then
    engine=docker
else
    echo "Install podman or docker to use this helper" >&2
    exit 1
fi

case "${1:-}" in
    build-images)
        "$engine" build -f "$root/containers/Containerfile.arch-build" -t mlwm-arch-build "$root"
        "$engine" build -f "$root/containers/Containerfile.arch-test" -t mlwm-arch-test "$root"
        ;;
    build)
        "$engine" run --rm -v "$root:/src:Z" -w /src mlwm-arch-build bash -lc \
            'dune build @all && dune runtest && ldd _build/default/bin/main.exe && ldd _build/default/test/test_core.exe'
        ;;
    *)
        echo "Usage: $0 {build-images|build}" >&2
        exit 2
        ;;
esac
