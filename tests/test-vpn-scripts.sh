#!/usr/bin/env bash
set -euo pipefail
umask 022

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/configs/90-hotspot-vpn-policy"
ROUTES="$ROOT/scripts/github-vpn-routes.sh"
OPENVPN_WRAPPER="$ROOT/scripts/openvpn-replay-wrapper"
OPENVPN_DIVERSION="$ROOT/scripts/openvpn-diversion.sh"
SETUP="$ROOT/setup.sh"
UNINSTALL="$ROOT/uninstall.sh"
QUALITY_WORKFLOW="$ROOT/.github/workflows/quality.yml"

cmp -s "$POLICY" "$ROOT/scripts/vpn-routing.sh"

test_policy_skips_mtu_when_tun_is_absent() {
  local tmp fakebin policy_copy
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  policy_copy="$tmp/policy"
  mkdir -p "$fakebin" "$tmp/run/lock"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$fakebin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
if [ "$1 $2 $3" = "link show tun0" ] || [ "$1 $2 $3 $4" = "link show dev tun0" ]; then
  exit 1
fi
exit 0
EOF
  cat > "$fakebin/iptables" <<'EOF'
#!/bin/sh
case " $* " in
  *" -C "*) exit 1 ;;
esac
exit 0
EOF
  cp "$fakebin/iptables" "$fakebin/ip6tables"
  for command in ipset nmcli; do
    cat > "$fakebin/$command" <<'EOF'
