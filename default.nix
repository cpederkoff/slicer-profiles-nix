# Declaratively manages PrusaSlicer-format (ini, printer/filament/print
# subdirs) printer/filament/print-quality profiles. Actual values live in
# profiles.nix; this file just renders them. Works with PrusaSlicer as-is;
# for a fork with a different config directory name but the same on-disk
# layout (e.g. SuperSlicer), override `configDir` below.
#
# <app>.ini (app UI prefs) and physical_printer/*.ini (host + API key) are
# intentionally NOT managed here - no reason to fight the GUI over window
# positions, and no secrets in a source controlled repo.
#
# Nix owns the profile files directly (read-only symlinks into the nix
# store) at their real path, "$HOME/${configDir}/<type>/<name>.ini". Saving
# over a managed profile from the slicer's GUI will fail (the file is
# read-only) - use "Save As" under a new name for experiments, then
# hand-port anything worth keeping into profiles.nix and rebuild. Profiles
# not declared here are untouched, ordinary mutable files.
{ config, lib, ... }:

let
  cfg = config.slicerProfiles;
  prusaLib = import ./lib.nix { inherit lib; };

  profileType = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [
    lib.types.int
    lib.types.str
  ]));

  mkProfileFiles = type: profiles:
    lib.mapAttrs' (name: value:
      lib.nameValuePair "${cfg.configDir}/${type}/${name}.ini" {
        text = prusaLib.toPrusaIni value;
      }
    ) profiles;
in
{
  options.slicerProfiles = {
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".config/PrusaSlicer";
      example = ".config/SuperSlicer";
      description = ''
        Path, relative to $HOME, that the slicer stores its profiles under.
        Defaults to PrusaSlicer's own config directory. Override this for a
        fork that uses a different app/config directory name but the same
        on-disk profile layout (ini format, printer/filament/print
        subdirs) - the profile *contents* in profiles.nix still need to
        match whatever option keys that fork actually understands.
      '';
    };

    printers = lib.mkOption {
      type = profileType;
      default = { };
      description = ''
        Printer profiles, keyed by the exact profile name the slicer uses
        on disk (matches the .ini filename minus extension). See the
        header of home/slicer-profiles/default.nix for how this is applied.
      '';
    };

    filaments = lib.mkOption {
      type = profileType;
      default = { };
      description = "Filament profiles. See `printers` above.";
    };

    prints = lib.mkOption {
      type = profileType;
      default = { };
      description = "Print-quality profiles. See `printers` above.";
    };
  };

  config = {
    home.file = (mkProfileFiles "printer" cfg.printers)
      // (mkProfileFiles "filament" cfg.filaments)
      // (mkProfileFiles "print" cfg.prints);
  };
}
