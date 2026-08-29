# slicer-profiles-nix

[![check](https://github.com/cpederkoff/slicer-profiles-nix/actions/workflows/check.yml/badge.svg)](https://github.com/cpederkoff/slicer-profiles-nix/actions/workflows/check.yml)

Manage Slic3r-derivative slicer profiles - printer, filament, print-quality,
and any other flat `key = value` `.ini` profile your slicer reads -
declaratively with [Home Manager](https://github.com/nix-community/home-manager),
instead of hand-editing them in the GUI.

Profiles are plain Nix attrsets, rendered to `.ini`, and installed as
read-only files under `~/.config/<configDir>/<directory>/<name>.ini`. Built
against PrusaSlicer; works unmodified for any fork with the same on-disk
layout (SuperSlicer, etc.) under a different `configDir`. Won't work for
slicers with a different profile format (e.g. OrcaSlicer/Bambu Studio's
JSON bundles).

## Installation

```nix
{
  inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";
}
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.slicer-profiles-nix.homeModules.default ];
}
```

## Usage

### One profile, inline

```nix
{
  slicerProfiles.configDir = "PrusaSlicer";
  slicerProfiles.directories.filament."My PLA (nix)" = {
    filament_type = "PLA";
    temperature = "210";
    bed_temperature = "60";
  };
}
```

`directories` is keyed by output subdirectory - `printer`/`filament`/`print`
by convention, but [any name your slicer uses works](#arbitrary-directories)
- then by the exact profile name shown in the UI. Field values must be
strings or ints; write decimals as strings (`"0.4"`, not `0.4`) since Nix's
`toString` on a float corrupts it (`"0.400000"`).

### Many profiles, one file each

```
nix flake init -t github:cpederkoff/slicer-profiles-nix
```

scaffolds `profiles.nix` plus `printers/`, `filaments/`, `prints/`
directories that get scanned for `*.nix` files - drop a file in, it's
picked up, nothing to register elsewhere. See
[templates/default/README.md](./templates/default/README.md).

### Vendor-bundle presets

Pull a stock profile out of a slicer's bundled `<Vendor>.ini` (`inherits =`
chains resolved) and layer your own overrides on top:

```nix
{ lib, ... }:
let
  slicerLib = slicer-profiles-nix.lib.mkProfileLib {
    inherit lib;
    # A directory of "<Vendor>.ini" files - a pinned source tree, or
    # whatever profiles ship with the installed package.
    vendorSrc = "${vendor-profiles}/resources/profiles";
  };
in
{
  slicerProfiles.configDir = "PrusaSlicer";
  slicerProfiles.directories.filament."My PLA (nix)" = slicerLib.mergeAttrsListAndWarn [
    (slicerLib.vendorBundles.SomeVendor "filament:Some Vendor PLA")
    { bed_temperature = "65"; }
  ];
}
```

`mergeAttrsListAndWarn` merges like `a // b // c` (later wins), but warns
via `lib.warn` - without failing the build - when a later layer redundantly
repeats a value an earlier one already set.

### A different fork

```nix
{ slicerProfiles.configDir = "SuperSlicer"; }
```

`configDir` is a path relative to `xdg.configHome` - point it at whatever
app directory name the fork uses.

## What this doesn't manage

- `<App>.ini` (the app's own UI preferences)
- `physical_printer/*.ini` (host + API key - keeps secrets out of the repo)
- Anything not declared in `slicerProfiles.directories`

Declared files are read-only store symlinks, so saving over one from the
GUI fails - use "Save As" to experiment, then port changes back into Nix.

## Advanced

### Arbitrary directories

`directories` keys are literal subdirectories under `configDir` -
`printer`/`filament`/`print` aren't special, just the names most
Slic3r-derivative apps use. Any key works.

### Layering profiles

A profile's rendered `.value` is a plain ini-field attrset, so it composes
into another profile's `mergeAttrsListAndWarn` list the same way a vendor
bundle does - useful for e.g. a `coarse` print profile built on a `0.2mm`
one instead of starting over.

### Library internals

`lib.mkProfileLib` exposes `toSlic3rIni`, `parseVendorIni`,
`resolveVendorSection`, `mkVendorBundle`, `mkVendorBundles`, and
`mergeAttrsListAndWarn`; see [lib.nix](./lib.nix).

## Development

`nix flake check` runs the module-evaluation smoke test plus a fixture
test of the ini/vendor-parsing/merge logic (CRLF line endings, `inherits =`
resolution, `key=value` with no space before `=`). `nix fmt` formats with
`nixfmt`. Both run in CI on push.

## License

MIT, see [LICENSE](./LICENSE).
