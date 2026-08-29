# Rename this file (and the `name` below) to match your print profile, or
# add more files alongside it - every *.nix file here becomes one.
{ slicerLib }:

{
  name = "0.2mm (nix)";
  value = slicerLib.mergeAttrsListAndWarn [ { layer_height = "0.2"; } ];
}
