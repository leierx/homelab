# fetch the k3s kubeconfig into ~/.kube/config
kubeconfig:
    mkdir -p ~/.kube
    ssh -o ClearAllForwardings=yes loft01 doas cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config.tmp
    chmod 600 ~/.kube/config.tmp
    mv ~/.kube/config.tmp ~/.kube/config
