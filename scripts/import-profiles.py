"""Port PrusaSlicer-format user profiles into this project's per-file Nix layout.

Each source "<type>/<Name>.ini" becomes "<outdir>/<name>.nix" with a
`{ slicerLib }: { name; value; }` shape (matching templates/default/). It drops
straight into a scaffold's printers/filaments/prints directories.

--vendor-src takes a directory of <Vendor>.ini files (same shape as the Nix
side's vendorSrc). A profile's `inherits` resolves to the matching vendor
section; fields already equal to it are dropped, keeping only what differs.

--defaults-src takes the slicer's compiled defaults (dump with
`prusa-slicer --save defaults.ini`). Fields equal to a default are dropped too.
The defaults are written as a per-directory "_slicer_defaults.nix" base layer
that every profile composes under its vendor/_common/own layers, so dropped
fields still render from an explicit base. Vendor values win over defaults.

Without a resolvable bundle, nothing is dropped and the vendorBundles lookup is
commented out with a <Vendor> placeholder; an ambiguous name (present in several
bundles) lists its candidate bundles inline. Every profile composes its layers
with plain `//`; later layers win.
"""

import argparse
import re
import sys
from pathlib import Path

# Source subdir (under configDir) -> output subdir. The key also serves as the
# "<type>:" prefix for vendorBundles section lookups.
TYPE_DIRS = {
    "printer": "printers",
    "filament": "filaments",
    "print": "prints",
}

INT_RE = re.compile(r"^-?[0-9]+$")
SECTION_RE = re.compile(r"^\[([a-zA-Z_]+):(.*)\]$")

NAME_SUFFIX = " (nix)"

VendorIndex = dict[tuple[str, str], list[str]]


def build_vendor_index(vendor_src: Path) -> VendorIndex:
    # Index section headers only: which vendor file(s) hold a given
    # "[type:name]" section. Field/inherits resolution happens later.
    index: VendorIndex = {}
    for ini_file in sorted(vendor_src.glob("*.ini")):
        vendor_name = ini_file.stem
        for line in ini_file.read_text(encoding="utf-8", errors="replace").splitlines():
            match = SECTION_RE.match(line.strip())
            if match:
                index.setdefault((match.group(1), match.group(2)), []).append(vendor_name)
    return index


def resolve_vendor(
    vendor_index: VendorIndex, section_prefix: str, inherits: str
) -> tuple[str | None, list[str]]:
    # Return (resolved vendor, all candidates). The candidates let the renderer
    # list the choices inline when the name is ambiguous.
    candidates = vendor_index.get((section_prefix, inherits), [])
    if len(candidates) == 1:
        return candidates[0], candidates
    if len(candidates) > 1:
        print(
            f'warning: "{section_prefix}:{inherits}" found in multiple vendor bundles '
            f"({', '.join(candidates)}) - leaving <Vendor> placeholder",
            file=sys.stderr,
        )
    return None, candidates


# These MUST mirror lib.nix's parseVendorIni regexes (tolerate "key=value"
# and CRLF).
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
    # resolves to what it can, rather than throwing.
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
    # Parse each vendor file at most once, however many profiles inherit it.
    sections = cache.get(vendor_name)
    if sections is None:
        sections = parse_vendor_ini(vendor_src / f"{vendor_name}.ini")
        cache[vendor_name] = sections
    return resolve_vendor_section(sections, section)


def unset_canon(value: str) -> str:
    # A nullable unset field is "nil" in saved profiles but "" from
    # `prusa-slicer --save`. Treat them as equal so they dedupe.
    return "" if value == "nil" else value


def is_own_field(key: str, value: str, baseline: dict[str, str], parent_known: bool) -> bool:
    # True when the profile MUST keep this field (the rendered ini cannot omit
    # it). A field present in baseline is redundant iff it matches. With no
    # baseline entry, an explicitly-unset field is redundant only when the layer
    # beneath is known (resolved vendor chain, or no `inherits`); otherwise the
    # parent might set it, so keep it.
    if key in baseline:
        return unset_canon(baseline[key]) != unset_canon(value)
    return not (unset_canon(value) == "" and parent_known)


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
    # Escape backslashes and quotes so the value round-trips byte-for-byte
    # through toSlic3rIni. A literal "\n" (two chars) MUST NOT become a real
    # newline in Nix.
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
    return f'"{escaped}"'


def nix_value(value: str) -> str:
    # Whole numbers stay ints; everything else MUST be a string. Nix's toString
    # corrupts floats ("0.400000"), so only integers are safe unquoted.
    return value if INT_RE.match(value) else nix_string(value)


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "_", name).strip("_").lower()
    return slug or "profile"


