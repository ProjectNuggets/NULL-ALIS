{
  description = "nullALIS";
  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    { zig2nix, treefmt-nix, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        # S3.1 — pin Zig version to the value in `.zigversion` so the
        # dev-shell matches the CI + Docker build pipeline. Previously
        # used `zig-latest` which drifted whenever zig2nix upstream
        # updated. If the transformed attribute doesn't exist on
        # zig2nix (e.g. pinning an older version that was removed),
        # the flake fails loudly rather than silently picking up a
        # different release — loud fail is the point.
        zigVersion =
          let raw = builtins.readFile ./.zigversion;
          in
          builtins.replaceStrings [ "\n" " " "\t" ] [ "" "" "" ] raw;
        zigAttrName = "zig-" + builtins.replaceStrings [ "." ] [ "_" ] zigVersion;
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.${zigAttrName};
        };
        pkgs = env.pkgs;
        project = "nullalis";
        mkPackage =
          {
            optimize ? "ReleaseSmall",
          }:
          env.package {
            pname = project;
            src = ./.;

            zigBuildZonLock = ./build.zig.zon2json-lock;

            zigBuildFlags = [ "-Doptimize=${optimize}" ];

            nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];

            meta = with pkgs.lib; {
              mainProgram = project;
              description = "Fastest, smallest, and fully autonomous AI assistant infrastructure written in Zig ";
              homepage = "https://github.com/ProjectNuggets/NULL-ALIS";
              license = licenses.mit;
              maintainers = [
                {
                  name = "Igor Somov";
                  github = "DonPrus";
                }
                {
                  name = "psynyde";
                  github = "psynyde";
                }
              ];
              platforms = platforms.all;
            };
          };
      in
      {
        packages.default = pkgs.lib.makeOverridable mkPackage { };
        devShells.default = env.mkShell {
          name = project;
          packages = with pkgs; [
            zls
          ];
          shellHook = ''
            echo -e '(¬_¬") Entered ${project} :D'
          '';
        };

        formatter = treefmt-nix.lib.mkWrapper pkgs {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
            zig.enable = true;
          };
        };
      }
    ));
}
