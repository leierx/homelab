variable "talos_version" {
  description = "Pinned Talos release used for the VM image and machine configuration."
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
