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
    lib = nixpkgs.lib;
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = pkg:
        builtins.elem (lib.getName pkg) [
          "spotify"
        ];
    };

    # GitHub repository that publishes release assets.  `qubixctl -Command up`
    # downloads images from here when it is not asked to build them in WSL.
    releaseRepo = "PhysShell/qubix";

    # Evaluate a machine's NixOS config.  The Hyper-V manifest is derived from
    # evaluated machine configs so that settings like hostName, static
    # networking and the home-disk contract have one source of truth: the
    # machine file.  No more keeping two files in sync by hand.
    #
    # The Hyper-V image module is part of the evaluation so that
    # `nixosConfigurations.*` describe exactly the system that ends up in the
    # VHDX (root filesystem, growPartition, Hyper-V guest services included).
    evalMachine = modules: lib.nixosSystem {
      inherit system pkgs;
      modules = modules ++ [
        "${nixpkgs}/nixos/modules/virtualisation/hyperv-image.nix"
      ];
      specialArgs = { inherit self; };
    };

    # Extract network-related manifest fields from an evaluated NixOS config.
    # Returns an empty attrset when no static IP is configured (DHCP mode).
    mkNetworkFields = cfg:
      let net = cfg.qubix.network;
      in lib.optionalAttrs (net.staticIp != null) {
        staticIp    = net.staticIp;
        gatewayIp   = net.gateway;
        # Derive subnet from staticIp + prefixLength (correct for /17-/24).
        natSwitchSubnet =
          let parts = lib.splitString "." net.staticIp;
          in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}"
           + ".${builtins.elemAt parts 2}.0/${toString net.prefixLength}";
      };

    # One manifest entry per machine.  Everything the Windows controller needs
    # to create the VM, find the images and open the RDP window lives here.
    mkMachineManifest = { name, cfg }: {
      # Nix package names, used by the WSL build path.
      package     = "${name}-vhdx";
      homePackage = "${name}-home-vhdx";

      # Derived from the machine config — only one place to change.
      vmName   = "qubix-${cfg.networking.hostName}";
      hostName = cfg.networking.hostName;

      # Used in DHCP mode; ignored when staticIp is present.
      switchName = "Default Switch";
      cpuCount           = 2;
      memoryStartupBytes = 4294967296;
      maxMemoryBytes     = 6442450944;
      vmRoot    = "C:\\HyperV\\Qubix";
      wslDistro = "NixOS";

      homeDisk = {
        inherit (cfg.qubix.homeDisk) enable label sizeMiB;
      };

      # RDP window the controller opens after boot.  The lab password is
      # already public in this repo; storing it in Windows Credential Manager
      # for one-click connects does not make it any less public.
      rdp = {
        user     = "rdp";
        password = cfg.qubix.labPassword;
        width    = 1280;
        height   = 800;
      };

      # GitHub release assets, as produced by the `${name}-release` package.
      release = {
        repo        = releaseRepo;
        systemAsset = "${name}.vhdx.gz";
        homeAsset   = "${name}-home.vhdx.gz";
        sumsAsset   = "SHA256SUMS";
      };

      # Network fields are present only when qubix.network.staticIp is set
      # in the machine file.  Nothing to change here when toggling static IP.
    } // mkNetworkFields cfg;

    spotibox      = evalMachine [ ./machines/spotibox.nix ];
    spotiboxDebug = evalMachine [ ./machines/spotibox-debug.nix ];

    qubixManifest = {
      schemaVersion = 2;
      machines = {
        spotibox = mkMachineManifest { name = "spotibox"; cfg = spotibox.config; };
      };
    };

    mkHypervImage = modules:
      nixos-generators.nixosGenerate {
        inherit system pkgs lib;
        nixosSystem = lib.nixosSystem;
        format = "hyperv";
        modules = modules;
        specialArgs = {
          inherit self;
        };
      };

    # Pre-formatted, labelled, empty ext4 disk for /home as a dynamic VHDX.
    # The guest mounts it by label (profiles/storage/persistent-home.nix), the
    # host copies it next to the VM once and never touches it again.
    mkHomeSeed = cfg:
      let hd = cfg.qubix.homeDisk;
      in pkgs.runCommand "qubix-home-${cfg.networking.hostName}.vhdx" {
        nativeBuildInputs = [ pkgs.e2fsprogs pkgs.qemu-utils ];
      } ''
        raw="$TMPDIR/home.raw"
        truncate -s ${toString hd.sizeMiB}M "$raw"
        mkfs.ext4 -q -F -L ${lib.escapeShellArg hd.label} -m 0 \
          -E lazy_itable_init=1,lazy_journal_init=1 "$raw"
        qemu-img convert -f raw -O vhdx -o subformat=dynamic "$raw" "$out"
      '';

    # Everything one GitHub release needs, gzip'd so that Windows can unpack
    # it with nothing but .NET (no zstd/7-Zip dependency on the host).
    mkReleaseBundle = { name, systemImage, homeImage, manifest }:
      pkgs.runCommand "qubix-release-${name}" {
        nativeBuildInputs = [ pkgs.pigz ];
      } ''
        mkdir -p "$out"
        vhdx=$(find -L ${systemImage} -type f -name '*.vhdx' -print -quit)
        test -n "$vhdx" || { echo "no .vhdx in ${systemImage}" >&2; exit 1; }
        pigz -9 -n -c "$vhdx" > "$out/${name}.vhdx.gz"
        pigz -9 -n -c ${homeImage} > "$out/${name}-home.vhdx.gz"
        cp ${manifest} "$out/manifest.json"
        cd "$out"
        sha256sum ${name}.vhdx.gz ${name}-home.vhdx.gz manifest.json > SHA256SUMS
      '';

    manifestJson = (pkgs.formats.json { }).generate "qubix-manifest.json" qubixManifest;
  in {
    # Exposed for introspection (`nix eval`, `nixos-rebuild build-vm`, tests).
    nixosConfigurations = {
      spotibox       = spotibox;
      spotibox-debug = spotiboxDebug;
    };

    packages.${system} = {
      spotibox-vhdx = mkHypervImage [
        ./machines/spotibox.nix
      ];

      spotibox-debug-vhdx = mkHypervImage [
        ./machines/spotibox-debug.nix
      ];

      spotibox-home-vhdx = mkHomeSeed spotibox.config;

      spotibox-release = mkReleaseBundle {
        name = "spotibox";
        systemImage = self.packages.${system}.spotibox-vhdx;
        homeImage = self.packages.${system}.spotibox-home-vhdx;
        manifest = manifestJson;
      };

      qubix-manifest-json = manifestJson;

      default = self.packages.${system}.spotibox-vhdx;
    };

    checks.${system}.spotibox-basic =
      import ./tests/spotibox-basic.nix {
        inherit pkgs;
      };
  };
}
