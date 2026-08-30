{
  description = "Declarative Slic3r-derivative (ini) printer/filament/print-quality profile management for Home Manager, with vendor-bundle inheritance and compiled-default base layers.";

  inputs = {
    # Dev-tooling only (checks/formatter); the module takes `lib` from its
    # caller, not nixpkgs directly. Consumers SHOULD `follows` this input.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      # x86_64-darwin omitted - dropped by this nixpkgs pin.
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Single source for the importer binary, shared by the app output and
      # the checks so the script is only wrapped in one place.
      mkImportProfiles =
        pkgs:
        pkgs.writers.writePython3Bin "import-profiles" { flakeIgnore = [ "E501" ]; } (
          builtins.readFile ./scripts/import-profiles.py
        );
    in
    {
      # homeModules is current convention (parity with nixosModules/
      # darwinModules); homeManagerModules is a back-compat alias.
      homeModules.default = import ./default.nix;
      homeManagerModules.default = self.homeModules.default;

      # Generic ini/vendor tooling (see README) - no app knowledge. vendorSrc
      # is optional: a directory of "<Vendor>.ini" files (a source-tree pin
      # or `${pkgs.<slicer>}/share/...` both work identically); when given,
      # its bundles show up pre-attached at `.vendorBundles`.
      lib.mkProfileLib =
        {
          lib,
          vendorSrc ? null,
        }:
        let
          base = import ./lib.nix { inherit lib; };
        in
        base // lib.optionalAttrs (vendorSrc != null) { vendorBundles = base.mkVendorBundles vendorSrc; };

      templates.default = {
        path = ./templates/default;
        description = "slicerProfiles scaffold: profiles.nix scanning printers/filaments/prints, plus one example file in each";
      };

      # Same scaffold without the example profiles - empty dirs for the
      # import-profiles flow, so there are no placeholders to delete after.
      templates.bare = {
        path = ./templates/bare;
        description = "slicerProfiles scaffold with no example profiles - empty dirs to fill with import-profiles";
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      # Reproducible dump of PrusaSlicer's compiled-in defaults, for
      # `import-profiles --defaults-src`. Pinned to this flake's nixpkgs so it
      # matches the vendor bundles you diff against.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          prusaslicer-defaults =
            pkgs.runCommand "prusaslicer-defaults.ini"
              {
                nativeBuildInputs = [ pkgs.prusa-slicer ];
              }
              ''
                export HOME="$(mktemp -d)"
                prusa-slicer --save "$out"
              '';
        }
      );

      # `nix run .#import-profiles -- --config-dir ~/.config/PrusaSlicer --out
      # ./home/slicer-profiles` - see README "Port existing profiles".
      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          import-profiles = {
            type = "app";
            program = "${mkImportProfiles pkgs}/bin/import-profiles";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./checks.nix {
          inherit self pkgs;
          importProfilesPkg = mkImportProfiles pkgs;
        }
      );
    };
}
