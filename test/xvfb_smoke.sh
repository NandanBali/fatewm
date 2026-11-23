#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MLWM_BIN=${1:-${MLWM_BIN:-}}
if [[ -z $MLWM_BIN ]]; then
    if [[ -x /usr/local/bin/mlwm ]]; then MLWM_BIN=/usr/local/bin/mlwm
    else MLWM_BIN=$ROOT/_build/default/bin/main.exe; fi
fi
if [[ $MLWM_BIN != /* ]]; then MLWM_BIN=$ROOT/$MLWM_BIN; fi
[[ -x $MLWM_BIN ]] || { printf 'mlwm binary is not executable: %s\n' "$MLWM_BIN" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
XVFB_PID=
WM_PID=
DISPLAY_NUM=
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
kill_tree() {
    local parent=$1 child
    while read -r child; do [[ -n $child ]] && kill_tree "$child"; done < <(pgrep -P "$parent" || true)
    kill "$parent" 2>/dev/null || true
}
cleanup() {
    local name pid
    if [[ -n ${WM_PID:-} ]] && kill -0 "$WM_PID" 2>/dev/null; then kill_tree "$WM_PID"; fi
    for name in xterm dmenu rofi dmenu_run; do
        while read -r pid; do [[ -n $pid ]] && kill "$pid" 2>/dev/null || true; done < <(pgrep -x "$name" || true)
    done
    if [[ -n ${XVFB_PID:-} ]] && kill -0 "$XVFB_PID" 2>/dev/null; then kill_tree "$XVFB_PID"; fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
wait_for() {
    local description=$1 timeout=${2:-8} start=$SECONDS
    shift 2
    while (( SECONDS - start < timeout )); do
        if "$@"; then return 0; fi
        sleep 0.05
    done
    if [[ $description == 'dmenu override_redirect window' ]]; then cat "$TMP_DIR/override.log" >&2; fi
    fail "timed out waiting for $description"
}

win_info() { xwininfo -id "$1" 2>/dev/null; }
win_viewable() { [[ $(win_info "$1") == *IsViewable* ]]; }
win_unmapped() { [[ $(win_info "$1") == *IsUnMapped* ]]; }
win_geometry() {
    local data
    data=$(xdotool getwindowgeometry --shell "$1" 2>/dev/null) || return 1
    GEOM_X= GEOM_Y= GEOM_W= GEOM_H=
    while IFS='=' read -r key value; do
        case $key in X) GEOM_X=$value;; Y) GEOM_Y=$value;; WIDTH) GEOM_W=$value;; HEIGHT) GEOM_H=$value;; esac
    done <<< "$data"
    [[ -n $GEOM_X && -n $GEOM_Y && -n $GEOM_W && -n $GEOM_H ]]
}
xterms() {
    local id
    XTERMS=()
    while read -r id; do [[ -n $id ]] && XTERMS+=("$id"); done < <(xdotool search --class xterm 2>/dev/null || true)
}
two_viewable_xterms() {
    local count=0 id
    xterms
    for id in "${XTERMS[@]}"; do if win_viewable "$id"; then ((count+=1)); fi; done
    (( count == 2 ))
}
visible_xterm_count() {
    local count=0 id
    xterms
    for id in "${XTERMS[@]}"; do if win_viewable "$id"; then ((count+=1)); fi; done
    printf '%s' "$count"
}
one_xterm() { xterms; (( ${#XTERMS[@]} >= 1 )); }
master_wider() { win_geometry "$W1" || return 1; (( GEOM_W > $1 + 20 )); }
swapped_positions() {
    win_geometry "$W1" || return 1; local right_x=$GEOM_X
    win_geometry "$W2" || return 1
    (( GEOM_X == 0 && right_x > GEOM_X ))
}
monocle_geometry() {
    local id
    id=$(xdotool getwindowfocus)
    win_geometry "$id" || return 1
    (( GEOM_X <= 2 && GEOM_Y <= 2 && GEOM_W >= 1276 && GEOM_H >= 716 ))
}
tall_again() { win_geometry "$W1" && win_geometry "$W2" && (( GEOM_W < 1276 )); }
dmenu_mapped() {
    local id info
    while read -r id; do
        [[ -n $id ]] || continue
        info=$(win_info "$id")
        if [[ $info == *IsViewable* && $info == *'Override Redirect State: yes'* ]]; then DMENU_WID=$id; return 0; fi
    done < <(xdotool search --class dmenu 2>/dev/null || true)
    return 1
}
dmenu_gone() { ! win_viewable "${DMENU_WID:-0}"; }
float_geometry() {
    win_geometry "$FLOAT_WID" || return 1
    (( GEOM_W >= 760 && GEOM_W <= 780 && GEOM_H >= 420 && GEOM_H <= 440 && GEOM_X > 200 && GEOM_Y > 100 && GEOM_X != TILE_X ))
}
float_resized() { win_geometry "$FLOAT_WID" && (( GEOM_W == 500 && GEOM_H == 360 )); }
returned_tiled() { win_geometry "$FLOAT_WID" && (( GEOM_W > 500 && GEOM_W < 1276 )); }
hidden_on_one() { win_unmapped "$FLOAT_WID"; }
shown_on_two() { win_viewable "$FLOAT_WID" && win_unmapped "$OTHER_WID"; }
both_after_restart() { two_viewable_xterms; }
one_left() { [[ $(visible_xterm_count) == 1 ]]; }
wm_exited() { ! kill -0 "$WM_PID" 2>/dev/null; }
assert_log_clean() {
    local output
    output=$(cat "$TMP_DIR/mlwm.stderr")
    [[ $output != *BadWindow* && $output != *Fatal* && $output != *Exception* && $output != *exception* ]] || {
        printf 'Unexpected mlwm stderr:\n%s\n' "$output" >&2; return 1;
    }
}

for n in $(seq 90 200); do
    if [[ ! -e /tmp/.X11-unix/X$n && ! -e /tmp/.X$n-lock ]]; then DISPLAY_NUM=$n; break; fi
done
[[ -n $DISPLAY_NUM ]] || fail 'no free X display found'
export DISPLAY=:$DISPLAY_NUM
Xvfb "$DISPLAY" -screen 0 1280x720x24 -nolisten tcp >"$TMP_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
wait_for 'Xvfb' 8 xrandr --query >/dev/null 2>&1
"$MLWM_BIN" >"$TMP_DIR/mlwm.stdout" 2>"$TMP_DIR/mlwm.stderr" &
WM_PID=$!

log 'automatic Tall tiling'
xdotool key --clearmodifiers Super_L+Return
wait_for 'first xterm' 8 one_xterm
xdotool key --clearmodifiers Super_L+Return
wait_for 'two tiled xterms' 10 two_viewable_xterms
xterms
W1=${XTERMS[0]}; W2=${XTERMS[1]}
win_geometry "$W1"; X1=$GEOM_X; Y1=$GEOM_Y; MW=$GEOM_W; MH=$GEOM_H
win_geometry "$W2"; X2=$GEOM_X; Y2=$GEOM_Y; SW=$GEOM_W; SH=$GEOM_H
if (( X1 > X2 )); then
    tmp=$W1; W1=$W2; W2=$tmp
    tmp=$X1; X1=$X2; X2=$tmp
    tmp=$MW; MW=$SW; SW=$tmp
    tmp=$MH; MH=$SH; SH=$tmp
    tmp=$Y1; Y1=$Y2; Y2=$tmp
fi
(( X1 != X2 && MW > SW && MW >= 600 && MW <= 750 && SW >= 480 && SW <= 650 )) || fail "Tall geometry unexpected: xterm1 x=$X1 w=$MW; xterm2 x=$X2 w=$SW"
(( Y1 <= 2 && MH >= 700 && SH >= 700 )) || fail "Tall windows do not fill output: heights $MH/$SH"

log 'master resize, swap, and Monocle'
xdotool key --clearmodifiers Super_L+l
wait_for 'master width increase' 5 master_wider "$MW"
win_geometry "$W1"; MW=$GEOM_W
xdotool windowfocus --sync "$W2"
xdotool key --clearmodifiers Super_L+Shift_L+Return
wait_for 'master swap' 5 swapped_positions
xdotool key --clearmodifiers Super_L+space
wait_for 'Monocle geometry' 5 monocle_geometry
xdotool key --clearmodifiers Super_L+space
wait_for 'Tall layout restored' 5 tall_again

log 'override_redirect launcher pass-through'
win_geometry "$W1"; BEFORE_W1=$GEOM_W; BEFORE_X1=$GEOM_X
win_geometry "$W2"; BEFORE_W2=$GEOM_W; BEFORE_X2=$GEOM_X
(printf 'one\ntwo\n' | dmenu) >"$TMP_DIR/override.log" 2>&1 &
wait_for 'dmenu override_redirect window' 8 dmenu_mapped
win_geometry "$W1"; (( GEOM_W == BEFORE_W1 && GEOM_X == BEFORE_X1 )) || fail 'dmenu changed first tiled geometry'
win_geometry "$W2"; (( GEOM_W == BEFORE_W2 && GEOM_X == BEFORE_X2 )) || fail 'dmenu changed second tiled geometry'
xdotool key Escape
wait_for 'dmenu to close' 5 dmenu_gone

log 'floating and ConfigureRequest handling'
FOCUS=$(xdotool getwindowfocus)
[[ $FOCUS == "$W1" || $FOCUS == "$W2" ]] || fail "focused window $FOCUS is not an xterm"
if [[ $FOCUS == "$W1" ]]; then FLOAT_WID=$W1; OTHER_WID=$W2; else FLOAT_WID=$W2; OTHER_WID=$W1; fi
win_geometry "$FLOAT_WID"; TILE_W=$GEOM_W; TILE_H=$GEOM_H; TILE_X=$GEOM_X
xdotool key --clearmodifiers Super_L+f
wait_for 'floating centered geometry' 5 float_geometry
xdotool windowsize "$FLOAT_WID" 500 360
wait_for 'floating ConfigureRequest size' 5 float_resized
xdotool key --clearmodifiers Super_L+f
wait_for 'window returned to tiled slot' 5 returned_tiled
win_geometry "$FLOAT_WID"; TILE_W=$GEOM_W; TILE_H=$GEOM_H
xdotool windowsize "$FLOAT_WID" 300 200
sleep 0.2
win_geometry "$FLOAT_WID"
(( GEOM_W == TILE_W && GEOM_H == TILE_H )) || fail "tiled ConfigureRequest changed geometry to ${GEOM_W}x${GEOM_H}"

log 'workspace mapping and restart re-adoption'
xdotool key --clearmodifiers Super_L+Shift_L+2
wait_for 'window unmapped on workspace 1' 5 hidden_on_one
xdotool key --clearmodifiers Super_L+2
wait_for 'workspace 2 window viewable' 5 shown_on_two
xdotool key --clearmodifiers Super_L+Shift_L+r
wait_for 'restart re-adopts both xterms on workspace 1' 10 both_after_restart
[[ $(visible_xterm_count) == 2 ]] || fail 'restart did not make both xterms viewable on workspace 1'

log 'close focused xterm and clean Quit'
xdotool key --clearmodifiers Super_L+Shift_L+c
wait_for 'one xterm closed' 8 one_left
xdotool key --clearmodifiers Super_L+Shift_L+q
wait_for 'mlwm clean exit' 8 wm_exited
wait "$WM_PID" || fail 'mlwm exited nonzero after Quit'
assert_log_clean || fail 'mlwm stderr contains an X11 or exception error'
log 'PASS: Xvfb end-to-end smoke suite'
