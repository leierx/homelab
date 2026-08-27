REMOTE     ?= leier@loftserveren01
REMOTE_DIR ?= /home/leier/tofuV2
TOFU       ?= tofu
# ClearAllForwardings: the local ssh config forwards k8s API ports; skip that
# noise for non-interactive commands.
SSH        := ssh -o ClearAllForwardings=yes
# SSH into a VM via the Incus host. incus exec doesn't work: Kairos VMs run no
# incus-agent. Host keys churn on VM replacement, so don't pin them.
VMSSH      := ssh -o ClearAllForwardings=yes -o ProxyJump=$(REMOTE) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

CLUSTERS   := $(notdir $(wildcard clusters/*))
KUBE_DIR   := $(HOME)/.kube

.PHONY: sync image init plan apply destroy fmt validate ssh kubeconfig kubeconfig-merge

# State and lock file live only on the server — keep them out of --delete's reach.
sync:
	rsync -av --delete \
	  --exclude '.terraform/' \
	  --exclude '.terraform.lock.hcl' \
	  --exclude 'terraform.tfstate*' \
	  --exclude 'image/build/' \
	  ./ $(REMOTE):$(REMOTE_DIR)/

image: sync
	$(SSH) $(REMOTE) 'cd $(REMOTE_DIR)/image && ./build.sh'

init: sync
	$(SSH) $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) init'

plan: sync
	$(SSH) $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) plan'

apply: sync
	$(SSH) -t $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) apply'

destroy: sync
	$(SSH) -t $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) destroy'

fmt:
	$(TOFU) fmt -recursive

validate: sync
	$(SSH) $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) validate'

ssh:
	ssh $(REMOTE)

# Fetch each cluster's k3s admin kubeconfig, point it at the bootstrap CP IP,
# rename everything default -> hadron-<cluster>, merge into ~/.kube/config-hadron.
# Needs yq (mikefarah v4) and kubectl locally: nix shell nixpkgs#yq-go nixpkgs#kubectl
kubeconfig:
	@command -v yq >/dev/null || { echo "yq missing — try: nix shell nixpkgs#yq-go"; exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl missing — try: nix shell nixpkgs#kubectl"; exit 1; }
	@mkdir -p $(KUBE_DIR); tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	ips=$$($(SSH) $(REMOTE) 'cd $(REMOTE_DIR) && $(TOFU) output -json bootstrap_ips'); \
	for c in $(CLUSTERS); do \
	  ip=$$(echo "$$ips" | yq ".$$c"); \
	  $(VMSSH) kairos@$$ip 'sudo cat /etc/rancher/k3s/k3s.yaml' \
	    | yq "(.clusters[].cluster.server) = \"https://$$ip:6443\" \
	        | (.clusters[].name, .contexts[].context.cluster, .contexts[].context.user, .contexts[].name, .users[].name) = \"hadron-$$c\" \
	        | .\"current-context\" = \"hadron-$$c\"" \
	    > "$$tmp/$$c.yaml"; \
	done; \
	KUBECONFIG=$$(printf '%s:' "$$tmp"/*.yaml) kubectl config view --flatten > $(KUBE_DIR)/config-hadron; \
	chmod 600 $(KUBE_DIR)/config-hadron; \
	echo "wrote $(KUBE_DIR)/config-hadron (contexts: $(CLUSTERS))"

# Opt-in: fold ~/.kube/config-hadron into ~/.kube/config (backup kept).
kubeconfig-merge:
	@[ -f $(KUBE_DIR)/config-hadron ] || { echo "run 'make kubeconfig' first"; exit 1; }
	@[ -f $(KUBE_DIR)/config ] && cp $(KUBE_DIR)/config $(KUBE_DIR)/config.bak || true
	@KUBECONFIG=$(KUBE_DIR)/config:$(KUBE_DIR)/config-hadron kubectl config view --flatten > $(KUBE_DIR)/config.new
	@mv $(KUBE_DIR)/config.new $(KUBE_DIR)/config && chmod 600 $(KUBE_DIR)/config
	@echo "merged into $(KUBE_DIR)/config (backup: $(KUBE_DIR)/config.bak)"
