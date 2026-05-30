# gsa-godot

Godot 4.6 multi-camera viewer + recorder for 3D Gaussian splats, built on
[ReconWorldLab/godot-gaussian-splatting](https://github.com/ReconWorldLab/godot-gaussian-splatting)
(plugin vendored under `addons/gdgs/`, MIT).

## Setup

Requires Godot 4.6+ installed on macOS. With nix + direnv:

```sh
direnv allow            # provisions `just` + `ffmpeg` in PATH
```

Drop a 3DGS `.ply` at `scene.ply` (or change the path in `main.tscn`).

## Run

```sh
just run                # interactive free-fly viewer
```

Controls:

| Key            | Action                                |
| -------------- | ------------------------------------- |
| RMB drag       | Look around                           |
| W A S D        | Move (forward / left / back / right)  |
| Q / E          | Down / up                             |
| Shift          | 3× speed                              |
| Wheel          | Zoom along view direction             |
| 1 – 9          | Jump to `CAMERAS[N-1]`                |
| ← / →          | Cycle cameras                         |
| Esc            | Release mouse                         |

## Record

Edit the `CAMERAS` array in `main.gd` to add poses, then:

```sh
just frames=100 fps=10 record
```

This launches **one** Godot process, builds N `SubViewport`s (all sharing the
main `World3D`), and writes one `.avi` per camera through a custom AVI MJPEG
writer (`avi_mjpeg.gd`). Pays the splat-decode + shader-compile cost once,
not per camera.

Output: `out/<name>.avi`, validatable with `ffprobe`, playable in QuickTime /
VLC.

## Layout

- `main.gd` / `main.tscn` — scene + free-fly + recording orchestration
- `avi_mjpeg.gd` — minimal RIFF/AVI MJPEG writer (no ffmpeg dependency)
- `addons/gdgs/` — vendored Godot Gaussian Splatting plugin (v2.2.0, MIT)
- `flake.nix` / `.envrc` — nix devShell providing `just` + `ffmpeg`
- `justfile` — `run` / `record` / `list-cameras` / `clean`
