resource "incus_storage_pool" "default" {
  name   = "default"
  driver = "dir"
}

# The Kairos base image, imported once. Every VM's root disk is created from
# this image by Incus (one image, cloned per instance). Raw block volumes
# can't be imported on Incus 7.x, so `make image` converts the AuroraBoot raw
# to qcow2 and this imports it as a split VM image (metadata tarball + disk).
resource "incus_image" "kairos" {
  source_file = {
    data_path     = var.image_path
    metadata_path = var.image_metadata_path
  }

  alias {
    name = "kairos-hadron"
  }
}

locals {
  cluster_names = toset([
    for f in fileset("${path.module}/clusters", "*/cluster.yaml") : dirname(f)
  ])
}

module "cluster" {
  source   = "./modules/cluster"
  for_each = local.cluster_names

  name         = each.key
  cluster_yaml = yamldecode(file("${path.module}/clusters/${each.key}/cluster.yaml"))
  nodes = {
    for f in fileset("${path.module}/clusters/${each.key}/nodes", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/clusters/${each.key}/nodes/${f}"))
  }
  acls = {
    for f in fileset("${path.module}/clusters/${each.key}/acls", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/clusters/${each.key}/acls/${f}"))
  }
  image = incus_image.kairos.fingerprint
  pool  = incus_storage_pool.default.name
}
