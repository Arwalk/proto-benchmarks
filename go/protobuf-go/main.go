// proto-benchmarks harness: google.golang.org/protobuf (protobuf-go).
// See docs/HARNESS.md for the contract; the measurement loop mirrors tools/pyharness.py.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"protobench/gen/bench"
)

const (
	harnessLanguage = "go"
	harnessName     = "protobuf-go"
	libraryModule   = "google.golang.org/protobuf"
)

var allDatasets = []string{"small", "medium", "large"}
var allOps = []string{"wire_encode", "wire_decode", "json_encode", "json_decode"}

// Black hole: every iteration folds one scalar into it; printed once at the end.
var sink uint64

type roundResult struct {
	Iterations int   `json:"iterations"`
	ElapsedNs  int64 `json:"elapsed_ns"`
}

type validation struct {
	WireBytesMatch bool  `json:"wire_bytes_match"`
	WireSizeMatch  bool  `json:"wire_size_match"`
	JSONRoundtrip  *bool `json:"json_roundtrip_ok"`
	JSONBytes      *int  `json:"json_bytes"`
}

type result struct {
	Dataset      string        `json:"dataset"`
	Operation    string        `json:"operation"`
	Supported    bool          `json:"supported"`
	Reason       string        `json:"reason,omitempty"`
	PayloadBytes *int          `json:"payload_bytes,omitempty"`
	Validation   *validation   `json:"validation,omitempty"`
	WarmupNs     *int64        `json:"warmup_ns,omitempty"`
	Steady       *bool         `json:"steady,omitempty"`
	Batch        *int          `json:"batch,omitempty"`
	Rounds       []roundResult `json:"rounds,omitempty"`
}

type harnessInfo struct {
	Language       string `json:"language"`
	Name           string `json:"name"`
	Runtime        string `json:"runtime"`
	LibraryVersion string `json:"library_version"`
}

type document struct {
	SchemaVersion int         `json:"schema_version"`
	Harness       harnessInfo `json:"harness"`
	Results       []result    `json:"results"`
}

// ---- the four operations, per dataset (static generated code, no reflection) ----

