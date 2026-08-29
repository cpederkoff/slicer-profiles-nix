# slicer-profiles-nix
Manage Slic3r-derivative slicer profiles - printer, filament, print-quality, and anything else your slicer keeps as `.ini` - declaratively with Home Manager

## Main Features
* Import your existing PrusaSlicer profiles with one command
* Profiles as plain Nix attrsets, rendered to read-only `.ini` files
* Vendor-bundle presets via `inherits =` chain resolution
* Warns on fields that redundantly repeat an earlier layer
* Works for any Slic3r-derivative fork (PrusaSlicer, SuperSlicer, ...)

## Quick start
Already have profiles saved in PrusaSlicer (or a fork) and use Home Manager? This gets them under Nix in four steps.

**1. Add the flake input**
```nix
inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";
```

**2. Import the module**
```nix
imports = [ inputs.slicer-profiles-nix.homeModules.default ];
```

**3. Back up, scaffold, and import**
```bash
cp -r ~/.config/PrusaSlicer ~/.config/PrusaSlicer.bkp
mkdir -p home/slicer-profiles 
cd home/slicer-profiles
nix flake init -t github:cpederkoff/slicer-profiles-nix
nix run github:cpederkoff/slicer-profiles-nix#import-profiles -- \
  --config-dir ~/.config/PrusaSlicer.bkp \
  --vendor-src "$(nix build --no-link --print-out-paths nixpkgs#prusa-slicer)/share/PrusaSlicer/profiles" \
  --out .
```

**4. Wire it into your config**

The flake needs to be in scope of the module that uses it. The simplest way is to reference `inputs` directly, which Home Manager passes to your modules when you use `extraSpecialArgs` (or `specialArgs` under a NixOS `home-manager.users.*`). If `inputs` isn't already threaded through, add `extraSpecialArgs = { inherit inputs; };` where you call `home-manager.lib.homeManagerConfiguration` (or set it on the NixOS module).

```nix
{ lib, pkgs, inputs, ... }:
let
  slicer-profiles-nix = inputs.slicer-profiles-nix;
  slicerLib = slicer-profiles-nix.lib.mkProfileLib {
    inherit lib;
    vendorSrc = "${pkgs.prusa-slicer}/share/PrusaSlicer/profiles";
  };
in
{
  imports = [ slicer-profiles-nix.homeModules.default ];
  slicerProfiles = import ./home/slicer-profiles/profiles.nix { inherit lib slicerLib; };
}
```

Run `home-manager switch` and reopen your slicer - your profiles are there under their old names, now rendered as read-only files. See [What this doesn't manage](#what-this-doesnt-manage) before you delete the backup.

## Other ways to use this
### Generate the scaffold without importing
No existing profiles, or want to start clean? Skip `import-profiles` and scaffold on its own:
```bash
nix flake init -t github:cpederkoff/slicer-profiles-nix
```
Drop a `*.nix` file into `printers/`, `filaments/`, or `prints/` and it's picked up automatically. See [templates/default/README.md](./templates/default/README.md).

### Use vendor bundles from GitHub
Quick start pointed `--vendor-src`/`vendorSrc` at an installed `pkgs.prusa-slicer`. Pin the profiles straight from the PrusaSlicer GitHub repo instead - no need to build or fetch the whole app, and the version is pinned independent of nixpkgs:
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
Either source works the same once wired in - bundles are keyed by filename (without `.ini`):
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

### Use a different slicer
```nix
slicerProfiles.configDir = "SuperSlicer";
```
`configDir` must match the directory the slicer already uses under `~/.config` (`$XDG_CONFIG_HOME`), not just its display name - check `ls ~/.config` if you're not sure what it's called.

### Write profiles from scratch
```nix
slicerProfiles.configDir = "PrusaSlicer";
slicerProfiles.directories.filament."My PLA (nix)" = {
  filament_type = "PLA";
  temperature = 210;
  bed_temperature = 60;
};
```
Whole numbers can be ints; decimals must be strings (`"0.4"`, not `0.4`) - Nix's `toString` on a float corrupts it (`"0.400000"`).

## What this doesn't manage
* `<App>.ini` (the app's own UI preferences)
* `physical_printer/*.ini` (host + API key)
* Anything not declared in `slicerProfiles.directories`

`directories` accepts any key, so nothing stops you from pointing one at `physical_printer` yourself - not advised, since it can hold a host + API key. Let the GUI manage `physical_printer/*.ini` directly.

Declared files are read-only store symlinks - use "Save As" in the GUI to experiment, then port changes back into Nix.

## Development
```bash
nix flake check
nix fmt
```

## License
MIT, see [LICENSE](./LICENSE).
