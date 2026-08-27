variable "name" {
  description = "Cluster name. Drives network name, node names, ACL prefixes."
  type        = string
}

variable "cluster_yaml" {
  description = "Decoded clusters/<name>/cluster.yaml."
  type = object({
    network = object({
      cidr             = string
      gateway          = string
      mac_prefix       = string
      dns_domain       = string
      dhcp_range_start = number
      dhcp_range_end   = number
    })
    node_specs = object({
      cpu        = number
      memory_gib = number
      disk_gib   = number
    })
  })
}

variable "nodes" {
  description = "Decoded clusters/<name>/nodes/*.yaml, keyed by filename (e.g. master-01)."
  type = map(object({
    role       = string
    bootstrap  = optional(bool, false)
    ip_offset  = number
    mac_offset = number
  }))

  validation {
    condition     = length([for n in var.nodes : n if n.bootstrap]) == 1
    error_message = "Exactly one node per cluster must set bootstrap: true."
  }

  validation {
    condition     = alltrue([for n in var.nodes : contains(["controlplane", "worker"], n.role)])
    error_message = "Node role must be \"controlplane\" or \"worker\"."
  }

  validation {
    condition     = alltrue([for n in var.nodes : n.role == "controlplane" if n.bootstrap])
    error_message = "The bootstrap node must have role \"controlplane\"."
  }
}

variable "acls" {
  description = "Decoded clusters/<name>/acls/*.yaml, keyed by filename."
  type = map(object({
    description = optional(string, "")
    ingress     = optional(list(map(string)), [])
    egress      = optional(list(map(string)), [])
  }))
  default = {}
}

variable "image" {
  description = "Fingerprint (or alias) of the Kairos base image every node boots from."
  type        = string
}

variable "pool" {
  description = "Storage pool holding the node root disks."
  type        = string
}
