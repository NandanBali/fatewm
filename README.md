# mlwm

Minimal dynamic-tiling window manager written in OCaml with direct C interop
(`libX11` + `libXrandr` for v1), architected with a pure-OCaml rules core so a
future Wayland (`wlroots`) backend can replace the display backend without
touching the core.

## Layout & Size Budget (Hard Cap: 6,000 LOC)

- `lib/proto/` — Display-server-agnostic types, events, commands, and `Backend.S` (stdlib only).
- `lib/core/` — Pure OCaml tiling rules (`StackSet`, `Tall`/`Monocle`, floating, reducer). Zero C/X11.
- `cbits/` — Direct OCaml C FFI stubs (`x11_stubs.c` + `x11_c.ml`) linking `libX11` + `libXrandr`.
- `lib/x11_backend/` — X11 adapter implementing `Backend.S` (`ignore_unmap`, RandR fallback, click-to-focus).
- `lib/fake_backend/` — Headless in-memory backend proving `mlwm.core` builds & runs with zero X11.
- `config/` — OCaml configuration module (`config/config.ml`); edit and rebuild to apply.
- `bin/` — `mlwm` executable wiring `config` + `core` + `x11_backend`.
- `test/` — Pure core & fake-backend unit tests (`dune runtest`) + Arch `Xvfb` end-to-end suite (`test/xvfb_smoke.sh`).
- `containers/` & `packaging/arch/` — Clean-room Arch Linux build, headless test, runtime image, and drop-in session files (`packaging/arch/INSTALL.md`).

## Default Keybindings (`Super` / `Mod4`)

| Binding | Action |
|---|---|
| `Super+Return` | Spawn `xterm` |
| `Super+d` / `Super+p` | Spawn `rofi -show drun` / `dmenu_run` |
| `Super+j` / `Super+k` | Focus next / previous window |
| `Super+Shift+Return` | Promote focused window to master |
| `Super+Shift+j` / `Super+Shift+k` | Swap window next / previous |
| `Super+h` / `Super+l` | Shrink / grow master ratio (`5%`) |
| `Super+Space` | Cycle layout (`Tall` <-> `Monocle`) |
| `Super+f` | Toggle floating on focused window |
| `Super+1..9` / `Super+Shift+1..9` | View / move window to workspace `1..9` |
| `Super+w` / `Super+e` | Focus previous / next monitor |
| `Super+Shift+w` / `Super+Shift+e` | Move window to previous / next monitor |
| `Super+Shift+c` | Close focused window (`WM_DELETE_WINDOW` / kill fallback) |
| `Super+Shift+r` | In-place restart (`execv`, re-adopts open windows) |
| `Super+Shift+q` | Quit `mlwm` |

## Building & Testing

```sh
# Host build & pure X11-free unit tests
dune build @all
dune runtest

# Clean-room Arch Linux build, stripped runtime image & Xvfb E2E smoke suite
./containers/run-arch.sh build
./containers/run-arch.sh release
./containers/run-arch.sh smoke-runtime
```

See `packaging/arch/INSTALL.md` for installing on a blank Arch Linux system.
