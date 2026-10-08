# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# The development toolchain for ash_agent_tools, and the source of the
# dev container image (`.devcontainer/devcontainer.json` pulls it).
#
#   devenv shell                       # toolchain on this machine
#   devenv container build devenv      # build the image
#   devenv container copy devenv --registry docker-daemon:   # load it into Docker
#
# The toolchain matches CI (.github/actions/setup-elixir): OTP 27 and
# Elixir 1.18, PostgreSQL 16 for the :db-tagged tests, xmllint for the DMN
# fixtures. Change the two together.
#
# Bump `containers.devenv.version` whenever this file or devenv.lock changes,
# and update the image tag in .devcontainer/devcontainer.json to match.
{ pkgs, lib, config, ... }:

let
  # beam_minimal: Erlang without wxWidgets.
  beam = pkgs.beam_minimal.packages.erlang_27;
  stateDir = config.devenv.state;

  # devenv's profile installs every output of a package: postgresql's -dev
  # output pulls clang/LLVM (~1.4 GiB) and git's pulls -debug. Keep the
  # binaries and libraries only.
  binsOnly = name: pkg: pkgs.symlinkJoin {
    inherit name;
    paths = [ (lib.getBin pkg) (lib.getLib pkg) ];
  };

  # The trust store, for container builds.
  #
  # The image cannot use `sudo`: Nix store paths cannot be setuid, so the
  # usual `sudo update-ca-certificates` fails. Instead the bundle is a
  # regular file in a directory the container user (uid 1000) owns, and the
  # standard paths are symlinks to it. `.devcontainer/install-ca.sh` rewrites
  # it as the Mozilla bundle plus the platform CA, without root.
  #
  # Erlang's :public_key.cacerts_get/0 reads only these OS paths and ignores
  # SSL_CERT_FILE, so the symlinks are needed as well as the env vars below.
  trustBundle = "/etc/ssl/sdlc/ca-bundle.crt";
  mozillaBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  trustStore = pkgs.runCommand "sdlc-trust-store" { } ''
    mkdir -p $out/etc/ssl/sdlc $out/etc/ssl/certs
    cp ${mozillaBundle} $out${trustBundle}
    ln -s ${trustBundle} $out/etc/ssl/certs/ca-certificates.crt
    ln -s ${trustBundle} $out/etc/ssl/certs/ca-bundle.crt
    ln -s ${trustBundle} $out/etc/ssl/cert.pem
  '';
  certFile = if config.container.isBuilding then "/etc/ssl/certs/ca-certificates.crt" else mozillaBundle;
in
{
  name = "ash-agent-tools";

  languages.erlang = { enable = true; package = beam.erlang; lsp.enable = false; };
  languages.elixir = { enable = true; package = beam.elixir_1_18; lsp.enable = false; };

  packages = with pkgs; [
    (binsOnly "git-bin" pkgs.git)
    (binsOnly "postgresql-bin" pkgs.postgresql_16) # :db-tagged tests (CI: postgres:16)
    libxml2.bin                                    # xmllint, for boxic_dmn's XSD validation
    inotify-tools                                  # file_system backend: daemon reload watcher
    beam.rebar3
    openssl
    curl
    jq
    cacert
    # The image's base layer has coreutils and bash only. Agents and the
    # Coder agent's bootstrap expect the rest of a normal userland.
    gnused
    gnugrep
    gawk
    findutils
    diffutils
    gnutar
    gzip
    which
    procps
    less
  ];

  env = {
    MIX_HOME = "${stateDir}/mix";
    HEX_HOME = "${stateDir}/hex";
    MIX_PATH = "${beam.hex}/lib/erlang/lib/hex/ebin"; # hex baked in: no `mix local.hex`
    MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
    SSL_CERT_FILE = certFile;
    NIX_SSL_CERT_FILE = certFile;
    CURL_CA_BUNDLE = certFile;
    GIT_SSL_CAINFO = certFile;
    PGDATA = "${stateDir}/postgres";
    LANG = "C.UTF-8";
  } // lib.optionalAttrs config.container.isBuilding {
    # `docker exec`, the devcontainer CLI and the Coder agent bypass the
    # devenv entrypoint, so the profile must be on the image's own PATH.
    PATH = "${config.devenv.profile}/bin:/bin:/usr/bin";
    SDLC_CA_BASE = mozillaBundle;
    SDLC_CA_BUNDLE = trustBundle;
  };

  enterShell = ''
    mkdir -p "$MIX_HOME" "$HEX_HOME"
  '';

  containers.devenv = {
    name = "ash-agent-tools-devenv";
    version = "2026-10-08";
    registry = "docker://harbor.sdlc.home.arpa/sdlc/";
    startupCommand = "bash";
    maxLayers = 100; # a rebuilt image re-pulls only the layers that changed
    layers = [
      {
        copyToRoot = [ trustStore ];
        perms = [
          {
            path = trustStore;
            regex = "/etc/ssl/sdlc.*";
            mode = "0755";
            uid = 1000;
            gid = 1000;
            uname = "user";
            gname = "user";
          }
        ];
      }
    ];
  };
}
