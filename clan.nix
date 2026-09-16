{ inputs }:
{
  # Ensure this is unique among all clans you want to use.
  meta.name = "nixcon-ctf";
  meta.domain = "immutable-byte.de";

  # Local clan services.
  # Takes `inputs` to reach the CTFd chall-manager plugin source tree.
  modules.ctfd = import ./services/ctfd { inherit inputs; };
  modules.chall-manager = ./services/chall-manager;
  modules.gitea = ./services/gitea;
  # Takes `inputs` to reach the nixbot flake's module.
  modules.nixbot = import ./services/nixbot { inherit inputs; };
  # Takes `inputs` to reach the challenge flake it hosts.
  modules.homewort = import ./services/homewort { inherit inputs; };


  vars.settings.secretStore = "age";
  vars.settings.recipients.default = [
    "age1pq14ddx6vxm3vy9z9ul2gre6ztrnd2867e9nxkhsftc03puzvww94nhzkqpgzduymwgq6lte3503ueqrvdvs4fsve9jqe9y4veyvu6zllgmha0zq4t67jhs2cvdm7z23cmrtnkh3wx44jcz5cf6a37ff5lh92wns6ass2888puw3s3jyqf3xhyaymru8ryeka4cc8gt4dk8dahrcy69wjcufazq8lssgx6e9tqx0yzenysymgjjuuuhtt0m346unqgccgkg7zj5mm23tq9zpgdvzlqvfg994cfpvsg868l55d9649jygcy6j5evkzj4pg58vrwkpv9gppwykpn9a49j9y2880k35gljd2ta5gvzs4qehh56fg4j0t2n62v9afwgzq25pnce3le4y8kd6sdhae7rwx6ta67et4hvvgjydjyxapk2nwaufn8zrq8dgqsg6z52xse3vzjfac6z2m52rf0zegwwr9v6qvgs5jmh25e5s5lf49egwqa97y5kayg8kmedg7g6j7fhtkphxpwtw9cydrjtxseh5sqynk3nftcn0u2ktvct3yn7cf027ut2ac9ktsqjrcmyzzfnk46ta0pyy4fzqqkspmshgctkwsn2f6uq5cz2p75c3xhyds6uzpj5pcp23c4efqk5yxz4z4pp5g9h6z7z0nz2r888yqrpczyydq0cr9g2mge9h4jhyj094z02afskm9p9fgfgrtvf2salymtavw099qy9z836d23uyyuapn279ya444em864qlxpx83g4kuc8c7y5udnr3let4lrntp8qj8tjdvk5du3ajfc35s0vzgz4xywghykz0a7yt54e7asynywt2q4fvvgsd73v73r9mfdy8jd782dr5ay4e5nw86mux05vrtt2k9kgczrv57dj3yjywt7nnyygvdgq2qdd9vuu4yz9kxkzhpsdqwckjn8962smnz7vgmh94f9kvzkvw9sjfs4h9mjcy88435nlqffqvak23prkuxvx5rze9ynysjmsfdxq9c5rkpq5m55gc27qz8xvsup2dzxd99ts36jyp3vxry9e0jxa99a0vqr6af8urdt5xpyqeg84c42rvu9f3hrvveqzkvz2mdd53yeytfk8tt9e02nqzmk20xdwuuus8d4gtzcy2ja3d3aswjquhanwd223xe3v2ul9kzvq56p64k5drgnqa3afc9wyk74etfrd07ge5g9k4ce8sf7evztdx6twna6jytahkr8r9xaggeeywe5ye6q03jmkqfcyj0amk0v34yetwsd0gx9glujgzhmecq9gt8x49zy8ujqy32dgwelg8x9g0zt9vgyxs55ftm3rtxe6nqf6g45hvc5j0xskusfpznw23rdnup9ca9w2mn2ckg6zqy7wj4yv3dcepfn3cfgz7dkqk9pfevuak98udl90psj3j09gneyuxu4dxfk58sny5ddyggt2pkhzjn99eq54m59xsxvhnfltx9wxjws67d8xa246dzq35wtz5635jv8l2ewfz2vjlwgnc8p50cazsawnv30q94zjfwrjg0jgggtqgvmktvd36337ycn37ak223x5f85k3d9u9ysat7a8jc2322mrkt8n8nzdjmx0jxv360kexq862udn8xla6wv9239f7hlmvq4p4p3jeza6qk6jwlvtjekvcq2wn8qx02ad8xz7l2u5mh2kd7u5gg3ymym5jxmwjlrexcqtq70hyufvqfqy5pcj8k5qmwwevgewxxqn5d4ag3jx72xy36rhzc30jvqv6zamcjf6ny6g523q0qfk39t86ywfmztsancegapgxqnuexv9e2xwmtkrmfmsc5zmn05jymuca42zaf6dd04aedq2tru43xrfgss27erexfx32lwf98ygq0mxuenamwatunpcd9kv2m99walywxdqdh7kvs3c6cge" # qubasa
    "age1pq1azezy5y8exr3ppl2swc7d7efgek8stpvzhneyrgnud6nqs3lxmdjr223fgt2x8twc890ydyhxaykarvgwr93e3grckgtc3g5nruvgg7xc8qr4sx3kyd6jp642tsms2z4e4py4f5dzgcvpc98gtrvqjcz0m7kk49dffh7q9w8w06eacnftky8x92054m98c38xz6n853cw88sc9xdl3w8xsfk35vc735yp5zljl4c7sqn7zq656nmd9yfg9cnwzvxwvgg8ptyhju3dsf3dqqjgt5gff95kqqqz2zuuhjzh39hctr9uem3xkqu6wdcmqtqvzfmf9n46swcywrtlvcz3m38s4lud09d3jlsjczkpx3jzfc8yr30rd8vvj0t53c8at3x4tmp2ulhvhg97z7fa7qrxtmvnw98pk60wczfcxgsv5f4tpwgeknntw8cx39m0flmeyj99xa87kv54cuzpppn00xmwnygtu6fkuhr4cqwtx9rk7r4769vudymuug45q9x3q9y6fkqtkg9zcfhf0m9y9puzgdpvqayyywz7zmgp3u8y2rd29eec9vdtxrxl3s37ehrxjuvspd24flfpefzc7m2zmpprpsz3vdnggu7r8qnx4zq3lnh4fsp3ncqyj9ch37yjwkgjkemp3cy08gyku5rwqmydlanvzkus772zvuzn9tnnz9g4pevmqchgp98kk8xgz89rze2h2axd3kktu5783ke327emecfhh4k4mmzc5pfkcas6qxh4vdzqjmkvknchkz99zsj3dw5eejgw5f8hh389hda53v8kghse9s4sxshh0fevssucfthwv6h392rgpgyksjcju8v56mddsypf4pgyky3sx9xkvkdwglf7aeg9947hr495c5u2tqegjf7zcpwwgn9r92kk9sf8a4tgvnyy3npqye5z25q4vf88zps9gapvcqmkacpl6zv235g9yyxcauh6y3rmumv5tasz8hfe6knjqq3evkpxduccr98k3nr3eh5q9jdz6gc7dfhlmjrcwj5h72lsptqu9sxj258deyudc98fxgkx5x0wqzld2nu3ratzyh44gu7z6xspnrl5wtm6hvqq6m32c0sspj5xqyd3dkpq97ys2j2zcj427ksvz9en9mzxrvzc6cpkwftkw8v6phgpse8sdephmzkwaxrgwlx02e4njqxt594tgnf9jrvdjg2wg7l0dumd89jmwsc824rkmvdc5svp7qhru2gs7e83x6uddxdhfpqtx23nxmcylkjtxe3prn6j64dt665kvym8h28fr84s94fgc06u6d9djjfaz22cshldt7t7k3qcsfeswyhtc2rfncrp205qquhh2ulkstnx2z5e006wqu8v264ce562mc9sv45ckts54nux8zfkft0p4j9eucuj4jy0szekxm722s6jwprwgs2k7vvkjv32j5nxx2ff2j2ln5vdkg9gj5wmssjye6x03cfnl6hk4840s3qszd4qf227cppmxw3fzqh28ycgrxywkrn4ausg0fcc8m0fyz272htpa9f73ph3evkymey43g8kufm88r54244svcqx74sxgp9eyrlf8rr4ck9cuzp2s063ygkcgljjvtvxecvtafgkvk6xx9mdplp8czgfn5gvewtd28akwczs293x3rhz09u4zvxp43sq524ff2s8kcctcstrv6rvmr0zdn4uwktt42xczry3m5uz0nuqley8r9s6awtqxr2dxee2yykvuwxh2q83umjzsn5svf29ey5jjutw9tz8hqvhu7fes44qklgxpl0xxh94xaj8d33kuzf4cwgege6ck25mawk84tkyjvdvx9hxrv4yqejy7g74gqkavum45w6cdgv75f7gkncsfr792tfkmaavtdjy22hqa595n9ympg0663vystccc5p5m8azyyqevsg" # 3ulalia
  ];
  
  inventory.machines = {
    # Define machines here.
    ctf-machine = { };
  };

  inventory.instances = {

    # Docs: https://clan.lol/docs/services/official/sshd
    # SSH service for secure remote access to machines.
    # Generates persistent host keys and configures authorized keys.
    sshd = {
      roles.server.tags.all = { };
      roles.server.settings.authorizedKeys = {
        # Insert the public key that you want to use for SSH access.
        # All keys will have ssh access to all machines ("tags.all" means 'all machines').
        # Alternatively set 'users.users.root.openssh.authorizedKeys.keys' in each machine
        "admin-machine-1" =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGXfyed2m6hEB5gXTclAYSdi8tDQJF5HQe+rop7Pj8ik lhebendanz@wintux";
        "3ulalia" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTVytCp3QF/PtqJ9LH4zYyT/UJC5JyhmEsD3YBBQKko eulalia@catalina";
      };
    };

    # Docs: https://clan.lol/docs/unstable/services/official/users
    # Root password management for all machines.
    user-root = {
      module = {
        name = "users";
      };
      roles.default.tags.all = { };
      roles.default.settings = {
        user = "root";
        prompt = true;
      };
    };

    # Docs: https://clan.lol/docs/unstable/services/official/p2p-ssh-iroh
    # Status experimental
    # Firewall-traversing SSH access via encrypted QUIC streams
    p2p-ssh-iroh = {
      roles.server.tags = [ "nixos" ];
    };

    # Local module (see ./services/ctfd). Runs the CTFd platform with its
    # MariaDB and Redis containers. Secrets are managed through clan vars.
    ctfd = {
      module = {
        name = "ctfd";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        nginx = {
          enable = true;
          hostName = "ctf.nixcon.org";
          # CNAME target of the official name: still reachable, and everything
          # that reaches it is bounced to ctf.nixcon.org.
          redirectHostNames = [ "ctf.immutable-byte.de" ];
          acmeEmail = "admin@immutable-byte.de";
        };
      };
    };

    # Local module (see ./services/gitea). Gitea on PostgreSQL behind nginx
    # with TLS and an Anubis proof-of-work challenge.
    gitea = {
      module = {
        name = "gitea";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        hostName = "git.immutable-byte.de";
        nginx.acmeEmail = "admin@immutable-byte.de";
      };
    };

    # Local module (see ./services/nixbot). Nix CI for the Gitea instance
    # above: webhooks -> `.#checks` -> commit statuses. Needs the manual Gitea
    # setup described in services/nixbot/README.md (bot user, access token,
    # OAuth2 app) before the first deploy.
    nixbot = {
      module = {
        name = "nixbot";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        hostName = "ci.immutable-byte.de";
        giteaUrl = "https://git.immutable-byte.de";
        acmeEmail = "admin@immutable-byte.de";
        # Client id of the Gitea OAuth2 application (non-secret).
        oauthId = "07f8d2ba-77ef-48e9-bce5-424e956596d0";
        admins = [ "gitea:qubasa" ];
      };
    };

    # Local module (see ./services/chall-manager). The engine behind the
    # on-demand challenges: CTFd's chall-manager plugin asks it for an
    # instance, it runs the challenge's Pulumi scenario, and its janitor
    # destroys instances once they expire. Unauthenticated by design, so it is
    # only reachable from the CTFd container over the `challmgr` network.
    #
    # The 2h instance lifetime is not set here: it is a per-challenge field of
    # the CTFd `dynamic_iac` form, which chall-manager receives over its API.
    chall-manager = {
      module = {
        name = "chall-manager";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        # The homewort allocator runs as a child of chall-manager, so it needs
        # its slot directory writable inside that service's mount namespace.
        # Keep this in sync with the slot directory in ./services/homewort.
        scenarioWritePaths = [ "/var/lib/homewort-slots" ];
      };
    };

    # Local module (see ./services/homewort). Pool of on-demand QEMU VMs
    # hosting the `homewort` privilege-escalation challenge. Slots are claimed
    # by `chall-manager` through the `homewort-instance` allocator, one
    # forwarded SSH port and one freshly minted flag per instance.
    homewort = {
      module = {
        name = "homewort";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        # Measured on this host (i7-7700, 8 threads, 64 GiB): a claimed VM
        # sits at 750 MiB RSS idle and 2.4 GiB after an in-guest rebuild, and
        # costs ~0.16 of a hardware thread while idle. 12 x 4 GiB is the
        # worst-case RAM budget if every guest touches its full `memorySize`,
        # which leaves ~14 GiB for CTFd, chall-manager and page cache; all 12
        # rebuilding at once measured 29 GiB, 146 s per rebuild against the
        # 46 s a lone one takes.
        maxSlots = 12;
        publicHost = "ctf.nixcon.org";
      };
    };
  };

  # Additional NixOS configuration can be added here.
  # machines/server/configuration.nix will be automatically imported.
  # See: https://clan.lol/docs/unstable/guides/inventory/autoincludes
  machines = {
    ctf-machine = { config, pkgs, ... }: {
      environment.systemPackages = [ pkgs.helix ];

      services.postgresql.package = pkgs.postgresql_17;
    };
  };
}
