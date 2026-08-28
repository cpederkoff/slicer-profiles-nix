# slicer-profiles-nix

Manage PrusaSlicer printer/filament/print-quality profiles declaratively
with [Home Manager](https://github.com/nix-community/home-manager), instead
of hand-editing them in the GUI. Profiles are written as plain Nix
attrsets, rendered to `.ini`, and installed as read-only files at their
real PrusaSlicer paths (`~/.config/PrusaSlicer/<type>/<name>.ini` by
default). Comes with a small library for merging in vendor-bundle presets
(with `inherits =` chain resolution) and for warning about fields that
duplicate an earlier layer or PrusaSlicer's own compiled-in default.

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
- Anything not declared in `slicerProfiles.{printers,filaments,prints}` -
  untouched, ordinary mutable files.

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

Then declare profiles. Each of `slicerProfiles.printers`,
`slicerProfiles.filaments`, `slicerProfiles.prints` is an attrset keyed by
the exact profile name PrusaSlicer should show in its UI (this becomes the
`.ini` filename), whose values are flat attrsets of ini fields:

```nix
{
  slicerProfiles.filaments."My PLA (nix)" = {
    filament_type = "PLA";
    temperature = 210;
    bed_temperature = 60;
  };
}
```

INI values must be `int` or `str` - author floats/bools as strings (e.g.
`"0.4"`, `"1"`) since Nix's `toString` on a float would corrupt the field
(`"0.400000"`).

### Overriding the config directory

If you're using a fork with a different app/config directory name but the
same on-disk profile layout, point `configDir` elsewhere (relative to
`$HOME`):

```nix
{ slicerProfiles.configDir = ".config/SuperSlicer"; }
```

The profile *contents* still need to match whatever option keys that fork
actually understands - this only changes where the files land.

### Vendor-bundle presets

`lib.mkProfileLib` exposes the same ini/vendor tooling the module uses
internally, for building profiles that start from an upstream vendor
bundle (e.g. PrusaSlicer's own `resources/profiles/*.ini`) instead of from
scratch:

```nix
{ lib, ... }:
let
  slicerLib = slicer-profiles-nix.lib.mkProfileLib { inherit lib; };

  # A PrusaSlicer vendor bundle, e.g. from a pin of prusa3d/PrusaSlicer's
  # source tree (resources/profiles/<Vendor>.ini).
  vendorSections = slicerLib.parseVendorIni ./vendor/PrusaResearch.ini;

  myFilament = slicerLib.mergeProfileLayers [
    { name = "vendor (Prusament PLA)";
      value = slicerLib.resolveVendorSection vendorSections "filament:Prusament PLA";
      warnIfRedundant = false; # not a layer we control - never flag it
    }
    { name = "my overrides"; value = { bed_temperature = 65; }; }
  ];
in
{
  slicerProfiles.filaments."My PLA (nix)" = myFilament;
}
```

`mergeProfileLayers` warns (via `lib.warn`, doesn't fail the build) when a
later layer sets a field to a value that's already set by an earlier
layer, or that matches PrusaSlicer's own compiled-in default for a field
no earlier layer touched (see `compiled-defaults.ini` - regenerate it with
`prusa-slicer --datadir <fresh dir> --save compiled-defaults.ini` if you
bump the PrusaSlicer version and want the default-matching check to stay
accurate).

`importProfileDir dir slicerLib` auto-registers every non-`_`-prefixed
`.nix` file in a directory as a profile (filename minus `.nix`, plus `"
(nix)"`) - handy for keeping one file per printer/filament/print instead
of one big attrset. See this repo's own `default.nix`/`lib.nix` for the
full function list (`toPrusaIni`, `parseFlatIni`, `resolveVendorSection`,
etc.) - all are exposed through `lib.mkProfileLib`.

## License

MIT, see [LICENSE](./LICENSE).
