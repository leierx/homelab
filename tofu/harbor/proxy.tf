# One public proxy cache project per upstream, named after its registry, so <harbor>/<registry>/<repository>
# is what containerd's mirrors (nixos/k3s.nix) and fleet.io/oci-mirror ask for. Keep the list in step with
# both and with the allowed-registries admission policy (fleet/addons/admission).
locals {
  upstreams = {
    "docker.io"          = { provider = "docker-hub", url = "https://hub.docker.com" }
    "ghcr.io"            = { provider = "docker-registry", url = "https://ghcr.io" }
    "quay.io"            = { provider = "docker-registry", url = "https://quay.io" }
    "registry.k8s.io"    = { provider = "docker-registry", url = "https://registry.k8s.io" }
    "ecr-public.aws.com" = { provider = "docker-registry", url = "https://ecr-public.aws.com" }
  }
}

resource "harbor_registry" "upstream" {
  for_each      = local.upstreams
  name          = each.key
  provider_name = each.value.provider
  endpoint_url  = each.value.url
}

resource "harbor_project" "proxy" {
  for_each    = local.upstreams
  name        = each.key
  registry_id = harbor_registry.upstream[each.key].registry_id
  # containerd and Argo CD pull anonymously
  public = true
  # an image the upstream deleted keeps being served from the cache
  proxy_cache_local_on_not_found = true
}

# every project event as one JSON line into Loki ({job="harbor-webhook"}) through Alloy's raw push endpoint
resource "harbor_project_webhook" "loki" {
  for_each    = harbor_project.proxy
  name        = "loki"
  project_id  = each.value.id
  address     = "http://alloy-logs.telemetry.svc:3500/loki/api/v1/raw"
  notify_type = "http"
  events_types = [
    "DELETE_ARTIFACT",
    "PULL_ARTIFACT",
    "PUSH_ARTIFACT",
    "SCANNING_COMPLETED",
    "SCANNING_FAILED",
    "TAG_RETENTION",
  ]
}
