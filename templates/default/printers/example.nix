# Rename this file (and `name`) to match your printer; every *.nix file here
# becomes a printer profile.
{ slicerLib }:

{
  name = "My Printer (nix)";
  value = {
    bed_shape = "0x0,250x0,250x210,0x210";
    nozzle_diameter = "0.4";
  };

  # With vendorSrc set (see the main README), compose a vendor preset and this
  # directory's _common.nix with `//` (later layers win) instead of a bare
  # attrset:
  # value =
  #   (slicerLib.vendorBundles.<Vendor> "printer:<Name>")
  #   // (import ./_common.nix)
  #   // { nozzle_diameter = "0.4"; };
}
