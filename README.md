# slicer-profiles-nix
Manage Slic3r-derivative slicer profiles - printer, filament, print-quality, and anything else your slicer keeps as `.ini` - declaratively with Home Manager

## Main Features
* Profiles as plain Nix attrsets, rendered to read-only `.ini` files
* Vendor-bundle presets via `inherits =` chain resolution
* Warns (without failing the build) on fields that redundantly repeat an earlier layer
* Works for any Slic3r-derivative fork (PrusaSlicer, SuperSlicer, ...) under a different `configDir`

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
  temperature = "210";
  bed_temperature = "60";
};
```
Decimals must be strings (`"0.4"`, not `0.4`) - Nix's `toString` on a float corrupts it (`"0.400000"`).

### Scaffold many profiles, one file each
```
nix flake init -t github:cpederkoff/slicer-profiles-nix
```
Drop a `*.nix` file into `printers/`, `filaments/`, or `prints/` and it's picked up automatically. See [templates/default/README.md](./templates/default/README.md).

### Use a vendor-bundle preset
```nix
slicerLib = slicer-profiles-nix.lib.mkProfileLib {
  inherit lib;
  vendorSrc = "${vendor-profiles}/resources/profiles"; # a directory of "<Vendor>.ini" files
};
```
```nix
slicerProfiles.directories.filament."My PLA (nix)" = slicerLib.mergeAttrsListAndWarn [
  (slicerLib.vendorBundles.SomeVendor "filament:Some Vendor PLA")
  { bed_temperature = "65"; }
];
```

### Target a different fork
```nix
slicerProfiles.configDir = "SuperSlicer";
```

### Run checks
```bash
nix flake check
nix fmt
```

## What this doesn't manage
* `<App>.ini` (the app's own UI preferences)
* `physical_printer/*.ini` (host + API key - keeps secrets out of the repo)
* Anything not declared in `slicerProfiles.directories`

Declared files are read-only store symlinks - use "Save As" in the GUI to experiment, then port changes back into Nix.

## License
MIT, see [LICENSE](./LICENSE).
