"""Port PrusaSlicer-format user profiles into this project's per-file Nix layout.

Each source "<type>/<Name>.ini" file becomes "<outdir>/<name>.nix" with a
`{ slicerLib }: { name; value; }` shape (matching templates/default/) so it
drops straight into a scaffold's printers/filaments/prints directories.

With --vendor-src (a directory of <Vendor>.ini files, same shape as the Nix
side's vendorSrc), a profile's `inherits` is resolved to the matching vendor
section and fields already equal to it are dropped, so the import keeps only
what differs. --defaults-src additionally drops fields equal to the slicer's
compiled defaults (dump with `prusa-slicer --save defaults.ini`); vendor
values win over defaults where both apply. Without a resolvable bundle nothing
is dropped and the vendorBundles lookup is commented out with a <Vendor>
placeholder. Every generated profile layers through mergeAttrsListAndWarn
alongside this directory's shared "_common.nix" stub.
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


# Mirror lib.nix's parseVendorIni regexes (tolerating "key=value" and CRLF).
VENDOR_SECTION_RE = re.compile(r"^\[(.*)]$")
VENDOR_KV_RE = re.compile(r"^([a-zA-Z0-9_]+) ?= ?(.*)$")
VENDOR_TYPE_RE = re.compile(r"^([a-zA-Z_]+):")


def parse_vendor_ini(path: Path) -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    current: str | None = None
    text = path.read_text(encoding="utf-8", errors="replace").replace("\r", "")
    for line in text.split("\n"):
        section = VENDOR_SECTION_RE.match(line)
        if section:
            current = section.group(1)
        elif current is not None:
            kv = VENDOR_KV_RE.match(line)
            if kv:
                sections.setdefault(current, {})[kv.group(1)] = kv.group(2)
    return sections


def resolve_vendor_section(sections: dict[str, dict[str, str]], name: str) -> dict[str, str]:
    # Follow the `inherits = A;B` chain (parents first, own fields win), like
    # lib.nix's resolveVendorSection but lenient: a missing section/parent
    # returns only what could be resolved rather than throwing.
    section = sections.get(name)
    if section is None:
        return {}
    type_match = VENDOR_TYPE_RE.match(name)
    type_prefix = type_match.group(1) if type_match else ""
    resolved: dict[str, str] = {}
    for parent in section.get("inherits", "").split(";"):
        parent = parent.strip()
        if parent:
            resolved.update(resolve_vendor_section(sections, f"{type_prefix}:{parent}"))
    resolved.update(section)
    resolved.pop("inherits", None)
    return resolved


def resolve_vendor_fields(
    vendor_src: Path,
    vendor_name: str,
    section: str,
    cache: dict[str, dict[str, dict[str, str]]],
) -> dict[str, str]:
    # Parse each vendor file at most once, no matter how many profiles inherit it.
    sections = cache.get(vendor_name)
    if sections is None:
        sections = parse_vendor_ini(vendor_src / f"{vendor_name}.ini")
        cache[vendor_name] = sections
    return resolve_vendor_section(sections, section)


def unset_canon(value: str) -> str:
    # An unset nullable field is "nil" in saved profiles but "" from
    # `prusa-slicer --save`; treat the two as equal so they dedupe.
    return "" if value == "nil" else value


def is_own_field(key: str, value: str, baseline: dict[str, str], parent_known: bool) -> bool:
    # True if the profile must keep this field, i.e. the rendered ini can't omit
    # it. A field set by a lower layer (baseline) is redundant iff it matches.
    # With no lower layer, an explicitly-unset field is redundant only when the
    # layer beneath is known (resolved vendor chain, or no `inherits`);
    # otherwise the parent might set it, so keep it.
    if key in baseline:
        return unset_canon(baseline[key]) != unset_canon(value)
    if unset_canon(value) == "" and parent_known:
        return False
    return True


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


def render(name: str, fields: dict[str, str], section_prefix: str, vendor: str | None) -> str:
    # Always layered through mergeAttrsListAndWarn - a vendor bundle call
    # (active if resolve_vendor found exactly one match, commented out with
    # a <Vendor> placeholder otherwise) plus this directory's _common.nix,
    # so the redundancy warning can point out which flattened fields below
    # already match the vendor default once vendorSrc is wired up.
    layers = []
    if "inherits" in fields:
        vendor_ref = vendor or "<Vendor>"
        vendor_call = f'(slicerLib.vendorBundles.{vendor_ref} "{section_prefix}:{fields["inherits"]}")'
        layers.append(vendor_call if vendor else f"# {vendor_call}")
    layers.append("(import ./_common.nix)")

    field_lines = "\n".join(f"      {key} = {nix_value(value)};" for key, value in sorted(fields.items()))
    layers.append(f"{{\n{field_lines}\n    }}")

    layers_text = "\n".join(f"    {layer}" for layer in layers)
    return (
        "{ slicerLib }:\n"
        "{\n"
        f"  name = {nix_string(name)};\n"
        f"  value = slicerLib.mergeAttrsListAndWarn {nix_string(name)} [\n"
        f"{layers_text}\n"
        "  ];\n"
        "}\n"
    )


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
    section_prefix: str,
    src_dir: Path,
    out_dir: Path,
    dry_run: bool,
    vendor_index: VendorIndex,
    vendor_src: Path | None,
    vendor_cache: dict[str, dict[str, dict[str, str]]],
    default_fields: dict[str, str],
) -> tuple[int, int]:
    write_common_stub(out_dir, dry_run)

    count = 0
    resolved = 0
    used_slugs: set[str] = set()
    for ini_file in sorted(src_dir.glob("*.ini")):
        name = ini_file.stem
        fields = parse_profile(ini_file)
        if not fields:
            print(f"warning: no fields parsed from {ini_file}, skipping", file=sys.stderr)
            continue

        vendor = None
        vendor_fields: dict[str, str] = {}
        if "inherits" in fields:
            vendor = resolve_vendor(vendor_index, section_prefix, fields["inherits"])
            if vendor:
                resolved += 1
                if vendor_src is not None:
                    vendor_fields = resolve_vendor_fields(
                        vendor_src, vendor, f"{section_prefix}:{fields['inherits']}", vendor_cache
                    )

        # Drop fields the rendered ini can safely omit (see is_own_field).
        # Vendor bundle wins over compiled defaults.
        baseline = {**default_fields, **vendor_fields}
        parent_known = "inherits" not in fields or vendor is not None
        own_fields = {k: v for k, v in fields.items() if is_own_field(k, v, baseline, parent_known)}

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
            out_path.write_text(render(name, own_fields, section_prefix, vendor), encoding="utf-8")
        count += 1
    return count, resolved


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
    parser.add_argument("--dry-run", action="store_true", help="print what would be written, without writing")
    parser.add_argument(
        "--defaults-src",
        type=Path,
        default=None,
        help=(
            "flat key=value file of the slicer's compiled defaults (produce with "
            "`prusa-slicer --save defaults.ini`); fields equal to these defaults "
            "are dropped too, on top of vendor-bundle dedup"
        ),
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
    vendor_cache: dict[str, dict[str, dict[str, str]]] = {}
    default_fields = parse_profile(args.defaults_src) if args.defaults_src else {}

    total = 0
    resolved_total = 0
    for src_name in requested:
        src_dir = args.config_dir / src_name
        if not src_dir.is_dir():
            print(f"warning: {src_dir} not found, skipping", file=sys.stderr)
            continue
        count, resolved = port_type(
            src_name,
            src_dir,
            args.out / TYPE_DIRS[src_name],
            args.dry_run,
            vendor_index,
            args.vendor_src,
            vendor_cache,
            default_fields,
        )
        total += count
        resolved_total += resolved

    verb = "would port" if args.dry_run else "ported"
    summary = f"{verb} {total} profile(s) into {args.out}"
    if args.vendor_src:
        summary += f" ({resolved_total} inherits resolved to a vendor bundle)"
    print(summary)


if __name__ == "__main__":
    main()
