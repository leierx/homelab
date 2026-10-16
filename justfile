# fetch the k3s kubeconfig (server is 127.0.0.1:6443, so run `just tunnel` to use it)
kubeconfig:
    mkdir -p ~/.kube
    ssh loft01 doas cat /etc/rancher/k3s/k3s.yaml > ~/.kube/loft01.tmp
    chmod 600 ~/.kube/loft01.tmp
    mv ~/.kube/loft01.tmp ~/.kube/loft01

# forward local 6443 to the k3s API in the background (the loft01 ssh host sets the LocalForward)
tunnel:
    ssh -fN -M -S ~/.ssh/loft01-tunnel.sock loft01

# close the background tunnel
untunnel:
    ssh -S ~/.ssh/loft01-tunnel.sock -O exit loft01
