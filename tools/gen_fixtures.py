#!/usr/bin/env python3
"""Generate the shared benchmark fixtures.

Produces fixtures/<dataset>.bin (wire format) and fixtures/<dataset>.json
(canonical ProtoJSON, compact) for the three datasets, using the official
Python protobuf runtime and a self-contained deterministic PRNG so the output
is byte-for-byte reproducible on any machine.

Usage:  gen_fixtures.py [--out DIR] [--gen DIR]
  --gen DIR   directory containing bench_pb2.py (generated with protoc)
"""
import argparse
import json
import os
import struct
import sys


class Rng:
    """splitmix64 - tiny, deterministic, independent of Python's random module."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int):
        self.state = seed & self.MASK

    def next_u64(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & self.MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & self.MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & self.MASK
        return z ^ (z >> 31)

    def below(self, n: int) -> int:
        return self.next_u64() % n

    def range(self, lo: int, hi: int) -> int:  # inclusive
        return lo + self.below(hi - lo + 1)

    def f64(self) -> float:
        # 53 random mantissa bits -> uniform in [0, 1)
        return (self.next_u64() >> 11) / float(1 << 53)

    def f32(self) -> float:
        # a float32-representable value with a short decimal form
        return struct.unpack("<f", struct.pack("<f", self.range(-100000, 100000) / 100.0))[0]

    def word(self, lo: int = 3, hi: int = 10) -> str:
        n = self.range(lo, hi)
        return "".join(chr(ord("a") + self.below(26)) for _ in range(n))

    def sentence(self, words: int) -> str:
        return " ".join(self.word() for _ in range(words))

    def bytes(self, n: int) -> bytes:
        return bytes(self.below(256) for _ in range(n))

    def status(self):
        return self.below(4)  # STATUS_UNSPECIFIED..PENDING


def build_small(pb, rng: Rng):
    m = pb.SmallMessage()
    m.id = rng.range(1, 1_000_000)
    m.timestamp = 1_700_000_000_000 + rng.below(10_000_000_000)
    m.flags = rng.below(1 << 16)
    m.value = round(rng.f64() * 1000, 6)
    m.enabled = True
    m.name = rng.sentence(2)
    m.status = 1 + rng.below(3)
    return m


def fill_address(a, rng: Rng):
    a.street = f"{rng.range(1, 999)} {rng.word().capitalize()} Street"
    a.city = rng.word(4, 9).capitalize()
    a.country = rng.word(2, 2).upper()
    a.zip = rng.range(10000, 99999)


def build_medium(pb, rng: Rng):
    m = pb.MediumMessage()
    m.order_id = "ORD-" + "".join(str(rng.below(10)) for _ in range(12))
    m.created_at = 1_700_000_000_000 + rng.below(10_000_000_000)
    fill_address(m.shipping, rng)
    fill_address(m.billing, rng)
    for _ in range(40):
        it = m.items.add()
        it.sku = rng.next_u64() >> 8
        it.description = rng.sentence(rng.range(4, 10))
        it.quantity = rng.range(1, 500)
        it.unit_price = round(rng.f64() * 500, 2)
        for _ in range(rng.range(1, 4)):
            it.tags.append(rng.word())
        it.status = rng.status()
    for _ in range(16):
        m.attributes[rng.word(4, 8)] = rng.range(-1_000_000_000_000, 1_000_000_000_000)
    m.card_token = "tok_" + rng.word(16, 16)
    m.status = 3
    m.signature = rng.bytes(64)
    for _ in range(5):
        m.notes.append(rng.sentence(rng.range(6, 14)))
    m.total = round(rng.f64() * 100000, 2)
    m.priority = rng.range(-10, 10)
    m.checksum = rng.next_u64()
    return m


def build_large(pb, rng: Rng):
    m = pb.LargeMessage()
    m.source = "sensor-array/" + rng.word(6, 6)
    m.measurements.extend(round(rng.f64() * 1e6, 3) for _ in range(20000))
    m.counters.extend(rng.range(0, 2_000_000) for _ in range(50000))
    m.deltas.extend(rng.range(-5_000_000, 5_000_000) for _ in range(30000))
    for i in range(5000):
        s = m.samples.add()
        s.timestamp = 1_700_000_000_000 + i * 1000 + rng.below(1000)
        s.value = round(rng.f64() * 100, 4)
        s.label = rng.word(3, 8)
        s.status = rng.status()
    for _ in range(10000):
        v = m.vertices.add()
        v.x = rng.f32()
        v.y = rng.f32()
        v.z = rng.f32()
    for i in range(1000):
        m.labels[rng.range(-100000, 100000)] = rng.sentence(2)
    m.blob = rng.bytes(65536)
    return m


BUILDERS = {"small": (build_small, 0x5EED0001), "medium": (build_medium, 0x5EED0002), "large": (build_large, 0x5EED0003)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "fixtures"))
    ap.add_argument("--gen", required=True, help="dir containing bench_pb2.py")
    args = ap.parse_args()
    sys.path.insert(0, os.path.abspath(args.gen))
    import bench_pb2 as pb  # noqa: E402
    from google.protobuf import json_format  # noqa: E402

    os.makedirs(args.out, exist_ok=True)
    for name, (builder, seed) in BUILDERS.items():
        msg = builder(pb, Rng(seed))
        wire = msg.SerializeToString(deterministic=True)
        js = json_format.MessageToJson(msg, indent=None, sort_keys=True)
        # Normalise to compact JSON regardless of runtime version.
        js = json.dumps(json.loads(js), separators=(",", ":"), ensure_ascii=False, sort_keys=True)
        with open(os.path.join(args.out, f"{name}.bin"), "wb") as f:
            f.write(wire)
        with open(os.path.join(args.out, f"{name}.json"), "w", encoding="utf-8") as f:
            f.write(js)
        print(f"{name:7s} wire={len(wire):8d} bytes  json={len(js.encode()):8d} bytes")


if __name__ == "__main__":
    main()
