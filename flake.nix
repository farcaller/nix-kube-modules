{
  description = "A nixos module to configure helm charts to be installed into k3s";

  outputs = { self, nixpkgs }: {
    nixosModule = import ./helm.nix;
  };
}
