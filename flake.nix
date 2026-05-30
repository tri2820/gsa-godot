{
  description = "Godot Gaussian splat viewer — recording demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.just
            pkgs.ffmpeg
          ];

          shellHook = ''
            # Use the locally-installed Godot 4 app on macOS. Override by
            # exporting GODOT before entering the shell.
            export GODOT="''${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
          '';
        };
      });
}
