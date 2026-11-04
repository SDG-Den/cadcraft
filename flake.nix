{
  description = "CADCraft — 2D computer-aided design and drafting, in pure Rust";

  inputs = {
    # CADCraft needs edition 2024 and rustc ≥ 1.95, so the flake tracks unstable. Consumers on a
    # release channel can retarget it: `inputs.cadcraft.inputs.nixpkgs.follows = "nixpkgs";`
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Optional build input of the repository: the fonts that `crates/fonts/build.rs` embeds when
    # `CRAFT_FONTS_DIR` is set. Official releases always build with them; without them everything
    # works but non-Latin text lacks glyphs. Pinned to the revision `.github/workflows/release.yml`
    # fetches — bump both together (`nix flake update craft-fonts`).
    craft-fonts = {
      url = "github:storytold/craft-fonts/b076417b5880bd4154bd22f00695b1d28c6bea83";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      craft-fonts,
    }:
    let
      inherit (nixpkgs) lib;

      # No x86_64-darwin: the pinned nixpkgs dropped it. On an Intel Mac, retarget nixpkgs at a
      # release that still has it, or install the release build.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # The AppStream metadata carries a release date. The flake source's own commit date is
      # reproducible, unlike "now"; a tarball or dirty tree without one falls back to the epoch.
      buildDate =
        let
          d = self.lastModifiedDate or "";
        in
        if builtins.stringLength d >= 8 then
          "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}"
        else
          "1970-01-01";

      packageArgs = {
        inherit craft-fonts buildDate;
      };

      forAllSystems = f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }) system);
    in
    {
      packages = forAllSystems (
        pkgs: _:
        let
          cadcraft = pkgs.callPackage ./nix/package.nix packageArgs;
        in
        {
          inherit cadcraft;
          default = cadcraft;
        }
      );

      # `nixpkgs.overlays = [ inputs.cadcraft.overlays.default ]` → `pkgs.cadcraft` everywhere.
      overlays.default = final: _prev: {
        cadcraft = final.callPackage ./nix/package.nix packageArgs;
      };

      apps = forAllSystems (
        _: system: {
          default = {
            type = "app";
            program = lib.getExe self.packages.${system}.cadcraft;
          };
        }
      );

      devShells = forAllSystems (
        pkgs: system:
        let
          cadcraft = self.packages.${system}.cadcraft;
        in
        {
          default = pkgs.mkShell (
            {
              # The package's own native inputs, so `cargo run` in the shell needs no extra setup.
              inputsFrom = [ cadcraft ];
              packages = with pkgs; [
                cargo
                rustc
                clippy
                rustfmt
                rust-analyzer
              ];
              # `cargo run` dlopens the Vulkan loader, libwayland and libxkbcommon like the packaged binary.
              LD_LIBRARY_PATH = lib.makeLibraryPath cadcraft.passthru.runtimeLibs;
              RUST_BACKTRACE = "1";
            }
            // lib.optionalAttrs (craft-fonts != null) {
              # Embedded fonts in `cargo run` too; build.rs reads this as CRAFT_FONTS_DIR.
              CRAFT_FONTS_DIR = toString craft-fonts;
            }
          );
        }
      );

      checks = forAllSystems (
        pkgs: system:
        let
          cadcraft = self.packages.${system}.cadcraft;
        in
        {
          cadcraft = cadcraft;

          # Both module entry points evaluate with `enable = true` (no full NixOS evaluation).
          modules = pkgs.callPackage ./nix/module-check.nix { inherit cadcraft; };

          # `nix fmt` formats the flake; this keeps it formatted.
          formatting = pkgs.runCommand "cadcraft-nix-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./nix}
            touch $out
          '';
        }
      );

      formatter = forAllSystems (pkgs: _: pkgs.nixfmt);

      # Both modules take the package from this flake unless `programs.cadcraft.package` is set,
      # so `nixosModules.default`/`homeManagerModules.default` work without the overlay.
      nixosModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "nixos"; }) ];
          _module.args.cadcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.cadcraft;
        };

      homeManagerModules.default =
        { pkgs, ... }:
        {
          imports = [ (import ./nix/module.nix { kind = "home-manager"; }) ];
          _module.args.cadcraftPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.cadcraft;
        };
    };
}
