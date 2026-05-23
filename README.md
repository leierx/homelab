```text
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # shows public recipient (age1...)

sops secrets/main.yaml

sops -d secrets/main.yaml

# rekey
sops --rekey -i secrets/main.yaml
```
