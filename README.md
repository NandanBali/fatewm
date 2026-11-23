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
- `test/` — Pure core unit tests + Arch `Xvfb` end-to-end tests.
- `containers/` & `packaging/arch/` — Clean-room Arch Linux build, headless test, and blank-install verification.

## Building & Testing

```sh
dune build @all
dune runtest
```
