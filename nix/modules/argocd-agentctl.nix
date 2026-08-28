{
  modules.argocdAgentctl =
    { pkgs, ... }:
    let
      argocd-agentctl = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "argocd-agentctl";
        version = "0.10.0";

        src = pkgs.fetchurl {
          url = "https://github.com/argoproj-labs/argocd-agent/releases/download/v${version}/argocd-agentctl-linux-amd64";
          hash = "sha256-/VJ0UKLoy/VE8zTWfrY9g6STyhkYK1BanMsMpqGg7hs=";
        };

        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        dontUnpack = true;

        installPhase = ''
          install -Dm755 $src $out/bin/argocd-agentctl
        '';
      };
    in
    {
      environment.systemPackages = [ argocd-agentctl ];
    };
}
