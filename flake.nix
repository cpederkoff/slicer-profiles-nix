{
  description = "Declarative PrusaSlicer-format (ini) printer/filament/print-quality profile management for Home Manager, with vendor-bundle inheritance and dead-field warnings.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      homeManagerModules.default = import ./default.nix;
      # Alias for the newer home-manager module naming convention.
      homeModules.default = self.homeManagerModules.default;

      # Exposes the generic ini/vendor-bundle tooling standalone, for
      # building your own profiles.nix (see README) outside of this
      # module's own option surface.
      lib.mkProfileLib = { lib }: import ./lib.nix { inherit lib; };

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          evaled = pkgs.lib.evalModules { modules = [ self.homeManagerModules.default ]; };
        in {
          module-evaluates = pkgs.runCommand "slicer-profiles-nix-module-evaluates" { } ''
            echo "configDir=${evaled.config.slicerProfiles.configDir}" > $out
          '';
        });
    };
}
