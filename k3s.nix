{ config, pkgs, lib, ... }:

let
  cfg = config.services.k3sManaged;
  k3cfg = config.services.k3s;
in

with lib;

{
  options = {
    services.k3sManaged = {
      enable = mkOption {
        default = false;
        type = with types; bool;
        description = ''
          Start a managed k3s.
        '';
      };

      nodeName = mkOption {
        type = with types; uniq string;
        default = config.networking.hostName;
      };
      
      clusterDomain = mkOption {
        type = with types; uniq string;
        default = "${cfg.nodeName}.k8s.prod.zone";
      };

      clusterCIDR = mkOption {
        type = with types; uniq string;
      };

      clusterCIDRv6 = mkOption {
        default = "";
        type = with types; uniq string;
      };

      serviceCIDR = mkOption {
        type = with types; uniq string;
      };

      serviceCIDRv6 = mkOption {
        default = "";
        type = with types; uniq string;
      };

      clusterDNS = mkOption {
        type = with types; uniq string;
      };

      nodeIP = mkOption {
        default = "";
        type = with types; uniq string;
      };

      zfs = mkOption {
        default = false;
        type = with types; bool;
      };

      disableLocalPV = mkOption {
        default = false;
        type = with types; bool;
      };

      disableFlannel = mkOption {
        default = false;
        type = with types; bool;
      };

      disableKubeProxy = mkOption {
        default = false;
        type = with types; bool;
      };

      disableMetricsServer = mkOption {
        default = false;
        type = with types; bool;
      };

      package = mkOption {
        default = pkgs.k3s;
        type = with types; package;
      };

      tlsSAN = mkOption {
        default = "";
        type = with types; uniq string;
      };

      apiServerArgs = mkOption {
        default = [ ];
        type = with types; types.listOf string;
      };

      deviceOwnershipFromSecurityContext = mkOption {
        default = false;
        type = with types; bool;
      };
    };
  };

  config =
    let
      finalClusterCIDR = cfg.clusterCIDR + (if cfg.clusterCIDRv6 != "" then ",${cfg.clusterCIDRv6}" else "");
      finalServiceCIDR = cfg.serviceCIDR + (if cfg.serviceCIDRv6 != "" then ",${cfg.serviceCIDRv6}" else "");
      isAgent = k3cfg.role == "agent";
    in
    mkIf cfg.enable {
      networking.firewall.trustedInterfaces = mkIf (!cfg.disableFlannel) [ "cni0" ];
      environment.systemPackages = [ cfg.package ];
      services.k3s.enable = true;
      services.k3s.package = cfg.package;
      services.k3s.extraFlags = builtins.toString
        (
          [ "--node-name ${cfg.nodeName}" ]
          ++ (optional (cfg.nodeIP != "") "--node-ip ${cfg.nodeIP}")
          ++ (optional cfg.zfs "--container-runtime-endpoint unix:///run/containerd/containerd.sock")
          ++ (if (isAgent == false) then
            (
              [
                "--cluster-cidr ${finalClusterCIDR}"
                "--service-cidr ${finalServiceCIDR}"
                "--cluster-dns ${cfg.clusterDNS}"
                "--cluster-domain ${cfg.clusterDomain}"
                "--disable servicelb"
                "--disable traefik"
              ]
              ++ (optional (cfg.tlsSAN != "") "--tls-san ${cfg.tlsSAN}")
              ++ (optional cfg.disableLocalPV "--disable local-storage")
              ++ (optional cfg.disableMetricsServer "--disable metrics-server")
              ++ (
                if cfg.disableFlannel
                then [ "--flannel-backend none --disable-network-policy" ]
                else [ "--flannel-backend host-gw" ]
              )
              ++ (optional cfg.disableKubeProxy "--disable-kube-proxy")
              ++ (optional (cfg.apiServerArgs != "") (toString (map (s: "--kube-apiserver-arg ${s}") cfg.apiServerArgs)))
            ) else [ ]
          )
        );

      system.activationScripts = mkIf cfg.zfs {
        sbinZfs = {
          text = ''
            mkdir -p /sbin
            ln -sf ${pkgs.zfs}/bin/zfs /sbin/zfs
          '';
          deps = [ ];
        };
      };

      virtualisation.containerd = mkIf cfg.zfs
        (
          let
            deviceOwnership =
              if cfg.deviceOwnershipFromSecurityContext then {
                plugins."io.containerd.grpc.v1.cri".device_ownership_from_security_context = true;
              } else { };
            hostedCni = {
              plugins."io.containerd.grpc.v1.cri".cni = {
                bin_dir = "/opt/cni/bin/";
                conf_dir = "/etc/cni/net.d/";
              };
            };
            nixCni =
              let
                fullCNIPlugins = pkgs.buildEnv {
                  name = "full-cni";
                  paths = with pkgs; [
                    cni-plugins
                    cni-plugin-flannel
                  ];
                };
              in
              {
                plugins."io.containerd.grpc.v1.cri".cni = {
                  bin_dir = "${fullCNIPlugins}/bin";
                  conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d/";
                };
              };
          in
          {
            enable = true;
            settings = lib.recursiveUpdate deviceOwnership (if cfg.disableFlannel then hostedCni else nixCni);
          }
        );

    };
}
