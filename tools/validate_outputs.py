#!/usr/bin/env python3
"""Cross-check every implementation's dumped outputs against the reference runtime.

For each results/dumps/<impl>/ directory:
  * <dataset>.wire.bin is parsed with the official Python protobuf runtime and compared
    (message equality) with the fixture message -> catches partial/lazy/incorrect encoders;
    its length is compared with the fixture's (wire_size_match) -> catches dropped or
    duplicated fields that still parse to an equal message.
  * <dataset>.json is parsed with google.protobuf.json_format (unknown fields rejected) and
    compared with the fixture message -> catches dropped fields and wrong values.
  * <dataset>.json is additionally walked against the message descriptor to verify it is
    *canonical* ProtoJSON (json_canonical): lowerCamelCase keys, 64-bit integers as strings,
    enums as names, bytes as base64, proto3 defaults omitted. The reference parser is lenient
    (it accepts snake_case keys, numeric int64 and enum numbers), so this check is what actually
    catches non-canonical output. Whitespace is ignored.
Writes results/validation.json and prints a table. Exit code 1 if any check fails.
"""
import argparse
import base64
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATASETS = ("small", "medium", "large")
MAX_PROBLEMS = 20


# ----------------------------------------------------------------------------- canonical ProtoJSON
def _is_repeated(field, FD):
    # protobuf >= 30 exposes is_repeated; older runtimes only have label.
    rep = getattr(field, "is_repeated", None)
    return rep if rep is not None else field.label == FD.LABEL_REPEATED


def _is_map(field, FD):
    return (field.type == FD.TYPE_MESSAGE and _is_repeated(field, FD)
            and field.message_type.GetOptions().map_entry)


def _b64_ok(s):
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            decoder(s + "=" * (-len(s) % 4), validate=False)
            return True
        except Exception:  # noqa: BLE001
            continue
    return False


def check_scalar(value, field, path, problems, FD):
    """Check one value of `field` (not a map/repeated container) for canonical form."""
    t = field.type
    if t in (FD.TYPE_INT64, FD.TYPE_UINT64, FD.TYPE_SINT64, FD.TYPE_FIXED64, FD.TYPE_SFIXED64):
        if not (isinstance(value, str) and re.fullmatch(r"-?\d+", value)):
            problems.append(f"{path}: 64-bit integer not encoded as a decimal string ({value!r})")
    elif t in (FD.TYPE_INT32, FD.TYPE_UINT32, FD.TYPE_SINT32, FD.TYPE_FIXED32, FD.TYPE_SFIXED32):
        if isinstance(value, bool) or not isinstance(value, int):
            problems.append(f"{path}: 32-bit integer not encoded as a JSON number ({value!r})")
    elif t in (FD.TYPE_FLOAT, FD.TYPE_DOUBLE):
        ok = (isinstance(value, (int, float)) and not isinstance(value, bool)) or value in ("NaN", "Infinity", "-Infinity")
        if not ok:
            problems.append(f"{path}: float not encoded as a JSON number ({value!r})")
    elif t == FD.TYPE_BOOL:
        if not isinstance(value, bool):
            problems.append(f"{path}: bool not encoded as true/false ({value!r})")
    elif t == FD.TYPE_STRING:
        if not isinstance(value, str):
            problems.append(f"{path}: string not encoded as a JSON string ({value!r})")
    elif t == FD.TYPE_BYTES:
        if not (isinstance(value, str) and _b64_ok(value)):
            problems.append(f"{path}: bytes not encoded as base64 ({str(value)[:30]!r})")
    elif t == FD.TYPE_ENUM:
        if not isinstance(value, str):
            problems.append(f"{path}: enum not encoded as its name ({value!r})")
        elif value not in field.enum_type.values_by_name:
            problems.append(f"{path}: unknown enum name {value!r}")
    elif t == FD.TYPE_MESSAGE:
        check_message(value, field.message_type, path, problems, FD)
    else:
        problems.append(f"{path}: unexpected field type {t}")


def is_default(value, field, FD):
    """True when `value` is the proto3 default of a singular `field` (which must be omitted)."""
    t = field.type
    if t in (FD.TYPE_INT64, FD.TYPE_UINT64, FD.TYPE_SINT64, FD.TYPE_FIXED64, FD.TYPE_SFIXED64):
        return value == "0"
    if t in (FD.TYPE_FLOAT, FD.TYPE_DOUBLE):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and value == 0 and not math.isnan(value)
    if t in (FD.TYPE_INT32, FD.TYPE_UINT32, FD.TYPE_SINT32, FD.TYPE_FIXED32, FD.TYPE_SFIXED32):
        return value == 0 and not isinstance(value, bool)
    if t == FD.TYPE_BOOL:
        return value is False
    if t in (FD.TYPE_STRING, FD.TYPE_BYTES):
        return value == ""
    if t == FD.TYPE_ENUM:
        return value == field.enum_type.values_by_number[0].name
    return False  # messages: presence is explicit, an empty object is legitimate


