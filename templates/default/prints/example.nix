# Rename this file (and the `name` below) to match your print profile, or
# add more files alongside it - every *.nix file here becomes one.
{ slicerLib }:

{
  name = "0.2mm (nix)";
  value = {
    layer_height = "0.2";
  };

  # Once vendorSrc is set (see the main README's "Use a vendor-bundle
  # preset"), start from a vendor profile plus this directory's shared
  # _common.nix instead of a bare attrset:
  # value = slicerLib.mergeAttrsListAndWarn [
  #   (slicerLib.vendorBundles.<Vendor> "print:<Name>")
  #   (import ./_common.nix)
  #   { layer_height = "0.2"; }
  # ];
}
