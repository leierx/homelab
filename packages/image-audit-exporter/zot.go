package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// manifestAccept lists every manifest media type a container runtime asks for, so Zot answers
// with whatever the upstream holds (and syncs it on demand) instead of a 404 for docker types.
const manifestAccept = "application/vnd.oci.image.index.v1+json, " +
	"application/vnd.oci.image.manifest.v1+json, " +
	"application/vnd.docker.distribution.manifest.list.v2+json, " +
	"application/vnd.docker.distribution.manifest.v2+json"

var errNotFound = errors.New("not found in Zot")

type zotClient struct {
	baseURL string
	http    *http.Client
}

type platform struct {
	OS           string `json:"os"`
	Architecture string `json:"architecture"`
	Variant      string `json:"variant,omitempty"`
}

type manifest struct {
	MediaType string `json:"mediaType"`
	Manifests []struct {
		Digest   string   `json:"digest"`
		Platform platform `json:"platform"`
	} `json:"manifests"`
}

type vulnerabilities struct {
	Critical, High, Medium, Low, Unknown int
}

type signature struct {
	Tool    string
	Trusted bool
}

// fetchManifest GETs a manifest, which makes Zot sync it (with its layers, for an image
// manifest) from the upstream and counts as a pull for its retention policy.
func (z *zotClient) fetchManifest(ctx context.Context, repo, reference string) (*manifest, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/v2/%s/manifests/%s", z.baseURL, repo, reference), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", manifestAccept)

	resp, err := z.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("manifest %s@%s: %w", repo, reference, errNotFound)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("manifest %s@%s: HTTP %d", repo, reference, resp.StatusCode)
	}

	var m manifest
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return nil, fmt.Errorf("manifest %s@%s: %w", repo, reference, err)
	}
	return &m, nil
}

// platformManifest returns the digest of the image manifest the node runs: the digest itself
// for a single-platform image, or the index entry matching want for a multi-platform one.
func (z *zotClient) platformManifest(ctx context.Context, repo, digest string, want platform) (string, error) {
	m, err := z.fetchManifest(ctx, repo, digest)
	if err != nil {
		return "", err
	}
	if len(m.Manifests) == 0 {
		return digest, nil
	}

	for _, entry := range m.Manifests {
		p := entry.Platform
		if p.OS == want.OS && p.Architecture == want.Architecture && (want.Variant == "" || p.Variant == want.Variant) {
			// Zot syncs only the index on its own; asking for the child brings in the image and its layers
			if _, err := z.fetchManifest(ctx, repo, entry.Digest); err != nil {
				return "", err
			}
			return entry.Digest, nil
		}
	}
	return "", fmt.Errorf("%s@%s has no %s/%s image", repo, digest, want.OS, want.Architecture)
}

// syncReferrers asks for the referrers of a digest, which makes Zot sync the upstream's
// signatures and attestations for it. The answer itself is not needed.
func (z *zotClient) syncReferrers(ctx context.Context, repo, digest string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/v2/%s/referrers/%s", z.baseURL, repo, digest), nil)
	if err != nil {
		return err
	}
	resp, err := z.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("referrers %s@%s: HTTP %d", repo, digest, resp.StatusCode)
	}
	return nil
}

func (z *zotClient) graphql(ctx context.Context, query string, variables map[string]string, out any) error {
	body, err := json.Marshal(map[string]any{"query": query, "variables": variables})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, z.baseURL+"/v2/_zot/ext/search", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := z.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("search API: HTTP %d", resp.StatusCode)
	}

	var result struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("search API: %w", err)
	}
	if len(result.Errors) > 0 {
		messages := make([]string, 0, len(result.Errors))
		for _, e := range result.Errors {
			messages = append(messages, e.Message)
		}
		return fmt.Errorf("search API: %s", strings.Join(messages, "; "))
	}
	return json.Unmarshal(result.Data, out)
}

// vulnerabilities has Zot's Trivy scan the image manifest (or return its cached result).
func (z *zotClient) vulnerabilities(ctx context.Context, repo, digest string) (vulnerabilities, error) {
	const query = `query($image: String!) {
  CVEListForImage(image: $image, requestedPage: {limit: 1, offset: 0}) {
    Summary { CriticalCount HighCount MediumCount LowCount UnknownCount }
  }
}`
	var data struct {
		CVEListForImage struct {
			Summary struct {
				CriticalCount, HighCount, MediumCount, LowCount, UnknownCount int
			}
		}
	}
	if err := z.graphql(ctx, query, map[string]string{"image": repo + "@" + digest}, &data); err != nil {
		return vulnerabilities{}, err
	}
	s := data.CVEListForImage.Summary
	return vulnerabilities{Critical: s.CriticalCount, High: s.HighCount, Medium: s.MediumCount, Low: s.LowCount, Unknown: s.UnknownCount}, nil
}

// signatures returns the signatures on digest and on the platform manifest beneath it, with
// whether one of the public keys Zot trusts verifies them.
func (z *zotClient) signatures(ctx context.Context, repo, digest, platformDigest string) ([]signature, error) {
	const query = `query($digest: String!) {
  ImageListForDigest(id: $digest, requestedPage: {limit: 100, offset: 0}) {
    Results {
      RepoName Digest
      SignatureInfo { Tool IsTrusted }
      Manifests { Digest SignatureInfo { Tool IsTrusted } }
    }
  }
}`
	type signatureInfo struct {
		Tool      string
		IsTrusted bool
	}
	var data struct {
		ImageListForDigest struct {
			Results []struct {
				RepoName      string
				Digest        string
				SignatureInfo []signatureInfo
				Manifests     []struct {
					Digest        string
					SignatureInfo []signatureInfo
				}
			}
		}
	}
	if err := z.graphql(ctx, query, map[string]string{"digest": digest}, &data); err != nil {
		return nil, err
	}

	var sigs []signature
	add := func(infos []signatureInfo) {
		for _, s := range infos {
			sigs = append(sigs, signature{Tool: s.Tool, Trusted: s.IsTrusted})
		}
	}
	for _, r := range data.ImageListForDigest.Results {
		if r.RepoName != repo || r.Digest != digest {
			continue
		}
		add(r.SignatureInfo)
		for _, m := range r.Manifests {
			if m.Digest == platformDigest && m.Digest != digest {
				add(m.SignatureInfo)
			}
		}
		break
	}
	return sigs, nil
}