def render(
    name: str,
    fields: dict[str, str],
    section_prefix: str,
    vendor: str | None,
    vendor_candidates: list[str],
    has_defaults: bool,
) -> str:
    # Compose the layers with plain `//`; later layers win. Order:
    # compiled-defaults base (only with --defaults-src), vendor bundle, this
    # directory's _common.nix, then the profile's own fields on top. An
    # unresolved vendor bundle is emitted as a bare comment the chain steps past;
    # if the name is ambiguous across bundles, the candidates are listed inline.
    #
    # entries holds (kind, text): "layer" joins the `//` chain, "comment" is a
    # plain line between layers.
    entries: list[tuple[str, str]] = []
    if has_defaults:
        entries.append(("layer", "(import ./_slicer_defaults.nix)"))
    if "inherits" in fields:
        section = f"{section_prefix}:{fields['inherits']}"
        if vendor:
            entries.append(("layer", f'(slicerLib.vendorBundles.{vendor} "{section}")'))
        else:
            comment = f'# (slicerLib.vendorBundles.<Vendor> "{section}")'
            if vendor_candidates:
                comment += f"  # Replace <Vendor> with one of [{', '.join(vendor_candidates)}]"
            entries.append(("comment", comment))
    entries.append(("layer", "(import ./_common.nix)"))
    if fields:
        field_lines = "\n".join(f"      {key} = {nix_value(value)};" for key, value in sorted(fields.items()))
        entries.append(("layer", "{\n" + field_lines + "\n    }"))
    else:
        entries.append(("layer", "{ }"))

    body_lines: list[str] = []
    first_layer = True
    for kind, text in entries:
        if kind == "comment":
            body_lines.append(f"    {text}")
            continue
        prefix = "" if first_layer else "// "
        first_layer = False
        text_lines = text.split("\n")
        body_lines.append(f"    {prefix}{text_lines[0]}")
        body_lines.extend(text_lines[1:])
    body = "\n".join(body_lines)

    return f"{{ slicerLib }}:\n{{\n  name = {nix_string(name)};\n  value =\n{body};\n}}\n"


def common_stub() -> str:
    return (
        "# Shared by this directory's profiles via `(import ./_common.nix)`. Not a\n"
        '# profile itself - scanDir skips "_"-prefixed files.\n'
        "{\n}\n"
    )


def render_defaults(layer: dict[str, str]) -> str:
    field_lines = "\n".join(f"  {key} = {nix_value(value)};" for key, value in sorted(layer.items()))
    body = f"\n{field_lines}\n" if field_lines else "\n"
    return (
        "# Compiled slicer defaults (from --defaults-src) for the fields this\n"
        "# directory's profiles touch. Each profile's base layer, via\n"
        "# `(import ./_slicer_defaults.nix)`; every layer above wins. Not a\n"
        '# profile itself - scanDir skips "_"-prefixed files.\n'
        f"{{{body}}}\n"
    )


def write_defaults_layer(
    out_dir: Path, used_keys: set[str], default_fields: dict[str, str], dry_run: bool
) -> None:
    layer = {k: default_fields[k] for k in used_keys if k in default_fields}
    path = out_dir / "_slicer_defaults.nix"
    print(f"(defaults) -> {path}")
    if not dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(render_defaults(layer), encoding="utf-8")


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

    # Parse everything first so the defaults layer can cover the union of fields
    # these profiles touch. The flat --defaults-src mixes printer/filament/print
    # keys, so a per-directory layer MUST stay restricted to keys used here.
    parsed = []
    for ini_file in sorted(src_dir.glob("*.ini")):
        fields = parse_profile(ini_file)
        if not fields:
            print(f"warning: no fields parsed from {ini_file}, skipping", file=sys.stderr)
            continue
        parsed.append((ini_file, fields))

    has_defaults = bool(default_fields) and bool(parsed)
    if has_defaults:
        used_keys = {key for _, fields in parsed for key in fields}
        write_defaults_layer(out_dir, used_keys, default_fields, dry_run)

    count = 0
    resolved = 0
    used_slugs: set[str] = set()
    for ini_file, fields in parsed:
        name = ini_file.stem + NAME_SUFFIX

        vendor = None
        vendor_candidates: list[str] = []
        vendor_fields: dict[str, str] = {}
        if "inherits" in fields:
            vendor, vendor_candidates = resolve_vendor(vendor_index, section_prefix, fields["inherits"])
            if vendor:
                resolved += 1
                if vendor_src is not None:
                    vendor_fields = resolve_vendor_fields(
                        vendor_src, vendor, f"{section_prefix}:{fields['inherits']}", vendor_cache
                    )

        # Drop fields the rendered ini can omit (see is_own_field). Vendor wins
        # over compiled defaults.
        baseline = {**default_fields, **vendor_fields}
        parent_known = "inherits" not in fields or vendor is not None
        own_fields = {k: v for k, v in fields.items() if is_own_field(k, v, baseline, parent_known)}

        slug = candidate = slugify(ini_file.stem)
        n = 2
        while candidate in used_slugs:
            candidate = f"{slug}_{n}"
            n += 1
        used_slugs.add(candidate)

        out_path = out_dir / f"{candidate}.nix"
        print(f"{ini_file} -> {out_path}")
        if not dry_run:
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path.write_text(
                render(name, own_fields, section_prefix, vendor, vendor_candidates, has_defaults),
                encoding="utf-8",
            )
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
            "are dropped from each profile, on top of vendor-bundle dedup, and the "
            "defaults are written as a per-directory _slicer_defaults.nix base layer "
            "every profile composes under its other layers"
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
