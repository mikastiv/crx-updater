{
  description = "zig flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
      zls,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        lib = nixpkgs.lib;
        fs = lib.fileset;
        pkgs = import nixpkgs { inherit system; };
        version = "0.1.0";
        zigPkg = zig.packages.${system}."0.15.2";
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zigPkg
            zls.packages.${system}.zls
          ];
        };

        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "ziginit";
          version = version;
          src = fs.toSource {
            root = ./.;
            fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
              fs.unions [
                ./src
                ./build.zig
                ./build.zig.zon
              ]
            );
          };

          strictDeps = true;
          nativeBuildInputs = [ zigPkg ];

          zigBuildFlags = [
            "-Doptimize=ReleaseSafe"
          ];

          configurePhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
          '';

          buildPhase = ''
            zig build install --color off --prefix $out
          '';
        };
      }
    );
}
