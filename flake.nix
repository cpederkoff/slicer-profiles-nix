{
  description = "Declarative Slic3r-derivative (ini) printer/filament/print-quality profile management for Home Manager, with vendor-bundle inheritance and dead-field warnings.";

  inputs = {
    # Dev-tooling only (checks/formatter) - the module takes `lib` from its
    # caller, not nixpkgs directly. Consumers should `follows` this input.
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

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

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
            program = "${
              pkgs.writers.writePython3Bin "import-profiles" { flakeIgnore = [ "E501" ]; } (
                builtins.readFile ./scripts/import-profiles.py
              )
            }/bin/import-profiles";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # home-manager itself defines xdg.configFile - stub it so the
          # module evaluates without depending on home-manager.
          xdgConfigFileStub = { lib, ... }: {
            options.xdg.configFile = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
          evaled = pkgs.lib.evalModules {
            modules = [
              self.homeModules.default
              xdgConfigFileStub
              { slicerProfiles.configDir = "TestSlicer"; }
            ];
          };

          # Fixture for scripts/import-profiles.py: a decimal (must port as
          # a string), a whole number (fine as an int), an `inherits =` (the
          # commented vendorBundles hint), and gcode with a literal "\n" and
          # embedded quotes (escaping the importer must round-trip).
          importProfilesPkg = pkgs.writers.writePython3Bin "import-profiles" { flakeIgnore = [ "E501" ]; } (
            builtins.readFile ./scripts/import-profiles.py
          );
          importProfilesFixture = pkgs.writeTextDir "printer/My Printer (test).ini" (
            "nozzle_diameter = 0.4\n"
            + "retract_length = 5\n"
            + "inherits = Some Vendor Printer\n"
            + ''start_gcode = G28\nG1 Z5\n"quoted"''
            + "\n"
          );
          # Vendor fixture for --vendor-src: a matching "[printer:Some Vendor
          # Printer]" section the importer's hint should resolve by name.
          importProfilesVendorFixture = pkgs.writeTextDir "TestVendor.ini" (
            "[printer:Some Vendor Printer]\nnozzle_diameter = 0.4\n"
          );

          # Fixture covers `inherits =` resolution, CRLF, and "key=value"
          # (no space) - real vendor-bundle quirks the ini regex must handle.
          slicerLib = self.lib.mkProfileLib { inherit (pkgs) lib; };
          vendorFixture = pkgs.writeText "vendor-fixture.ini" (
            "[printer:Base]\nnozzle_diameter = 0.4\r\nretract_length=0.8\r\n"
            + "[printer:Child]\ninherits = Base\nnozzle_diameter = 0.6\n"
          );
          sections = slicerLib.parseVendorIni vendorFixture;
          resolved = slicerLib.resolveVendorSection sections "printer:Child";
          merged = slicerLib.mergeAttrsListAndWarn [
            resolved
            {
              nozzle_diameter = "0.6";
              extra = "1";
            }
          ];
          rendered = slicerLib.toSlic3rIni merged;
          renderedWithInt = slicerLib.toSlic3rIni {
            filament_cost = 20;
            filament_type = "PLA";
          };

          testProfile = {
            name = "Test Printer (nix)";
            value = {
              nozzle_diameter = "0.4";
            };
          };

          basePrinter = {
            name = "Base Printer (nix)";
            value = slicerLib.mergeAttrsListAndWarn [
              {
                nozzle_diameter = "0.4";
                retract_length = "0.8";
              }
            ];
          };
          derivedPrinter = {
            name = "Derived Printer (nix)";
            value = slicerLib.mergeAttrsListAndWarn [
              basePrinter.value
              { nozzle_diameter = "0.6"; }
            ];
          };

          vendorSrcFixture = pkgs.writeTextDir "TestVendor.ini" (
            "[filament:Test Filament]\nfilament_type = PLA\n"
          );
          testBundle = slicerLib.mkVendorBundle vendorSrcFixture "TestVendor.ini";
          testBundles = slicerLib.mkVendorBundles vendorSrcFixture;

          # mkProfileLib without vendorSrc shouldn't grow a vendorBundles
          # attr; with it, bundles should show up pre-attached.
          slicerLibWithVendor = self.lib.mkProfileLib {
            inherit (pkgs) lib;
            vendorSrc = vendorSrcFixture;
          };

          libBehaviorOk =
            assert
              resolved == {
                nozzle_diameter = "0.6";
                retract_length = "0.8";
              };
            assert
              merged == {
                nozzle_diameter = "0.6";
                retract_length = "0.8";
                extra = "1";
              };
            assert rendered == "extra = 1\nnozzle_diameter = 0.6\nretract_length = 0.8\n";
            assert renderedWithInt == "filament_cost = 20\nfilament_type = PLA\n";
            assert !(slicerLib ? vendorBundles);
            assert
              slicerLibWithVendor.vendorBundles.TestVendor "filament:Test Filament" == {
                filament_type = "PLA";
              };
            assert
              builtins.listToAttrs [ testProfile ] == {
                "Test Printer (nix)" = {
                  nozzle_diameter = "0.4";
                };
              };
            assert
              derivedPrinter.value == {
                nozzle_diameter = "0.6";
                retract_length = "0.8";
              };
            assert testBundle "filament:Test Filament" == { filament_type = "PLA"; };
            assert
              testBundles.TestVendor "filament:Test Filament" == {
                filament_type = "PLA";
              };
            true;
        in
        {
          module-evaluates = pkgs.runCommand "slicer-profiles-nix-module-evaluates" { } ''
            echo "configDir=${evaled.config.slicerProfiles.configDir}" > $out
          '';

          lib-behaves-correctly = pkgs.runCommand "slicer-profiles-nix-lib-behaves-correctly" { } ''
            echo "${pkgs.lib.boolToString libBehaviorOk}" > $out
          '';

          import-profiles-works =
            pkgs.runCommand "slicer-profiles-nix-import-profiles-works"
              {
                nativeBuildInputs = [ importProfilesPkg ];
              }
              ''
                import-profiles --config-dir ${importProfilesFixture} --out $out

                common="$out/printers/_common.nix"
                test -f "$common"

                profile="$out/printers/my_printer_test.nix"
                test -f "$profile"
                grep -qF 'nozzle_diameter = "0.4";' "$profile"
                grep -qF 'retract_length = 5;' "$profile"
                grep -qF 'start_gcode = "G28\\nG1 Z5\\n\"quoted\"";' "$profile"
                grep -qF 'vendorBundles.<Vendor> "printer:Some Vendor Printer"' "$profile"
                grep -qF 'import ./_common.nix' "$profile"
              '';

          import-profiles-vendor-resolves =
            pkgs.runCommand "slicer-profiles-nix-import-profiles-vendor-resolves"
              {
                nativeBuildInputs = [ importProfilesPkg ];
              }
              ''
                import-profiles --config-dir ${importProfilesFixture} --vendor-src ${importProfilesVendorFixture} --out $out

                profile="$out/printers/my_printer_test.nix"
                grep -qF 'vendorBundles.TestVendor "printer:Some Vendor Printer"' "$profile"
                grep -qF 'Found it in vendorBundles.TestVendor.' "$profile"
              '';
        }
      );
    };
}
