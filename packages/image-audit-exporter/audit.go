package main

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// image is one image a container runs, as the kubelet reports it: Status.Image is the
// normalized name the pod asked for (docker.io/library/redis:8.6.4-alpine) and
// Status.ImageID the repository digest the runtime pulled (docker.io/library/redis@sha256:…).
type image struct {
	Name   string
	Repo   string
	Tag    string
	Digest string
}

// result is what one audit run learned about one image, reported for every namespace running it.
type result struct {
	Image      image
	Namespaces []string
	// Mirrored is false for images from a registry Zot doesn't proxy; nothing else is known then.
	Mirrored bool
	// Cached is true once Zot has the platform image, so the node can pull it without the upstream.
	Cached          bool
	Scanned         bool
	Vulnerabilities vulnerabilities
	Signatures      []signature
}

type auditor struct {
	zot        *zotClient
	registries []string
	platform   platform
	timeout    time.Duration
}

// parseImage splits a container status into the image name and the pulled repository digest;
// ok is false for statuses without a repository digest (a container still being created, or an
// image only known by its local ID).
func parseImage(statusImage, imageID string) (image, bool) {
	repo, digest, found := strings.Cut(imageID, "@")
	if !found || !strings.HasPrefix(digest, "sha256:") || !strings.Contains(repo, "/") {
		return image{}, false
	}
	name := statusImage
	if name == "" || strings.HasPrefix(name, "sha256:") {
		name = repo + "@" + digest
	}
	return image{Name: name, Repo: repo, Tag: tag(name), Digest: digest}, true
}

// tag returns the tag in an image name (redis:8 -> 8, quay.io/a/b:v1@sha256:… -> v1), or "".
func tag(name string) string {
	name, _, _ = strings.Cut(name, "@")
	i := strings.LastIndex(name, ":")
	if i < 0 || strings.Contains(name[i:], "/") {
		return ""
	}
	return name[i+1:]
}

// images returns every distinct image the pods run, with the namespaces running it, sorted.
func images(pods []corev1.Pod) map[image][]string {
	found := map[image][]string{}
	for _, pod := range pods {
		statuses := slices.Concat(pod.Status.InitContainerStatuses, pod.Status.ContainerStatuses, pod.Status.EphemeralContainerStatuses)
		for _, s := range statuses {
			img, ok := parseImage(s.Image, s.ImageID)
			if !ok {
				continue
			}
			if !slices.Contains(found[img], pod.Namespace) {
				found[img] = append(found[img], pod.Namespace)
			}
		}
	}
	for img := range found {
		slices.Sort(found[img])
	}
	return found
}

// registry returns the host part of a normalized repository (docker.io/library/redis -> docker.io).
func registry(repo string) string {
	host, _, _ := strings.Cut(repo, "/")
	return host
}

// audit looks up one image in Zot. Zot's on-demand sync stores images under
// <upstream host>/<path>, the same path the node's containerd mirror pulls from, so the
// repository digest the node pulled is the one Zot is asked for.
func (a *auditor) audit(ctx context.Context, img image, namespaces []string) result {
	r := result{Image: img, Namespaces: namespaces}
	if !slices.Contains(a.registries, registry(img.Repo)) {
		return r
	}
	r.Mirrored = true

	ctx, cancel := context.WithTimeout(ctx, a.timeout)
	defer cancel()
	log := slog.With("image", img.Name, "digest", img.Digest)

	platformDigest, err := a.zot.platformManifest(ctx, img.Repo, img.Tag, img.Digest, a.platform)
	if err != nil {
		log.Warn("image not in Zot", "error", err)
		return r
	}
	r.Cached = true

	if r.Vulnerabilities, err = a.zot.vulnerabilities(ctx, img.Repo, platformDigest); err != nil {
		log.Warn("vulnerability scan failed", "error", err)
	} else {
		r.Scanned = true
	}

	// a multi-platform image is usually signed at the index, a single-platform one at its manifest
	for _, d := range slices.Compact([]string{img.Digest, platformDigest}) {
		if err := a.zot.syncReferrers(ctx, img.Repo, d); err != nil {
			log.Warn("syncing signatures failed", "error", err)
		}
	}
	if r.Signatures, err = a.zot.signatures(ctx, img.Repo, img.Digest, platformDigest); err != nil {
		log.Warn("reading signatures failed", "error", err)
	}
	log.Info("audited image", "scanned", r.Scanned, "critical", r.Vulnerabilities.Critical,
		"high", r.Vulnerabilities.High, "signatures", len(r.Signatures))
	return r
}

func (a *auditor) run(ctx context.Context, pods []corev1.Pod) []result {
	found := images(pods)
	keys := make([]image, 0, len(found))
	for img := range found {
		keys = append(keys, img)
	}
	slices.SortFunc(keys, func(x, y image) int { return strings.Compare(x.Name+x.Digest, y.Name+y.Digest) })

	results := make([]result, 0, len(keys))
	for _, img := range keys {
		if ctx.Err() != nil {
			break
		}
		results = append(results, a.audit(ctx, img, found[img]))
	}
	return results
}

func (p platform) String() string {
	s := fmt.Sprintf("%s/%s", p.OS, p.Architecture)
	if p.Variant != "" {
		s += "/" + p.Variant
	}
	return s
}
