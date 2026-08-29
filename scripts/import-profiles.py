"""Port PrusaSlicer-format user profiles into this project's per-file Nix layout.

Each source "<type>/<Name>.ini" file becomes "<outdir>/<name>.nix" with a
`{ slicerLib }: { name; value; }` shape (matching templates/default/) so it
drops straight into a scaffold's printers/filaments/prints directories.

Profiles are ported as fully flattened field lists, not diffed against a
vendor bundle - PrusaSlicer already writes every field explicit in each
saved profile, `inherits` included, so flattening is always correct even
if the referenced parent isn't ported too. When a source profile has an
`inherits`, the generated file also gets a commented hint pointing at the
real mergeAttrsListAndWarn shape (a vendorBundles lookup plus this
directory's shared "_common.nix") - left commented because applying it
would mean diffing the flattened fields against a specific vendor bundle
version, which the importer won't guess at. If --vendor-src is given (a
directory of <Vendor>.ini files, same shape as the Nix side's vendorSrc),
the hint's `<Vendor>` placeholder gets filled in with the real vendor name
whenever exactly one vendor file has a "[type:inherits-value]" section
matching it - PrusaSlicer's own saved profiles don't record which vendor
bundle they came from, so this is a best-effort search, not a guarantee.
Each output directory also gets an empty "_common.nix" stub (skipped by
scanDir, kept only if missing) - move whatever fields turn out to be
shared across sibling profiles into it by hand.
"""

import argparse
import re
import sys
from pathlib import Path

# source subdirectory (under configDir) -> output subdirectory, matching the
# flake template's printers/filaments/prints scaffold. Also doubles as the
# "<type>:" prefix vendorBundles section lookups use.
TYPE_DIRS = {
    "printer": "printers",
    "filament": "filaments",
    "print": "prints",
}

INT_RE = re.compile(r"^-?[0-9]+$")
SECTION_RE = re.compile(r"^\[([a-zA-Z_]+):(.*)\]$")

VendorIndex = dict[tuple[str, str], list[str]]


def build_vendor_index(vendor_src: Path) -> VendorIndex:
    # Only section headers matter here (not full field/inherits resolution
    # like the Nix side does) - we just need to know which vendor file(s)
    # a "[type:name]" section lives in.
    index: VendorIndex = {}
    for ini_file in sorted(vendor_src.glob("*.ini")):
        vendor_name = ini_file.stem
        for line in ini_file.read_text(encoding="utf-8", errors="replace").splitlines():
            match = SECTION_RE.match(line.strip())
            if match:
                index.setdefault((match.group(1), match.group(2)), []).append(vendor_name)
    return index


def resolve_vendor(vendor_index: VendorIndex, section_prefix: str, inherits: str) -> str | None:
    candidates = vendor_index.get((section_prefix, inherits), [])
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        print(
            f'warning: "{section_prefix}:{inherits}" found in multiple vendor bundles '
            f"({', '.join(candidates)}) - leaving <Vendor> placeholder",
            file=sys.stderr,
        )
    return None


def parse_profile(path: Path) -> dict[str, str]:
    fields = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            print(f"warning: skipping unparseable line in {path}: {line!r}", file=sys.stderr)
            continue
        fields[key.strip()] = value.strip()
    return fields


def nix_string(value: str) -> str:
    # Round-trips byte-for-byte through toSlic3rIni: escape backslashes and
    # quotes so a literal "\n" (two chars, as PrusaSlicer writes gcode
    # newlines) doesn't get reinterpreted as an actual newline by Nix.
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
    return f'"{escaped}"'


def nix_value(value: str) -> str:
    # Bare integers can stay ints; everything else (decimals, "nil", hex
    # colors, percentages, gcode) must be a string - Nix's toString on a
    # float corrupts it ("0.400000"), so only whole numbers are safe as ints.
    return value if INT_RE.match(value) else nix_string(value)


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "_", name).strip("_").lower()
    return slug or "profile"


def inherits_hint(section_prefix: str, inherits: str, vendor: str | None) -> str:
    vendor_ref = vendor or "<Vendor>"
    resolved_line = f"  # Found it in vendorBundles.{vendor}.\n" if vendor else ""
    return (
        "\n"
        f'  # PrusaSlicer had this as "inherits = {inherits}".\n'
        f"{resolved_line}"
        '  # If you set up vendorSrc (see README: "Use a vendor-bundle preset"),\n'
        "  # you may be able to replace the fields below with just your\n"
        "  # overrides, layered on the vendor profile and this directory's\n"
        "  # shared _common.nix:\n"
        "  #   slicerLib.mergeAttrsListAndWarn [\n"
        f'  #     (slicerLib.vendorBundles.{vendor_ref} "{section_prefix}:{inherits}")\n'
        "  #     (import ./_common.nix)\n"
        "  #     { ...your overrides... }\n"
        "  #   ]\n"
    )


