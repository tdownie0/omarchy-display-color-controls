# Additional Monitor Settings for Omarchy

An extension for the default `omarchy.monitor` plugin that adds smooth gamma and display brightness control for Wayland compositors using `wl-gammarelay-rs`.

## Features

- Seamless integration with the existing `omarchy.monitor` module.
- Smooth hardware/software brightness and color temperature adjustment via D-Bus.
- Low-latency response optimized for Wayland environments (Hyprland, Sway, etc.).

## Prerequisites

This plugin relies on `wl-gammarelay-rs` to communicate with the compositor.


### Install AUR package
omarchy pkg aur add wl-gammarelay-rs

### Enabling Serivce
systemctl --user daemon-reload
cp wl-gammarelay.service ~/.config/systemd/user/
systemctl --user enable --now wl-gammarelay.service

