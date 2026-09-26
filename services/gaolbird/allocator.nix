# The seam between chall-manager's Pulumi scenario and the VM host.
#
# The scenario has no idea what a systemd unit or a qcow2 overlay is; it runs
# one command per lifecycle event and parses one line of JSON. Everything that
# knows about slots, flags and QEMU lives here, so the scenario stays a thin
# `pulumi-command` wrapper and this file stays testable without KVM.
{
  pkgs,
  lib,

  # Resolved knobs, all baked into the script: the allocator has no config file
  # and no environment overrides, so what the module deployed is what runs.
  maxSlots,
  basePort,
  internalBasePort,
  flagFormat,
  publicHost,
  password,
  readyTimeout,
  loginUser ? "gaolbird",

  # Name of the produced binary (e.g. "gaolbird-1-instance") and the prefix of
  # the systemd units it drives (slot `n`'s unit is "<unitPrefix>-<n>.service",
  # e.g. "gaolbird-1-vm-3.service"). Every stage's module instance installs
  # its own allocator into the same profile and runs its own VM units, so a
  # shared name or prefix across stages would collide.
  name,
  unitPrefix,

  stateDir ? "/var/lib/gaolbird-slots",
  # `user:group` given to the flag files, or null to leave ownership alone
  # (the test runs unprivileged and cannot chown).
  flagOwner ? "gaolbird:gaolbird",

  # Injected so the test can stub them out.
  systemctl ? "${pkgs.systemd}/bin/systemctl",
  readyProbe ? null,
}:
let
  # A completed connect() proves nothing: QEMU binds the forwarded port the
  # moment the VM process starts and slirp only tears the connection down once
  # it finds nothing listening in the guest. The SSH banner is the first byte
  # that actually means "the guest booted".
  sshProbe = pkgs.writeShellApplication {
    name = "gaolbird-ssh-probe";
    text = ''
      set -euo pipefail
      port=$1
      exec 3<>"/dev/tcp/127.0.0.1/$port"
      banner=""
      read -r -t 5 banner <&3 || true
      exec 3<&-
      [[ $banner == SSH-* ]]
    '';
  };

  probe = if readyProbe != null then readyProbe else "${sshProbe}/bin/gaolbird-ssh-probe";