def render(name: str, fields: dict[str, str], section_prefix: str, vendor_index: VendorIndex) -> str:
    hint = ""
    if "inherits" in fields:
        vendor = resolve_vendor(vendor_index, section_prefix, fields["inherits"])
        hint = inherits_hint(section_prefix, fields["inherits"], vendor)
    body = "\n".join(f"    {key} = {nix_value(value)};" for key, value in sorted(fields.items()))
    return f"{{ slicerLib }}:\n{{\n  name = {nix_string(name)};{hint}\n  value = {{\n{body}\n  }};\n}}\n"


def common_stub() -> str:
    return (
        "# Shared by every profile in this directory - layer it into each\n"
        "# profile's mergeAttrsListAndWarn list via `(import ./_common.nix)`.\n"
        '# Not a profile itself - scanDir skips files starting with "_".\n'
        "{\n}\n"
    )


def write_common_stub(out_dir: Path, dry_run: bool) -> None:
    stub_path = out_dir / "_common.nix"
    if stub_path.exists():
        return
    print(f"(stub) -> {stub_path}")
    if not dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
        stub_path.write_text(common_stub(), encoding="utf-8")


def port_type(
    section_prefix: str, src_dir: Path, out_dir: Path, dry_run: bool, vendor_index: VendorIndex
) -> int:
    write_common_stub(out_dir, dry_run)

    count = 0
    used_slugs: set[str] = set()
    for ini_file in sorted(src_dir.glob("*.ini")):
        name = ini_file.stem
        fields = parse_profile(ini_file)
        if not fields:
            print(f"warning: no fields parsed from {ini_file}, skipping", file=sys.stderr)
            continue

        slug = candidate = slugify(name)
        n = 2
        while candidate in used_slugs:
            candidate = f"{slug}_{n}"
            n += 1
        used_slugs.add(candidate)

        out_path = out_dir / f"{candidate}.nix"
        print(f"{ini_file} -> {out_path}")
        if not dry_run:
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path.write_text(render(name, fields, section_prefix, vendor_index), encoding="utf-8")
        count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--config-dir",
        required=True,
        type=Path,
        help='slicer config directory, e.g. "~/.config/PrusaSlicer"',
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="scaffold root to write into (contains printers/, filaments/, prints/)",
    )
    parser.add_argument(
        "--types",
        default=",".join(TYPE_DIRS),
        help=f"comma-separated source subdirectories to port (default: {','.join(TYPE_DIRS)})",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print what would be written, without writing"
    )
    parser.add_argument(
        "--vendor-src",
        type=Path,
        default=None,
        help=(
            "directory of <Vendor>.ini files (same shape as the Nix side's vendorSrc) - "
            "if given, resolves inherits hints to the real vendorBundles name whenever "
            "exactly one vendor file has a matching section"
        ),
    )
    args = parser.parse_args()

    requested = [t.strip() for t in args.types.split(",") if t.strip()]
    unknown = [t for t in requested if t not in TYPE_DIRS]
    if unknown:
        parser.error(f"unknown --types entries: {', '.join(unknown)} (known: {', '.join(TYPE_DIRS)})")

    vendor_index = build_vendor_index(args.vendor_src) if args.vendor_src else {}

    total = 0
    for src_name in requested:
        src_dir = args.config_dir / src_name
        if not src_dir.is_dir():
            print(f"warning: {src_dir} not found, skipping", file=sys.stderr)
            continue
        total += port_type(
            src_name, src_dir, args.out / TYPE_DIRS[src_name], args.dry_run, vendor_index
        )

    physical_printer = args.config_dir / "physical_printer"
    if physical_printer.is_dir() and any(physical_printer.glob("*.ini")):
        print(
            f"note: not touching {physical_printer} - it holds host + API key secrets, "
            "let the GUI manage it directly",
            file=sys.stderr,
        )

    verb = "would port" if args.dry_run else "ported"
    print(f"{verb} {total} profile(s) into {args.out}")


if __name__ == "__main__":
    main()
