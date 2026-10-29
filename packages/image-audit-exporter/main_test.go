package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	indexDigest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
	amd64Digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
	arm64Digest = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
	plainDigest = "sha256:4444444444444444444444444444444444444444444444444444444444444444"
)

func TestParseImage(t *testing.T) {
	tests := []struct {
		name, image, imageID string
		want                 image
		ok                   bool
	}{
		{"tag", "docker.io/library/redis:8.6.4-alpine", "docker.io/library/redis@" + indexDigest,
			image{"docker.io/library/redis:8.6.4-alpine", "docker.io/library/redis", indexDigest}, true},
		{"tag and digest", "quay.io/cilium/cilium:v1.20.4@" + indexDigest, "quay.io/cilium/cilium@" + indexDigest,
			image{"quay.io/cilium/cilium:v1.20.4@" + indexDigest, "quay.io/cilium/cilium", indexDigest}, true},
		{"image is a local ID", "sha256:abc", "ghcr.io/leierx/x@" + plainDigest,
			image{"ghcr.io/leierx/x@" + plainDigest, "ghcr.io/leierx/x", plainDigest}, true},
		{"container being created", "docker.io/library/redis:8", "", image{}, false},
		{"image ID without repository", "docker.io/library/redis:8", "sha256:abc", image{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := parseImage(tt.image, tt.imageID)
			if ok != tt.ok || got != tt.want {
				t.Errorf("parseImage() = %+v, %v; want %+v, %v", got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestImagesGroupsNamespaces(t *testing.T) {
	status := func(img, id string) corev1.ContainerStatus { return corev1.ContainerStatus{Image: img, ImageID: id} }
	pods := []corev1.Pod{
		{ObjectMeta: metav1.ObjectMeta{Namespace: "b"}, Status: corev1.PodStatus{
			InitContainerStatuses: []corev1.ContainerStatus{status("docker.io/library/busybox:1", "docker.io/library/busybox@"+plainDigest)},
			ContainerStatuses:     []corev1.ContainerStatus{status("docker.io/library/redis:8", "docker.io/library/redis@"+indexDigest)},
		}},
		{ObjectMeta: metav1.ObjectMeta{Namespace: "a"}, Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{
				status("docker.io/library/redis:8", "docker.io/library/redis@"+indexDigest),
				status("docker.io/library/redis:8", ""),
			},
		}},
		{ObjectMeta: metav1.ObjectMeta{Namespace: "a"}, Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{status("docker.io/library/redis:8", "docker.io/library/redis@"+indexDigest)},
		}},
	}
	got := images(pods)
	redis := image{"docker.io/library/redis:8", "docker.io/library/redis", indexDigest}
	if len(got) != 2 || !slices.Equal(got[redis], []string{"a", "b"}) {
		t.Errorf("images() = %v", got)
	}
}

func TestParsePlatform(t *testing.T) {
	if p, err := parsePlatform("linux/arm/v7"); err != nil || p != (platform{"linux", "arm", "v7"}) {
		t.Errorf("parsePlatform(linux/arm/v7) = %+v, %v", p, err)
	}
	for _, bad := range []string{"linux", "linux/", "/amd64", "a/b/c/d"} {
		if _, err := parsePlatform(bad); err == nil {
			t.Errorf("parsePlatform(%q) accepted", bad)
		}
	}
}

// fakeZot answers like Zot for one multi-platform repository and one single-platform one.
type fakeZot struct {
	fetched   []string
	referrers []string
}

func (f *fakeZot) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case strings.HasPrefix(r.URL.Path, "/v2/docker.io/library/redis/manifests/"):
		ref := strings.TrimPrefix(r.URL.Path, "/v2/docker.io/library/redis/manifests/")
		f.fetched = append(f.fetched, ref)
		if !strings.Contains(r.Header.Get("Accept"), "application/vnd.docker.distribution.manifest.list.v2+json") {
			http.Error(w, "accept", http.StatusNotAcceptable)
			return
		}
		switch ref {
		case indexDigest:
			_, _ = io.WriteString(w, `{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
				{"digest":"`+arm64Digest+`","platform":{"os":"linux","architecture":"arm64"}},
				{"digest":"`+amd64Digest+`","platform":{"os":"linux","architecture":"amd64"}}]}`)
		case amd64Digest:
			_, _ = io.WriteString(w, `{"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}`)
		default:
			http.NotFound(w, r)
		}
	case strings.HasPrefix(r.URL.Path, "/v2/ghcr.io/leierx/gone/manifests/"):
		http.NotFound(w, r)
	case strings.Contains(r.URL.Path, "/referrers/"):
		f.referrers = append(f.referrers, r.URL.Path)
		_, _ = io.WriteString(w, `{"manifests":[]}`)
	case r.URL.Path == "/v2/_zot/ext/search" && r.Method == http.MethodPost:
		var req struct {
			Query     string
			Variables map[string]string
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		switch {
		case strings.Contains(req.Query, "CVEListForImage") && req.Variables["image"] == "docker.io/library/redis@"+amd64Digest:
			_, _ = io.WriteString(w, `{"data":{"CVEListForImage":{"Summary":{"CriticalCount":1,"HighCount":2,"MediumCount":3,"LowCount":4,"UnknownCount":5}}}}`)
		case strings.Contains(req.Query, "ImageListForDigest") && req.Variables["digest"] == indexDigest:
			_, _ = io.WriteString(w, `{"data":{"ImageListForDigest":{"Results":[
				{"RepoName":"docker.io/library/other","Digest":"`+indexDigest+`","SignatureInfo":[{"Tool":"cosign","IsTrusted":true}],"Manifests":[]},
				{"RepoName":"docker.io/library/redis","Digest":"`+indexDigest+`","SignatureInfo":[{"Tool":"cosign","IsTrusted":false}],
				 "Manifests":[{"Digest":"`+amd64Digest+`","SignatureInfo":[{"Tool":"notation","IsTrusted":true}]},
				              {"Digest":"`+arm64Digest+`","SignatureInfo":[{"Tool":"cosign","IsTrusted":true}]}]}]}}}`)
		default:
			_, _ = io.WriteString(w, `{"errors":[{"message":"tag metadata not found"}],"data":null}`)
		}
	default:
		http.NotFound(w, r)
	}
}

func newTestAuditor(t *testing.T) (*auditor, *fakeZot) {
	f := &fakeZot{}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	return &auditor{
		zot:        &zotClient{baseURL: srv.URL, http: srv.Client()},
		registries: []string{"docker.io", "ghcr.io"},
		platform:   platform{OS: "linux", Architecture: "amd64"},
		timeout:    time.Minute,
	}, f
}

func TestAuditMultiPlatformImage(t *testing.T) {
	a, f := newTestAuditor(t)
	img := image{"docker.io/library/redis:8", "docker.io/library/redis", indexDigest}

	r := a.audit(context.Background(), img, []string{"argocd"})

	if !r.Mirrored || !r.Cached || !r.Scanned {
		t.Fatalf("result = %+v", r)
	}
	if !slices.Equal(f.fetched, []string{indexDigest, amd64Digest}) {
		t.Errorf("fetched %v, want the index and then the amd64 image", f.fetched)
	}
	if len(f.referrers) != 2 {
		t.Errorf("referrers synced for %v, want the index and the amd64 image", f.referrers)
	}
	if r.Vulnerabilities != (vulnerabilities{Critical: 1, High: 2, Medium: 3, Low: 4, Unknown: 5}) {
		t.Errorf("vulnerabilities = %+v", r.Vulnerabilities)
	}
	want := []signature{{"cosign", false}, {"notation", true}}
	if !slices.Equal(r.Signatures, want) {
		t.Errorf("signatures = %+v, want %+v (the other repository and the arm64 image don't count)", r.Signatures, want)
	}
}

func TestAuditImageMissingFromZot(t *testing.T) {
	a, _ := newTestAuditor(t)
	r := a.audit(context.Background(), image{"ghcr.io/leierx/gone:1", "ghcr.io/leierx/gone", plainDigest}, []string{"x"})
	if !r.Mirrored || r.Cached || r.Scanned {
		t.Errorf("result = %+v, want mirrored but not cached or scanned", r)
	}
}

func TestAuditUnmirroredRegistry(t *testing.T) {
	a, f := newTestAuditor(t)
	r := a.audit(context.Background(), image{"example.com/app:1", "example.com/app", plainDigest}, []string{"x"})
	if r.Mirrored || len(f.fetched) != 0 {
		t.Errorf("result = %+v, fetched %v; want Zot left alone", r, f.fetched)
	}
}

func TestCollector(t *testing.T) {
	c := &collector{}
	if n := testutil.CollectAndCount(c); n != 0 {
		t.Errorf("collected %d metrics before the first run", n)
	}

	redis := image{"docker.io/library/redis:8", "docker.io/library/redis", indexDigest}
	c.set([]result{
		{Image: redis, Namespaces: []string{"a", "b"}, Mirrored: true, Cached: true, Scanned: true,
			Vulnerabilities: vulnerabilities{Critical: 2}, Signatures: []signature{{"cosign", false}, {"cosign", true}}},
		{Image: image{"example.com/app:1", "example.com/app", plainDigest}, Namespaces: []string{"a"}},
	}, time.Unix(1000, 0), 3*time.Second)

	expected := `
# HELP image_audit_signature_trusted 1 if one of the image's signatures verifies with a public key Zot trusts.
# TYPE image_audit_signature_trusted gauge
image_audit_signature_trusted{digest="` + indexDigest + `",image="docker.io/library/redis:8",namespace="a"} 1
image_audit_signature_trusted{digest="` + indexDigest + `",image="docker.io/library/redis:8",namespace="b"} 1
# HELP image_audit_mirrored 1 if the image's registry is one Zot proxies.
# TYPE image_audit_mirrored gauge
image_audit_mirrored{digest="` + indexDigest + `",image="docker.io/library/redis:8",namespace="a"} 1
image_audit_mirrored{digest="` + indexDigest + `",image="docker.io/library/redis:8",namespace="b"} 1
image_audit_mirrored{digest="` + plainDigest + `",image="example.com/app:1",namespace="a"} 0
`
	if err := testutil.CollectAndCompare(c, strings.NewReader(expected), "image_audit_signature_trusted", "image_audit_mirrored"); err != nil {
		t.Error(err)
	}
	// 3 run gauges, 1 for the unmirrored image, and per redis namespace: mirrored, cached, scanned, 5 severities, signed, trusted
	if n := testutil.CollectAndCount(c); n != 3+1+2*10 {
		t.Errorf("collected %d metrics", n)
	}
}
