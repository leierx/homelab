# runs on loftserveren01 itself; for plan/apply just type `tofu plan` etc.

KUBE_DIR := $(HOME)/.kube
# no incus-agent in Kairos VMs, and host keys churn on VM replacement
VMSSH := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

.PHONY: image kubeconfig kubeconfig-replace

image:
	cd image && mkdir -p build && \
	  out=$$(nix build -L --no-link --print-out-paths "path:.#kairos-hadron-image") && \
	  install -m 644 "$$out/kairos-hadron.qcow2" build/kairos-hadron.qcow2 && \
	  install -m 644 "$$out/kairos-metadata.tar.gz" build/kairos-metadata.tar.gz

# k3s admin kubeconfigs -> ~/.kube/config-hadron (contexts prod/test/mgmt/...)
kubeconfig:
	@mkdir -p $(KUBE_DIR); tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	ips=$$(tofu output -json bootstrap_ips); \
	clusters=$$(echo "$$ips" | yq 'keys | .[]'); \
	for c in $$clusters; do \
	  ip=$$(echo "$$ips" | yq ".$$c"); \
	  $(VMSSH) kairos@$$ip 'sudo cat /etc/rancher/k3s/k3s.yaml' \
	    | yq "(.clusters[].cluster.server) = \"https://$$ip:6443\" \
	        | (.clusters[].name, .contexts[].context.cluster, .contexts[].context.user, .contexts[].name, .users[].name) = \"$$c\" \
	        | .\"current-context\" = \"$$c\"" \
	    > "$$tmp/$$c.yaml"; \
	done; \
	KUBECONFIG=$$(printf '%s:' "$$tmp"/*.yaml) kubectl config view --flatten > $(KUBE_DIR)/config-hadron; \
	chmod 600 $(KUBE_DIR)/config-hadron; \
	echo "wrote $(KUBE_DIR)/config-hadron (contexts: $$(echo $$clusters))"

# merge config-hadron into ~/.kube/config (backup kept), replacing it
kubeconfig-replace:
	@[ -f $(KUBE_DIR)/config-hadron ] || { echo "run 'make kubeconfig' first"; exit 1; }
	@[ -f $(KUBE_DIR)/config ] && cp $(KUBE_DIR)/config $(KUBE_DIR)/config.bak || true
	@KUBECONFIG=$(KUBE_DIR)/config:$(KUBE_DIR)/config-hadron kubectl config view --flatten > $(KUBE_DIR)/config.new
	@mv $(KUBE_DIR)/config.new $(KUBE_DIR)/config && chmod 600 $(KUBE_DIR)/config
	@echo "merged into $(KUBE_DIR)/config (backup: $(KUBE_DIR)/config.bak)"
