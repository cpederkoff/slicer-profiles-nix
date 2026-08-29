# Rename this file (and the `name` below) to match your filament, or add
# more files alongside it - every *.nix file here becomes a filament profile.
{ slicerLib }:

{
  name = "My PLA (nix)";
  value = {
    filament_type = "PLA";
    temperature = "210";
    bed_temperature = "60";
  };

  # Once vendorSrc is set (see the main README's "Use a vendor-bundle
  # preset"), start from a vendor profile plus this directory's shared
  # _common.nix instead of a bare attrset:
  # value = slicerLib.mergeAttrsListAndWarn [
  #   (slicerLib.vendorBundles.<Vendor> "filament:<Name>")
  #   (import ./_common.nix)
  #   { bed_temperature = "60"; }
  # ];
}