// dsOps bundles the per-dataset closures. wireDecode/jsonDecode return the
// "scalar consumed by the black hole" of the freshly built message, which is
// then dropped.
type dsOps struct {
	wireDecode func(b []byte) uint64
	wireEncode func() []byte
	jsonEncode func() []byte
	jsonDecode func(b []byte) uint64
	decodeMsg  func(b []byte) (proto.Message, error) // validation only
	encodeMsg  func(m proto.Message) ([]byte, error) // validation only
	jsonDecMsg func(b []byte) (proto.Message, error) // validation only
	jsonEncMsg func(m proto.Message) ([]byte, error) // validation only
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// checkDuration rejects negative / non-finite values of a decimal-seconds flag.
func checkDuration(name string, s float64) {
	if math.IsNaN(s) || math.IsInf(s, 0) || s < 0 {
		fmt.Fprintf(os.Stderr, "--%s must be a finite number >= 0 (got %v)\n", name, s)
		os.Exit(2)
	}
}

func opsFor(ds string, wire []byte) (dsOps, proto.Message) {
	var o dsOps
	o.encodeMsg = func(m proto.Message) ([]byte, error) { return proto.Marshal(m) }
	o.jsonEncMsg = func(m proto.Message) ([]byte, error) { return protojson.Marshal(m) }
	switch ds {
	case "small":
		o.decodeMsg = func(b []byte) (proto.Message, error) { m := &bench.SmallMessage{}; return m, proto.Unmarshal(b, m) }
		o.jsonDecMsg = func(b []byte) (proto.Message, error) { m := &bench.SmallMessage{}; return m, protojson.Unmarshal(b, m) }
		fm := &bench.SmallMessage{}
		must(proto.Unmarshal(wire, fm))
		o.wireDecode = func(b []byte) uint64 {
			m := &bench.SmallMessage{}
			must(proto.Unmarshal(b, m))
			return uint64(m.GetId())
		}
		o.wireEncode = func() []byte { b, err := proto.Marshal(fm); must(err); return b }
		o.jsonEncode = func() []byte { b, err := protojson.Marshal(fm); must(err); return b }
		o.jsonDecode = func(b []byte) uint64 {
			m := &bench.SmallMessage{}
			must(protojson.Unmarshal(b, m))
			return uint64(m.GetId())
		}
		return o, fm
	case "medium":
		o.decodeMsg = func(b []byte) (proto.Message, error) { m := &bench.MediumMessage{}; return m, proto.Unmarshal(b, m) }
		o.jsonDecMsg = func(b []byte) (proto.Message, error) {
			m := &bench.MediumMessage{}
			return m, protojson.Unmarshal(b, m)
		}
		fm := &bench.MediumMessage{}
		must(proto.Unmarshal(wire, fm))
		o.wireDecode = func(b []byte) uint64 {
			m := &bench.MediumMessage{}
			must(proto.Unmarshal(b, m))
			return uint64(m.GetCreatedAt())
		}
		o.wireEncode = func() []byte { b, err := proto.Marshal(fm); must(err); return b }
		o.jsonEncode = func() []byte { b, err := protojson.Marshal(fm); must(err); return b }
		o.jsonDecode = func(b []byte) uint64 {
			m := &bench.MediumMessage{}
			must(protojson.Unmarshal(b, m))
			return uint64(m.GetCreatedAt())
		}
		return o, fm
	case "large":
		o.decodeMsg = func(b []byte) (proto.Message, error) { m := &bench.LargeMessage{}; return m, proto.Unmarshal(b, m) }
		o.jsonDecMsg = func(b []byte) (proto.Message, error) { m := &bench.LargeMessage{}; return m, protojson.Unmarshal(b, m) }
		fm := &bench.LargeMessage{}
		must(proto.Unmarshal(wire, fm))
		o.wireDecode = func(b []byte) uint64 {
			m := &bench.LargeMessage{}
			must(proto.Unmarshal(b, m))
			return uint64(len(m.GetSource()))
		}
		o.wireEncode = func() []byte { b, err := proto.Marshal(fm); must(err); return b }
		o.jsonEncode = func() []byte { b, err := protojson.Marshal(fm); must(err); return b }
		o.jsonDecode = func(b []byte) uint64 {
			m := &bench.LargeMessage{}
			must(protojson.Unmarshal(b, m))
			return uint64(len(m.GetSource()))
		}
		return o, fm
	}
	fmt.Fprintln(os.Stderr, "unknown dataset", ds)
	os.Exit(2)
	return o, nil
}

// ---- measurement loop (identical to docs/HARNESS.md) ----

// Steady-state warm-up parameters (identical in every harness of the suite).
const (
	WARMUP_PROBE_NS = 500_000_000 // length of one warm-up probe
	STEADY_WINDOW   = 3           // consecutive probes that must agree
	STEADY_TOL      = 0.05        // max spread (hi <= lo * (1 + tol)) within the window
)

// measure returns batch, the timed rounds, the actual warm-up duration in ns and
// whether the warm-up reached a steady state before hitting warmupMax.
func measure(fn func(), warmup, warmupMax, round time.Duration, rounds int) (int, []roundResult, int64, bool) {
	batch := 1
	for { // calibration
		t0 := time.Now()
		for i := 0; i < batch; i++ {
			fn()
		}
		if time.Since(t0) >= 10*time.Millisecond {
			break
		}
		batch *= 2
	}
	minNs := warmup // warm-up: probes until steady (after >= minNs) or capped at maxNs
	maxNs := warmupMax
	if maxNs < minNs {
		maxNs = minNs
	}
	var rates [STEADY_WINDOW]float64
	n := 0
	steady := false
	w0 := time.Now()
	for {
		elapsed := time.Since(w0)
		if elapsed >= maxNs {
			break
		}
		probeNs := time.Duration(WARMUP_PROBE_NS)
		if maxNs-elapsed < probeNs {
			probeNs = maxNs - elapsed
		}
		p0 := time.Now()
		iters := 0
		for time.Since(p0) < probeNs {
			for i := 0; i < batch; i++ {
				fn()
			}
			iters += batch
		}
		rates[n%STEADY_WINDOW] = float64(iters) * 1e9 / float64(time.Since(p0).Nanoseconds())
		n++
		if time.Since(w0) >= minNs && n >= STEADY_WINDOW {
			lo, hi := rates[0], rates[0]
			for _, r := range rates[1:] {
				if r < lo {
					lo = r
				}
				if r > hi {
					hi = r
				}
			}
			if hi <= lo*(1.0+STEADY_TOL) {
				steady = true
				break
			}
		}
	}
	warmupNs := time.Since(w0).Nanoseconds()
	out := make([]roundResult, 0, rounds)
	for r := 0; r < rounds; r++ { // timed rounds
		iters := 0
		start := time.Now()
		for time.Since(start) < round {
			for i := 0; i < batch; i++ {
				fn()
			}
			iters += batch
		}
		out = append(out, roundResult{Iterations: iters, ElapsedNs: time.Since(start).Nanoseconds()})
	}
	return batch, out, warmupNs, steady
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func libraryVersion() string {
	if info, ok := debugReadBuildInfo(); ok {
		for _, d := range info {
			if d.path == libraryModule {
				return strings.TrimPrefix(d.version, "v")
			}
		}
	}
	return "?"
}

func main() {
	fs := flag.NewFlagSet("bench", flag.ExitOnError)
	fixtures := fs.String("fixtures", "", "directory containing small|medium|large.{bin,json} (required)")
	out := fs.String("out", "", "where to write the result JSON (required)")
	warmup := fs.Float64("warmup-seconds", 3, "minimum warm-up duration per dataset x operation")
	warmupMax := fs.Float64("warmup-max-seconds", 15, "maximum warm-up duration per dataset x operation (stops earlier once the rate is steady)")
	roundS := fs.Float64("round-seconds", 1, "duration of one timed round")
	rounds := fs.Int("rounds", 10, "number of timed rounds")
	datasetsArg := fs.String("datasets", strings.Join(allDatasets, ","), "subset of small,medium,large")
	opsArg := fs.String("ops", strings.Join(allOps, ","), "subset of wire_encode,wire_decode,json_encode,json_decode")
	dump := fs.String("dump", "", "write <dataset>.wire.bin and <dataset>.json into DIR")
	must(fs.Parse(os.Args[1:]))
	if fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "unexpected positional arguments:", fs.Args())
		os.Exit(2)
	}
	if *fixtures == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "--fixtures and --out are required")
		os.Exit(2)
	}
	datasets := splitList(*datasetsArg)
	ops := splitList(*opsArg)
	for _, d := range datasets {
		if !contains(allDatasets, d) {
			fmt.Fprintln(os.Stderr, "unknown dataset", d)
			os.Exit(2)
		}
	}
	for _, o := range ops {
		if !contains(allOps, o) {
			fmt.Fprintln(os.Stderr, "unknown op", o)
			os.Exit(2)
		}
	}
	checkDuration("warmup-seconds", *warmup)
	checkDuration("warmup-max-seconds", *warmupMax)
	checkDuration("round-seconds", *roundS)
	warmupD := time.Duration(*warmup * float64(time.Second))
	warmupMaxD := time.Duration(*warmupMax * float64(time.Second))
	roundD := time.Duration(*roundS * float64(time.Second))

	var results []result
	for _, ds := range datasets {
		wire, err := os.ReadFile(filepath.Join(*fixtures, ds+".bin"))
		must(err)
		text, err := os.ReadFile(filepath.Join(*fixtures, ds+".json"))
		must(err)
		o, fixtureMsg := opsFor(ds, wire)

		// validation
		reenc, err := o.encodeMsg(fixtureMsg)
		must(err)
		v := validation{
			WireBytesMatch: bytes.Equal(reenc, wire),
			WireSizeMatch:  len(reenc) == len(wire),
		}
		js, err := o.jsonEncMsg(fixtureMsg)
		must(err)
		jb := len(js)
		v.JSONBytes = &jb
		back0, err := o.jsonDecMsg(js)
		must(err)
		back, err := o.encodeMsg(back0)
		must(err)
		var rt bool
		if v.WireBytesMatch {
			rt = bytes.Equal(back, wire)
		} else {
			rt = len(back) == len(wire)
		}
		v.JSONRoundtrip = &rt
		if *dump != "" {
			must(os.MkdirAll(*dump, 0o755))
			must(os.WriteFile(filepath.Join(*dump, ds+".json"), js, 0o644))
			must(os.WriteFile(filepath.Join(*dump, ds+".wire.bin"), reenc, 0o644))
		}

		for _, op := range ops {
			var fn func()
			var payload int
			switch op {
			case "wire_decode":
				payload = len(wire)
				fn = func() { sink ^= o.wireDecode(wire) }
			case "wire_encode":
				payload = len(wire)
				fn = func() { sink ^= uint64(len(o.wireEncode())) }
			case "json_decode":
				payload = len(text)
				fn = func() { sink ^= o.jsonDecode(text) }
			case "json_encode":
				payload = len(text)
				fn = func() { sink ^= uint64(len(o.jsonEncode())) }
			}
			batch, rr, warmupNs, steady := measure(fn, warmupD, warmupMaxD, roundD, *rounds)
			vcopy := v
			pb := payload
			b := batch
			wn := warmupNs
			st := steady
			results = append(results, result{
				Dataset: ds, Operation: op, Supported: true, PayloadBytes: &pb,
				Validation: &vcopy, WarmupNs: &wn, Steady: &st, Batch: &b, Rounds: rr,
			})
			best := 0.0
			for _, r := range rr {
				if x := float64(r.Iterations) / float64(r.ElapsedNs) * 1e9; x > best {
					best = x
				}
			}
			steadyStr := "steady"
			if !steady {
				steadyStr = "NOT steady"
			}
			fmt.Fprintf(os.Stderr, "%s/%s %-6s %-12s %14.1f ops/s warmup %.1fs %s\n", harnessLanguage, harnessName, ds, op, best, float64(warmupNs)/1e9, steadyStr)
		}
	}

	doc := document{
		SchemaVersion: 1,
		Harness: harnessInfo{
			Language:       harnessLanguage,
			Name:           harnessName,
			Runtime:        fmt.Sprintf("%s (GOMAXPROCS=%d)", runtime.Version(), runtime.GOMAXPROCS(0)),
			LibraryVersion: libraryVersion(),
		},
		Results: results,
	}
	if doc.Results == nil {
		doc.Results = []result{}
	}
	data, err := json.MarshalIndent(doc, "", " ")
	must(err)
	must(os.WriteFile(*out, append(data, '\n'), 0o644))
	fmt.Fprintf(os.Stderr, "sink=%d\n", sink)
}
