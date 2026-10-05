{
  description = "Fixed-output derivations for the nix-update-hash tests";

  # No inputs: each package is a bare fixed-output derivation that writes its
  # own name, so a build needs neither nixpkgs nor the network.
  outputs =
    { self }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      fixed =
        system: name: hash:
        derivation {
          inherit name system;
          builder = "/bin/sh";
          args = [
            "-c"
            "echo ${name} > $out"
          ];
          outputHashMode = "flat";
          outputHashAlgo = "sha256";
          outputHash = hash;
        };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = {
            default = fixed system "default" "sha256-AWZuwGBGbBS5+gbGE/usRJFj8qIBdVj+FlJiCat4xrA=";
            second = fixed system "second" "sha256-SAwjNrQQ8a1fi/GyiURJAlWAS2U1DFJ3h+dOvdUR46Q=";
          };
        }) systems
      );
    };
}
