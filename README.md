# slicer-profiles-nix

Manage PrusaSlicer printer/filament/print-quality profiles declaratively
with [Home Manager](https://github.com/nix-community/home-manager), instead
of hand-editing them in the GUI. Profiles are written as plain Nix
attrsets, rendered to `.ini`, and installed as read-only files at their
real PrusaSlicer paths (`~/.config/PrusaSlicer/<type>/<name>.ini` by
default). Comes with a small library for merging in vendor-bundle presets
(with `inherits =` chain resolution) and for warning about fields that
duplicate an earlier layer.

This targets PrusaSlicer's on-disk profile format specifically (flat `key
= value` ini, `printer`/`filament`/`print` subdirectories). It should work
unmodified for a fork that keeps that exact layout under a different
config directory name (see `configDir` below) - it will not work for a
slicer that uses a different profile format (e.g. OrcaSlicer/Bambu
Studio's JSON bundles).

## What this does *not* manage

- `PrusaSlicer.ini` (the app's own UI preferences) - no reason to fight
  the GUI over window positions.
- `physical_printer/*.ini` (host + API key) - so no secrets end up in a
  source-controlled repo.
- Anything not declared in `slicerProfiles.directories` - untouched,
  ordinary mutable files.

Because Nix owns the declared files as read-only store symlinks, saving
over one of them from the PrusaSlicer GUI will fail. Use "Save As" under a
new name to experiment, then hand-port anything worth keeping back into
your Nix profile definitions and rebuild.

## Usage

Add as a flake input and import the Home Manager module:

```nix
{
  inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";

  # in your home-manager module list:
  # imports = [ inputs.slicer-profiles-nix.homeManagerModules.default ];
}
```

Then declare profiles. `slicerProfiles.directories` is an attrset keyed by
output subdirectory - for PrusaSlicer that's `"printer"`/`"filament"`/
`"print"` (its own fixed convention; this module has no opinion on the
name, see [Arbitrary directories](#arbitrary-directories) below) - each of
those in turn an attrset keyed by the exact profile name PrusaSlicer
should show in its UI (this becomes the `.ini` filename), whose values are
flat attrsets of ini fields:

```nix
{
  slicerProfiles.directories.filament."My PLA (nix)" = {
    filament_type = "PLA";
    temperature = "210";
    bed_temperature = "60";
  };
}
```

INI values must be strings or ints - `temperature = 210;` works as well as
`temperature = "210";`. Decimal values still need to be strings (e.g.
`"0.4"`), since Nix's `toString` on a float would corrupt the field
(`"0.400000"`).

### Overriding the config directory

Profiles are installed via `xdg.configFile`, so they land under
`xdg.configHome` (which itself follows `$XDG_CONFIG_HOME` if you have it
set, not a hardcoded `~/.config`). If you're using a fork with a different
app/config directory name but the same on-disk profile layout, point
`configDir` elsewhere (relative to `xdg.configHome`):

```nix
{ slicerProfiles.configDir = "SuperSlicer"; }
```

The profile *contents* still need to match whatever option keys that fork
actually understands - this only changes where the files land. `configDir`
is a plain option value, not something this library computes - set it
directly for whatever app/fork you're targeting, same as any other
profile field (see [Profiles spread across files](#profiles-spread-across-files)
below for scanning a whole directory of profile files at once).

### Profiles spread across files

`lib.mkProfileLib` exposes the same ini tooling the module uses internally
(`toSlic3rIni`, `mergeAttrsListAndWarn`, ...) for keeping one file per
profile without any filename-derived naming - it has no opinion on
directory-scanning conventions (see below). A profile file is just
`{ name; value; }` - the shape `builtins.listToAttrs` wants - built with
`mergeAttrsListAndWarn`, entirely self-contained:

```nix
# printers/my-printer.nix - name and location are unrelated; put it anywhere
{ slicerLib }:

{
  name = "My Printer (nix)"; # exactly what shows up in the slicer's UI
  value = slicerLib.mergeAttrsListAndWarn [ { nozzle_diameter = "0.4"; } ];
}
```

`mergeAttrsListAndWarn` merges its list like `lib.mergeAttrsList` (`a // b
// c`, later wins), but also warns via `lib.warn` - doesn't fail the build
- when a later attrset in the list sets a field to a value that's already
set by an earlier one.

Notice this never says whether it's a printer, filament, or print-quality
profile - that's not a property of the profile, it's a property of *where
you put it*: which key under `slicerProfiles.directories` a file's result
ends up in is entirely up to you, the caller. Wire files together
explicitly if you want full control over the list:

```nix
{ lib, ... }:
let
  slicerLib = slicer-profiles-nix.lib.mkProfileLib { inherit lib; };
  args = { inherit slicerLib; };
in
{
  slicerProfiles.directories.printer = builtins.listToAttrs [
    (import ./somewhere/my-printer.nix args)
    # ...
  ];
}
```

...or scan a directory for them yourself - this isn't library code, just
plain `builtins.readDir`, small enough to own and adjust rather than call
through a fixed function:

```nix
{ lib, ... }:
let
  slicerLib = slicer-profiles-nix.lib.mkProfileLib { inherit lib; };
  args = { inherit slicerLib; };

  # Every *.nix file directly in `dir` becomes a profile - add a file,
  # it's picked up, no line to add anywhere. Not recursive: fields shared
  # across profiles in the same directory (e.g. everything all your
  # printers have in common) belong in a subdirectory instead, `import`ed
  # by relative path from whichever profile files need them. To skip
  # files that aren't profiles themselves (e.g. a conventional `_base.nix`
  # of shared fields kept alongside instead), add a name check to the
  # filter below.
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
  slicerProfiles.directories = {
    printer = builtins.listToAttrs (scanDir ./printers);
    filament = builtins.listToAttrs (scanDir ./filaments);
    print = builtins.listToAttrs (scanDir ./prints);
  };
}
```

Scan one directory per `slicerProfiles.directories` key - which directory
you scan *is* which subdirectory a profile ends up under.

### Arbitrary directories

`slicerProfiles.directories` doesn't know "printer"/"filament"/"print" are
special - they're just the three subdirectory names PrusaSlicer itself
understands. The option is a plain `attrsOf (attrsOf profileFields)`; any
key works, and becomes a literal subdirectory under `configDir`. This
matters if you're targeting a fork with a different (or additional)
on-disk layout - nothing here needs to change, you just use different
keys.

If you don't need any of this - just a couple of profiles, no vendor
bundle - the direct attrset form from the Usage section above is simpler;
these are for when you have enough profiles that spreading them across
files is worth it.

### Vendor-bundle presets

`mkVendorBundle`/`mkVendorBundles` (in `lib.nix`, exposed through
`lib.mkProfileLib`) are fully generic - they know nothing about
PrusaSlicer, just how to parse a directory of `<Vendor>.ini` files and
resolve a `type:Name` section from one (`inherits =` chains and all).
Pass a vendor bundle directory as `vendorSrc` and `mkProfileLib` attaches
the parsed bundles at `slicerLib.vendorBundles` for you (continuing the
same `scanDir` helper from [Profiles spread across files](#profiles-spread-across-files)
above):

```nix
{ lib, ... }:
let
  slicerLib = slicer-profiles-nix.lib.mkProfileLib {
    inherit lib;
    # Two common choices for vendorSrc - both just a directory of
    # <Vendor>.ini files, no code-level distinction between them:
    #   - a pin of PrusaSlicer's own source tree (or a fork's), reproducible,
    #     independent of whatever prusa-slicer version is actually installed
    #     (flake = false: source tree only, not evaluated as its own flake):
    #     "${prusaslicer-profiles}/resources/profiles"
    #   - whatever bundles ship with the PrusaSlicer actually installed on
    #     this machine - no separate pin to keep in sync, but drifts with
    #     whatever package version you have:
    #     "${pkgs.prusa-slicer}/share/PrusaSlicer/profiles"
    vendorSrc = "${prusaslicer-profiles}/resources/profiles";
  };
  args = { inherit slicerLib; };
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
  slicerProfiles = {
    configDir = "PrusaSlicer";
    directories.filament = builtins.listToAttrs (scanDir ./filaments);
    directories.printer = builtins.listToAttrs (scanDir ./printers);
  };
}
```

`vendorSrc` is optional - omit it and `slicerLib` just doesn't get a
`vendorBundles` attribute, for programs/setups with no vendor bundle to
pull from.

```nix
# filaments/pla.nix
{ slicerLib }:
{
  name = "My PLA (nix)";
  value = slicerLib.mergeAttrsListAndWarn [
    (slicerLib.vendorBundles.PrusaResearch "filament:Prusament PLA")
    { bed_temperature = "65"; }
  ];
}
```

Each entry in `vendorBundles` (keyed without the extension, e.g.
`vendorBundles.PrusaResearch`) is a lazy per-key thunk, not a fresh
computation - it only gets parsed the first time *any* profile file
actually reads it, and every file shares that same parsed result (they're
all looking at the same `vendorBundles` attrset). Calling
`slicerLib.mkVendorBundle "PrusaResearch.ini"` yourself instead re-parses
the file every time - `vendorBundles` exists so you don't have to.

Profile files can build on each other the same way they build on a vendor
bundle - a profile's rendered `.value` is just an ini-field attrset, so it
slots into another profile's merge list the same way any other layer does:

```nix
# prints/0.2mm.nix
{ slicerLib }:
{
  name = "0.2mm (nix)";
  value = slicerLib.mergeAttrsListAndWarn [ { layer_height = "0.2"; } ];
}
```

```nix
# prints/coarse.nix - builds on 0.2mm.nix rather than starting over
{ slicerLib }:
{
  name = "coarse (nix)";
  value = slicerLib.mergeAttrsListAndWarn [
    (import ./0.2mm.nix { inherit slicerLib; }).value
    { fill_density = "10%"; }
  ];
}
```

Every attrset in the list is checked for redundancy against what came
before it, including this one - here that's a no-op since it's first
(nothing to be redundant against yet). If you ever need to build on a
profile that *isn't* first in the list, merge it in as a floor instead of
putting it in the list, so it's not checked at all:
`base.value // slicerLib.mergeAttrsListAndWarn [ own1 own2 ]`.

See this repo's own `lib.nix` for the full generic function list
(`toSlic3rIni`, `parseVendorIni`, `resolveVendorSection`, `mkVendorBundle`,
etc.) - exposed through `lib.mkProfileLib`.

## Development

`nix flake check` runs the module-evaluation smoke test plus a fixture
test of the ini/vendor-parsing/merge logic (CRLF line endings, `inherits =`
resolution, `key=value` with no space before `=`). `nix fmt` formats with
`nixfmt`. Both run in CI on push.

## License

MIT, see [LICENSE](./LICENSE).
