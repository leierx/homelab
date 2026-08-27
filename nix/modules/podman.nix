{
  modules.podman = {
    virtualisation.podman = {
      enable = true;
      autoPrune.enable = true;
      # Rootful API socket (+ docker.sock alias) for image builds that need
      # real root (loop devices) — see tofuV2/image/build.sh. Access is gated
      # by the "podman" group.
      dockerSocket.enable = true;
    };
  };
}
