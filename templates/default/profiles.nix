# Full `slicerProfiles` module value - see README.md in this directory for
# how to wire it into your home-manager config.
{ lib, slicerLib }:

let
  args = { inherit slicerLib; };

  # Every *.nix file becomes a profile - add a file, it's picked up, no
  # list to maintain.
  scanDir =
    dir:
    let
      fileNames = lib.attrNames (
        lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
          builtins.readDir dir
        )
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
