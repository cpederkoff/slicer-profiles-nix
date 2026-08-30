# Rename this file (and `name`) to match your filament; every *.nix file here
# becomes a filament profile.
{ slicerLib }:

{
  name = "My PLA (nix)";
  value = {
    filament_type = "PLA";
    temperature = "210";
    bed_temperature = "60";
  };

  # With vendorSrc set (see the main README), layer a vendor preset and this
  # directory's _common.nix instead of a bare attrset:
  # value = slicerLib.mergeAttrsListAndWarn [
  #   (slicerLib.vendorBundles.<Vendor> "filament:<Name>")
  #   (import ./_common.nix)
  #   { bed_temperature = "60"; }
  # ];
}
