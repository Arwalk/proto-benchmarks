package main

import "runtime/debug"

type depInfo struct{ path, version string }

// debugReadBuildInfo returns the module dependencies baked into the binary so
// the reported library_version is exactly what was linked.
func debugReadBuildInfo() ([]depInfo, bool) {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return nil, false
	}
	out := make([]depInfo, 0, len(bi.Deps))
	for _, d := range bi.Deps {
		if d.Replace != nil {
			d = d.Replace
		}
		out = append(out, depInfo{d.Path, d.Version})
	}
	return out, true
}
