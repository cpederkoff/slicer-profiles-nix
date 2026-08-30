# slicer-profiles-nix
Manage Slic3r-derivative slicer profiles - printer, filament, print-quality, and anything else your slicer keeps as `.ini` - declaratively with Home Manager

## Main Features
* Import your existing PrusaSlicer profiles with one command
* Profiles as plain Nix attrsets, rendered to read-only `.ini` files
* Vendor-bundle presets via `inherits =` chain resolution
* Imports keep only what differs, layered over the slicer's compiled defaults
* Works for any Slic3r-derivative fork (PrusaSlicer, SuperSlicer, ...)

## Quick start
Have profiles saved in PrusaSlicer (or another Slic3r fork like SuperSlicer) and use Home Manager? Manage them declaritively with nix!

**1. Back up your profiles**
```bash
cp -r ~/.config/PrusaSlicer ~/.config/PrusaSlicer.bkp
```

**2. Scaffold the project**
```bash
mkdir -p home/slicer-profiles
cd home/slicer-profiles
nix flake init -t github:cpederkoff/slicer-profiles-nix#bare
```

**3. Generate the slicer's defaults, then import**
```bash
prusaslicer="$(nix build --no-link --print-out-paths nixpkgs#prusa-slicer)"

# Dump the slicer's raw compiled defaults.
HOME="$(mktemp -d)" "$prusaslicer/bin/prusa-slicer" --save /tmp/prusaslicer-defaults.ini

# Convert your saved profiles into the scaffold's .nix files, keeping only what
# differs from the vendor preset (--vendor-src) and defaults (--defaults-src).
nix run github:cpederkoff/slicer-profiles-nix#import-profiles -- \
  --config-dir ~/.config/PrusaSlicer \
  --vendor-src "$prusaslicer/share/PrusaSlicer/profiles" \
  --defaults-src /tmp/prusaslicer-defaults.ini \
  --out .
```

**4. Set `configDir`**

The scaffolded `profiles.nix` ships with a placeholder. Set it to the same `~/.config` directory you've been using - `PrusaSlicer` above:
```nix
configDir = "PrusaSlicer";
```

**5. Add the flake input**
```nix
inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";
```

**6. Wire it into your config**

```nix
# Needs `inputs` in scope - thread it in via Home Manager's
# `extraSpecialArgs = { inherit inputs; }` (or `specialArgs` under NixOS).
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

Run `home-manager switch` and reopen your slicer - your profiles are there, each suffixed with ` (nix)` so it sits alongside the original rather than clobbering it, now rendered as read-only files. See [What this doesn't manage](#what-this-doesnt-manage) before you delete the backup.

## Other ways to use this
### Generate the scaffold without importing
No existing profiles, or want to start clean? Skip `import-profiles` and scaffold on its own. The default template ships one example profile in each of `printers/`, `filaments/`, and `prints/`:
```bash
nix flake init -t github:cpederkoff/slicer-profiles-nix
```
Drop a `*.nix` file into `printers/`, `filaments/`, or `prints/` and it's picked up automatically; delete the examples you don't need. See [templates/default/README.md](./templates/default/README.md). (The import flow uses the `#bare` variant, which omits the examples.)

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
Either source works the same once wired in - bundles are keyed by filename (without `.ini`). A vendor bundle is a plain attrset, so compose it with Nix's own `//` (later layers win, so your overrides sit on the right):
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
