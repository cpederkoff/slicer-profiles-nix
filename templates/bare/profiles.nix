# Full `slicerProfiles` module value - see README.md for how to wire it in.
{ lib, slicerLib }:

let
  args = { inherit slicerLib; };

  # Every *.nix file becomes a profile; "_"-prefixed files (e.g. _common.nix)
  # are skipped.
  scanDir =
    dir:
    let
      fileNames = lib.attrNames (
        lib.filterAttrs (
          name: type: type == "regular" && lib.hasSuffix ".nix" name && !(lib.hasPrefix "_" name)
        ) (builtins.readDir dir)
      );
    in
    map (fileName: import (dir + "/${fileName}") args) fileNames;
in
{
  configDir = "YourSlicer"; # e.g. "PrusaSlicer", "SuperSlicer"
  directories = {
    printer = builtins.listToAttrs (scanDir ./printers);
    filament = builtins.listToAttrs (scanDir ./filaments);
    print = builtins.listToAttrs (scanDir ./prints);
  };
}
