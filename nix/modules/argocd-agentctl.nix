{
  modules.argocdAgentctl =
    { pkgs, ... }:
    let
      argocd-agentctl = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "argocd-agentctl";
        version = "0.4.1";

        src = pkgs.fetchurl {
          url = "https://github.com/argoproj-labs/argocd-agent/releases/download/v${version}/argocd-agentctl_linux-amd64";
          hash = "sha256-kkgkCBMi5Jqplb9wajyZri63Ahi9Vtnkab25TXgZv/w=";
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
