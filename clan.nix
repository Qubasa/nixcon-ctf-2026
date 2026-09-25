{ inputs }:
{
  meta.name = "nixcon-ctf";
  meta.domain = "immutable-byte.de";

  modules.ctfd = import ./services/ctfd { inherit inputs; };
  modules.chall-manager = ./services/chall-manager;
  modules.gitea = ./services/gitea;
  modules.baas = import ./services/baas { inherit inputs; };
  modules.nixbot = import ./services/nixbot { inherit inputs; };
  modules.homewort = import ./services/homewort { inherit inputs; };
  modules.homewort-v2 = import ./services/homewort-v2 { inherit inputs; };
  modules.rtunreal = import ./services/rtunreal { inherit inputs; };

  vars.settings.secretStore = "age";
  vars.settings.recipients.default = [
    "age1pq14ddx6vxm3vy9z9ul2gre6ztrnd2867e9nxkhsftc03puzvww94nhzkqpgzduymwgq6lte3503ueqrvdvs4fsve9jqe9y4veyvu6zllgmha0zq4t67jhs2cvdm7z23cmrtnkh3wx44jcz5cf6a37ff5lh92wns6ass2888puw3s3jyqf3xhyaymru8ryeka4cc8gt4dk8dahrcy69wjcufazq8lssgx6e9tqx0yzenysymgjjuuuhtt0m346unqgccgkg7zj5mm23tq9zpgdvzlqvfg994cfpvsg868l55d9649jygcy6j5evkzj4pg58vrwkpv9gppwykpn9a49j9y2880k35gljd2ta5gvzs4qehh56fg4j0t2n62v9afwgzq25pnce3le4y8kd6sdhae7rwx6ta67et4hvvgjydjyxapk2nwaufn8zrq8dgqsg6z52xse3vzjfac6z2m52rf0zegwwr9v6qvgs5jmh25e5s5lf49egwqa97y5kayg8kmedg7g6j7fhtkphxpwtw9cydrjtxseh5sqynk3nftcn0u2ktvct3yn7cf027ut2ac9ktsqjrcmyzzfnk46ta0pyy4fzqqkspmshgctkwsn2f6uq5cz2p75c3xhyds6uzpj5pcp23c4efqk5yxz4z4pp5g9h6z7z0nz2r888yqrpczyydq0cr9g2mge9h4jhyj094z02afskm9p9fgfgrtvf2salymtavw099qy9z836d23uyyuapn279ya444em864qlxpx83g4kuc8c7y5udnr3let4lrntp8qj8tjdvk5du3ajfc35s0vzgz4xywghykz0a7yt54e7asynywt2q4fvvgsd73v73r9mfdy8jd782dr5ay4e5nw86mux05vrtt2k9kgczrv57dj3yjywt7nnyygvdgq2qdd9vuu4yz9kxkzhpsdqwckjn8962smnz7vgmh94f9kvzkvw9sjfs4h9mjcy88435nlqffqvak23prkuxvx5rze9ynysjmsfdxq9c5rkpq5m55gc27qz8xvsup2dzxd99ts36jyp3vxry9e0jxa99a0vqr6af8urdt5xpyqeg84c42rvu9f3hrvveqzkvz2mdd53yeytfk8tt9e02nqzmk20xdwuuus8d4gtzcy2ja3d3aswjquhanwd223xe3v2ul9kzvq56p64k5drgnqa3afc9wyk74etfrd07ge5g9k4ce8sf7evztdx6twna6jytahkr8r9xaggeeywe5ye6q03jmkqfcyj0amk0v34yetwsd0gx9glujgzhmecq9gt8x49zy8ujqy32dgwelg8x9g0zt9vgyxs55ftm3rtxe6nqf6g45hvc5j0xskusfpznw23rdnup9ca9w2mn2ckg6zqy7wj4yv3dcepfn3cfgz7dkqk9pfevuak98udl90psj3j09gneyuxu4dxfk58sny5ddyggt2pkhzjn99eq54m59xsxvhnfltx9wxjws67d8xa246dzq35wtz5635jv8l2ewfz2vjlwgnc8p50cazsawnv30q94zjfwrjg0jgggtqgvmktvd36337ycn37ak223x5f85k3d9u9ysat7a8jc2322mrkt8n8nzdjmx0jxv360kexq862udn8xla6wv9239f7hlmvq4p4p3jeza6qk6jwlvtjekvcq2wn8qx02ad8xz7l2u5mh2kd7u5gg3ymym5jxmwjlrexcqtq70hyufvqfqy5pcj8k5qmwwevgewxxqn5d4ag3jx72xy36rhzc30jvqv6zamcjf6ny6g523q0qfk39t86ywfmztsancegapgxqnuexv9e2xwmtkrmfmsc5zmn05jymuca42zaf6dd04aedq2tru43xrfgss27erexfx32lwf98ygq0mxuenamwatunpcd9kv2m99walywxdqdh7kvs3c6cge" 
    "age1pq1azezy5y8exr3ppl2swc7d7efgek8stpvzhneyrgnud6nqs3lxmdjr223fgt2x8twc890ydyhxaykarvgwr93e3grckgtc3g5nruvgg7xc8qr4sx3kyd6jp642tsms2z4e4py4f5dzgcvpc98gtrvqjcz0m7kk49dffh7q9w8w06eacnftky8x92054m98c38xz6n853cw88sc9xdl3w8xsfk35vc735yp5zljl4c7sqn7zq656nmd9yfg9cnwzvxwvgg8ptyhju3dsf3dqqjgt5gff95kqqqz2zuuhjzh39hctr9uem3xkqu6wdcmqtqvzfmf9n46swcywrtlvcz3m38s4lud09d3jlsjczkpx3jzfc8yr30rd8vvj0t53c8at3x4tmp2ulhvhg97z7fa7qrxtmvnw98pk60wczfcxgsv5f4tpwgeknntw8cx39m0flmeyj99xa87kv54cuzpppn00xmwnygtu6fkuhr4cqwtx9rk7r4769vudymuug45q9x3q9y6fkqtkg9zcfhf0m9y9puzgdpvqayyywz7zmgp3u8y2rd29eec9vdtxrxl3s37ehrxjuvspd24flfpefzc7m2zmpprpsz3vdnggu7r8qnx4zq3lnh4fsp3ncqyj9ch37yjwkgjkemp3cy08gyku5rwqmydlanvzkus772zvuzn9tnnz9g4pevmqchgp98kk8xgz89rze2h2axd3kktu5783ke327emecfhh4k4mmzc5pfkcas6qxh4vdzqjmkvknchkz99zsj3dw5eejgw5f8hh389hda53v8kghse9s4sxshh0fevssucfthwv6h392rgpgyksjcju8v56mddsypf4pgyky3sx9xkvkdwglf7aeg9947hr495c5u2tqegjf7zcpwwgn9r92kk9sf8a4tgvnyy3npqye5z25q4vf88zps9gapvcqmkacpl6zv235g9yyxcauh6y3rmumv5tasz8hfe6knjqq3evkpxduccr98k3nr3eh5q9jdz6gc7dfhlmjrcwj5h72lsptqu9sxj258deyudc98fxgkx5x0wqzld2nu3ratzyh44gu7z6xspnrl5wtm6hvqq6m32c0sspj5xqyd3dkpq97ys2j2zcj427ksvz9en9mzxrvzc6cpkwftkw8v6phgpse8sdephmzkwaxrgwlx02e4njqxt594tgnf9jrvdjg2wg7l0dumd89jmwsc824rkmvdc5svp7qhru2gs7e83x6uddxdhfpqtx23nxmcylkjtxe3prn6j64dt665kvym8h28fr84s94fgc06u6d9djjfaz22cshldt7t7k3qcsfeswyhtc2rfncrp205qquhh2ulkstnx2z5e006wqu8v264ce562mc9sv45ckts54nux8zfkft0p4j9eucuj4jy0szekxm722s6jwprwgs2k7vvkjv32j5nxx2ff2j2ln5vdkg9gj5wmssjye6x03cfnl6hk4840s3qszd4qf227cppmxw3fzqh28ycgrxywkrn4ausg0fcc8m0fyz272htpa9f73ph3evkymey43g8kufm88r54244svcqx74sxgp9eyrlf8rr4ck9cuzp2s063ygkcgljjvtvxecvtafgkvk6xx9mdplp8czgfn5gvewtd28akwczs293x3rhz09u4zvxp43sq524ff2s8kcctcstrv6rvmr0zdn4uwktt42xczry3m5uz0nuqley8r9s6awtqxr2dxee2yykvuwxh2q83umjzsn5svf29ey5jjutw9tz8hqvhu7fes44qklgxpl0xxh94xaj8d33kuzf4cwgege6ck25mawk84tkyjvdvx9hxrv4yqejy7g74gqkavum45w6cdgv75f7gkncsfr792tfkmaavtdjy22hqa595n9ympg0663vystccc5p5m8azyyqevsg" 
    "age1pq1h44kjz6frjey8g6rfvxewxqua9cp7rg4f387keq8srzudxkvew79x2jqprv3z5ejwylmrx7q6hys9wghxz53vf0f2g6gtu6aa2ertf5tt9vue90esp0maet3v0c68j82wkuy89mlu6s70u3043ru55uewff0ctjp2xplsc9hfm3klymqndq52fxcpjxv3r93dq36zdy4h5gm0jf45zu26xyvm2tej9q4z4vlzeny6z3cmswv49c4heemslswvy7ec9xus72uctw8zcl9yp6pjhdn3qcjguru4js6n4wzfh48xuzfk559y8xt9c6yfgw9q723k9wc5ssn5ccxj4gztgznrhvdh83q57qhs5ndd0wts0k883hcjwu4mqfdvxal7wekdt7jwaxnewvfxxe20cupmmmhgzsx3pd348sk0f9fk27xxedjeaatymnxcr6gn9rax9prmyr6fx7prwvq3rtuxc3cq33zu6yssvw9nv6vw40ukqez53nxnavkul5cncwvqcy6pyc3vv6dyj9uuxuhe6w0suqyu68w54pnpgq6z7rm55w6ev7lhz54075zraxt28nrdap8sqqayw9c54ankdfmhdzct7hqwdaqrnyqgk6hx3v9svnq2eg0sq30udh9dlyhw24vwr8qd7s63pdztjl4xpukcfpghtwyqwdu4nf99sztsecm64vmfl5uxhnngpfyud3rw3ms0fnhm79vnyl7xvtdzmyjufktnxuuwew94mcujnauk694qcregg6xsmlv8u9q3g3w09dnqmx2n2x2ylcs9l2anxwun2vh5yp298az7y4zqagkcm9ycwr8fesqtzs896mkngrcg7tzlgfvyyv0w4metqzpwgpj5l7ptsj9vd3rd5pes7fhnnmazq8zef0pqvjc0vffs4rvpkqgvwmc5u9qn64f6f99rymjj6csq8ureqnj9ppz2aazvyygtsn9kw50tw76dhpvkc2gqqsm45npc505h24525pnlysupdwps4fywezf6d6d76rvwjv4grtyp97aw858qw22ac2xp53qmltytwak2rh4wxh65ju948nxl9ht2cxaknrm9w3cvcy34pd27zl8qsshypm7ve76fd6qpc96cm54jsm0zhqm7dtl7x7yeqffqt0hhnxxytad6je4pjajsq3hedptfuf6wkq0j5kz0kwxhumfwey3pcusjsvz77vas7py5yauxu6z4cg72tg2syue0m9vmzetdf7zhx4sg82u8s3lfvpxmx5xe3z4vzp8z62g5vgnln92fluhcwdh9g8v28p4d2m4zemtk6ay96quq2grxg0g5ajm8crsv3uhevwpcv7r8y4kvw586xghhydk4cm5na8rys4t8jhxmwcwpe9uv68gf7aee9nrj7h67c5hr6u2gm39d427n2attyxhpwzfqptmjl8vrlk5pwj0zavumufut8wtlcvjrjccvpxja30s8xzvktuf4eerrlgan2su9nqe834dmeycn3082qqjwwzxw4h4zf5fqta9g95xdph5gqgshqel9zmuxsd87n85fpj8wz6yjq8wykm8hf9rkyx4zgynzpzta9729u9c7yunagdcnl2kqn4xqfspyyew40afu0jmgqjyypucgw5ww0xwrkak0gvptfxgpdvmu0qrzfkyvtj4qevz4szldwgf0ynxqynvu5gka7txddgqvm9vy59q4kgug5k9762px9r6y9m97qgrhuug3l5hjlj9che0tfy9aysesg3enq26v7zef6mqc902gglvuez0geu907xf8ll68fs4v5yztrxpz5z3vhwunu5j0n4jlzf6dkpj6yapqjg4y6xd323ufw3ns0f67l0gywgf7dglw38qt7frsdyyv5v0z3vaksejqsflf7vyz25psyyqsxzy7n6rlkf0j8zsv79cxvtvt79z" 
    "age1pq10hgusrfrgkx4nsn9yz03w6s376zvf57hkcystz8hwqjpeqsh54yk747esgm5t9360qulyquk6zggz962zekhwqt60wthyenjwyk973tp8wufqtptj0zzm4z3ulztvqmkhwjt28hvxjkwluspvrfvtkm2tssx5nh0z389e95csl2cxtmn2nvfxw29rx4e0j44qr4zx8uv94jf8s2k2ge7axnda4pn94atwrxjdzjv9sayt3zz38dhrwqq5pt6kl875n9h2e6mw059x68sg5tjxh0h6duw2hyegqnu360rrj44zsfp3yarv3sm7rjntevznflmv9e8337z0uyuyts2hynnxfrh9r9g3dcx9yzyv2pz9jt89a26dppusyy4f4kfvycmh82tzezaq89hqjpp3ysg8u25d2uc8xxnqagdexcgcgzzhvcxsng9pcud0yxeq3v3tecsefpvnuke40h62vyjy5mn6c3a2lp4gjw6nlhlntelt9dkzqfadv4nd622fp52zw5vj7rt2qtsdqat8gl4jxnge20xu3aw7eaplmqmdarj940ywuql7mrhmzupty6zrm7jh77vw28kdtqrlj48q6v3wy2frncdfn4t2d9gd9ttl3n4684gg57mk2g3409szvzkah36uux4peq2znhas938jdprja98k5f2sx9t5ekrhzv59lztv05fe4tcpzxqyued7k8qpaqet7r6mwqxpkg6xjcs3gjq5ydfwpysknckyjt63t7mlf70pwqu7vrzuww8j8t0k56evj4kczsv5vjvh0eq3hxj5f9kxe4p0gncylf3q0hv8d5l2hpnaxh7tw2a5pejt5kysyy8ffwe3venmnqj58qsxdmknfjvqjch2c9847qdx9pjt63r5efu8xd36a7t3tqwajw9whe6cm0n2l4emxxj8hzhlu2ue8u3s5gcst5hjnrvd2j9l43yttm6td37ngtmjhrycaxqjter8scs2a84c5e78gz7d9e440qq2jnx96fdyzqga2r2c2aqrp66vczh3f0dpgt9x9jkdge09yxxjyty4mu5tv5cv2smk99puxmr3jh3elr24sze3vzxau788anxl29r0vcfddj4l3syjcf59cyke5p2gxy7e8um02gpq2xz9nm8jy882wupsfhw0pjxzjr667emk4mszx8g5rltqsjsjutuz5qy6lfxjnvvqchxuc82c94xn3nhhnsrhqlaw7tz5z589ys4hpj4qum9hv4vf35rz2cmuydqd8ahqu03ftu4p2k356ga47r4am7x8xxnqp8wcx00k4d96sxzafzr83xt2vnhyf3hfqaq4k70dmwymw25eehfslpmzxusmdf3ac4fgexkp0n8kcp5fdg5x4nvjedc3qnyf05y59wtxauxjlytqpjrdmjns6ktwfelu4jmvgqu66nmw5ttxqav0d4ddypfpkxyezg8pwzv8ghgcnxqupucvvddn64jcjju5cv8yfxmurzpggxyem2emrzkrcdwtvq829sxrwcar9u2x8z3dj2xx7c8fdmnmv9w87xxjayg907an23q3vaj0rqf6vw238my3ndlwahk83tl96wx3quhj3scraew4jnm8vm2nu2fu362ryj2v2jxst2hl3gnct9q7nfgpp9xeqj4yum7kg9kwpyv50jug0gmjggvkntlt2j2tja9l0u5j80gz963kmgtk9han99gprtzculvsxy3xr8se9exzcf0huepu7g2wx9p5kcdsfxtk6dvajenzlys032uk5hrwt93p3s8wzszkas2ya03fprzep5u84d7du3utyh55ft2j0qcadcvjwep0q8vx9cqqzrjz4394ekzfg86xhfve70gkwlthvu99v5ceyzgpxs4st60dxk073xk4gz3hp5j90glxpt8x8fw0n0qw47y36cu2gt9xx89"
  ];

  inventory.machines = {
    ctf-machine = { };
  };

  inventory.instances = {

    sshd = {
      roles.server.tags.all = { };
      roles.server.settings.authorizedKeys = {
        "admin-machine-1" =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGXfyed2m6hEB5gXTclAYSdi8tDQJF5HQe+rop7Pj8ik lhebendanz@wintux";
        "3ulalia" =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDTVytCp3QF/PtqJ9LH4zYyT/UJC5JyhmEsD3YBBQKko eulalia@catalina";
        "virchau" =
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCxZL3sVGCdUlD3sivB7kFTJGIdgXjzggXLshqIsxqkmMk2zLUOfB3vWcgt9k9jhhoH1kJRe06eOsZsUzNoUPtBs4crMoRYDj8PBUsKD6BgLa96/PRGk7jm5hSAqedDC7yTuGp0u5pVlyplqY7eiacKu/TyM84V9rOT+9tFT8334GOBdHEuFpDVwdc2xJMr/AGu1tL9fpgLSYSkHyFiCn1/t1BTNt9wf8wWw3vLhHxBHI119LOTf9na2xscAFEFRQxy5Q1HDf15AuAbuhaMb8siZZtQRqlElJadUpPfjfQdR7qcLandbfrhI4oVaT2bYyvLV7AXaO8pFDgPgjNzfQ7lfJvdH7jSSjsUMh9hQhnat41yw9hiHhTrn7wBojH6lg32R7I+GMXoMmsEQof8XTdzf67xVEYKgqQlF1zVCVZ2Y3yNk1AFwKbR13hrDFCDI/7cy7BkcD179qCb+C73zHzAF0DYxA7k4Sr/WTS0ihjbfOQvHblwrdYvugHXQyK7fEgeaL+CjeqpX6OFc4cnAYwe6Rlzk+mZj8lTo0cXGDi35cd2y2UYmdU79+GyzNPvR62GnACwXAWiSyKTIwIpIxvoEpQEZ3ZXYHq3UqTg4fuin9LeX2pNIekVYchoIdTbZbkPN1hMtPZl+aw7k+baZSmTXnoN8WVLtRsj75DcczhCdQ== virchau13@hexular.net";
        "julian" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHs8Op0RUW6V/cdBqbFKABYP3BvseIHPpFo8cW0/TF9E julian.kuners@gmail.com";
      };
    };

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

    p2p-ssh-iroh = {
      roles.server.tags = [ "nixos" ];
    };

    ctfd = {
      module = {
        name = "ctfd";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        nginx = {
          enable = true;
          hostName = "ctf.nixcon.org";
          redirectHostNames = [ "ctf.immutable-byte.de" ];
          acmeEmail = "admin@immutable-byte.de";
        };
      };
    };

    gitea = {
      module = {
        name = "gitea";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        hostName = "git.immutable-byte.de";
        nginx.acmeEmail = "admin@immutable-byte.de";
      };
    };

    chall-manager = {
      module = {
        name = "chall-manager";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        scenarioWritePaths = [
          "/var/lib/homewort-slots"
          "/var/lib/homewort-v2-slots"
        ];
      };
    };

    homewort = {
      module = {
        name = "homewort";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        maxSlots = 40;
        publicHost = "ctf.nixcon.org";
      };
    };

    homewort-v2 = {
      module = {
        name = "homewort-v2";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        maxSlots = 14;
        publicHost = "ctf.nixcon.org";
      };
    };

    baas = {
      module = {
        name = "baas";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        nginx = {
          enable = true;
          hostName = "ctf.nixcon.org";
        };
      };
    };

    rtunreal = {
      module = {
        name = "rtunreal";
        input = "self";
      };
      roles.server.machines.prod-ctf-machine = { };
      roles.server.settings = {
        nginx.hostName = "ctf.nixcon.org";
      };
    };
  };

  machines = {
    prod-ctf-machine = { config, pkgs, ... }: {
      environment.systemPackages = [ pkgs.helix ];

      services.postgresql.package = pkgs.postgresql_17;
    };
  };
}
