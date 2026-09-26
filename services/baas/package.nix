{
  lib,
  stdenvNoCC,
  runCommandLocal,
  importNpmLock,
  makeWrapper,
  nodejs,
  nix,
  src-baas,
}:
let
  package = (lib.importJSON "${src-baas}/package.json") // {
    name = "baas";
    version = "0.1.0";
  };

  src = runCommandLocal "baas-src" { } ''
    mkdir -p "$out/views"
    install -m444 ${src-baas}/index.js "$out/index.js"
    install -m444 ${src-baas}/package.json "$out/package.json"
    install -m444 ${src-baas}/package-lock.json "$out/package-lock.json"
    install -m444 ${src-baas}/views/*.ejs "$out/views/"
  '';

  nodeModules = importNpmLock.buildNodeModules {
    npmRoot = src;
    inherit package nodejs;
  };

  portLine = "const port = 3000;";
  portPatched = "const port = Number(process.env.PORT ?? 3000);";
in
stdenvNoCC.mkDerivation {
  pname = "baas";
  inherit (package) version;
  inherit src;

  nativeBuildInputs = [ makeWrapper ];

  postPatch = ''
    # The listening port must be a deployment decision: the service sets it
    # through its `port` setting, and on the host itself 3000 is already
    # gitea's loopback port.
    substituteInPlace index.js \
      --replace-fail ${lib.escapeShellArg portLine} ${lib.escapeShellArg portPatched}
  '';

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/baas
    cp index.js $out/libexec/baas/index.js
    cp -r views $out/libexec/baas/views
    ln -s ${nodeModules}/node_modules $out/libexec/baas/node_modules

    # No `--chdir`: `nix-build` drops a `./result` symlink into the working
    # directory on every request, so the caller has to start this from a
    # writable one. The unit uses its state directory.
    makeWrapper ${lib.getExe nodejs} $out/bin/baas \
      --add-flags $out/libexec/baas/index.js \
      --set NODE_PATH $out/libexec/baas/node_modules \
      --prefix PATH : ${lib.makeBinPath [ nix ]}

    runHook postInstall
  '';

  meta = {
    description = "Build as a Service: the NixCon CTF challenge web app";
    mainProgram = "baas";
    platforms = lib.platforms.linux;
  };
}
