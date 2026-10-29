package main

import (
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	labels = []string{"namespace", "image", "digest"}

	descVulnerabilities = prometheus.NewDesc("image_audit_vulnerabilities",
		"Vulnerabilities Zot's Trivy scan found in a running image, by severity.",
		append(labels, "severity"), nil)
	descMirrored = prometheus.NewDesc("image_audit_mirrored",
		"1 if the image's registry is one Zot proxies.", labels, nil)
	descCached = prometheus.NewDesc("image_audit_cached",
		"1 if Zot holds the image the node runs, so it can be pulled again without the upstream.", labels, nil)
	descScanned = prometheus.NewDesc("image_audit_scanned",
		"1 if Zot returned a vulnerability scan for the image.", labels, nil)
	descSigned = prometheus.NewDesc("image_audit_signed",
		"1 if the image carries a cosign or notation signature.", labels, nil)
	descTrusted = prometheus.NewDesc("image_audit_signature_trusted",
		"1 if one of the image's signatures verifies with a public key Zot trusts.", labels, nil)
	descLastRun = prometheus.NewDesc("image_audit_last_run_timestamp_seconds",
		"When the last audit run finished.", nil, nil)
	descDuration = prometheus.NewDesc("image_audit_last_run_duration_seconds",
		"How long the last audit run took.", nil, nil)
	descImages = prometheus.NewDesc("image_audit_images",
		"Distinct images the last audit run found running.", nil, nil)
)

// collector serves the results of the last completed run, so a scrape never sees a run in progress.
type collector struct {
	mu       sync.RWMutex
	results  []result
	finished time.Time
	duration time.Duration
}

func (c *collector) set(results []result, finished time.Time, duration time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.results, c.finished, c.duration = results, finished, duration
}

func (c *collector) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{descVulnerabilities, descMirrored, descCached, descScanned, descSigned, descTrusted, descLastRun, descDuration, descImages} {
		ch <- d
	}
}

func boolValue(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func (c *collector) Collect(ch chan<- prometheus.Metric) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.finished.IsZero() {
		return
	}
	ch <- prometheus.MustNewConstMetric(descLastRun, prometheus.GaugeValue, float64(c.finished.Unix()))
	ch <- prometheus.MustNewConstMetric(descDuration, prometheus.GaugeValue, c.duration.Seconds())
	ch <- prometheus.MustNewConstMetric(descImages, prometheus.GaugeValue, float64(len(c.results)))

	for _, r := range c.results {
		signed, trusted := len(r.Signatures) > 0, false
		for _, s := range r.Signatures {
			trusted = trusted || s.Trusted
		}
		for _, ns := range r.Namespaces {
			lv := []string{ns, r.Image.Name, r.Image.Digest}
			gauge := func(d *prometheus.Desc, v float64, extra ...string) {
				ch <- prometheus.MustNewConstMetric(d, prometheus.GaugeValue, v, append(lv, extra...)...)
			}
			gauge(descMirrored, boolValue(r.Mirrored))
			if !r.Mirrored {
				continue
			}
			gauge(descCached, boolValue(r.Cached))
			gauge(descScanned, boolValue(r.Scanned))
			if r.Scanned {
				v := r.Vulnerabilities
				gauge(descVulnerabilities, float64(v.Critical), "critical")
				gauge(descVulnerabilities, float64(v.High), "high")
				gauge(descVulnerabilities, float64(v.Medium), "medium")
				gauge(descVulnerabilities, float64(v.Low), "low")
				gauge(descVulnerabilities, float64(v.Unknown), "unknown")
			}
			if r.Cached {
				gauge(descSigned, boolValue(signed))
				gauge(descTrusted, boolValue(trusted))
			}
		}
	}
}
