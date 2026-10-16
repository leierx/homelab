# fetch the k3s kubeconfig into ~/.kube/config (server is 127.0.0.1:6443, so it needs `just tunnel`)
kubeconfig:
    mkdir -p ~/.kube
    ssh -o ClearAllForwardings=yes loft01 doas cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config.tmp
    chmod 600 ~/.kube/config.tmp
    mv ~/.kube/config.tmp ~/.kube/config

# forward local 6443 to the k3s API in the background; no-op if already up
tunnel:
    ssh -S ~/.ssh/loft01-tunnel.sock -O check loft01 2>/dev/null || ssh -fN -M -S ~/.ssh/loft01-tunnel.sock loft01

# close the background tunnel
untunnel:
    ssh -S ~/.ssh/loft01-tunnel.sock -O exit loft01
