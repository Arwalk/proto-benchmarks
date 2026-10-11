"""proto-benchmarks harness: official Python protobuf (upb backend)."""
import os
import platform
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))

import bench_pb2 as pb  # noqa: E402
import google.protobuf  # noqa: E402
from google.protobuf import json_format  # noqa: E402
from google.protobuf.internal import api_implementation  # noqa: E402
import pyharness  # noqa: E402

TYPES = {"small": pb.SmallMessage, "medium": pb.MediumMessage, "large": pb.LargeMessage}
SCALAR = {"small": lambda m: m.id, "medium": lambda m: m.created_at, "large": lambda m: len(m.source)}


class Impl(pyharness.Implementation):
    language = "python"
    name = "protobuf"

    def runtime(self):
        return f"{platform.python_implementation()} {platform.python_version()} ({api_implementation.Type()} backend)"

    def library_version(self):
        return google.protobuf.__version__

    def wire_decode(self, dataset, data):
        m = TYPES[dataset]()
        m.ParseFromString(data)
        return m

    def wire_encode(self, dataset, msg):
        return msg.SerializeToString()

    def json_decode(self, dataset, text):
        return json_format.Parse(text, TYPES[dataset]())

    def json_encode(self, dataset, msg):
        return json_format.MessageToJson(msg, indent=None)

    def scalar(self, dataset, msg):
        return SCALAR[dataset](msg)


if __name__ == "__main__":
    pyharness.main(Impl())
