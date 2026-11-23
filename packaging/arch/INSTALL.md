# Installing mlwm on Arch Linux

## 1. Runtime packages

Install Xorg and the runtime/launcher packages on a blank Arch Linux machine:

```sh
pacman -S --needed xorg-server xorg-xinit libx11 libxrandr xterm rofi dmenu
```

## 2. Install prebuilt binary and session files

Copy the `mlwm` binary (e.g., extracted from `mlwm-arch-runtime` at `/usr/local/bin/mlwm` or built via `dune build --profile=release`) and drop-in files:

```sh
install -Dm755 mlwm /usr/local/bin/mlwm
install -Dm644 packaging/arch/mlwm.desktop /usr/share/xsessions/mlwm.desktop
install -Dm644 packaging/arch/xinitrc ~/.xinitrc
```

Start X with `startx`, or pick **mlwm** in your display manager.

## 3. Optional: Build and install with makepkg

From a repository checkout with `ocaml` and `dune` installed:

```sh
cd packaging/arch
makepkg -si
```
