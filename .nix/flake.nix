{
  description = "benfactor-cc development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          # Static landing page. (Note: this is the typo-named repo that
          # duplicates the benefactor.cc CNAME and is slated to be archived.)
          default = pkgs.mkShell {
            packages = with pkgs; [
              git
              python3
            ];

            shellHook = ''
              echo "benfactor-cc (static) dev shell (${system})"
              echo "preview locally: python3 -m http.server 8000"
            '';
          };
        });
    };
}
