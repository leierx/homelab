host := "loft01"
kubeconfig := env("HOME") / ".kube" / "loft01"

# fetch the k3s kubeconfig (server is 127.0.0.1:6443, so run `just tunnel` to use it)
kubeconfig:
    mkdir -p {{ parent_directory(kubeconfig) }}
    ssh {{ host }} doas cat /etc/rancher/k3s/k3s.yaml > {{ kubeconfig }}.tmp
    chmod 600 {{ kubeconfig }}.tmp
    mv {{ kubeconfig }}.tmp {{ kubeconfig }}

# forward local 6443 to the k3s API (ssh config for loft01 sets the LocalForward)
tunnel:
    ssh -N {{ host }}
