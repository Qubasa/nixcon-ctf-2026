{ pkgs, lib }:
let
  systemctlStub = pkgs.writeShellScript "systemctl-stub" ''
    printf '%s\n' "$*" >> "$GAOLBIRD_TEST_LOG"
  '';

  readyProbeStub = pkgs.writeShellScript "ready-probe-stub" ''
    printf 'probe %s\n' "$*" >> "$GAOLBIRD_TEST_LOG"
  '';

  deadProbeStub = pkgs.writeShellScript "dead-probe-stub" ''
    printf 'deadprobe %s\n' "$*" >> "$GAOLBIRD_TEST_LOG"
    exit 1
  '';

  # Mirrors what `default.nix` computes for a given `challengeStage`: the
  # allocator itself no longer knows the concept of a "stage", only the
  # binary name and unit prefix that follow from one.
  mkAllocator =
    stage:
    args:
    import ./allocator.nix (
      {
        inherit pkgs lib;
        flagFormat = "nixcon{gaolbird-${toString stage}_%s}";
        publicHost = "ctf.example.org";
        password = "word-word-word";
        flagOwner = null;
        systemctl = "${systemctlStub}";
        name = "gaolbird-${toString stage}-instance";
        unitPrefix = "gaolbird-${toString stage}-vm";
      }
      // args
    );

  allocator = mkAllocator 1 {
    maxSlots = 2;
    basePort = 2201;
    internalBasePort = 42201;
    readyTimeout = 5;
    stateDir = "state-1";
    readyProbe = "${readyProbeStub}";
  };

  allocatorDeadGuest = mkAllocator 1 {
    maxSlots = 1;
    basePort = 2301;
    internalBasePort = 42301;
    readyTimeout = 1;
    stateDir = "state-1-dead";
    readyProbe = "${deadProbeStub}";
  };

  # A lighter per-stage smoke test: every stage's pool is otherwise identical
  # shell code, so what actually differs (and what broke once already: the
  # unit name the allocator starts/stops for its own slots) is what this
  # checks, for every stage the module supports.
  otherStages = [
    2
    3
    4
  ];

  mkStageCheck =
    stage:
    let
      alloc = mkAllocator stage {
        maxSlots = 1;
        basePort = 2400 + stage * 10;
        internalBasePort = 42400 + stage * 10;
        readyTimeout = 5;
        stateDir = "state-${toString stage}";
        readyProbe = "${readyProbeStub}";
      };
    in
    ''
      alloc=${alloc}/bin/gaolbird-${toString stage}-instance
      stageOut=$("$alloc" create --identity "stage${toString stage}")
      jq -e '.slot == 1' <<< "$stageOut"
      jq -e '.flag | test("^nixcon\\{gaolbird-${toString stage}_[0-9a-f]{32}\\}$")' <<< "$stageOut"
      "$alloc" destroy --identity "stage${toString stage}"
      grep -qx 'start gaolbird-${toString stage}-vm-1.service' "$GAOLBIRD_TEST_LOG"
      grep -qx 'stop gaolbird-${toString stage}-vm-1.service' "$GAOLBIRD_TEST_LOG"
    '';
