{ config, lib, pkgs }:

with lib;

let
  cfg = config.services.prometheus.exporters.node;
in
{
  port = 9100;
  extraOpts = {
    enabledCollectors = mkOption {
      type = types.listOf types.string;
      default = [];
      example = ''[ "systemd" ]'';
      description = ''
        Collectors to enable. The collectors listed here are enabled in addition to the default ones.
      '';
    };
    disabledCollectors = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ''[ "timex" ]'';
      description = ''
        Collectors to disable which are enabled by default.
      '';
    };
    textfileDirectory = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/path/to/prom/files";
      description = ''
        The collector will parse all files in this directory matching the glob *.prom
      '';
    }
  };
  serviceOpts = {
    serviceConfig = {
      RuntimeDirectory = "prometheus-node-exporter";
      ExecStart = ''
        ${pkgs.prometheus-node-exporter}/bin/node_exporter \
          ${concatMapStringsSep " " (x: "--collector." + x) cfg.enabledCollectors} \
          ${concatMapStringsSep " " (x: "--no-collector." + x) cfg.disabledCollectors} \
          ${optionalString (cfg.textfileDirectory != null) ("--collector.textfile.directory" + cfg.textfileDirectory)}
          --web.listen-address ${cfg.listenAddress}:${toString cfg.port} \
          ${concatStringsSep " \\\n  " cfg.extraFlags}
      '';
    };
  };
}
