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
}
