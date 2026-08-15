{
  lib,
  stdenv,
  autoPatchelfHook,
  bun2nix,
  fetchurl,
  installShellFiles,
  makeWrapper,
  nodejs,
}:
let
  sourcesData = lib.importJSON ./sources.json;
  inherit (sourcesData) version;
  sources = sourcesData.platforms;

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  vpBinary = fetchurl {
    inherit (source) url hash;
  };

in
stdenv.mkDerivation {
  pname = "vite-plus";
  inherit version;

  src = ./wrapper;

  nativeBuildInputs = [
    bun2nix.hook
    installShellFiles
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
  ];

  # nodejs is a host dependency so that fixupPhase resolves the
  # `#!/usr/bin/env node` shebangs shipped inside node_modules against it.
  buildInputs = [
    nodejs
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];

  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ./wrapper/bun.nix;
    # bun2nix rewrites every `#!/usr/bin/env node` shebang to a bun shim, which
    # would both change the runtime under vp's helper scripts and pull bun into
    # the closure. Leave them for our own fixupPhase to resolve to nodejs.
    patchShebangs = false;
  };

  # `node_modules` is moved into `$out` verbatim, so it must contain real files
  # under a flat layout: the isolated linker would leave `$out/node_modules`
  # entries pointing into `node_modules/.bun`, and the symlink backend (bun's
  # default on darwin) would point them at the build-local cache copy, which
  # is gone by the time `vp` runs.
  bunInstallFlags = "--linker=hoisted --backend=copyfile";

  dontRunLifecycleScripts = true;
  dontUseBunBuild = true;
  dontUseBunCheck = true;
  dontUseBunInstall = true;

  buildPhase = ''
    runHook preBuild
    chmod -R u+w node_modules/vite-plus/dist/create
    substituteInPlace node_modules/vite-plus/dist/create/bin.js \
      --replace-fail \
        'else fs.copyFileSync(src, dest);' \
        'else { fs.copyFileSync(src, dest); fs.chmodSync(dest, 0o644); }'

    # bun2nix marks every file it extracts executable, which makes fixupPhase
    # rewrite the shebangs it finds. `vp create` copies templates/ into the
    # user's new project, so a store path must never end up in there.
    find node_modules/vite-plus/templates -type f -exec chmod a-x {} +

    # bun.lock records no `libc` field, so bun cannot do npm's musl/glibc
    # filtering and installs both builds of every native package. The musl ones
    # can never load on our glibc targets, and autoPatchelf fails outright on
    # the dynamically linked ones (lightningcss-linux-x64-musl).
    find node_modules -type d -name '*-musl*' -exec rm -rf {} +

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    tar xzf ${vpBinary} --strip-components=1 -C $out/bin
    chmod 755 $out/bin/vp

    find node_modules -name '.bin' -type d -exec rm -rf {} + 2>/dev/null || true
    mv node_modules $out/node_modules

    wrapProgram $out/bin/vp \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]}

    ln -s vp $out/bin/vpr
    ln -s vp $out/bin/vpx

    runHook postInstall
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    # vp only becomes runnable after autoPatchelfHook patches it in fixupPhase, so
    # completions are generated here, the first phase that runs after fixup.
    installShellCompletion --cmd vp \
      --bash <(VP_COMPLETE=bash $out/bin/vp) \
      --fish <(VP_COMPLETE=fish $out/bin/vp) \
      --zsh <(VP_COMPLETE=zsh $out/bin/vp)

    tmpcheck=$(mktemp -d)
    echo "${nodejs.version}" > "$tmpcheck/.node-version"
    output=$(cd "$tmpcheck" && $out/bin/vp --version 2>&1)
    echo "$output" | grep -q "vp v${version}"

    runHook postInstallCheck
  '';

  dontStrip = true;

  passthru = {
    updateScript = ./update.nu;
  };

  meta = with lib; {
    inherit version;
    description = "The Unified Toolchain for the Web";
    homepage = "https://viteplus.dev";
    license = licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "vp";
    platforms = import ./nix/systems.nix;
    maintainers = with maintainers; [ ryoppippi ];
  };
}
