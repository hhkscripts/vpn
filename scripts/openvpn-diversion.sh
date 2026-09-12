#!/bin/sh
# Safely manage the local OpenVPN replay-window diversion.

set -eu

OPENVPN_PATH="${OPENVPN_PATH:-/usr/sbin/openvpn}"
OPENVPN_REAL_PATH="${OPENVPN_REAL_PATH:-/usr/sbin/openvpn.real}"
DPKG_DIVERT="${DPKG_DIVERT:-dpkg-divert}"
DPKG_ADMINDIR="${DPKG_ADMINDIR:-}"
LOCK_TIMEOUT="${OPENVPN_LOCK_TIMEOUT:-60}"
EXPECTED_DIVERSION="local diversion of $OPENVPN_PATH to $OPENVPN_REAL_PATH"
if [ "$OPENVPN_PATH" = /usr/sbin/openvpn ] && \
   [ "$OPENVPN_REAL_PATH" = /usr/sbin/openvpn.real ]; then
    OWNER_UID=0
    OWNER_GID=0
    LOCK_OWNER_UID=0
    LOCK_OWNER_GID=0
    LOCK_DIR="${OPENVPN_DIVERSION_LOCK_DIR:-/run/goodwifi-openvpn-diversion}"
else
    OWNER_UID="${OPENVPN_OWNER_UID:-$(id -u)}"
    OWNER_GID="${OPENVPN_OWNER_GID:-$(id -g)}"
    LOCK_OWNER_UID="$(id -u)"
    LOCK_OWNER_GID="$(id -g)"
    LOCK_DIR="${OPENVPN_DIVERSION_LOCK_DIR:-${OPENVPN_PATH}.goodwifi-lock}"
fi
LOCK_PATH="${OPENVPN_DIVERSION_LOCK:-$LOCK_DIR/lifecycle.lock}"

fail() {
    echo "OpenVPN diversion: $*" >&2
    exit 1
}

run_dpkg_divert() {
    if [ -n "$DPKG_ADMINDIR" ]; then
        LC_ALL=C "$DPKG_DIVERT" --admindir "$DPKG_ADMINDIR" "$@"
    else
        LC_ALL=C "$DPKG_DIVERT" "$@"
    fi
}

read_diversion_registration() {
    if REGISTRATION="$(run_dpkg_divert --list "$OPENVPN_PATH")"; then
        return 0
    fi
    echo "OpenVPN diversion: could not query diversion registration for $OPENVPN_PATH" >&2
    return 1
}