def check_field(value, field, path, problems, FD):
    if _is_map(field, FD):
        if not isinstance(value, dict):
            problems.append(f"{path}: map not encoded as a JSON object")
            return
        if not value:
            problems.append(f"{path}: empty map emitted (defaults must be omitted)")
        value_field = field.message_type.fields_by_name["value"]
        for k, v in value.items():
            if not isinstance(k, str):
                problems.append(f"{path}: map key is not a string")
            check_scalar(v, value_field, f"{path}[{k!r}]", problems, FD)
    elif _is_repeated(field, FD):
        if not isinstance(value, list):
            problems.append(f"{path}: repeated field not encoded as a JSON array")
            return
        if not value:
            problems.append(f"{path}: empty repeated field emitted (defaults must be omitted)")
        for i, v in enumerate(value):
            check_scalar(v, field, f"{path}[{i}]", problems, FD)
    else:
        check_scalar(value, field, path, problems, FD)
        if field.containing_oneof is None and is_default(value, field, FD):
            problems.append(f"{path}: proto3 default value emitted ({value!r})")


def check_message(obj, desc, path, problems, FD):
    if not isinstance(obj, dict):
        problems.append(f"{path}: message not encoded as a JSON object")
        return
    by_json = {f.json_name: f for f in desc.fields}
    by_name = {f.name: f for f in desc.fields}
    for key, value in obj.items():
        if key in by_json:
            check_field(value, by_json[key], f"{path}.{key}", problems, FD)
        elif key in by_name:
            problems.append(f"{path}.{key}: field name not in lowerCamelCase (json_name is {by_name[key].json_name!r})")
            check_field(value, by_name[key], f"{path}.{key}", problems, FD)
        else:
            problems.append(f"{path}.{key}: unknown field")


def check_canonical(text, msg_type):
    """Return the list of canonical-form problems of `text` for message class `msg_type`."""
    from google.protobuf.descriptor import FieldDescriptor as FD  # noqa: E402
    problems = []
    try:
        obj = json.loads(text)
    except ValueError as e:
        return [f"invalid JSON: {e}"]
    check_message(obj, msg_type.DESCRIPTOR, msg_type.DESCRIPTOR.name, problems, FD)
    return problems


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dumps", default=os.path.join(ROOT, "results", "dumps"))
    ap.add_argument("--fixtures", default=os.path.join(ROOT, "fixtures"))
    ap.add_argument("--gen", default=os.path.join(ROOT, "python", "protobuf", "gen"))
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "validation.json"))
    args = ap.parse_args()

    sys.path.insert(0, os.path.abspath(args.gen))
    import bench_pb2 as pb  # noqa: E402
    from google.protobuf import json_format  # noqa: E402

    types = {"small": pb.SmallMessage, "medium": pb.MediumMessage, "large": pb.LargeMessage}
    ref = {}
    ref_len = {}
    for ds in DATASETS:
        with open(os.path.join(args.fixtures, f"{ds}.bin"), "rb") as f:
            data = f.read()
            m = types[ds]()
            m.ParseFromString(data)
            ref[ds] = m
            ref_len[ds] = len(data)

    report = {}
    failed = False
    if not os.path.isdir(args.dumps):
        print(f"no dumps directory at {args.dumps}")
        return 0
    for impl in sorted(os.listdir(args.dumps)):
        d = os.path.join(args.dumps, impl)
        if not os.path.isdir(d):
            continue
        report[impl] = {}
        for ds in DATASETS:
            entry = {}
            wire = os.path.join(d, f"{ds}.wire.bin")
            if os.path.exists(wire):
                try:
                    with open(wire, "rb") as f:
                        data = f.read()
                    entry["wire_size_match"] = (len(data) == ref_len[ds])
                    m = types[ds]()
                    m.ParseFromString(data)
                    entry["wire_equal"] = (m == ref[ds])
                except Exception as e:  # noqa: BLE001
                    entry["wire_equal"] = False
                    entry["wire_error"] = str(e)[:200]
            js = os.path.join(d, f"{ds}.json")
            if os.path.exists(js):
                with open(js, "r", encoding="utf-8") as f:
                    text = f.read()
                entry["json_bytes"] = len(text.encode("utf-8"))
                try:
                    m = json_format.Parse(text, types[ds](), ignore_unknown_fields=False)
                    entry["json_equal"] = (m == ref[ds])
                except Exception as e:  # noqa: BLE001
                    entry["json_equal"] = False
                    entry["json_error"] = str(e)[:200]
                problems = check_canonical(text, types[ds])
                entry["json_canonical"] = not problems
                if problems:
                    entry["json_canonical_problems"] = problems[:MAX_PROBLEMS]
                    if len(problems) > MAX_PROBLEMS:
                        entry["json_canonical_problems"].append(f"... {len(problems) - MAX_PROBLEMS} more")
            report[impl][ds] = entry
            for k in ("wire_equal", "wire_size_match", "json_equal", "json_canonical"):
                if entry.get(k) is False:
                    failed = True

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    flag = {True: "ok", False: "FAIL", None: "-"}
    print(f"{'implementation':28s} {'dataset':8s} wire   size   json   canon  ")
    for impl, dss in report.items():
        for ds, e in dss.items():
            detail = e.get("wire_error") or e.get("json_error") or (e.get("json_canonical_problems") or [""])[0]
            print(f"{impl:28s} {ds:8s} {flag[e.get('wire_equal')]:6s} {flag[e.get('wire_size_match')]:6s} "
                  f"{flag[e.get('json_equal')]:6s} {flag[e.get('json_canonical')]:6s} {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