in
pkgs.runCommand "gaolbird-allocator-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail

    mkdir -p "$out"
    export GAOLBIRD_TEST_LOG="$out/systemctl.log"
    : > "$GAOLBIRD_TEST_LOG"
    alloc=${allocator}/bin/gaolbird-1-instance

    # `create` is idempotent: same identity, same slot, same flag, byte-identical
    # JSON. chall-manager retries, so the idempotency is load bearing.
    a1=$("$alloc" create --identity alpha)
    a2=$("$alloc" create --identity alpha)
    [[ $a1 == "$a2" ]]
    jq -e '.identity == "alpha" and .slot == 1 and .port == 2201' <<< "$a1"
    jq -e '.flag | test("^nixcon\\{gaolbird-1_[0-9a-f]{32}\\}$")' <<< "$a1"
    jq -e '.connection_info == "ssh gaolbird@ctf.example.org -p 2201  (password: word-word-word)"' <<< "$a1"
    [[ $(jq -r 'keys_unsorted | join(",")' <<< "$a1") == identity,slot,port,flag,connection_info ]]

    # `create` prints one line of JSON on stdout and nothing else, because the
    # scenario parses it whole.
    [[ $(wc -l <<< "$a1") == 1 ]]

    # A second identity gets its own slot, port, and flag.
    b=$("$alloc" create --identity bravo)
    jq -e '.identity == "bravo" and .slot == 2 and .port == 2202' <<< "$b"
    [[ $(jq -r .flag <<< "$a1") != $(jq -r .flag <<< "$b") ]]

    "$alloc" list | jq -e 'length == 2 and (map(.identity) == ["alpha", "bravo"])'

    # maxSlots == 2: capacity exhaustion is exit 4, which the scenario surfaces
    # as a failed deploy.
    rc=0
    "$alloc" create --identity charlie 2> /dev/null || rc=$?
    [[ $rc == 4 ]]

    # A malformed identity exits 2 and consumes no slot.
    rc=0
    "$alloc" create --identity 'Bad Ident' 2> /dev/null || rc=$?
    [[ $rc == 2 ]]
    rc=0
    "$alloc" status --identity "" 2> /dev/null || rc=$?
    [[ $rc == 2 ]]

    # An unknown identity exits 3 and prints nothing on stdout.
    rc=0
    stdout=$("$alloc" status --identity nobody 2> /dev/null) || rc=$?
    [[ $rc == 3 && -z $stdout ]]
    jq -e '.slot == 1' <<< "$("$alloc" status --identity alpha)"

    # `destroy` releases the slot and is idempotent, including for an identity
    # that never held one: exit 0, silent. It does NOT delete the disk overlay:
    # the VM unit wipes its own in `ExecStopPost`, so the allocator writes
    # nothing outside its state directory.
    [[ -e state-1/1/flag ]]
    "$alloc" destroy --identity alpha
    "$alloc" destroy --identity alpha
    rc=0
    "$alloc" destroy --identity neverexisted || rc=$?
    [[ $rc == 0 ]]
    [[ ! -e state-1/1 ]]

    # The freed slot is handed to the next identity, with a new flag.
    c=$("$alloc" create --identity charlie)
    jq -e '.identity == "charlie" and .slot == 1 and .port == 2201' <<< "$c"
    [[ $(jq -r .flag <<< "$c") != $(jq -r .flag <<< "$a1") ]]

    "$alloc" list | jq -e 'length == 2'

    # A guest that never answers makes `create` exit 5, and the slot is free
    # again afterwards, so the next team gets it instead of losing it for the
    # event.
    dead=${allocatorDeadGuest}/bin/gaolbird-1-instance
    rc=0
    "$dead" create --identity delta 2> /dev/null || rc=$?
    [[ $rc == 5 ]]
    [[ ! -e state-1-dead/1 ]]
    "$dead" list | jq -e 'length == 0'
    grep -qx 'stop gaolbird-1-vm-1.service' "$GAOLBIRD_TEST_LOG"
    grep -qx 'deadprobe 42301' "$GAOLBIRD_TEST_LOG"
    # The failed claim released the slot, so it is handed out again.
    "$dead" create --identity echo1 > /dev/null 2>&1 || [[ $? == 5 ]]

    # The allocator drives the units it claims to drive, named after its own
    # stage: this pool never touches another stage's units.
    grep -qx 'start gaolbird-1-vm-1.service' "$GAOLBIRD_TEST_LOG"
    grep -qx 'start gaolbird-1-vm-2.service' "$GAOLBIRD_TEST_LOG"
    grep -qx 'stop gaolbird-1-vm-1.service' "$GAOLBIRD_TEST_LOG"
    grep -qx 'probe 42201' "$GAOLBIRD_TEST_LOG"
    grep -qx 'probe 42202' "$GAOLBIRD_TEST_LOG"
    ! grep -qE 'gaolbird-[^1]-vm-' "$GAOLBIRD_TEST_LOG"

    ${lib.concatMapStringsSep "\n" mkStageCheck otherStages}

    # Every stage's units stayed inside that stage's own name: no stage's
    # allocator ever started or stopped another stage's VM.
    shape='^(start|stop) gaolbird-[1-4]-vm-[12]\.service$'
    shape+='|^(dead)?probe [0-9]+$'
    ! grep -qvE "$shape" "$GAOLBIRD_TEST_LOG"

    echo ok > "$out/result"
  ''
