{
  description = "A set of nixos modules to simplify kubernetes management.";

  outputs = { self, nixpkgs }: {
    nixosModules = {
      helm = import ./helm.nix;
      k3s = import ./k3s.nix;
    };
  };
}
