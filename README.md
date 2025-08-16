# SOPS quickstart (AGE)

You need an AGE private key at `~/.config/sops/age/keys.txt` to decrypt/edit secrets.

## Create key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Show your public recipient (use this when encrypting): `age-keygen -y "$HOME/.config/sops/age/keys.txt"`

## Common actions
Encrypt (in place):

```bash
sops --encrypt --in-place secrets.yml
```

Edit in place (auto-decrypts/encrypts on save): `sops secrets.yml`

Decrypt to stdout (don’t write plaintext to disk): `sops --decrypt secrets.yml`

Re-key file after changing recipients in .sops.yaml: `sops updatekeys -y secrets.yml`

---

# Build a minimal ISO (with SSH key) for remote install

From the `installer/` directory:

```bash
cd installer
docker build -t nixos-iso -q . | xargs docker run --rm -v "$PWD":/work nixos-iso
```

# Remote install with `nixos-anywhere` (copy AGE key to /root)

```bash
# 1) Stage files in a temp dir that mirrors target paths
tmpdir="$(mktemp -d)"
install -D -m 0600 "$HOME/.config/sops/age/keys.txt" "$tmpdir/root/keys.txt"

# 2) Run nixos-anywhere, copying that tree to the target’s
nix run github:nix-community/nixos-anywhere -- \
  --flake '.#loftserveren01' \
  --target-host root@192.0.0.0 \
  --extra-files "$tmpdir"

# 3) Clean up
rm -rf "$tmpdir"
```

