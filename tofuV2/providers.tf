# tofu runs on loftserveren01 itself (the Makefile rsyncs and SSHes), so the
# provider talks to the local Incus daemon over its unix socket. No TLS token
# needed. Point a `remote` block here instead if you ever run tofu elsewhere.
provider "incus" {}
