#!/usr/bin/env python3
"""Validate the endpoints ComfySwiftSDK depends on against the ComfyUI front-facing
OpenAPI contract.

The SDK talks to https://cloud.comfy.org, which exposes the ComfyUI API described by
Comfy-Org/ComfyUI:openapi.yaml. This check turns the SDK's worst failure mode — a
backend contract change surfacing as a runtime decode failure — into a CI signal.

Policy:
  * A `required: true` endpoint (the default) that is absent from the contract FAILS.
  * A `required: false` endpoint that is absent is a non-blocking WARNING
    (known legacy endpoints pending migration).
  * Any endpoint marked `deprecated: true` in the contract is a non-blocking WARNING.

Exit codes:
  0  all required endpoints present (warnings allowed)
  1  a required endpoint is missing, or the inputs could not be read
"""

import argparse
import os
import sys

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

IN_ACTIONS = bool(os.environ.get("GITHUB_ACTIONS"))


def annotate(level, message):
    """Emit a GitHub Actions workflow annotation when running in CI."""
    if IN_ACTIONS:
        print(f"::{level}::{message}")


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, help="Path to the OpenAPI spec (openapi.yaml)")
    parser.add_argument("--manifest", required=True, help="Path to the SDK endpoint manifest")
    args = parser.parse_args()

    try:
        spec = load_yaml(args.spec)
        manifest = load_yaml(args.manifest)
    except (OSError, yaml.YAMLError) as exc:
        annotate("error", f"failed to load inputs: {exc}")
        print(f"error: failed to load inputs: {exc}", file=sys.stderr)
        return 1

    paths = spec.get("paths") or {}
    endpoints = manifest.get("endpoints") or []
    if not endpoints:
        annotate("error", "manifest declares no endpoints")
        print("error: manifest declares no endpoints", file=sys.stderr)
        return 1

    ok, warnings, errors = [], [], []

    for entry in endpoints:
        method = str(entry.get("method", "")).strip().lower()
        path = str(entry.get("path", "")).strip()
        required = entry.get("required", True)
        note = entry.get("note", "")
        label = f"{method.upper()} {path}"

        path_item = paths.get(path)
        if path_item is None:
            (errors if required else warnings).append(
                (label, f"{label} — not found in the contract", note)
            )
            continue

        operation = path_item.get(method)
        if operation is None:
            (errors if required else warnings).append(
                (label, f"{label} — path exists but method is not defined in the contract", note)
            )
            continue

        is_deprecated = bool(operation.get("deprecated")) or bool(path_item.get("deprecated"))
        if is_deprecated:
            warnings.append((label, f"{label} — marked deprecated in the contract", note))
        else:
            ok.append(label)

    print(f"Validated {len(endpoints)} SDK endpoint(s) against {args.spec}\n")
    for label in ok:
        print(f"  OK       {label}")
    for label, message, note in warnings:
        print(f"  WARN     {message}")
        if note:
            print(f"           note: {note}")
        annotate("warning", message)
    for label, message, note in errors:
        print(f"  MISSING  {message}")
        if note:
            print(f"           note: {note}")
        annotate("error", message)

    print(f"\nSummary: {len(ok)} ok, {len(warnings)} warning(s), {len(errors)} error(s)")
    if errors:
        print("Contract check FAILED — a required endpoint is absent from the front-facing contract.")
        return 1
    print("Contract check passed (warnings are non-blocking).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
