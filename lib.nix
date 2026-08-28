{ lib }:

# Generic PrusaSlicer-format (ini, [type:Name] vendor sections, "inherits ="
# chains) profile tooling - no assumptions about which app, vendor bundle,
# or printer this is used for. That's all supplied by the caller: see
# profiles.nix for how vendorSrc and the specific vendor bundles/presets
# used here are wired up on top of this file.
rec {
  # INI values must be int or string - Nix's toString renders floats like
  # "0.400000", which would corrupt numeric fields. Author floats/bools as
  # strings (e.g. "0.4", "1").
  mkPrusaValue = v:
    if builtins.isString v then v
    else if builtins.isInt v then toString v
    else throw "slicerProfiles: values must be int or string - author floats/bools as strings (e.g. \"0.4\", \"1\"); got ${builtins.typeOf v}";

  toPrusaIni = attrs:
    lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = ${mkPrusaValue v}\n") attrs);

  # Auto-registers every file in `dir` as a profile, skipping names starting
  # with "_" (shared fields merged in via mergeProfileLayers, not a profile
  # itself). Profile name = filename minus ".nix", plus " (nix)". A file may
  # be a flat attrset or a function of `{ prusaLib }:`.
  importProfileDir = dir: prusaLib:
    let
      entries = builtins.readDir dir;
      fileNames = lib.attrNames (lib.filterAttrs
        (name: type: type == "regular" && !(lib.hasPrefix "_" name) && lib.hasSuffix ".nix" name)
        entries);
      nameForFile = fileName: "${lib.removeSuffix ".nix" fileName} (nix)";
      loadOne = fileName:
        let
          imported = import (dir + "/${fileName}");
          value = if builtins.isFunction imported then imported { inherit prusaLib; } else imported;
        in
          lib.nameValuePair (nameForFile fileName) value;
    in
      lib.listToAttrs (map loadOne fileNames);

  # Resolves a [type:Name] section from a PrusaSlicer vendor .ini bundle,
  # following its `inherits = Parent;OtherParent` chain (child fields win).
  parseVendorIni = path:
    let
      lines = lib.splitString "\n" (builtins.readFile path);
      step = acc: line:
        let
          sectionMatch = builtins.match "\\[(.*)]" line;
          kvMatch = builtins.match "([a-zA-Z0-9_]+) = ?(.*)" line;
        in
          if sectionMatch != null then
            acc // { current = builtins.elemAt sectionMatch 0; }
          else if kvMatch != null && acc.current != null then
            acc // {
              sections = acc.sections // {
                "${acc.current}" = (acc.sections."${acc.current}" or { }) // {
                  "${builtins.elemAt kvMatch 0}" = builtins.elemAt kvMatch 1;
                };
              };
            }
          else acc;
    in
      (lib.foldl' step { current = null; sections = { }; } lines).sections;

  resolveVendorSection = sections: name:
    let
      sec = sections."${name}" or (throw "slicerProfiles: no vendor section [${name}]");
      type = builtins.elemAt (builtins.match "([a-zA-Z_]+):.*" name) 0;
      parents =
        if sec ? inherits && sec.inherits != ""
        then map (p: "${type}:${lib.strings.trim p}") (lib.splitString ";" sec.inherits)
        else [ ];
      inherited = lib.foldl' (acc: p: acc // (resolveVendorSection sections p)) { } parents;
    in
      builtins.removeAttrs (inherited // sec) [ "inherits" ];

  # Parses a flat `key = value` PrusaSlicer config dump (no [section]
  # headers) - the format `prusa-slicer --save` produces.
  parseFlatIni = path:
    let
      lines = lib.splitString "\n" (builtins.readFile path);
      step = acc: line:
        let
          kvMatch = builtins.match "([a-zA-Z0-9_]+) = ?(.*)" line;
        in
          if kvMatch == null then acc
          else acc // { "${builtins.elemAt kvMatch 0}" = builtins.elemAt kvMatch 1; };
    in
      lib.foldl' step { } lines;

  # PrusaSlicer's compiled-in defaults for every FFF option, dumped from the
  # binary itself (`--datadir <fresh dir> --save <file>`, no --load/profile
  # flags - nothing to load but its own hardcoded option definitions). Used
  # by mergeProfileLayers to catch fields that duplicate the app's default
  # even when the vendor preset doesn't set them.
  #
  # Committed as a static file (not built via a derivation) to avoid an
  # import-from-derivation. Regenerate with `prusa-slicer --datadir <fresh
  # dir> --save compiled-defaults.ini` when bumping the prusa-slicer version.
  compiledDefaults = parseFlatIni ./compiled-defaults.ini;

  # Merges profile layers (vendor preset, _base.nix, per-profile overrides)
  # like `a // b // c`, and warns (lib.warn, stderr, doesn't fail the build)
  # when a layer sets a key to a value that's dead weight - matching an
  # earlier layer, or matching PrusaSlicer's compiled-in default for a key
  # no earlier layer touched. Layers are `{ name, value, warnIfRedundant ?
  # true }`; set `warnIfRedundant = false` on layers outside this repo's
  # control (the vendor preset) so they're merged but never themselves
  # flagged - a later layer duplicating one of their fields is still
  # flagged, since that line lives in a file we do control.
  mergeProfileLayers = layers:
    let
      step = acc: { name, value, warnIfRedundant ? true }:
        let
          keys = builtins.attrNames value;
          redundantVsLayer =
            if !warnIfRedundant then [ ]
            else builtins.filter
              (k: (acc.merged ? ${k}) && (mkPrusaValue value.${k}) == (mkPrusaValue acc.merged.${k}))
              keys;
          redundantVsDefault =
            if !warnIfRedundant then [ ]
            else builtins.filter
              (k: !(acc.merged ? ${k}) && (compiledDefaults ? ${k}) && (mkPrusaValue value.${k}) == compiledDefaults.${k})
              keys;
          describeLayer = k: "${name}: `${k} = ${mkPrusaValue value.${k}}` already set to that value by an earlier layer";
          describeDefault = k: "${name}: `${k} = ${mkPrusaValue value.${k}}` is PrusaSlicer's own compiled-in default - delete, don't need to set it at all";
        in {
          merged = acc.merged // value;
          warnings = acc.warnings ++ (map describeLayer redundantVsLayer) ++ (map describeDefault redundantVsDefault);
        };
      result = lib.foldl' step { merged = { }; warnings = [ ]; } layers;
    in
      if result.warnings == [ ]
      then result.merged
      else lib.warn
        "slicerProfiles: redundant field override(s), safe to delete:\n  ${lib.concatStringsSep "\n  " result.warnings}"
        result.merged;
}
