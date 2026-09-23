{
  lib,
  stdenvNoCC,
  runCommandLocal,
  importNpmLock,
  makeWrapper,
  nodejs,
  nix,
  # The challenge's own repository is consumed as a plain source tree, the same
  # way the homewort flakes are: `challenges/` in this repo is a gitignored
  # scratch mirror, so a path into it is invisible to the flake.
  src-baas,
}:
let
  # `package.json` in the challenge repo carries only `dependencies`.
  # `importNpmLock` derives `pname`/`version` from it and fails evaluation
  # without them, so the two missing fields are added here rather than in the
  # challenge tree, which is published to players as is.
  package = (lib.importJSON "${src-baas}/package.json") // {
    name = "baas";
    version = "0.1.0";
  };

  # The source is copied file by file rather than filtered: the challenge repo
  # also holds `flag.txt`, `payload.nix` (the published solution), and a
  # README, and the flag in particular must never reach the store of a machine
  # whose whole job is serving `/nix/store` over HTTP. The deployed flag comes
  # from the `baas` clan var. An allowlist fails loudly when the repo gains a
  # file, but a denylist would ship it.
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

  appLine = "const app = express();";
  trustProxyPatched = "${appLine}\napp.set('trust proxy', true);";
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

    # `builtPaths` is keyed on `req.ip`, and Express 5 defaults to
    # `trust proxy = false`. Behind the host's nginx every request would then
    # report 127.0.0.1, which puts all players in one shared bucket. The startup
    # flag build would land in that bucket too, so `GET /` would hand the flag's
    # store path to everybody. The bootstrap POST sends an unguessable
    # `X-Forwarded-For` for the same reason: with all hops trusted, the
    # left-most entry wins, so the flag must not be parked on an address a
    # player could claim.
    substituteInPlace index.js \
      --replace-fail ${lib.escapeShellArg appLine} ${lib.escapeShellArg trustProxyPatched}
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
