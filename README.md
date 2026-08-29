# slicer-profiles-nix
Manage Slic3r-derivative slicer profiles - printer, filament, print-quality, and anything else your slicer keeps as `.ini` - declaratively with Home Manager

## Main Features
* Profiles as plain Nix attrsets, rendered to read-only `.ini` files
* Vendor-bundle presets via `inherits =` chain resolution
* Warns on fields that redundantly repeat an earlier layer
* Works for any Slic3r-derivative fork (PrusaSlicer, SuperSlicer, ...)

## How to run
### Add as a flake input
```nix
inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";
```

### Import the module
```nix
imports = [ inputs.slicer-profiles-nix.homeModules.default ];
```

### Define a profile
```nix
slicerProfiles.configDir = "PrusaSlicer";
slicerProfiles.directories.filament."My PLA (nix)" = {
  filament_type = "PLA";
  temperature = 210;
  bed_temperature = 60;
};
```
Whole numbers can be ints; decimals must be strings (`"0.4"`, not `0.4`) - Nix's `toString` on a float corrupts it (`"0.400000"`).

### Scaffold many profiles, one file each
```
nix flake init -t github:cpederkoff/slicer-profiles-nix
```
Drop a `*.nix` file into `printers/`, `filaments/`, or `prints/` and it's picked up automatically. See [templates/default/README.md](./templates/default/README.md).

### Use a vendor-bundle preset
`vendorSrc` is any directory of `<Vendor>.ini` files - PrusaSlicer ships these in-tree under `resources/profiles`, so either a pinned checkout or the installed package works.

From the PrusaSlicer GitHub repo:
```nix
inputs.prusaslicer-src = {
  url = "github:prusa3d/PrusaSlicer";
  flake = false;
};
```
```nix
slicerLib = slicer-profiles-nix.lib.mkProfileLib {
  inherit lib;
  vendorSrc = "${inputs.prusaslicer-src}/resources/profiles";
};
```

From the installed `pkgs.prusa-slicer` package:
```nix
slicerLib = slicer-profiles-nix.lib.mkProfileLib {
  inherit lib;
  vendorSrc = "${pkgs.prusa-slicer}/share/PrusaSlicer/resources/profiles";
};
```

Either way, bundles are keyed by filename (without `.ini`):
```nix
slicerProfiles.directories.filament."My PLA (nix)" = slicerLib.mergeAttrsListAndWarn [
  (slicerLib.vendorBundles.PrusaResearch "filament:Prusament PLA")
  { bed_temperature = 65; }
];
```
Don't care about the redundancy warning? A vendor bundle is a plain attrset, so Nix's own `//` merges it just as well:
```nix
slicerProfiles.directories.filament."My PLA (nix)" =
  slicerLib.vendorBundles.PrusaResearch "filament:Prusament PLA" // { bed_temperature = 65; };
```

### Target a different slicer
```nix
slicerProfiles.configDir = "SuperSlicer";
```
`configDir` must match the directory the slicer already uses under `~/.config` (`$XDG_CONFIG_HOME`), not just its display name - check `ls ~/.config` if you're not sure what it's called.

### Run checks
```bash
nix flake check
nix fmt
```

## What this doesn't manage
* `<App>.ini` (the app's own UI preferences)
* `physical_printer/*.ini` (host + API key)
* Anything not declared in `slicerProfiles.directories`

`directories` accepts any key, so nothing stops you from pointing one at `physical_printer` yourself - not advised, since it can hold a host + API key. Let the GUI manage `physical_printer/*.ini` directly.

Declared files are read-only store symlinks - use "Save As" in the GUI to experiment, then port changes back into Nix.

## License
MIT, see [LICENSE](./LICENSE).
