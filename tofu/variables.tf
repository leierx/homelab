variable "talos_schematic_id" {
  description = "Talos Image Factory schematic used to build the bootable disk image."
  type        = string
  default     = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"
}

variable "talos_version" {
  description = "Pinned Talos release used for the bootable disk image. Talos configuration is applied manually."
  type        = string
  default     = "v1.13.8"
}

variable "vm_vcpu" {
  description = "Virtual CPUs assigned to each Talos node."
  type        = number
  default     = 4
}

variable "vm_memory_mib" {
  description = "Memory assigned to each Talos node in MiB."
  type        = number
  default     = 16384
}

variable "vm_disk_gib" {
  description = "Disk capacity assigned to each Talos node in GiB."
  type        = number
  default     = 32
}
