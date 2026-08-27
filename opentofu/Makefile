# Runs on loftserveren01 itself (tofu, incus and the podman socket live there).
# For plan/apply/destroy just type `tofu plan` etc.

KUBE_DIR := $(HOME)/.kube
# SSH into a VM: incus exec doesn't work (Kairos runs no incus-agent), and
# host keys churn on VM replacement, so don't pin them.
VMSSH := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

.PHONY: image kubeconfig kubeconfig-merge

image:
	cd image && ./build.sh

# Fetch each cluster's k3s admin kubeconfig, point it at the bootstrap CP IP,
# rename everything default -> hadron-<cluster>, merge into ~/.kube/config-hadron.
# Needs yq (mikefarah v4) and kubectl: nix shell nixpkgs#yq-go nixpkgs#kubectl
kubeconfig:
	@command -v yq >/dev/null || { echo "yq missing — try: nix shell nixpkgs#yq-go"; exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl missing — try: nix shell nixpkgs#kubectl"; exit 1; }
	@mkdir -p $(KUBE_DIR); tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	ips=$$(tofu output -json bootstrap_ips); \
	clusters=$$(echo "$$ips" | yq 'keys | .[]'); \
	for c in $$clusters; do \
	  ip=$$(echo "$$ips" | yq ".$$c"); \
	  $(VMSSH) kairos@$$ip 'sudo cat /etc/rancher/k3s/k3s.yaml' \
	    | yq "(.clusters[].cluster.server) = \"https://$$ip:6443\" \
	        | (.clusters[].name, .contexts[].context.cluster, .contexts[].context.user, .contexts[].name, .users[].name) = \"hadron-$$c\" \
	        | .\"current-context\" = \"hadron-$$c\"" \
	    > "$$tmp/$$c.yaml"; \
	done; \
	KUBECONFIG=$$(printf '%s:' "$$tmp"/*.yaml) kubectl config view --flatten > $(KUBE_DIR)/config-hadron; \
	chmod 600 $(KUBE_DIR)/config-hadron; \
	echo "wrote $(KUBE_DIR)/config-hadron (contexts: $$(echo $$clusters))"

# Opt-in: fold ~/.kube/config-hadron into ~/.kube/config (backup kept).
kubeconfig-merge:
	@[ -f $(KUBE_DIR)/config-hadron ] || { echo "run 'make kubeconfig' first"; exit 1; }
	@[ -f $(KUBE_DIR)/config ] && cp $(KUBE_DIR)/config $(KUBE_DIR)/config.bak || true
	@KUBECONFIG=$(KUBE_DIR)/config:$(KUBE_DIR)/config-hadron kubectl config view --flatten > $(KUBE_DIR)/config.new
	@mv $(KUBE_DIR)/config.new $(KUBE_DIR)/config && chmod 600 $(KUBE_DIR)/config
	@echo "merged into $(KUBE_DIR)/config (backup: $(KUBE_DIR)/config.bak)"
