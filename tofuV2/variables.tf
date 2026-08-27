variable "image_path" {
  description = "Path (on the Incus host, relative to this module) to the qcow2 produced by `make image`."
  type        = string
  default     = "image/build/kairos-hadron.qcow2"
}

variable "image_metadata_path" {
  description = "Path to the Incus image metadata tarball produced by `make image`."
  type        = string
  default     = "image/build/kairos-metadata.tar.gz"
}
