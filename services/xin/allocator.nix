{
  pkgs,
  lib,

  maxSlots,
  basePort,
  internalBasePort,
  publicHost,
  password,
  readyTimeout,
  loginUser ? "friend",

  unitPrefix,

  stateDir ? "/var/lib/xin-slots",

  systemctl ? "${pkgs.systemd}/bin/systemctl",
  readyProbe ? null,
}:
let
  sshProbe = pkgs.writeShellApplication {
    name = "xin-ssh-probe";
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

  probe = if readyProbe != null then readyProbe else "${sshProbe}/bin/xin-ssh-probe";
in
pkgs.writeShellApplication {
  name = "xin-instance";

  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.util-linux
  ];

  text = ''
    set -euo pipefail

    stateDir=${lib.escapeShellArg stateDir}
    lockFile="$stateDir/.lock"
    maxSlots=${toString maxSlots}
    basePort=${toString basePort}
    internalBasePort=${toString internalBasePort}
    readyTimeout=${toString readyTimeout}
    systemctl=${lib.escapeShellArg systemctl}
    probe=${lib.escapeShellArg probe}
    publicHost=${lib.escapeShellArg publicHost}
    password=${lib.escapeShellArg password}
    unitPrefix=${lib.escapeShellArg unitPrefix}

    die() {
      printf 'xin-instance: %s\n' "$1" >&2
      exit "$2"
    }

    usage() {
      cat >&2 <<'EOF'
    usage: xin-instance create|destroy|status --identity <ID>
           xin-instance list
    EOF
      exit 2
    }

    unit_of_slot() {
      printf '%s-%s.service\n' "$unitPrefix" "$1"
    }

    # `<stateDir>/<n>/identity` exists iff slot n is claimed. flock serialises
    # the claim only, because `create` must not hold the lock while a guest boots.
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
      local n=$1 identity=$2 dir="$stateDir/$1"
      install -d -m 0755 "$dir"
      printf '%s' "$identity" > "$dir/identity"
      chmod 0644 "$dir/identity"
    }

    teardown() {
      local n=$1
      # The VM unit wipes its own overlay in `ExecStopPost`, so the allocator
      # never writes outside `stateDir`.
      "$systemctl" stop "$(unit_of_slot "$n")" || true
      rm -rf "''${stateDir:?}/''${n:?}"
    }

    emit_json() {
      local n=$1 identity port connection_info
      identity=$(cat "$stateDir/$n/identity")
      port=$((basePort + n - 1))
      connection_info=$(printf -- 'ssh %s@%s -p %s  (password: %s)' \
        ${lib.escapeShellArg loginUser} "$publicHost" "$port" "$password")
      jq -c -n \
        --arg identity "$identity" \
        --argjson slot "$n" \
        --argjson port "$port" \
        --arg connection_info "$connection_info" \
        '{
           identity: $identity,
           slot: $slot,
           port: $port,
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
        claim_slot "$n" "$identity"
      fi
      unlock

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
        # The identity ends up in file names and unit lookups.
        [[ $identity =~ ^[a-z0-9]{1,64}$ ]] || die "malformed identity: '$identity'" 2
        "cmd_$verb" "$identity"
        ;;
      list) cmd_list ;;
      *) usage ;;
    esac
  '';
}
