{ pkgs, lib }:
let
  systemctlStub = pkgs.writeShellScript "systemctl-stub" ''
    printf '%s\n' "$*" >> "$HOMEWORT_V2_TEST_LOG"
  '';

  readyProbeStub = pkgs.writeShellScript "ready-probe-stub" ''
    printf 'probe %s\n' "$*" >> "$HOMEWORT_V2_TEST_LOG"
  '';

  deadProbeStub = pkgs.writeShellScript "dead-probe-stub" ''
    printf 'deadprobe %s\n' "$*" >> "$HOMEWORT_V2_TEST_LOG"
    exit 1
  '';

  allocator = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 2;
    basePort = 2301;
    internalBasePort = 42301;
    flagFormat = "nixcon{homewort_v2_%s}";
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 5;
    unitPrefix = "homewort-v2-vm";
    stateDir = "state-v2";
    flagOwner = null;
    systemctl = "${systemctlStub}";
    readyProbe = "${readyProbeStub}";
  };

  allocatorDeadGuest = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 1;
    basePort = 2401;
    internalBasePort = 42401;
    flagFormat = "nixcon{homewort_v2_%s}";
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 1;
    unitPrefix = "homewort-v2-dead-vm";
    stateDir = "state-v2-dead";
    flagOwner = null;
    systemctl = "${systemctlStub}";
    readyProbe = "${deadProbeStub}";
  };
in
pkgs.runCommand "homewort-v2-allocator-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail

    mkdir -p "$out"
    export HOMEWORT_V2_TEST_LOG="$out/systemctl.log"
    : > "$HOMEWORT_V2_TEST_LOG"
    alloc=${allocator}/bin/homewort-v2-instance

    # `create` is idempotent: same identity, same slot, same flag, byte-identical
    # JSON. chall-manager retries, so the idempotency is load bearing.
    a1=$("$alloc" create --identity alpha)
    a2=$("$alloc" create --identity alpha)
    [[ $a1 == "$a2" ]]
    jq -e '.identity == "alpha" and .slot == 1 and .port == 2301' <<< "$a1"
    jq -e '.flag | test("^nixcon\\{homewort_v2_[0-9a-f]{32}\\}$")' <<< "$a1"
    jq -e '.connection_info == "ssh friend@ctf.example.org -p 2301  (password: word-word-word)"' <<< "$a1"
    [[ $(jq -r 'keys_unsorted | join(",")' <<< "$a1") == identity,slot,port,flag,connection_info ]]

    # `create` prints one line of JSON on stdout and nothing else, because the
    # scenario parses it whole.
    [[ $(wc -l <<< "$a1") == 1 ]]

    # A second identity gets its own slot, port, and flag.
    b=$("$alloc" create --identity bravo)
    jq -e '.identity == "bravo" and .slot == 2 and .port == 2302' <<< "$b"
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
    [[ -e state-v2/1/flag ]]
    "$alloc" destroy --identity alpha
    "$alloc" destroy --identity alpha
    rc=0
    "$alloc" destroy --identity neverexisted || rc=$?
    [[ $rc == 0 ]]
    [[ ! -e state-v2/1 ]]
    # Nothing but the state directories was ever created: no overlay, no stray
    # path outside `stateDir`.
    [[ $(find . -maxdepth 1 -mindepth 1 -type d | sort | tr '\n' ' ') == "./state-v2 " ]]

    # The freed slot is handed to the next identity, with a new flag.
    c=$("$alloc" create --identity charlie)
    jq -e '.identity == "charlie" and .slot == 1 and .port == 2301' <<< "$c"
    [[ $(jq -r .flag <<< "$c") != $(jq -r .flag <<< "$a1") ]]

    "$alloc" list | jq -e 'length == 2'

    # A guest that never answers makes `create` exit 5, and the slot is free
    # again afterwards, so the next team gets it instead of losing it for the
    # event.
    dead=${allocatorDeadGuest}/bin/homewort-v2-instance
    rc=0
    "$dead" create --identity delta 2> /dev/null || rc=$?
    [[ $rc == 5 ]]
    [[ ! -e state-v2-dead/1 ]]
    "$dead" list | jq -e 'length == 0'
    grep -qx 'stop homewort-v2-dead-vm-1.service' "$HOMEWORT_V2_TEST_LOG"
    grep -qx 'deadprobe 42401' "$HOMEWORT_V2_TEST_LOG"
    # The failed claim released the slot, so it is handed out again.
    "$dead" create --identity echo1 > /dev/null 2>&1 || [[ $? == 5 ]]

    # The allocator drives the units it claims to drive.
    grep -qx 'start homewort-v2-vm-1.service' "$HOMEWORT_V2_TEST_LOG"
    grep -qx 'start homewort-v2-vm-2.service' "$HOMEWORT_V2_TEST_LOG"
    grep -qx 'stop homewort-v2-vm-1.service' "$HOMEWORT_V2_TEST_LOG"
    grep -qx 'probe 42301' "$HOMEWORT_V2_TEST_LOG"
    grep -qx 'probe 42302' "$HOMEWORT_V2_TEST_LOG"
    # Everything the allocator did names one of this pool's own units and a
    # slot inside its range, so neither slot 0 or 3 nor another pool's VM unit
    # can have been touched.
    shape='^(start|stop) homewort-v2(-dead)?-vm-[12]\.service$'
    shape+='|^(dead)?probe 4(230[12]|2401)$'
    ! grep -qvE "$shape" "$HOMEWORT_V2_TEST_LOG"

    echo ok > "$out/result"
  ''
