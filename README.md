# slicer-profiles-nix
Manage Slic3r-derivative slicer profiles - printer, filament, print-quality, and anything else your slicer keeps as `.ini` - declaratively with Home Manager

## Main Features
* Import your existing PrusaSlicer profiles with one command
* Profiles as plain Nix attrsets, rendered to read-only `.ini` files
* Vendor-bundle presets via `inherits =` chain resolution
* Imports keep only what differs, layered over the slicer's compiled defaults
* Works for any Slic3r-derivative fork (PrusaSlicer, SuperSlicer, ...)

## Quick start
Already have profiles saved in PrusaSlicer (or a fork) and use Home Manager? This gets them under Nix in seven steps.

**1. Back up your profiles**
```bash
cp -r ~/.config/PrusaSlicer ~/.config/PrusaSlicer.bkp
```

**2. Add the flake input**
```nix
inputs.slicer-profiles-nix.url = "github:cpederkoff/slicer-profiles-nix";
```

**3. Import the module**
```nix
imports = [ inputs.slicer-profiles-nix.homeModules.default ];
```

**4. Scaffold the project**
```bash
mkdir -p home/slicer-profiles
cd home/slicer-profiles
nix flake init -t github:cpederkoff/slicer-profiles-nix#bare
```

**5. Generate the slicer's defaults, then import**
```bash
prusaslicer="$(nix build --no-link --print-out-paths nixpkgs#prusa-slicer)"
HOME="$(mktemp -d)" "$prusaslicer/bin/prusa-slicer" --save /tmp/prusaslicer-defaults.ini

nix run github:cpederkoff/slicer-profiles-nix#import-profiles -- \
  --config-dir ~/.config/PrusaSlicer \
  --vendor-src "$prusaslicer/share/PrusaSlicer/profiles" \
  --defaults-src /tmp/prusaslicer-defaults.ini \
  --out .
```

The first line dumps PrusaSlicer's compiled defaults from a clean `HOME`, using the same `$prusaslicer` build as `--vendor-src` so the two agree (point both at the same version if you run a different one). Then `--vendor-src` starts each profile from the matching vendor preset and `--defaults-src` drops fields left at those defaults, so a saved profile imports as just its meaningful overrides. The dropped defaults aren't lost: the importer writes a `_slicer_defaults.nix` base layer into each of `printers/`, `filaments/`, and `prints/` that every profile there composes under its vendor/`_common`/own layers, so the rendered `.ini` still carries them - just tracked against an explicit base instead of copied into every file. Both flags are optional (drop them and every field is written out explicitly).

**6. Set `configDir`**

The scaffolded `profiles.nix` ships with a placeholder. Set it to the same `~/.config` directory you've been using - `PrusaSlicer` above:
```nix
configDir = "PrusaSlicer";
```

**7. Wire it into your config**

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
