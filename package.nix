{
  lib,
  stdenv,
  installShellFiles,
  zig_0_15,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "base24-gen";
  version = "0.1.0";

  # Only the files the build consumes: the build graph (build.zig + zon),
  # the sources, the vendored stb_image, and the completions installPhase
  # installs. Entry points (default.nix, package.nix, overlay.nix,
  # shell.nix), npins/, docs, and sample assets are not package inputs, so
  # editing them must not churn the source hash.
  src = builtins.path {
    # Preserve the store path name the old `src = ./.` copy had — the
    # unpacked source root name leaks into DWARF compile-unit paths.
    name = "base24-gen";
    path = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./build.zig
        ./build.zig.zon
        ./completions
        ./src
        ./vendor
      ];
    };
  };

  nativeBuildInputs = [
    zig_0_15
    installShellFiles
  ];

  # stb_image is vendored; no system libraries required beyond libc.

  buildPhase = ''
    export HOME=$(mktemp -d)
    zig build --prefix $out -Doptimize=ReleaseSafe
  '';

  installPhase = ''
    installShellCompletion --bash completions/base24-gen.bash
    installShellCompletion --zsh completions/base24-gen.zsh
    installShellCompletion --fish completions/base24-gen.fish
  '';

  meta = {
    description = "Deterministic Base24 colour scheme generator from images";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "base24-gen";
  };
})
