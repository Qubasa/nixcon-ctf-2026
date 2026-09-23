# Exercises the allocator's CLI contract without KVM, root or a network: the
# only things this test cannot check are the parts it stubs out (systemctl and
# the SSH readiness probe), which is exactly the seam `allocator.nix` exposes
# for that reason.
{ pkgs, lib }:
let
  # Both stubs append their argv to $HOMEWORT_TEST_LOG so the test can assert
  # which units the allocator touched.
  systemctlStub = pkgs.writeShellScript "systemctl-stub" ''
    printf '%s\n' "$*" >> "$HOMEWORT_TEST_LOG"
  '';

  readyProbeStub = pkgs.writeShellScript "ready-probe-stub" ''
    printf 'probe %s\n' "$*" >> "$HOMEWORT_TEST_LOG"
  '';

  # A guest that never presents a banner: `create` must give the slot back
  # instead of leaking it, which is the difference between one lost deploy and
  # a pool that silently shrinks over an event.
  deadProbeStub = pkgs.writeShellScript "dead-probe-stub" ''
    printf 'deadprobe %s\n' "$*" >> "$HOMEWORT_TEST_LOG"
    exit 1
  '';

  # The allocator never chdirs, so relative state paths resolve against the
  # builder's cwd (a private, unique directory), which keeps the test off any
  # shared absolute path without needing an escape hatch in the allocator.
  # Production always passes absolute paths.
  allocator = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 2;
    basePort = 2201;
    internalBasePort = 42201;
    flagFormat = "nixcon{homewort_%s}";
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 5;
    stateDir = "state";
    flagOwner = null;
    systemctl = "${systemctlStub}";
    readyProbe = "${readyProbeStub}";
  };

  # Builds the same allocator with its own state tree and a probe that never
  # succeeds.
  allocatorDeadGuest = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 1;
    basePort = 2301;
    internalBasePort = 42301;
    flagFormat = "nixcon{homewort_%s}";
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 1;
    stateDir = "state-dead";
    flagOwner = null;
    systemctl = "${systemctlStub}";
    readyProbe = "${deadProbeStub}";
  };
in
pkgs.runCommand "homewort-allocator-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail

    mkdir -p "$out"
    export HOMEWORT_TEST_LOG="$out/systemctl.log"
    : > "$HOMEWORT_TEST_LOG"
    alloc=${allocator}/bin/homewort-instance

    # `create` is idempotent: same identity, same slot, same flag, byte-identical
    # JSON. chall-manager retries, so the idempotency is load bearing.
    a1=$("$alloc" create --identity alpha)
    a2=$("$alloc" create --identity alpha)
    [[ $a1 == "$a2" ]]
    jq -e '.identity == "alpha" and .slot == 1 and .port == 2201' <<< "$a1"
    jq -e '.flag | test("^nixcon\\{homewort_[0-9a-f]{32}\\}$")' <<< "$a1"
    jq -e '.connection_info == "ssh friend@ctf.example.org -p 2201  (password: word-word-word)"' <<< "$a1"
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

    # `destroy` releases the slot and is idempotent. It does NOT delete the
    # disk overlay: the VM unit wipes its own in `ExecStopPost`, so the
    # allocator writes nothing outside its state directory.
    [[ -e state/1/flag ]]
    "$alloc" destroy --identity alpha
    "$alloc" destroy --identity alpha
    "$alloc" destroy --identity neverexisted
    [[ ! -e state/1 ]]
    # Nothing but the state directory was ever created: no overlay, no stray
    # path outside `stateDir`.
    [[ $(find . -maxdepth 1 -mindepth 1 -type d | tr -d '\n') == "./state" ]]

    # The freed slot is handed to the next identity.
    c=$("$alloc" create --identity charlie)
    jq -e '.identity == "charlie" and .slot == 1 and .port == 2201' <<< "$c"

    "$alloc" list | jq -e 'length == 2'

    # A guest that never answers makes `create` exit 5, and the slot is free
    # again afterwards, so the next team gets it instead of losing it for the
    # event.
    dead=${allocatorDeadGuest}/bin/homewort-instance
    rc=0
    "$dead" create --identity delta 2> /dev/null || rc=$?
    [[ $rc == 5 ]]
    [[ ! -e state-dead/1 ]]
    "$dead" list | jq -e 'length == 0'
    grep -qx 'stop homewort-vm-1.service' "$HOMEWORT_TEST_LOG"
    grep -qx 'deadprobe 42301' "$HOMEWORT_TEST_LOG"
    # The failed claim released the slot, so it is handed out again.
    "$dead" create --identity echo1 > /dev/null 2>&1 || [[ $? == 5 ]]

    # The allocator drives the units it claims to drive.
    grep -qx 'start homewort-vm-1.service' "$HOMEWORT_TEST_LOG"
    grep -qx 'start homewort-vm-2.service' "$HOMEWORT_TEST_LOG"
    grep -qx 'stop homewort-vm-1.service' "$HOMEWORT_TEST_LOG"
    grep -qx 'probe 42201' "$HOMEWORT_TEST_LOG"
    grep -qx 'probe 42202' "$HOMEWORT_TEST_LOG"
    # No unit outside the configured slot range was touched.
    ! grep -qE 'homewort-vm-(0|3|[4-9])' "$HOMEWORT_TEST_LOG"

    echo ok > "$out/result"
  ''
