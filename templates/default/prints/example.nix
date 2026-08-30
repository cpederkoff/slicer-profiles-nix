# Rename this file (and `name`) to match your print profile; every *.nix file
# here becomes one.
{ slicerLib }:

{
  name = "0.2mm (nix)";
  value = {
    layer_height = "0.2";
  };

  # With vendorSrc set (see the main README), layer a vendor preset and this
  # directory's _common.nix instead of a bare attrset:
  # value = slicerLib.mergeAttrsListAndWarn [
  #   (slicerLib.vendorBundles.<Vendor> "print:<Name>")
  #   (import ./_common.nix)
  #   { layer_height = "0.2"; }
  # ];
}