acquire_lock() {
    if [ -L "$LOCK_DIR" ]; then
        fail "refusing symlink lock directory: $LOCK_DIR"
    fi
    if [ ! -e "$LOCK_DIR" ]; then
        old_umask="$(umask)"
        umask 077
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            umask "$old_umask"
            if [ ! -d "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
                fail "could not securely create lock directory: $LOCK_DIR"
            fi
        else
            umask "$old_umask"
        fi
    fi
    if [ ! -d "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; then
        fail "lock directory is not a real directory: $LOCK_DIR"
    fi
    [ "$(stat -c %u:%g:%a -- "$LOCK_DIR")" = \
      "$LOCK_OWNER_UID:$LOCK_OWNER_GID:700" ] || \
        fail "lock directory must have expected ownership and mode 0700: $LOCK_DIR"
    if [ -L "$LOCK_PATH" ]; then
        fail "refusing symlink lifecycle lock: $LOCK_PATH"
    fi
    exec 9>"$LOCK_PATH"
    flock -w "$LOCK_TIMEOUT" 9 || \
        fail "could not acquire lifecycle lock: $LOCK_PATH"
}

has_expected_owner() {
    [ "$(stat -c %u:%g -- "$1")" = "$OWNER_UID:$OWNER_GID" ]
}

has_safe_write_mode() {
    mode="$(stat -c %a -- "$1")"
    case "$mode" in
        *[!0-7]*|'') return 1 ;;
    esac
    [ $((0$mode & 0022)) -eq 0 ]
}

validate_real_executable() {
    path="$1"
    description="$2"
    if [ ! -f "$path" ] || [ ! -x "$path" ] || [ -L "$path" ]; then
        fail "$description is missing or invalid: $path"
    fi
    has_expected_owner "$path" ||
        fail "$description has unexpected ownership: $path"
    has_safe_write_mode "$path" ||
        fail "$description must not be group/world-writable: $path"
}

is_plausible_real_executable() {
    candidate="$1"
    wrapper="$2"
    [ -f "$candidate" ] && [ -x "$candidate" ] && [ ! -L "$candidate" ] &&
        has_expected_owner "$candidate" && has_safe_write_mode "$candidate" &&
        ! cmp -s "$wrapper" "$candidate"
}

check_diversion() {
    wrapper="$1"
    command -v "$DPKG_DIVERT" >/dev/null 2>&1 ||
        fail "dpkg-divert command is unavailable: $DPKG_DIVERT"
    command -v flock >/dev/null 2>&1 || fail "flock command is unavailable"
    if [ ! -f "$wrapper" ] || [ -L "$wrapper" ]; then
        fail "wrapper is not a regular file: $wrapper"
    fi
    read_diversion_registration || fail "registration query failed"
    if [ -z "$REGISTRATION" ]; then
        if [ -e "$OPENVPN_REAL_PATH" ] || [ -L "$OPENVPN_REAL_PATH" ]; then
            fail "refusing stale unregistered diverted path: $OPENVPN_REAL_PATH"
        fi
        validate_real_executable "$OPENVPN_PATH" "real OpenVPN executable"
        cmp -s "$wrapper" "$OPENVPN_PATH" &&
            fail "refusing to divert the replay wrapper as the real executable"
        return
    fi
    [ "$REGISTRATION" = "$EXPECTED_DIVERSION" ] ||
        fail "refusing conflicting diversion: $REGISTRATION"
    validate_real_executable "$OPENVPN_REAL_PATH" "diverted OpenVPN executable"
    if [ ! -f "$OPENVPN_PATH" ] || [ -L "$OPENVPN_PATH" ] ||
       ! cmp -s "$wrapper" "$OPENVPN_PATH"; then
        fail "pre-existing diversion does not have the managed wrapper: $OPENVPN_PATH"
    fi
    has_expected_owner "$OPENVPN_PATH" ||
        fail "managed wrapper has unexpected ownership: $OPENVPN_PATH"
    has_safe_write_mode "$OPENVPN_PATH" ||
        fail "managed wrapper must not be group/world-writable: $OPENVPN_PATH"
}

rollback_created_diversion() {
    run_dpkg_divert --quiet --remove --rename \
        --divert "$OPENVPN_REAL_PATH" "$OPENVPN_PATH" || return 1
    read_diversion_registration || return 1
    [ -z "$REGISTRATION" ] || return 1
    [ -f "$OPENVPN_PATH" ] && [ -x "$OPENVPN_PATH" ] && \
        [ ! -L "$OPENVPN_PATH" ] || return 1
    has_expected_owner "$OPENVPN_PATH" || return 1
    [ ! -e "$OPENVPN_REAL_PATH" ] && [ ! -L "$OPENVPN_REAL_PATH" ]
}

recover_failed_add() {
    read_diversion_registration || return 1

    if [ -z "$REGISTRATION" ]; then
        [ -f "$OPENVPN_PATH" ] && [ -x "$OPENVPN_PATH" ] && \
            [ ! -L "$OPENVPN_PATH" ] && has_expected_owner "$OPENVPN_PATH" && \
            has_safe_write_mode "$OPENVPN_PATH" && \
            [ ! -e "$OPENVPN_REAL_PATH" ] && [ ! -L "$OPENVPN_REAL_PATH" ]
        return
    fi
    [ "$REGISTRATION" = "$EXPECTED_DIVERSION" ] || return 1

    # dpkg-divert can commit its database before the filesystem rename. If
    # the original is still in place, undo only that database entry.
    if [ -f "$OPENVPN_PATH" ] && [ -x "$OPENVPN_PATH" ] && \
       [ ! -L "$OPENVPN_PATH" ] && has_expected_owner "$OPENVPN_PATH" && \
       has_safe_write_mode "$OPENVPN_PATH" && \
       [ ! -e "$OPENVPN_REAL_PATH" ] && [ ! -L "$OPENVPN_REAL_PATH" ]; then
        run_dpkg_divert --quiet --remove --no-rename \
            --divert "$OPENVPN_REAL_PATH" "$OPENVPN_PATH" || return 1
        read_diversion_registration || return 1
        [ -z "$REGISTRATION" ]
        return
    fi

    # Conversely, a failing caller may still have completed the rename.
    if [ ! -e "$OPENVPN_PATH" ] && [ ! -L "$OPENVPN_PATH" ] && \
       [ -f "$OPENVPN_REAL_PATH" ] && [ -x "$OPENVPN_REAL_PATH" ] && \
       [ ! -L "$OPENVPN_REAL_PATH" ] && has_expected_owner "$OPENVPN_REAL_PATH" && \
       has_safe_write_mode "$OPENVPN_REAL_PATH"; then
        rollback_created_diversion
        return
    fi
    return 1
}

install_diversion() {
    wrapper="$1"
    read_diversion_registration || fail "registration query failed"
    registration="$REGISTRATION"
    created=false

    if [ ! -f "$wrapper" ] || [ -L "$wrapper" ]; then
        fail "wrapper is not a regular file: $wrapper"
    fi

    if [ -z "$registration" ]; then
        if [ -e "$OPENVPN_REAL_PATH" ] || [ -L "$OPENVPN_REAL_PATH" ]; then
            fail "refusing stale unregistered diverted path: $OPENVPN_REAL_PATH"
        fi
        validate_real_executable "$OPENVPN_PATH" "real OpenVPN executable"
        if cmp -s "$wrapper" "$OPENVPN_PATH"; then
            fail "refusing to divert the replay wrapper as the real executable"
        fi
        if ! run_dpkg_divert --quiet --add --rename \
            --divert "$OPENVPN_REAL_PATH" "$OPENVPN_PATH"; then
            recover_failed_add || \
                fail "dpkg-divert add failed and safe state recovery failed"
            fail "dpkg-divert add failed; state was restored"
        fi
        created=true
        read_diversion_registration || fail "registration query failed after add"
        registration="$REGISTRATION"
        if [ "$registration" != "$EXPECTED_DIVERSION" ] || \
           [ ! -f "$OPENVPN_REAL_PATH" ] || [ ! -x "$OPENVPN_REAL_PATH" ] || \
           ! has_expected_owner "$OPENVPN_REAL_PATH"; then
            rollback_created_diversion || \
                fail "diversion validation and rollback both failed"
            fail "diversion did not produce a valid real OpenVPN executable"
        fi
    elif [ "$registration" != "$EXPECTED_DIVERSION" ]; then
        fail "refusing conflicting diversion: $registration"
    fi

    validate_real_executable "$OPENVPN_REAL_PATH" "diverted OpenVPN executable"

    if [ -e "$OPENVPN_PATH" ] || [ -L "$OPENVPN_PATH" ]; then
        if [ ! -f "$OPENVPN_PATH" ] || [ -L "$OPENVPN_PATH" ] || \
           ! cmp -s "$wrapper" "$OPENVPN_PATH"; then
            fail "refusing to overwrite unrecognized file: $OPENVPN_PATH"
        fi
        has_expected_owner "$OPENVPN_PATH" || \
            fail "refusing managed wrapper with unexpected ownership: $OPENVPN_PATH"
        has_safe_write_mode "$OPENVPN_PATH" || \
            fail "managed wrapper must not be group/world-writable: $OPENVPN_PATH"
        return
    fi

    [ "$created" = true ] || \
        fail "refusing pre-existing diversion without an owned wrapper"
    staged_wrapper="${OPENVPN_PATH}.goodwifi-install.$$"
    if [ -e "$staged_wrapper" ] || [ -L "$staged_wrapper" ]; then
        rollback_created_diversion || \
            fail "staging collision and diversion rollback both failed"
        fail "temporary install path already exists: $staged_wrapper"
    fi
    if ! install -o "$OWNER_UID" -g "$OWNER_GID" -m 0755 \
        "$wrapper" "$staged_wrapper" || ! mv "$staged_wrapper" "$OPENVPN_PATH"; then
        rm -f "$staged_wrapper" "$OPENVPN_PATH"
        rollback_created_diversion || \
            fail "wrapper installation and diversion rollback both failed"
        fail "wrapper installation failed; diversion was rolled back"
    fi
}

remove_diversion() {
    wrapper="$1"
    read_diversion_registration || fail "registration query failed"
    registration="$REGISTRATION"

    if [ -z "$registration" ]; then
        if [ -e "$OPENVPN_REAL_PATH" ] || [ -L "$OPENVPN_REAL_PATH" ]; then
            fail "refusing stale unregistered diverted path: $OPENVPN_REAL_PATH"
        fi
        if [ -e "$OPENVPN_PATH" ] && cmp -s "$wrapper" "$OPENVPN_PATH"; then
            fail "refusing stale unregistered managed wrapper: $OPENVPN_PATH"
        fi
        return
    fi
    [ "$registration" = "$EXPECTED_DIVERSION" ] || \
        fail "refusing conflicting diversion: $registration"
    validate_real_executable "$OPENVPN_REAL_PATH" "diverted OpenVPN executable"
    if [ ! -f "$OPENVPN_PATH" ] || [ -L "$OPENVPN_PATH" ] || \
       ! cmp -s "$wrapper" "$OPENVPN_PATH"; then
        fail "refusing to remove unrecognized wrapper: $OPENVPN_PATH"
    fi
    has_expected_owner "$OPENVPN_PATH" || \
        fail "refusing managed wrapper with unexpected ownership: $OPENVPN_PATH"
    has_safe_write_mode "$OPENVPN_PATH" || \
        fail "managed wrapper must not be group/world-writable: $OPENVPN_PATH"

    saved_wrapper="$LOCK_DIR/openvpn-wrapper.recovery.$$"
    if [ -e "$saved_wrapper" ] || [ -L "$saved_wrapper" ]; then
        fail "temporary wrapper path already exists: $saved_wrapper"
    fi
    mv "$OPENVPN_PATH" "$saved_wrapper"
    if ! run_dpkg_divert --quiet --remove --rename \
        --divert "$OPENVPN_REAL_PATH" "$OPENVPN_PATH"; then
        if [ ! -e "$OPENVPN_PATH" ] && [ ! -L "$OPENVPN_PATH" ] && \
           is_plausible_real_executable "$OPENVPN_REAL_PATH" "$wrapper"; then
            mv "$saved_wrapper" "$OPENVPN_PATH"
            fail "could not remove diversion; managed wrapper was restored"
        fi
        fail "could not remove diversion; retained recovery wrapper: $saved_wrapper"
    fi

    if ! read_diversion_registration; then
        fail "registration query failed after removal; retained recovery wrapper: $saved_wrapper"
    fi
    if [ -n "$REGISTRATION" ]; then
        fail "diversion is still registered after removal; retained recovery wrapper: $saved_wrapper"
    fi
    if ! is_plausible_real_executable "$OPENVPN_PATH" "$wrapper"; then
        fail "restored OpenVPN executable is invalid; retained recovery wrapper: $saved_wrapper"
    fi
    rm -f "$saved_wrapper"
}

case "${1:-}" in
    check)
        [ "$#" -eq 2 ] || fail "usage: $0 check WRAPPER"
        acquire_lock
        check_diversion "$2"
        ;;
    install)
        [ "$#" -eq 2 ] || fail "usage: $0 install WRAPPER"
        acquire_lock
        install_diversion "$2"
        ;;
    remove)
        [ "$#" -eq 2 ] || fail "usage: $0 remove WRAPPER"
        acquire_lock
        remove_diversion "$2"
        ;;
    *)
        fail "usage: $0 {check|install|remove} WRAPPER"
        ;;
esac
