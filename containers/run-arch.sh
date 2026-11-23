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
            'dune build --build-dir=/tmp/mlwm-build @all && dune runtest --build-dir=/tmp/mlwm-build && ldd /tmp/mlwm-build/default/bin/main.exe && ldd /tmp/mlwm-build/default/test/test_core.exe'
        ;;
    release)
        "$engine" image inspect mlwm-arch-build >/dev/null 2>&1 \
            || "$engine" build -f "$root/containers/Containerfile.arch-build" -t mlwm-arch-build "$root"
        "$engine" build -f "$root/containers/Containerfile.arch-runtime" -t mlwm-arch-runtime "$root"
        "$engine" run --rm mlwm-arch-runtime bash -lc '
            set -euo pipefail
            ! command -v ocaml && ! command -v dune && ! command -v gcc
            test -x /usr/local/bin/mlwm
            test -f /usr/share/xsessions/mlwm.desktop
            test -f /root/.xinitrc
            ldd_out=$(ldd /usr/local/bin/mlwm)
            echo "$ldd_out"
            echo "$ldd_out" | grep -q "libX11\.so\.6"
            echo "$ldd_out" | grep -q "libXrandr\.so\.2"
            ! echo "$ldd_out" | grep -qi "ocaml"
        '
        ;;
    smoke-runtime)
        "$engine" run --rm -v "$root:/src:ro,Z" mlwm-arch-runtime bash -lc '
            set -euo pipefail
            if [ -x /src/test/xvfb_smoke.sh ]; then
                exec /src/test/xvfb_smoke.sh /usr/local/bin/mlwm
            fi
            export DISPLAY=:99
            Xvfb :99 -screen 0 1280x720x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
            xvfb_pid=$!
            wm_pid=""
            cleanup() {
                [ -n "$wm_pid" ] && kill "$wm_pid" 2>/dev/null || true
                kill "$xvfb_pid" 2>/dev/null || true
                wait "$xvfb_pid" 2>/dev/null || true
            }
            trap cleanup EXIT
            for _ in $(seq 1 30); do
                if xprop -root >/dev/null 2>&1; then break; fi
                sleep 0.2
            done
            /usr/local/bin/mlwm >/tmp/mlwm.log 2>&1 &
            wm_pid=$!
            sleep 0.5
            xdotool key Super_L+Return
            mapped=0
            for _ in $(seq 1 25); do
                if xwininfo -root -tree | grep -qi "xterm"; then
                    mapped=1
                    break
                fi
                sleep 0.2
            done
            [ "$mapped" -eq 1 ] || { xwininfo -root -tree; cat /tmp/mlwm.log; exit 1; }
            xwininfo -root -tree
            xdotool key Super_L+Shift_L+q
            wait "$wm_pid"
            rc=$?
            wm_pid=""
            echo "mlwm exited with status $rc"
            exit "$rc"
        '
        ;;
    *)
        echo "Usage: $0 {build-images|build|release|smoke-runtime}" >&2
        exit 2
        ;;
esac
