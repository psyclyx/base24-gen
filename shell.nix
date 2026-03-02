{ pkgs ? import (import ./npins).nixpkgs {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ zig_0_15 ];
}
