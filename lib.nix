{ lib }:

# Generic Slic3r-derivative ini tooling. No app/vendor/printer assumptions.
# `let ... in { }`, not `rec { }` - overriding one returned field can't
# silently change what another field calls internally.
let
  # No floats - Nix's toString mangles them ("0.400000"); author those as
  # strings. Ints are fine, toString on an int is exact.
  mkIniValue =
    v:
    if builtins.isString v then
      # A real newline breaks the flat "key = value" ini - gcode newlines
      # must be authored as a literal "\n" (backslash-n, two chars), the way
      # PrusaSlicer writes them. Catch the mistake here instead of silently
      # emitting a corrupt profile.
      if lib.hasInfix "\n" v then
        throw "slicer-profiles-nix: value contains a real newline - gcode newlines must be a literal \"\\n\" (two chars, e.g. \"G28\\nG1 Z5\"), not an actual line break; got: ${v}"
      else
        v
    else if builtins.isInt v then
      toString v
    else
      throw "slicer-profiles-nix: values must be a string or int (e.g. \"0.4\", 1); got ${builtins.typeOf v}";

  toSlic3rIni =
    attrs: lib.concatStrings (lib.mapAttrsToList (k: v: "${k} = ${mkIniValue v}\n") attrs);

  # Resolves a [type:Name] section from a vendor .ini bundle, following its
  # `inherits = Parent;Other` chain. Tolerates CRLF and "key=value" (no space).
  parseVendorIni =
    path:
    let
      lines = lib.splitString "\n" (builtins.replaceStrings [ "\r" ] [ "" ] (builtins.readFile path));
      step =
        acc: line:
        let
          sectionMatch = builtins.match "\\[(.*)]" line;
          kvMatch = builtins.match "([a-zA-Z0-9_]+) ?= ?(.*)" line;
        in
        if sectionMatch != null then
          acc // { current = builtins.elemAt sectionMatch 0; }
        else if kvMatch != null && acc.current != null then
          acc
          // {
            sections = acc.sections // {
              "${acc.current}" = (acc.sections."${acc.current}" or { }) // {
                "${builtins.elemAt kvMatch 0}" = builtins.elemAt kvMatch 1;
              };
            };
          }
        else
          acc;
    in
    (lib.foldl' step {
      current = null;
      sections = { };
    } lines).sections;

  resolveVendorSection =
    sections: name:
    let
      sec = sections."${name}" or (throw "slicer-profiles-nix: no vendor section [${name}]");
      type = builtins.elemAt (builtins.match "([a-zA-Z_]+):.*" name) 0;
      parents =
        if sec ? inherits && sec.inherits != "" then
          map (p: "${type}:${lib.strings.trim p}") (lib.splitString ";" sec.inherits)
        else
          [ ];
      inherited = lib.foldl' (acc: p: acc // (resolveVendorSection sections p)) { } parents;
    in
    builtins.removeAttrs (inherited // sec) [ "inherits" ];

  # Loads one vendor bundle file; returns a lookup fn, e.g.
  # `bundle "filament:Esun ABS"`, mirroring the ini's own [filament:...] syntax.
  mkVendorBundle =
    vendorSrc: vendorFileName: resolveVendorSection (parseVendorIni "${vendorSrc}/${vendorFileName}");

  # Every "<Vendor>.ini" under vendorSrc, keyed without the extension.
  # Lazily shared, so each bundle parses at most once no matter how many
  # profile files read it - mkVendorBundle alone reparses every time.
  mkVendorBundles =
    vendorSrc:
    lib.mapAttrs'
      (
        fileName: _:
        lib.nameValuePair (lib.removeSuffix ".ini" fileName) (mkVendorBundle vendorSrc fileName)
      )
      (
        lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".ini" name) (
          builtins.readDir vendorSrc
        )
      );

  # Like lib.mergeAttrsList, but warns (doesn't fail) when a later attrset
  # redundantly repeats an earlier value. To skip the check on content you
  # don't control, merge it in as a floor instead of putting it in the list:
  # `base.value // mergeAttrsListAndWarn [ own1 own2 ]`.
  mergeAttrsListAndWarn =
    layers:
    let
      step =
        acc: value:
        let
          keys = builtins.attrNames value;
          redundantVsLayer = builtins.filter (
            k: (acc.merged ? ${k}) && (mkIniValue value.${k}) == (mkIniValue acc.merged.${k})
          ) keys;
          describeLayer =
            k: "`${k} = ${mkIniValue value.${k}}` already set to that value by an earlier layer";
        in
        {
          merged = acc.merged // value;
          warnings = acc.warnings ++ (map describeLayer redundantVsLayer);
        };
      result = lib.foldl' step {
        merged = { };
        warnings = [ ];
      } layers;
    in
    if result.warnings == [ ] then
      result.merged
    else
      lib.warn "slicer-profiles-nix: redundant field override(s), safe to delete:\n  ${lib.concatStringsSep "\n  " result.warnings}" result.merged;
in
{
  inherit
    mkIniValue
    toSlic3rIni
    parseVendorIni
    resolveVendorSection
    mkVendorBundle
    mkVendorBundles
    mergeAttrsListAndWarn
    ;
}
