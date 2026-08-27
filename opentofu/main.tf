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
