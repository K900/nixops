{ pkgs, nixops }:
let
  inherit (pkgs) lib;
  inherit (lib) optionalAttrs;

  tests = {
    legacy = testLegacyNetwork;
  };

  testLegacyNetwork = pkgs.nixosTest ({
    name = "nixops-legacy-network";
    nodes = {
      deployer = { config, lib, nodes, pkgs, modulesPath, ... }: {
        imports = [ (modulesPath + "/installer/cd-dvd/channel.nix") ];
        environment.systemPackages = [ nixops ];
        nix.settings.substituters = lib.mkForce [ ];
        users.users.person.isNormalUser = true;
        virtualisation.writableStore = true;
        virtualisation.additionalPaths = [
          pkgs.hello
          pkgs.figlet

          # This includes build dependencies all the way down. Not efficient,
          # but we do need build deps to an *arbitrary* depth, which is hard to
          # determine.
          (allDrvOutputs nodes.server.config.system.build.toplevel)
        ];
      };
      server = { lib, ... }: {
        imports = [ ./legacy/base-configuration.nix ];
      };
    };

    testScript = { nodes }:
      let
        deployerSetup = pkgs.writeScript "deployerSetup" ''
          #!${pkgs.runtimeShell}
          set -eux -o pipefail
          cp --no-preserve=mode -r ${./legacy} unicorn
          cp --no-preserve=mode ${./ssh-keys.nix} unicorn/ssh-keys.nix
          mkdir -p ~/.ssh
          cp ${snakeOilPrivateKey} ~/.ssh/id_ed25519
          chmod 0400 ~/.ssh/id_ed25519
        '';
        serverNetworkJSON = pkgs.writeText "server-network.json"
          (builtins.toJSON nodes.server.config.system.build.networkConfig);
      in
      ''
        import shlex

        def deployer_do(cmd):
            cmd = shlex.quote(cmd)
            return deployer.succeed(f"su person -l -c {cmd} &>/dev/console")

        start_all()

        deployer_do("cat /etc/hosts")

        deployer_do("${deployerSetup}")
        deployer_do("cp ${serverNetworkJSON} unicorn/server-network.json")

        # Establish that ssh works, regardless of nixops
        # Easy way to accept the server host key too.
        server.wait_for_open_port(22)
        deployer.wait_for_unit("network.target")

        # Put newlines on console, to flush the console reader's line buffer
        # in case nixops' last output did not end in a newline, as is the case
        # with a status line (if implemented?)
        deployer.succeed("while sleep 60s; do echo [60s passed]; done >&2 &")

        deployer_do("cd ~/unicorn; ssh -oStrictHostKeyChecking=accept-new root@server echo hi")

        # Create and deploy
        deployer_do("cd ~/unicorn; nixops create")

        deployer_do("cd ~/unicorn; nixops deploy --confirm")

        deployer_do("cd ~/unicorn; nixops ssh server 'hello | figlet'")

        deployer_do("cd ~/unicorn; nixops check")
      '';
  });

  inherit (import ./ssh-keys.nix pkgs) snakeOilPrivateKey snakeOilPublicKey;

  /*
    Return a store path with a closure containing everything including
    derivations and all build dependency outputs, all the way down.
  */
  allDrvOutputs = pkg:
    let name = "allDrvOutputs-${pkg.pname or pkg.name or "unknown"}";
    in
    pkgs.runCommand name { refs = pkgs.writeReferencesToFile pkg.drvPath; } ''
      touch $out
      while read ref; do
        case $ref in
          *.drv)
            cat $ref >>$out
            ;;
        esac
      done <$refs
    '';

in
optionalAttrs pkgs.stdenv.isLinux tests
