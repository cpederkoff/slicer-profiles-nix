# Full `slicerProfiles` module value - see README.md in this directory for
# how to wire it into your home-manager config.
{ lib, slicerLib }:

let
  args = { inherit slicerLib; };

  # Every *.nix file becomes a profile, except "_"-prefixed ones (shared
  # fields - import them directly where needed, see main README).
  scanDir =
    dir:
    let
      fileNames = lib.attrNames (
        lib.filterAttrs (
          name: type: type == "regular" && !(lib.hasPrefix "_" name) && lib.hasSuffix ".nix" name
        ) (builtins.readDir dir)
      );
    in
    map (fileName: import (dir + "/${fileName}") args) fileNames;
in
{
  configDir = "PrusaSlicer";
  directories = {
    printer = builtins.listToAttrs (scanDir ./printers);
    filament = builtins.listToAttrs (scanDir ./filaments);
    print = builtins.listToAttrs (scanDir ./prints);
  };
}
