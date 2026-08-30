# Render slicerProfiles.directories to ini files.
# Does not manage <app>.ini (GUI prefs) or physical_printer/*.ini (secrets).
# Rendered files are read-only store symlinks. Use "Save As" in the GUI to
# experiment, then port changes back here.
{ config, lib, ... }:

let
  cfg = config.slicerProfiles;
  slicerLib = import ./lib.nix { inherit lib; };

  profileType = lib.types.attrsOf (
    lib.types.attrsOf (
      lib.types.oneOf [
        lib.types.str
        lib.types.int
      ]
    )
  );
in
{
  options.slicerProfiles = {
    configDir = lib.mkOption {
      type = lib.types.str;
      example = "PrusaSlicer";
      description = ''
        Path relative to `xdg.configHome` (follows $XDG_CONFIG_HOME).
        Set to whatever app directory name your Slic3r-derivative slicer
        uses.
      '';
    };

    directories = lib.mkOption {
      type = lib.types.attrsOf profileType;
      default = { };
      example = lib.literalExpression ''
        {
          printer."My Printer (nix)" = {
            bed_shape = "0x0,250x0,250x210,0x210";
            nozzle_diameter = "0.4";
          };
          filament."My PLA (nix)" = { filament_type = "PLA"; temperature = "210"; };
          print."0.2mm (nix)" = { layer_height = "0.2"; };
        }
      '';
      description = ''
        Profiles by output subdirectory. Each top-level key is a literal
        directory under `configDir` (most Slic3r-derivative slicers want
        "printer"/"filament"/"print" - this option doesn't enforce that). Within
        each, profiles are keyed by the exact UI name; values are flat
        ini-field attrsets of strings or ints - no floats, since Nix's
        `toString` mangles them (e.g. "0.4" becomes "0.400000"); author
        those as strings instead (see README).
      '';
    };
  };

  config = {
    xdg.configFile = lib.concatMapAttrs (
      dir: profiles:
      lib.mapAttrs' (
        name: value:
        lib.nameValuePair "${cfg.configDir}/${dir}/${name}.ini" {
          text = slicerLib.toSlic3rIni value;
        }
      ) profiles
    ) cfg.directories;
  };
}
