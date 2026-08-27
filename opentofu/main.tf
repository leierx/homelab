resource "incus_storage_pool" "default" {
  name   = "default"
  driver = "dir"
}

# IMPORTANT: Incus VM images must be qcow2 split images — built by `make image`
resource "incus_image" "kairos" {
  source_file = {
    data_path     = var.image_path
    metadata_path = var.image_metadata_path
  }

  alias {
    name = "kairos-hadron"
  }
}
