fish_add_path $HOME/.local/bin

# Run toolkit apps natively on Wayland instead of Xwayland (so they render
# crisp under Sway's fractional scale 1.25 instead of being upscaled/blurry).
set -gx ELECTRON_OZONE_PLATFORM_HINT auto   # Electron: Discord, VS Code, ...
set -gx MOZ_ENABLE_WAYLAND 1                # Firefox / LibreWolf

if status is-interactive
    # Commands to run in interactive sessions can go here
    fastfetch
end
