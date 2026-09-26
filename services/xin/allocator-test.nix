{ pkgs, lib }:
let
  systemctlStub = pkgs.writeShellScript "systemctl-stub" ''
    printf '%s\n' "$*" >> "$XIN_TEST_LOG"
  '';

  readyProbeStub = pkgs.writeShellScript "ready-probe-stub" ''
    printf 'probe %s\n' "$*" >> "$XIN_TEST_LOG"
  '';

  deadProbeStub = pkgs.writeShellScript "dead-probe-stub" ''
    printf 'deadprobe %s\n' "$*" >> "$XIN_TEST_LOG"
    exit 1
  '';

  allocator = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 2;
    basePort = 2501;
    internalBasePort = 42501;
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 5;
    unitPrefix = "xin-vm";
    stateDir = "state";
    systemctl = "${systemctlStub}";
    readyProbe = "${readyProbeStub}";
  };

  allocatorDeadGuest = import ./allocator.nix {
    inherit pkgs lib;
    maxSlots = 1;
    basePort = 2601;
    internalBasePort = 42601;
    publicHost = "ctf.example.org";
    password = "word-word-word";
    readyTimeout = 1;
    unitPrefix = "xin-dead-vm";
    stateDir = "state-dead";
    systemctl = "${systemctlStub}";
    readyProbe = "${deadProbeStub}";
  };
in
pkgs.runCommand "xin-allocator-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail

    mkdir -p "$out"
    export XIN_TEST_LOG="$out/systemctl.log"
    : > "$XIN_TEST_LOG"
    alloc=${allocator}/bin/xin-instance

    # chall-manager retries, so `create` must reprint the same allocation.
    a1=$("$alloc" create --identity alpha)
    a2=$("$alloc" create --identity alpha)
    [[ $a1 == "$a2" ]]
    [[ $(wc -l <<< "$a1") == 1 ]]
    jq -e '.identity == "alpha" and .slot == 1 and .port == 2501' <<< "$a1"
    jq -e '.connection_info == "ssh friend@ctf.example.org -p 2501  (password: word-word-word)"' <<< "$a1"
    # The flag is static and registered in CTFd, so no instance flag may reach
    # chall-manager.
    [[ $(jq -r 'keys_unsorted | join(",")' <<< "$a1") == identity,slot,port,connection_info ]]

    b=$("$alloc" create --identity bravo)
    jq -e '.identity == "bravo" and .slot == 2 and .port == 2502' <<< "$b"
    "$alloc" list | jq -e 'length == 2 and (map(.identity) == ["alpha", "bravo"])'

    rc=0
    "$alloc" create --identity charlie 2> /dev/null || rc=$?
    [[ $rc == 4 ]]

    rc=0
    "$alloc" create --identity 'Bad Ident' 2> /dev/null || rc=$?
    [[ $rc == 2 ]]
    rc=0
    "$alloc" status --identity "" 2> /dev/null || rc=$?
    [[ $rc == 2 ]]

    rc=0
    stdout=$("$alloc" status --identity nobody 2> /dev/null) || rc=$?
    [[ $rc == 3 && -z $stdout ]]
    jq -e '.slot == 1' <<< "$("$alloc" status --identity alpha)"

    "$alloc" destroy --identity alpha
    "$alloc" destroy --identity alpha
    rc=0
    "$alloc" destroy --identity neverexisted || rc=$?
    [[ $rc == 0 ]]
    [[ ! -e state/1 ]]
    [[ $(find . -maxdepth 1 -mindepth 1 -type d | sort | tr '\n' ' ') == "./state " ]]

    c=$("$alloc" create --identity charlie)
    jq -e '.identity == "charlie" and .slot == 1 and .port == 2501' <<< "$c"
    "$alloc" list | jq -e 'length == 2'

    # A guest that never answers fails with 5 and frees its slot again.
    dead=${allocatorDeadGuest}/bin/xin-instance
    rc=0
    "$dead" create --identity delta 2> /dev/null || rc=$?
    [[ $rc == 5 ]]
    [[ ! -e state-dead/1 ]]
    "$dead" list | jq -e 'length == 0'
    grep -qx 'stop xin-dead-vm-1.service' "$XIN_TEST_LOG"
    grep -qx 'deadprobe 42601' "$XIN_TEST_LOG"

    grep -qx 'start xin-vm-1.service' "$XIN_TEST_LOG"
    grep -qx 'start xin-vm-2.service' "$XIN_TEST_LOG"
    grep -qx 'stop xin-vm-1.service' "$XIN_TEST_LOG"
    grep -qx 'probe 42501' "$XIN_TEST_LOG"
    grep -qx 'probe 42502' "$XIN_TEST_LOG"
    shape='^(start|stop) xin(-dead)?-vm-[12]\.service$'
    shape+='|^(dead)?probe 4(250[12]|2601)$'
    ! grep -qvE "$shape" "$XIN_TEST_LOG"

    echo ok > "$out/result"
  ''
