{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.elasticsearch;

  es5 = builtins.compareVersions (builtins.parseDrvName cfg.package.name).version "5" >= 0;
  es6 = builtins.compareVersions (builtins.parseDrvName cfg.package.name).version "6" >= 0;

  esConfig = ''
    network.host: ${cfg.listenAddress}
    cluster.name: ${cfg.cluster_name}

    ${if es5 then ''
      http.port: ${toString cfg.port}
      transport.tcp.port: ${toString cfg.tcp_port}
    '' else ''
      network.port: ${toString cfg.port}
      network.tcp.port: ${toString cfg.tcp_port}
      # TODO: find a way to enable security manager
      security.manager.enabled: false
    ''}

    ${cfg.extraConf}
  '';

  configDir = cfg.dataDir + "/config";

  elasticsearchYml = pkgs.writeTextFile {
    name = "elasticsearch.yml";
    text = esConfig;
  };

  loggingConfigFilename = if es5 then "log4j2.properties" else "logging.yml";
  loggingConfigFile = pkgs.writeTextFile {
    name = loggingConfigFilename;
    text = cfg.logging;
  };

  esPlugins = pkgs.buildEnv {
    name = "elasticsearch-plugins";
    paths = cfg.plugins;
    # Elasticsearch 5.x won't start when the plugins directory does not exist
    postBuild = if es5 then "${pkgs.coreutils}/bin/mkdir -p $out/plugins" else "";
  };

in {

  ###### interface

  options.services.elasticsearch = {
    enable = mkOption {
      description = "Whether to enable elasticsearch.";
      default = false;
      type = types.bool;
    };

    package = mkOption {
      description = "Elasticsearch package to use.";
      default = pkgs.elasticsearch2;
      defaultText = "pkgs.elasticsearch2";
      type = types.package;
    };

    listenAddress = mkOption {
      description = "Elasticsearch listen address.";
      default = "127.0.0.1";
      type = types.str;
    };

    port = mkOption {
      description = "Elasticsearch port to listen for HTTP traffic.";
      default = 9200;
      type = types.int;
    };

    tcp_port = mkOption {
      description = "Elasticsearch port for the node to node communication.";
      default = 9300;
      type = types.int;
    };

    cluster_name = mkOption {
      description = "Elasticsearch name that identifies your cluster for auto-discovery.";
      default = "elasticsearch";
      type = types.str;
    };

    extraConf = mkOption {
      description = "Extra configuration for elasticsearch.";
      default = "";
      type = types.str;
      example = ''
        node.name: "elasticsearch"
        node.master: true
        node.data: false
      '';
    };

    logging = mkOption {
      description = "Elasticsearch logging configuration.";
      default =
        if es5 then ''
          logger.action.name = org.elasticsearch.action
          logger.action.level = info

          appender.console.type = Console
          appender.console.name = console
          appender.console.layout.type = PatternLayout
          appender.console.layout.pattern = [%d{ISO8601}][%-5p][%-25c{1.}] %marker%m%n

          rootLogger.level = info
          rootLogger.appenderRef.console.ref = console
        '' else ''
          rootLogger: INFO, console
          logger:
            action: INFO
            com.amazonaws: WARN
          appender:
            console:
              type: console
              layout:
                type: consolePattern
                conversionPattern: "[%d{ISO8601}][%-5p][%-25c] %m%n"
        '';
      type = types.str;
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/elasticsearch";
      description = ''
        Data directory for elasticsearch.
      '';
    };

    extraCmdLineOptions = mkOption {
      description = "Extra command line options for the elasticsearch launcher.";
      default = [];
      type = types.listOf types.str;
    };

    extraJavaOptions = mkOption {
      description = "Extra command line options for Java.";
      default = [];
      type = types.listOf types.str;
      example = [ "-Djava.net.preferIPv4Stack=true" ];
    };

    plugins = mkOption {
      description = "Extra elasticsearch plugins";
      default = [];
      type = types.listOf types.package;
    };

    curatorCli = mkOption {
      description = "a curator-cli command, alternatively use curator which takes a full action file";
      example = ''
        delete_indices --ignore_empty_list --filter_list '[{"filtertype":"age","source":"creation_date","direction":"older","unit":"days","unit_count":45}]'
      '';
    };

    curator = mkOption {
      description = "curator action.yaml file contents, alternatively use curator-cli which takes a simple action command";
      example = ''
        ---
        actions:
          1:
            action: delete_indices
            description: >-
              Delete indices older than 45 days (based on index name), for logstash-
              prefixed indices. Ignore the error if the filter does not result in an
              actionable list of indices (ignore_empty_list) and exit cleanly.
            options:
              ignore_empty_list: True
              disable_action: True
            filters:
            - filtertype: pattern
              kind: prefix
              value: logstash-
            - filtertype: age
              source: name
              direction: older
              timestring: '%Y.%m.%d'
              unit: days
              unit_count: 45
      '';
    };

  };

  ###### implementation

  config = mkIf cfg.enable {
    systemd.services.elasticsearch = {
      description = "Elasticsearch Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      path = [ pkgs.inetutils ];
      environment = {
        ES_HOME = cfg.dataDir;
        ES_JAVA_OPTS = toString ( optional (!es6) [ "-Des.path.conf=${configDir}" ]
                                  ++ cfg.extraJavaOptions);
      } // optionalAttrs es6 {
        ES_PATH_CONF = configDir;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/elasticsearch ${toString cfg.extraCmdLineOptions}";
        User = "elasticsearch";
        PermissionsStartOnly = true;
        LimitNOFILE = "1024000";
      };
      preStart = ''
        ${optionalString (!config.boot.isContainer) ''
          # Only set vm.max_map_count if lower than ES required minimum
          # This avoids conflict if configured via boot.kernel.sysctl
          if [ `${pkgs.procps}/bin/sysctl -n vm.max_map_count` -lt 262144 ]; then
            ${pkgs.procps}/bin/sysctl -w vm.max_map_count=262144
          fi
        ''}

        mkdir -m 0700 -p ${cfg.dataDir}

        # Install plugins
        ln -sfT ${esPlugins}/plugins ${cfg.dataDir}/plugins
        ln -sfT ${cfg.package}/lib ${cfg.dataDir}/lib
        ln -sfT ${cfg.package}/modules ${cfg.dataDir}/modules

        # elasticsearch needs to create the elasticsearch.keystore in the config directory
        # so this directory needs to be writable.
        mkdir -m 0700 -p ${configDir}

        # Note that we copy config files from the nix store instead of symbolically linking them
        # because otherwise X-Pack Security will raise the following exception:
        # java.security.AccessControlException:
        # access denied ("java.io.FilePermission" "/var/lib/elasticsearch/config/elasticsearch.yml" "read")

        cp ${elasticsearchYml} ${configDir}/elasticsearch.yml
        # Make sure the logging configuration for old elasticsearch versions is removed:
        rm -f ${if es5 then "${configDir}/logging.yml" else "${configDir}/log4j2.properties"}
        cp ${loggingConfigFile} ${configDir}/${loggingConfigFilename}
        ${optionalString es5 "mkdir -p ${configDir}/scripts"}
        ${optionalString es6 "cp ${cfg.package}/config/jvm.options ${configDir}/jvm.options"}

        if [ "$(id -u)" = 0 ]; then chown -R elasticsearch:elasticsearch ${cfg.dataDir}; fi
      '';
    };

    environment.systemPackages = [ cfg.package ];

    users = {
      groups.elasticsearch.gid = config.ids.gids.elasticsearch;
      users.elasticsearch = {
        uid = config.ids.uids.elasticsearch;
        description = "Elasticsearch daemon user";
        home = cfg.dataDir;
        group = "elasticsearch";
      };
    };
  }
  // (optionalAttrs (cfg.curatorCli != null) {
          systemd.services.curator-cli = {
            enable = true;
            startAt = "hourly";
            serviceConfig = {
            ExecStart = ''${pkgs.python36Packages.elasticsearch-curator}/bin/curator_cli ${cfg.curatorCli}'';
            };
          };
      })
  // (optionalAttrs (cfg.curator != null) {
          environment.etc."curator/config.yaml" = { text = ''
            ---
            # Remember, leave a key empty if there is no value.  None will be a string,
            # not a Python "NoneType"
            client:
              hosts:
                - 127.0.0.1
              port: 9200
              url_prefix:
              use_ssl: False
              certificate:
              client_cert:
              client_key:
              ssl_no_validate: False
              http_auth:
              timeout: 30
              master_only: False
            logging:
              loglevel: INFO
              logfile:
              logformat: default
              blacklist: ['elasticsearch', 'urllib3']
            ''; };
          environment.etc."curator/action.yaml" = { text = cfg.curator; };
          systemd.services.curator = {
            enable = true;
            startAt = "hourly";
            serviceConfig = {
            ExecStart = ''${pkgs.python36Packages.elasticsearch-curator}/bin/curator ${cfg.curator}'';
            };
          };
      });
}
