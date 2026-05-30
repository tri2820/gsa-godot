# Run with `just <recipe>`. `just` is provided by the nix devShell — if
# you don't have it, `direnv allow` in this directory or `nix develop`
# will give you everything.

GODOT      := env_var_or_default("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")
frames     := "80"
fps        := "30"
output_dir := "out"

# Show available recipes.
default:
    @just --list

# Launch the interactive viewer (free-fly).
run:
    {{GODOT}} --path . main.tscn

# List camera names defined in CAMERAS (main.gd).
list-cameras:
    @{{GODOT}} --headless --path . --quit-after 2 -- --list-cameras 2>/dev/null \
        | grep -vE '^(Godot|Metal|$)'

# Record one .avi per camera in CAMERAS — single Godot process, N SubViewports
# sharing one World3D, custom AVI MJPEG writers (avi_mjpeg.gd). Pays startup
# (splat decode + shader compile) once total, not once per camera.
# Override per-invocation: `just frames=200 fps=60 record`.
record:
    @mkdir -p {{output_dir}}
    {{GODOT}} --path . main.tscn \
        --fixed-fps {{fps}} \
        -- --record --output {{output_dir}} --frames {{frames}} --fps {{fps}}

# Wipe {{output_dir}} to start the next record clean.
clean:
    rm -rf {{output_dir}}