in
pkgs.writeShellApplication {
  inherit name;

  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.openssl
    pkgs.util-linux # flock
  ];

  text = ''
    set -euo pipefail

    stateDir=${lib.escapeShellArg stateDir}
    unitPrefix=${lib.escapeShellArg unitPrefix}
    lockFile="$stateDir/.lock"
    maxSlots=${toString maxSlots}
    basePort=${toString basePort}
    internalBasePort=${toString internalBasePort}
    readyTimeout=${toString readyTimeout}
    flagOwner=${lib.escapeShellArg (if flagOwner == null then "" else flagOwner)}
    systemctl=${lib.escapeShellArg systemctl}
    probe=${lib.escapeShellArg probe}
    publicHost=${lib.escapeShellArg publicHost}
    password=${lib.escapeShellArg password}

    die() {
      printf '${name}: %s\n' "$1" >&2
      exit "$2"
    }

    usage() {
      cat >&2 <<'EOF'
    usage: ${name} create|destroy|status --identity <ID>
           ${name} list
    EOF
      exit 2
    }

    # The one place that knows how a slot number becomes a unit name, so a
    # fork of this pool changes `unitPrefix` and nothing else.
    unit_of_slot() {
      printf '%s-%s.service\n' "$unitPrefix" "$1"
    }

    # Slot bookkeeping is a directory tree, not a database: `<stateDir>/<n>/`
    # holds `identity` (presence == slot claimed) and `flag` (what fw_cfg hands
    # to the guest). flock serialises the claim, nothing else - `create` must
    # not hold the lock while it waits minutes for a guest to boot.
    lock() {
      exec 9>>"$lockFile"
      flock "$@" 9
    }

    unlock() {
      exec 9>&-
    }

    slot_of_identity() {
      local want=$1 n
      for ((n = 1; n <= maxSlots; n++)); do
        if [[ -f "$stateDir/$n/identity" && $(cat "$stateDir/$n/identity") == "$want" ]]; then
          printf '%s\n' "$n"
          return 0
        fi
      done
      return 1
    }

    free_slot() {
      local n
      for ((n = 1; n <= maxSlots; n++)); do
        if [[ ! -e "$stateDir/$n/identity" ]]; then
          printf '%s\n' "$n"
          return 0
        fi
      done
      return 1
    }

    claim_slot() {
      local n=$1 identity=$2 dir="$stateDir/$1" hex flag
      hex=$(openssl rand -hex 16)
      flag=$(printf -- ${lib.escapeShellArg flagFormat} "$hex")

      install -d -m 0755 "$dir"
      # Root-readable only by default: the guest gets it through fw_cfg, and a
      # flag that any host process could read is a flag that leaked.
      rm -f "$dir/flag"
      printf '%s\n' "$flag" > "$dir/flag"
      chmod 0400 "$dir/flag"
      if [[ -n $flagOwner ]]; then
        chown "$flagOwner" "$dir/flag"
      fi
      # Written last: a crash between the two leaves a free slot, not a slot
      # with a stale flag.
      printf '%s' "$identity" > "$dir/identity"
      chmod 0644 "$dir/identity"
      printf '%s\n' "$n"
    }

    teardown() {
      local n=$1
      # A slot may be torn down while its unit is dead, masked or never was:
      # `destroy` is contractually silent and idempotent. Stopping the unit is
      # all it takes to reclaim the disk: the VM service wipes its own overlay
      # in `ExecStopPost`, which also covers a crash or a manual `systemctl
      # stop`. Keeping that out of here means the allocator only ever writes
      # inside `stateDir`, and chall-manager - whose mount namespace the sudo
      # call inherits - only has to open up that one path.
      "$systemctl" stop "$(unit_of_slot "$n")" || true
      rm -rf "''${stateDir:?}/''${n:?}"
    }

    emit_json() {
      local n=$1 identity flag port connection_info
      identity=$(cat "$stateDir/$n/identity")
      flag=$(cat "$stateDir/$n/flag")
      port=$((basePort + n - 1))
      connection_info=$(printf -- 'ssh %s@%s -p %s  (password: %s)' \
        ${lib.escapeShellArg loginUser} "$publicHost" "$port" "$password")
      # jq builds the object so no identity, flag or password can smuggle a
      # quote into the scenario's parser.
      jq -c -n \
        --arg identity "$identity" \
        --argjson slot "$n" \
        --argjson port "$port" \
        --arg flag "$flag" \
        --arg connection_info "$connection_info" \
        '{
           identity: $identity,
           slot: $slot,
           port: $port,
           flag: $flag,
           connection_info: $connection_info
         }'
    }

    cmd_create() {
      local identity=$1 n internalPort deadline
      lock
      if ! n=$(slot_of_identity "$identity"); then
        if ! n=$(free_slot); then
          unlock
          die "no free slot (maxSlots=$maxSlots)" 4
        fi
        claim_slot "$n" "$identity" > /dev/null
      fi
      unlock

      # Idempotent by construction: an already running unit stays running and
      # a crashed one comes back, both without minting a new flag.
      "$systemctl" start "$(unit_of_slot "$n")"

      internalPort=$((internalBasePort + n - 1))
      deadline=$((SECONDS + readyTimeout))
      until "$probe" "$internalPort" 2> /dev/null; do
        if ((SECONDS >= deadline)); then
          lock
          teardown "$n"
          unlock
          die "slot $n did not accept ssh within ''${readyTimeout}s" 5
        fi
        sleep 2
      done

      emit_json "$n"
    }

    cmd_destroy() {
      local identity=$1 n
      lock
      if n=$(slot_of_identity "$identity"); then
        teardown "$n"
      fi
      unlock
    }

    cmd_status() {
      local identity=$1 n
      lock -s
      if ! n=$(slot_of_identity "$identity"); then
        unlock
        die "no slot for identity '$identity'" 3
      fi
      unlock
      emit_json "$n"
    }

    cmd_list() {
      local n
      lock -s
      {
        for ((n = 1; n <= maxSlots; n++)); do
          if [[ -f "$stateDir/$n/identity" ]]; then
            emit_json "$n"
          fi
        done
      } | jq -c -s '.'
      unlock
    }

    verb=''${1-}
    if (($# > 0)); then shift; fi
    identity=""
    while (($# > 0)); do
      case $1 in
        --identity)
          if (($# < 2)); then usage; fi
          identity=$2
          shift 2
          ;;
        *) die "unknown argument: $1" 2 ;;
      esac
    done

    install -d -m 0755 "$stateDir"

    case $verb in
      create | destroy | status)
        # The identity is a chall-manager-supplied string that ends up in file
        # names and unit lookups; anything but the contracted charset is a bug
        # upstream, not something to sanitise into silence.
        [[ $identity =~ ^[a-z0-9]{1,64}$ ]] || die "malformed identity: '$identity'" 2
        "cmd_$verb" "$identity"
        ;;
      list) cmd_list ;;
      *) usage ;;
    esac
  '';
}
