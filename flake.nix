{
  description = "Qubix: declarative Hyper-V appliance factory for NixOS VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg:
        builtins.elem (nixpkgs.lib.getName pkg) [
          "spotify"
        ];
    };

    # Evaluate a machine's NixOS config and return its config object.
    # The Hyper-V manifest is derived from evaluated machine configs so that
    # settings like hostName and static networking have one source of truth:
    # the machine file.  No more keeping two files in sync by hand.
    evalMachine = modules: (nixpkgs.lib.nixosSystem {
      inherit system pkgs;
      modules = modules;
      specialArgs = { inherit self; };
    }).config;

    # Extract network-related manifest fields from an evaluated NixOS config.
    # Returns an empty attrset when no static IP is configured (DHCP mode).
    mkNetworkFields = cfg:
      let net = cfg.qubix.network;
      in nixpkgs.lib.optionalAttrs (net.staticIp != null) {
        staticIp    = net.staticIp;
        gatewayIp   = net.gateway;
        # Derive subnet from staticIp + prefixLength (correct for /17-/24).
        natSwitchSubnet =
          let parts = nixpkgs.lib.splitString "." net.staticIp;
          in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}"
           + ".${builtins.elemAt parts 2}.0/${toString net.prefixLength}";
      };

    spotiboxCfg = evalMachine [ ./machines/spotibox.nix ];

    qubixManifest = {
      spotibox = {
        package  = "spotibox-vhdx";
        # Derived from the machine config — only one place to change.
        vmName   = "qubix-${spotiboxCfg.networking.hostName}";
        hostName = spotiboxCfg.networking.hostName;
        # Used in DHCP mode; ignored when staticIp is present.
        switchName = "Default Switch";
        cpuCount           = 2;
        memoryStartupBytes = 4294967296;
        maxMemoryBytes     = 6442450944;
        vmRoot    = "C:\\HyperV\\Qubix";
        wslDistro = "NixOS";
        # Network fields are present only when qubix.network.staticIp is set
        # in the machine file.  Nothing to change here when toggling static IP.
      } // mkNetworkFields spotiboxCfg;
    };

    mkHypervImage = modules:
      nixos-generators.nixosGenerate {
        inherit system;
        inherit pkgs;
        lib = nixpkgs.lib;
        nixosSystem = nixpkgs.lib.nixosSystem;
        format = "hyperv";
        modules = modules;
        specialArgs = {
          inherit self;
        };
      };
  in {
    packages.${system} = {
      spotibox-vhdx = mkHypervImage [
        ./machines/spotibox.nix
      ];

      spotibox-debug-vhdx = mkHypervImage [
        ./machines/spotibox-debug.nix
      ];

      qubix-manifest-json = pkgs.writeText "qubix-manifest.json"
        (builtins.toJSON qubixManifest);

      # Inspection helper: prints the spotibox system closure size and the top
      # 30 contributors, sorted by recursive closure size descending. Intended
      # for sizing decisions — building it forces the spotibox toplevel, since
      # there is nothing to measure otherwise.
      qubix-closure-info = pkgs.writeShellApplication {
        name = "qubix-closure-info";
        runtimeInputs = with pkgs; [ nix coreutils ];
        text = ''
          toplevel="${spotiboxCfg.system.build.toplevel}"

          echo "Spotibox system toplevel:"
          echo "  $toplevel"
          echo

          echo "Total closure size:"
          nix path-info -Sh "$toplevel"
          echo

          echo "Top 30 closure contributors (closure size, descending):"
          nix path-info -rSh "$toplevel" | sort -hrk2 | head -n 30
        '';
      };

      default = self.packages.${system}.spotibox-vhdx;
    };

    checks.${system}.spotibox-basic =
      import ./tests/spotibox-basic.nix {
        inherit pkgs;
      };
  };
}
