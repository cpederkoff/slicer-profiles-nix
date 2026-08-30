{ lib }:

# Generic Slic3r-derivative ini tooling; no app/vendor/printer assumptions.
# Uses `let ... in { }`, not `rec { }`: overriding a returned field MUST NOT
# change what another field calls internally.
let
  # Callers MUST author decimals as strings, not floats. Nix's toString
  # mangles floats ("0.400000"); on an int it is exact.
  mkIniValue =
    v:
    if builtins.isString v then
      # Gcode newlines MUST be a literal "\n" (two chars), as PrusaSlicer
      # writes them. A real newline breaks the flat "key = value" ini.
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

  # Parse a vendor .ini to `{ section = { key = value; }; }`. Tolerates CRLF
  # and "key=value" (no spaces).
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

  # Resolve a [type:Name] section, following its `inherits = Parent;Other`
  # chain. Parents resolve first; own fields win.
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

  # Load one bundle file; return a section lookup, e.g.
  # `bundle "filament:Esun ABS"`.
  mkVendorBundle =
    vendorSrc: vendorFileName: resolveVendorSection (parseVendorIni "${vendorSrc}/${vendorFileName}");

  # Every "<Vendor>.ini" under vendorSrc, keyed without the extension. Lazily
  # shared: each bundle parses at most once, however many profiles read it
  # (mkVendorBundle alone reparses every call).
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
in
{
  inherit
    mkIniValue
    toSlic3rIni
    parseVendorIni
    resolveVendorSection
    mkVendorBundle
    mkVendorBundles
    ;
}
