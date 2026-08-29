# Rename this file (and the `name` below) to match your printer, or add
# more files alongside it - every *.nix file here becomes a printer profile.
{ slicerLib }:

{
  name = "My Printer (nix)";
  value = {
    bed_shape = "0x0,250x0,250x210,0x210";
    nozzle_diameter = "0.4";
  };
}
