# fetch the k3s kubeconfig into ~/.kube/loft01 (server is 127.0.0.1:6443, so it needs `just tunnel`)
kubeconfig:
    mkdir -p ~/.kube
    ssh -o ClearAllForwardings=yes loft01 doas cat /etc/rancher/k3s/k3s.yaml > ~/.kube/loft01.tmp
    chmod 600 ~/.kube/loft01.tmp
    mv ~/.kube/loft01.tmp ~/.kube/loft01

# forward local 6443 to the k3s API in the background; no-op if already up
tunnel:
    ssh -S ~/.ssh/loft01-tunnel.sock -O check loft01 2>/dev/null || ssh -fN -M -S ~/.ssh/loft01-tunnel.sock loft01

# close the background tunnel
untunnel:
    ssh -S ~/.ssh/loft01-tunnel.sock -O exit loft01
