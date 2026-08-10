let
  npins = import ./npins;
  overlay = import ./overlay.nix;
  mkPackages = pkgs: overlay pkgs pkgs;
in
{
  nixpkgs ? npins.nixpkgs,
  pkgs ? import nixpkgs { },
}:
let
  finalPkgs = pkgs.extend overlay;
in
{
  packages = mkPackages finalPkgs;
  inherit overlay;
  shell = import ./shell.nix { pkgs = finalPkgs; };
  default = finalPkgs.base24-gen;
}
