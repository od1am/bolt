
# flake.nix
{
  description = "Bolt — a Zig BitTorrent client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; # or use a stable channel
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: 
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "bolt";
          version = "1.0.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          buildPhase = ''
            zig build
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/bolt $out/bin/
          '';
        };

        # This lets you do `nix run`
        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/bolt";
        };

        # For `nix develop`, giving you a dev shell w/ zig
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.zig ];
        };
      }
    );
}
