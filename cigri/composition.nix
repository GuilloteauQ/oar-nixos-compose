{ pkgs, modulesPath, nur, helpers, flavour, lib, ... }: {
  roles = let
    oarServerName = "oar-server";
    OarCtrlA = pkgs.nur.repos.kapack.oar.overrideAttrs (old: {
        patches = [
            ./common/add_gantt_route.patch
            ./common/oar_almighty.patch
        ];
    });
    commonOARConfig = import ./common/common_oar.nix {
      oarPackage = OarCtrlA;
      inherit pkgs modulesPath nur flavour oarServerName;
    };
    commonConfig =
      import ./common/common_config.nix { inherit pkgs modulesPath lib nur; };

    nfsConfig = import ./common/nfs.nix { inherit flavour oarServerName; };
    cigriCtrlA = pkgs.nur.repos.kapack.cigri.overrideAttrs (old: {
      #src = /home/quentin/ghq/gitlab.inria.fr/cigri-ctrl/feedforward-approach/cigri-src;
      src = pkgs.fetchFromGitLab {
        domain = "gitlab.inria.fr";
        owner = "cigri-ctrl/feedforward-approach";
        repo = "cigri-src";
        rev = "f825dc696f1a831716bd54d08ba63ac93d9c8df6";
        sha256 = "sha256-XqUEI3+3rYfoazLPSTLDUha9sHUMJpkwgduiL6G6OMg=";
      };
    });
  in {
    oar-server = { ... }: {
      imports = [ commonOARConfig nfsConfig.server commonConfig ];
      services.oar.server.enable = true;
      services.oar.client.enable = true;
      services.oar.dbserver.enable = true;

      environment.etc."oar/api-users" = {
        mode = "0644";
        text = ''
          user1:$apr1$yWaXLHPA$CeVYWXBqpPdN78e5FvbY3/
          user2:$apr1$qMikYseG$VL8nyeSSmxXNe3YDOiCwr1
        '';
      };
      services.oar.web.enable = true;
    };

    node = { ... }: {
      imports = [ commonOARConfig nfsConfig.client commonConfig ];
      services.oar.node = { enable = true; };
    };

    cigri = { ... }: {
      imports = [
        nur.repos.kapack.modules.cigri
        nur.repos.kapack.modules.my-startup
        nfsConfig.client
        commonConfig
      ];
      services.logrotate.enable = false;
      services.cigri = {
        package = cigriCtrlA;
        dbserver.enable = true;
        client.enable = true;
        database = {
          host = "cigri";
          passwordFile = ./common/cigri-dbpassword;
        };
        server = {
          enable = true;
          web.enable = true;
          host = "cigri";
          logfile = "/tmp/cigri.log";
          cycleDuration = 30;
        };
      };
      networking.hostName = "cigri";
      # users.users.oar = { isNormalUser = true; };
      services.my-startup = {
        enable = true;
        path = with pkgs; [ cigriCtrlA sudo postgresql openssh ];
        script = ''
          # Waiting cigri database is ready
          until pg_isready -h cigri -p 5432 -U postgres
          do
              echo "Waiting for postgres"
                  sleep 0.5;
          done

          until sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw cigri
          do
              echo "Waiting for cigri db created"
              sleep 0.5
          done

          newcluster cluster_0 http://${oarServerName}/api/ jwt fakeuser fakepasswd "" ${oarServerName} oar3 resource_id 1 ""
          # systemctl restart cigri-server

        '';
      };

    };
  };

  ##############################
  # Default number for each role
  rolesDistribution = { node = 1; }; # n1 ... n8

  testScript = ''
    frontend.succeed("true")
    # Prepare a simple script which execute cg.C.mpi 
    frontend.succeed('echo "mpirun --hostfile \$OAR_NODEFILE -mca pls_rsh_agent oarsh -mca btl tcp,self cg.C.mpi" > /users/user1/test.sh')
    # Set rigth and owner of script
    frontend.succeed("chmod 755 /users/user1/test.sh && chown user1 /users/user1/test.sh")
    # Submit job with script under user1
    frontend.succeed('su - user1 -c "cd && oarsub -l nodes=2 ./test.sh"')
    # Wait output job file 
    frontend.wait_for_file('/users/user1/OAR.1.stdout')
    # Check job's final state
    frontend.succeed("oarstat -j 1 -s | grep Terminated")
  '';
}