#!/bin/sh
exit 0
EOF
  done
  chmod +x "$fakebin"/*

  sed -e "s#/run/lock#$tmp/run/lock#g" \
      -e "s#/proc/sys/net/ipv4/ip_forward#$tmp/ip_forward#g" \
      "$POLICY" > "$policy_copy"
  chmod +x "$policy_copy"
  : > "$tmp/ip_forward"
  IP_LOG="$tmp/ip.log" PATH="$fakebin:$PATH" "$policy_copy" tun0 apply

  if grep -q '^link set dev tun0 mtu ' "$tmp/ip.log"; then
    echo "Policy must not set MTU when tun0 is absent" >&2
    return 1
  fi
}

test_policy_skips_mtu_when_tun_is_absent

run_policy_with_existing_tun() {
  local fail_set="$1" tmp fakebin policy_copy result
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  policy_copy="$tmp/policy"
  mkdir -p "$fakebin" "$tmp/run/lock"

  cat > "$fakebin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
if [ "$1 $2 $3 $4" = "link set dev tun0" ] && [ "${IP_SET_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
EOF
  cat > "$fakebin/iptables" <<'EOF'
#!/bin/sh
case " $* " in
  *" -C "*) exit 1 ;;
esac
exit 0
EOF
  cp "$fakebin/iptables" "$fakebin/ip6tables"
  for command in ipset nmcli; do
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/$command"
  done
  chmod +x "$fakebin"/*
  sed -e "s#/run/lock#$tmp/run/lock#g" \
      -e "s#/proc/sys/net/ipv4/ip_forward#$tmp/ip_forward#g" \
      "$POLICY" > "$policy_copy"
  chmod +x "$policy_copy"
  : > "$tmp/ip_forward"

  if IP_SET_FAIL="$fail_set" IP_LOG="$tmp/ip.log" PATH="$fakebin:$PATH" \
      "$policy_copy" tun0 apply; then
    result=0
  else
    result=$?
  fi
  grep -qx 'link set dev tun0 mtu 1400' "$tmp/ip.log"
  rm -rf "$tmp"
  return "$result"
}

test_policy_sets_default_mtu_on_existing_tun() {
  run_policy_with_existing_tun 0
}

test_policy_sets_default_mtu_on_existing_tun

test_policy_sets_default_mtu_on_existing_awg() {
  local tmp fakebin policy_copy result
  tmp="$(mktemp -d)"
  fakebin="$tmp/bin"
  policy_copy="$tmp/policy"
  mkdir -p "$fakebin" "$tmp/run/lock"

  cat > "$fakebin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_LOG"
exit 0
EOF
  cat > "$fakebin/iptables" <<'EOF'
#!/bin/sh
case " $* " in
  *" -C "*) exit 1 ;;
esac
exit 0
EOF
  cp "$fakebin/iptables" "$fakebin/ip6tables"
  for command in ipset nmcli; do
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/$command"
  done
  chmod +x "$fakebin"/*
  sed -e "s#/run/lock#$tmp/run/lock#g" \
      -e "s#/proc/sys/net/ipv4/ip_forward#$tmp/ip_forward#g" \
      "$POLICY" > "$policy_copy"
  chmod +x "$policy_copy"
  : > "$tmp/ip_forward"

  if IP_LOG="$tmp/ip.log" PATH="$fakebin:$PATH" "$policy_copy" awg0 apply; then
    result=0
  else
    result=$?
  fi
  grep -qx 'link set dev awg0 mtu 1280' "$tmp/ip.log"
  rm -rf "$tmp"
  return "$result"
}

test_policy_sets_default_mtu_on_existing_awg

test_policy_propagates_mtu_set_failure() {
  if run_policy_with_existing_tun 1; then
    echo "Policy must fail when the existing tunnel MTU cannot be set" >&2
    return 1
  fi
}

test_policy_propagates_mtu_set_failure

make_fake_dpkg_divert() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DIVERT_LOG"
case "$1" in
  --list)
    if [ -s "$DIVERT_STATE" ]; then
      cat "$DIVERT_STATE"
    fi
    ;;
  --quiet)
    case " $* " in
      *" --add "*)
        printf 'local diversion of %s to %s\n' "$OPENVPN_PATH" "$OPENVPN_REAL_PATH" > "$DIVERT_STATE"
        mv "$OPENVPN_PATH" "$OPENVPN_REAL_PATH"
        ;;
      *" --remove "*)
        : > "$DIVERT_STATE"
        mv "$OPENVPN_REAL_PATH" "$OPENVPN_PATH"
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$path"
}

test_diversion_refuses_hostile_lock_directory_symlink() {
  local tmp openvpn real fake_dpkg lock_dir output
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  lock_dir="$tmp/lock-dir"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod 0755 "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  mkdir "$tmp/attacker"
  ln -s "$tmp/attacker" "$lock_dir"
  make_fake_dpkg_divert "$fake_dpkg"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      OPENVPN_DIVERSION_LOCK_DIR="$lock_dir" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" 2>&1)"; then
    echo "Diversion must refuse a symlink lock directory" >&2
    return 1
  fi
  grep -q 'lock directory' <<<"$output"
  test ! -s "$tmp/divert.log"
  test ! -e "$tmp/attacker/lifecycle.lock"
}

test_diversion_refuses_hostile_lock_directory_symlink

test_diversion_serializes_lifecycle_changes() {
  local tmp openvpn real fake_dpkg lock ready locker
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  lock="$tmp/diversion.lock"
  ready="$tmp/lock.ready"
  trap 'test -z "${locker:-}" || kill "$locker" 2>/dev/null || true; rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  flock "$lock" sh -c "touch '$ready'; sleep 2" &
  locker=$!
  while [ ! -e "$ready" ]; do sleep 0.01; done

  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      OPENVPN_DIVERSION_LOCK="$lock" OPENVPN_LOCK_TIMEOUT=0 \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Diversion lifecycle must not run without acquiring its lock" >&2
    return 1
  fi
  test ! -s "$tmp/divert.log"
  wait "$locker"
  locker=""
}

test_diversion_serializes_lifecycle_changes

test_diversion_fails_closed_when_registration_query_fails() {
  local tmp openvpn real fake_dpkg output
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod 0755 "$openvpn"
  : > "$tmp/divert.log"
  cat > "$fake_dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DIVERT_LOG"
case "$1" in
  --list) exit 2 ;;
  *) echo MUTATION >> "$DIVERT_LOG" ;;
esac
EOF
  chmod +x "$fake_dpkg"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_LOG="$tmp/divert.log" \
      "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" 2>&1)"; then
    echo "Install must fail when diversion registration cannot be queried" >&2
    return 1
  fi
  grep -q 'could not query diversion registration' <<<"$output"
  test "$(grep -c MUTATION "$tmp/divert.log" || true)" -eq 0
}

test_diversion_fails_closed_when_registration_query_fails

test_diversion_install_is_safe_and_idempotent() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
    DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER"
  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
    DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER"

  cmp -s "$OPENVPN_WRAPPER" "$openvpn"
  test -x "$real"
  test "$(grep -c -- '--add' "$tmp/divert.log")" -eq 1
  grep -qxF "local diversion of $openvpn to $real" "$tmp/divert.state"
}

test_diversion_install_is_safe_and_idempotent

test_diversion_refuses_matching_wrapper_with_wrong_owner() {
  local tmp openvpn real fake_dpkg wrong_uid
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  wrong_uid="$(( $(id -u) + 1 ))"
  trap 'rm -rf "$tmp"' RETURN
  cp "$OPENVPN_WRAPPER" "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod +x "$openvpn" "$real"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      OPENVPN_OWNER_UID="$wrong_uid" OPENVPN_OWNER_GID="$(id -g)" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Install must refuse a matching wrapper with the wrong owner" >&2
    return 1
  fi
}

test_diversion_refuses_matching_wrapper_with_wrong_owner

test_diversion_refuses_diverted_executable_with_wrong_owner() {
  local tmp openvpn real fake_dpkg fakebin
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  fakebin="$tmp/bin"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$fakebin"
  cp "$OPENVPN_WRAPPER" "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod +x "$openvpn" "$real"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"
  cat > "$fakebin/stat" <<'EOF'
#!/bin/sh
last=""
for arg in "$@"; do last="$arg"; done
if [ "$last" = "$OPENVPN_REAL_PATH" ]; then
  printf '%s:%s\n' "$(( $(id -u) + 1 ))" "$(id -g)"
else
  /usr/bin/stat "$@"
fi
EOF
  chmod +x "$fakebin/stat"

  if PATH="$fakebin:$PATH" OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Install must refuse a diverted executable with the wrong owner" >&2
    return 1
  fi
}

test_diversion_refuses_diverted_executable_with_wrong_owner

test_diversion_refuses_group_writable_real_executable() {
  local tmp openvpn real fake_dpkg output
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  cp "$OPENVPN_WRAPPER" "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod 0755 "$openvpn"
  chmod 0775 "$real"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" 2>&1)"; then
    echo "Install must refuse a group-writable real executable" >&2
    return 1
  fi
  grep -q 'writable' <<<"$output"
}

test_diversion_refuses_group_writable_real_executable

test_diversion_refuses_writable_managed_wrapper() {
  local tmp openvpn real fake_dpkg action output
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  cp "$OPENVPN_WRAPPER" "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod 0777 "$openvpn"
  chmod 0755 "$real"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  for action in check install remove; do
    if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
        DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
        DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" "$action" \
        "$OPENVPN_WRAPPER" 2>&1)"; then
      echo "$action must refuse a writable managed wrapper" >&2
      return 1
    fi
    grep -q 'writable' <<<"$output"
  done
  test "$(stat -c %a "$openvpn")" = 777
}

test_diversion_refuses_writable_managed_wrapper

test_diversion_refuses_initial_executable_with_wrong_owner() {
  local tmp openvpn real fake_dpkg fakebin
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  fakebin="$tmp/bin"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"
  cat > "$fakebin/stat" <<'EOF'
#!/bin/sh
last=""
for arg in "$@"; do last="$arg"; done
if [ "$last" = "$OPENVPN_PATH" ]; then
  printf '%s:%s\n' "$(( $(id -u) + 1 ))" "$(id -g)"
else
  /usr/bin/stat "$@"
fi
EOF
  chmod +x "$fakebin/stat"

  if PATH="$fakebin:$PATH" OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Install must refuse an initial executable with the wrong owner" >&2
    return 1
  fi
  test "$(grep -c -- '--add' "$tmp/divert.log" || true)" -eq 0
  test ! -e "$real"
}

test_diversion_refuses_initial_executable_with_wrong_owner

test_diversion_install_rolls_back_wrapper_failure() {
  local tmp openvpn real fake_dpkg fakebin
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  fakebin="$tmp/bin"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/install"
  chmod +x "$fakebin/install"

  if PATH="$fakebin:$PATH" OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Install must fail when the wrapper cannot be installed" >&2
    return 1
  fi

  test -x "$openvpn"
  test ! -e "$real"
  test ! -s "$tmp/divert.state"
  test "$(grep -c -- '--remove' "$tmp/divert.log")" -eq 1
}

test_diversion_install_rolls_back_wrapper_failure

test_diversion_validation_failure_rolls_back_and_verifies_restoration() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  cat > "$fake_dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DIVERT_LOG"
case "$1" in
  --list) test ! -s "$DIVERT_STATE" || cat "$DIVERT_STATE" ;;
  --quiet)
    case " $* " in
      *" --add "*)
        printf 'invalid diversion registration\n' > "$DIVERT_STATE"
        mv "$OPENVPN_PATH" "$OPENVPN_REAL_PATH"
        ;;
      *" --remove "*)
        : > "$DIVERT_STATE"
        mv "$OPENVPN_REAL_PATH" "$OPENVPN_PATH"
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$fake_dpkg"

  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Install must fail when post-diversion validation fails" >&2
    return 1
  fi

  test -x "$openvpn"
  test ! -e "$real"
  test ! -s "$tmp/divert.state"
  test "$(grep -c -- '--remove' "$tmp/divert.log")" -eq 1
}

test_diversion_validation_failure_rolls_back_and_verifies_restoration

test_diversion_reports_failed_validation_rollback() {
  local tmp openvpn real fake_dpkg output
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  cat > "$fake_dpkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DIVERT_LOG"
case "$1" in
  --list) test ! -s "$DIVERT_STATE" || cat "$DIVERT_STATE" ;;
  --quiet)
    case " $* " in
      *" --add "*)
        printf 'invalid diversion registration\n' > "$DIVERT_STATE"
        mv "$OPENVPN_PATH" "$OPENVPN_REAL_PATH"
        ;;
      *" --remove "*) exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$fake_dpkg"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" \
      2>&1)"; then
    echo "Install must fail when validation rollback fails" >&2
    return 1
  fi

  grep -q 'validation and rollback both failed' <<<"$output"
  test "$(grep -c -- '--remove' "$tmp/divert.log")" -eq 1
  test -e "$real"
}

test_diversion_reports_failed_validation_rollback

test_diversion_refuses_unsafe_install_states() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  make_fake_dpkg_divert "$fake_dpkg"
  : > "$tmp/divert.log"

  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  printf 'stale-real\n' > "$real"
  chmod +x "$openvpn" "$real"
  : > "$tmp/divert.state"
  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" >/dev/null 2>&1; then
    echo "Install must refuse an unregistered stale real path" >&2
    return 1
  fi
  grep -qxF 'stale-real' "$real"

  rm -f "$real"
  cp "$OPENVPN_WRAPPER" "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" >/dev/null 2>&1; then
    echo "Install must not divert the replay wrapper as the real executable" >&2
    return 1
  fi
  cmp -s "$OPENVPN_WRAPPER" "$openvpn"
  test ! -e "$real"

  printf 'foreign-wrapper\n' > "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod +x "$openvpn" "$real"
  printf 'local diversion of %s to %s.other\n' "$openvpn" "$real" > "$tmp/divert.state"
  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" >/dev/null 2>&1; then
    echo "Install must refuse a conflicting diversion" >&2
    return 1
  fi
  grep -qxF 'foreign-wrapper' "$openvpn"

  rm -f "$openvpn"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" >/dev/null 2>&1; then
    echo "Install must not claim a pre-existing diversion with no owned wrapper" >&2
    return 1
  fi
  test ! -e "$openvpn"
}

test_diversion_refuses_unsafe_install_states

test_diversion_remove_refuses_unregistered_managed_wrapper() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  cp "$OPENVPN_WRAPPER" "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Remove must refuse an unregistered managed wrapper" >&2
    return 1
  fi
  cmp -s "$OPENVPN_WRAPPER" "$openvpn"
}

test_diversion_remove_refuses_unregistered_managed_wrapper

test_diversion_remove_refuses_unregistered_real_artifact() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  printf 'stale diverted executable\n' > "$real"
  chmod +x "$openvpn" "$real"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER" \
      >/dev/null 2>&1; then
    echo "Remove must refuse an unregistered real artifact" >&2
    return 1
  fi
  grep -qxF 'stale diverted executable' "$real"
}

test_diversion_remove_refuses_unregistered_real_artifact

test_diversion_remove_restores_only_owned_state() {
  local tmp openvpn real fake_dpkg
  tmp="$(mktemp -d)"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  fake_dpkg="$tmp/dpkg-divert"
  trap 'rm -rf "$tmp"' RETURN
  printf '#!/bin/sh\nexit 0\n' > "$openvpn"
  chmod +x "$openvpn"
  : > "$tmp/divert.state"
  : > "$tmp/divert.log"
  make_fake_dpkg_divert "$fake_dpkg"

  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
    DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER"
  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
    DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER"
  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
    DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER"

  test -x "$openvpn"
  test ! -e "$real"
  test ! -s "$tmp/divert.state"
  test "$(grep -c -- '--remove' "$tmp/divert.log")" -eq 1

  printf 'foreign-wrapper\n' > "$openvpn"
  printf '#!/bin/sh\nexit 0\n' > "$real"
  chmod +x "$openvpn" "$real"
  printf 'local diversion of %s to %s\n' "$openvpn" "$real" > "$tmp/divert.state"
  if OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      DPKG_DIVERT="$fake_dpkg" DIVERT_STATE="$tmp/divert.state" \
      DIVERT_LOG="$tmp/divert.log" "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER" >/dev/null 2>&1; then
    echo "Remove must refuse an unrecognized wrapper" >&2
    return 1
  fi
  grep -qxF 'foreign-wrapper' "$openvpn"
  grep -qxF "local diversion of $openvpn to $real" "$tmp/divert.state"
}

test_diversion_remove_restores_only_owned_state

test_real_dpkg_divert_install_remove_isolated() {
  local tmp adm openvpn real
  tmp="$(mktemp -d)"
  adm="$tmp/adm"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  trap 'rm -rf "$tmp"' RETURN
  mkdir "$adm"
  : > "$adm/diversions"
  : > "$adm/diversions-old"
  printf '#!/bin/sh\n# REAL-OPENVPN\nexit 0\n' > "$openvpn"
  chmod 0755 "$openvpn"

  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" DPKG_ADMINDIR="$adm" \
    "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER"
  cmp -s "$OPENVPN_WRAPPER" "$openvpn"
  grep -q 'REAL-OPENVPN' "$real"
  dpkg-divert --admindir "$adm" --list "$openvpn" | \
    grep -qxF "local diversion of $openvpn to $real"

  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" DPKG_ADMINDIR="$adm" \
    "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER"
  grep -q 'REAL-OPENVPN' "$openvpn"
  test ! -e "$real"
  test -z "$(dpkg-divert --admindir "$adm" --list "$openvpn")"
}

test_real_dpkg_divert_install_remove_isolated

test_real_dpkg_divert_add_rename_failure_restores_registration() {
  local tmp adm bindir openvpn real lock_dir output
  tmp="$(mktemp -d)"
  adm="$tmp/adm"
  bindir="$tmp/bin"
  openvpn="$bindir/openvpn"
  real="$bindir/openvpn.real"
  lock_dir="$tmp/secure-lock"
  trap 'chmod 0700 "$bindir" 2>/dev/null || true; rm -rf "$tmp"' RETURN
  mkdir "$adm" "$bindir"
  : > "$adm/diversions"
  : > "$adm/diversions-old"
  printf '#!/bin/sh\n# REAL-OPENVPN\nexit 0\n' > "$openvpn"
  chmod 0755 "$openvpn"
  chmod 0555 "$bindir"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      OPENVPN_DIVERSION_LOCK_DIR="$lock_dir" DPKG_ADMINDIR="$adm" \
      "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER" 2>&1)"; then
    echo "Install must report the forced dpkg-divert rename failure" >&2
    return 1
  fi
  grep -q 'REAL-OPENVPN' "$openvpn"
  test ! -e "$real"
  test -z "$(dpkg-divert --admindir "$adm" --list "$openvpn")"
  grep -q 'state was restored' <<<"$output"
}

test_real_dpkg_divert_add_rename_failure_restores_registration

test_real_dpkg_divert_post_rename_database_failure_preserves_real() {
  local tmp adm openvpn real lock_dir output artifact
  tmp="$(mktemp -d)"
  adm="$tmp/adm"
  openvpn="$tmp/openvpn"
  real="$tmp/openvpn.real"
  lock_dir="$tmp/secure-lock"
  trap 'chmod 0700 "$adm" 2>/dev/null || true; rm -rf "$tmp"' RETURN
  mkdir "$adm"
  : > "$adm/diversions"
  : > "$adm/diversions-old"
  printf '#!/bin/sh\n# REAL-OPENVPN\nexit 0\n' > "$openvpn"
  chmod 0755 "$openvpn"

  OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
    OPENVPN_DIVERSION_LOCK_DIR="$lock_dir" DPKG_ADMINDIR="$adm" \
    "$OPENVPN_DIVERSION" install "$OPENVPN_WRAPPER"
  chmod 0500 "$adm"

  if output="$(OPENVPN_PATH="$openvpn" OPENVPN_REAL_PATH="$real" \
      OPENVPN_DIVERSION_LOCK_DIR="$lock_dir" DPKG_ADMINDIR="$adm" \
      "$OPENVPN_DIVERSION" remove "$OPENVPN_WRAPPER" 2>&1)"; then
    echo "Removal must report an isolated dpkg database write failure" >&2
    return 1
  fi
  grep -q 'REAL-OPENVPN' "$openvpn"
  test ! -e "$real"
  artifact="$(find "$lock_dir" -maxdepth 1 -type f -name 'openvpn-wrapper.recovery.*' -print -quit)"
  test -n "$artifact"
  cmp -s "$OPENVPN_WRAPPER" "$artifact"
  grep -qF "$artifact" <<<"$output"
  grep -q 'retained recovery wrapper' <<<"$output"
}

test_real_dpkg_divert_post_rename_database_failure_preserves_real

test_setup_preflights_and_installs_diversion_before_other_mutations() {
  local check_line install_line credentials_line apt_line
  check_line="$(grep -n 'openvpn-diversion.sh.* check ' "$SETUP" | cut -d: -f1)"
  install_line="$(grep -n 'openvpn-diversion.sh.* install ' "$SETUP" | cut -d: -f1)"
  credentials_line="$(grep -n '^configure_hotspot_credentials$' "$SETUP" | cut -d: -f1)"
  apt_line="$(grep -n '^sudo apt update$' "$SETUP" | cut -d: -f1)"
  test -n "$check_line"
  test -n "$install_line"
  test "$check_line" -lt "$install_line"
  test "$install_line" -lt "$credentials_line"
  test "$install_line" -lt "$apt_line"
}

test_setup_preflights_and_installs_diversion_before_other_mutations

test_replay_wrapper_forwards_arguments_exactly() {
  local tmp fake_real wrapper_copy
  tmp="$(mktemp -d)"
  fake_real="$tmp/openvpn.real"
  wrapper_copy="$tmp/openvpn"
  trap 'rm -rf "$tmp"' RETURN
  cat > "$fake_real" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARG_LOG"
EOF
  sed "s#/usr/sbin/openvpn.real#$fake_real#" "$OPENVPN_WRAPPER" > "$wrapper_copy"
  chmod +x "$fake_real" "$wrapper_copy"

  ARG_LOG="$tmp/args" \
    "$wrapper_copy" 'two words' '*' '--config=/tmp/a b.conf'
  printf '%s\n' 'two words' '*' '--config=/tmp/a b.conf' --replay-window 8192 60 \
    > "$tmp/expected"
  cmp -s "$tmp/expected" "$tmp/args"

  ARG_LOG="$tmp/args" "$wrapper_copy" '/tmp/positional config.conf'
  printf '%s\n' --config '/tmp/positional config.conf' --replay-window 8192 60 \
    > "$tmp/expected"
  cmp -s "$tmp/expected" "$tmp/args"
}

test_replay_wrapper_forwards_arguments_exactly

test_replay_wrapper_option_wins_real_parser() {
  local tmp parser wrapper_copy output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  if [ -x /usr/sbin/openvpn.real ]; then
    parser=/usr/sbin/openvpn.real
  elif command -v openvpn >/dev/null 2>&1; then
    parser="$(command -v openvpn)"
  else
    echo "OpenVPN parser is required for replay-wrapper tests" >&2
    return 1
  fi
  wrapper_copy="$tmp/openvpn"
  sed "s#/usr/sbin/openvpn.real#$parser#" "$OPENVPN_WRAPPER" > "$wrapper_copy"
  chmod +x "$wrapper_copy"
  printf 'dev null\nreplay-window 64 15\n' > "$tmp/client.conf"

  output="$(timeout 2 "$wrapper_copy" --config "$tmp/client.conf" --verb 4 2>&1 || true)"
  grep -q 'replay_window = 8192' <<<"$output"
  grep -q 'replay_time = 60' <<<"$output"
}

test_replay_wrapper_option_wins_real_parser

test -x "$OPENVPN_WRAPPER"
test -x "$OPENVPN_DIVERSION"
grep -q 'scripts/openvpn-replay-wrapper scripts/openvpn-diversion.sh' "$QUALITY_WORKFLOW"
grep -q 'util-linux' "$SETUP"
grep -q 'exec /usr/sbin/openvpn.real "$@" --replay-window 8192 60' "$OPENVPN_WRAPPER"
# These are literal source-code patterns, not shell expressions.
# shellcheck disable=SC2016
grep -q 'sudo "$SCRIPT_DIR/openvpn-diversion.sh" install "$SCRIPT_DIR/openvpn-replay-wrapper"' "$SETUP"
# shellcheck disable=SC2016
grep -q 'sudo "$PROJECT_DIR/scripts/openvpn-diversion.sh" remove "$PROJECT_DIR/scripts/openvpn-replay-wrapper"' "$UNINSTALL"
test "$(grep -n 'openvpn-diversion.sh.* remove ' "$UNINSTALL" | cut -d: -f1)" \
  -lt "$(grep -n 'systemctl stop hostapd' "$UNINSTALL" | cut -d: -f1)"
if grep -q 'nmcli connection modify pi' "$SETUP"; then
  echo "Setup must not mutate the NetworkManager VPN profile" >&2
  exit 1
fi
if grep -q 'dpkg-divert .*\(/usr/sbin/openvpn\|OPENVPN\)' "$SETUP" "$UNINSTALL"; then
  echo "Setup and uninstall must delegate diversion lifecycle validation" >&2
  exit 1
fi
grep -q 'flock -w 60 9' "$POLICY"
# These are literal source-code patterns, not shell expressions.
# shellcheck disable=SC2016
grep -q 'VPN_MTU="${VPN_MTU:-1400}"' "$POLICY"
# shellcheck disable=SC2016
grep -q 'ip link set dev "$VPN_IF" mtu "$VPN_MTU"' "$POLICY"
if grep -q 'sleep 5; apply_policy\|sleep 15; apply_policy' "$POLICY"; then
  echo "Policy must not schedule overlapping delayed applies" >&2
  exit 1
fi
# This is a literal source-code pattern, not a shell expression.
# shellcheck disable=SC2016
if grep -q '"\$POLICY_SCRIPT" "\$VPN_IF" up' "$ROUTES"; then
  echo "GitHub refresh must not reapply the VPN policy" >&2
  exit 1
fi
grep -q -- '--retry 3' "$ROUTES"
grep -q -- '--max-time 60' "$ROUTES"
grep -q 'GITHUB_ROUTES_FORCE_REFRESH' "$ROUTES"
grep -q 'Keeping existing GitHub IPv4 ranges' "$ROUTES"

echo "PASS: VPN policy, diversion lifecycle, and route refresh checks"
