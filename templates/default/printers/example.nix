# Rename this file (and the `name` below) to match your printer, or add
# more files alongside it - every *.nix file here becomes a printer profile.
{ slicerLib }:

{
  name = "My Printer (nix)";
  value = {
    bed_shape = "0x0,250x0,250x210,0x210";
    nozzle_diameter = "0.4";
  };

  # Once vendorSrc is set (see the main README's "Use a vendor-bundle
  # preset"), start from a vendor profile plus this directory's shared
  # _common.nix instead of a bare attrset:
  # value = slicerLib.mergeAttrsListAndWarn [
  #   (slicerLib.vendorBundles.<Vendor> "printer:<Name>")
  #   (import ./_common.nix)
  #   { nozzle_diameter = "0.4"; }
  # ];
}
