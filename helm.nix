{ config, pkgs, lib, nixpkgs, ... }:

let
  cfg = config.system.k3s.helm;
in

with lib;

{
  options = {
    system.k3s.helm = {
      enable = mkOption {
        default = false;
        type = with types; bool;
      };

      charts = mkOption {
        type = with types; uniq attrs;
        default = [ ];
      };
    };
  };

  config =
    let
      makePython3JobScript = name: text:
        let
          # shellEscape = (import (nixpkgs + nixos/lib/systemd-lib.nix) (with pkgs; { inherit config pkgs lib; })).shellEscape;
          shellEscape = s: (lib.replaceChars [ "\\" ] [ "\\\\" ] s);
          mkScriptName = s: (builtins.replaceStrings [ "\\" ] [ "-" ] (shellEscape s));
          x = pkgs.writeTextFile {
            name = "unit-script.py";
            executable = true;
            destination = "/bin/${mkScriptName name}";
            text = "#!/usr/bin/env python3\n${text}";
          };
          deriv = pkgs.stdenv.mkDerivation {
            name = mkScriptName name;
            buildInputs = [ pkgs.python310 ];
            unpackPhase = "true";
            installPhase = ''
              mkdir -p $out/bin
              cp ${x}/bin/${mkScriptName name} $out/bin/${mkScriptName name}
            '';
          };
        in
        "${deriv}/bin/${mkScriptName name}";
      makeValues = name: text:
        let
          shellEscape = s: (lib.replaceChars [ "\\" ] [ "\\\\" ] s);
          mkScriptName = s: (builtins.replaceStrings [ "\\" ] [ "-" ] (shellEscape s));
          x = pkgs.writeTextFile {
            inherit text;
            name = "values.yaml";
            executable = false;
            destination = "/${mkScriptName name}.yaml";
          };
        in
        pkgs.stdenv.mkDerivation {
          name = mkScriptName name;
          unpackPhase = "true";
          installPhase = ''
            cp ${x}/${mkScriptName name}.yaml $out
          '';
        };
    in
    mkIf cfg.enable {
      systemd.services.helm-install = {
        description = "Automatic installation of helm packages";

        # make sure tailscale is running before trying to connect to tailscale
        after = [ "network-pre.target" "k3s.service" ];
        wants = [ "network-pre.target" "k3s.service" ];
        wantedBy = [ "multi-user.target" ];

        # set this service as a oneshot job
        serviceConfig.Type = "oneshot";

        environment = {
          HELM_CACHE_HOME = "/root/.cache/helm";
          HELM_CONFIG_HOME = "/root/.config/helm";
          HELM_DATA_HOME = "/root/.local/share/helm";
        };

        script = makePython3JobScript "update-helm" ''
          from subprocess import Popen, PIPE
          import json
          import os
          HELM_CHARTS = """${builtins.toJSON (builtins.mapAttrs (
            name: value: with value; {
              inherit chart namespace version repo;
              values = makeValues name valuesYaml;
            }
          ) cfg.charts)}"""
          HELM = '${pkgs.kubernetes-helm}/bin/helm'

          def run(*args, fail=True):
            kube_env = os.environ.copy()
            kube_env['KUBECONFIG'] = '/etc/rancher/k3s/k3s.yaml'
            p = Popen(args, stdout=PIPE, stderr=PIPE, env=kube_env)
            stdout, stderr = p.communicate()
            if p.returncode != 0 and fail:
              print(f'failed to run {args}:\n{stderr}')
              exit(1)
            return (stdout, stderr)

          kube_env = os.environ.copy()
          kube_env['KUBECONFIG'] = '/etc/rancher/k3s/k3s.yaml'
          requested_charts = json.loads(HELM_CHARTS)
          existing_charts = json.loads(run(HELM, "list", "-A", "-ojson")[0])
          print(f'need: {requested_charts} have {existing_charts}')
          for chart_name, chart_details in requested_charts.items():
            if len([p for p in filter(lambda f: f['name'] == chart_name, existing_charts)]) == 1:
              # TODO: check update
              continue
            else:
              print(f'install chart for {chart_name}')
              run(
                HELM, "install",
                "--repo", chart_details['repo'],
                chart_name, chart_details['chart'],
                "--version", chart_details['version'],
                "--namespace", chart_details['namespace'], "--create-namespace",
                "-f", chart_details['values']
              )
        '';
      };
    };
}
