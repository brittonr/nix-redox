#!/nix/system/profile/bin/bash
# Shared assertions: no package installs, network fetches or state repair here.
export PATH=/nix/var/snix/profiles/default/bin:/nix/system/profile/bin:/bin:/usr/bin
export HOME=/root
FIXTURES=/etc/browser-demo
SNIX=/bin/snix
MANIFEST=/etc/redox-system/manifest.json
PROFILE=/nix/var/snix/profiles/default

nix_assert() {
    local actual
    actual=$("$SNIX" eval --raw --expr "if ($1) then \"ok\" else throw \"browser-demo assertion failed\"")
    test "$actual" = ok
}

profile_absent() {
    test ! -e "$PROFILE/bin/rg"
    test ! -L "$PROFILE/bin/rg"
    if test -f "$PROFILE/manifest.json"; then
        nix_assert "!(builtins.hasAttr \"ripgrep\" (builtins.fromJSON (builtins.readFile $PROFILE/manifest.json)).packages)"
    fi
    if command -v rg >/dev/null 2>&1; then
        printf '%s\n' 'Unexpected preinstalled rg on PATH' >&2
        return 1
    fi
}

build_expression() {
    # Restrict the shell-facing input alphabet so constructing a Nix string is
    # unambiguous. The derivation itself accepts ordinary Nix string inputs.
    case "$1" in ''|*[!a-zA-Z0-9_-]*) return 2;; esac
    printf '(import /etc/browser-demo/build.nix) { input = "%s"; }' "$1"
}

output_path() {
    local expression
    expression=$(build_expression "$1")
    "$SNIX" eval --raw --expr "($expression).outPath"
}

initial_state() {
    test "$(< /etc/hostname)" = browser-demo
    test ! -e /var/lib/browser-demo
    test ! -e /etc/redox-system/generations/2
    profile_absent
    nix_assert 'let m = builtins.fromJSON (builtins.readFile /etc/redox-system/manifest.json); in
      m.generation.id == 1 && m.system.hostname == "browser-demo" &&
      m.system.target == "x86_64-unknown-redox" &&
      !m.configuration.networking.enabled && !m.configuration.graphics.enabled &&
      m.configuration.hardware.networkDrivers == [] &&
      m.configuration.hardware.audioDrivers == [] &&
      !m.configuration.hardware.usbEnabled &&
      builtins.all (p: p.name != "ripgrep") m.packages'
    nix_assert '(import /etc/redox-system/configuration.nix) == (import /etc/browser-demo/before.nix)'
    local first second
    first=$(output_path first)
    second=$(output_path second)
    test "$first" != "$second"
    test ! -e "$first"
    test ! -e "$second"
}

generation_listing() {
    local file=$1 current=$2 expected id rest found
    shift 2
    for expected in "$@"; do
        found=false
        while read -r id rest; do
            if test "$id" = "$expected"; then
                if test "$id" = "$current"; then
                    case "$rest" in \**) ;; *) return 1;; esac
                fi
                found=true
            fi
        done < "$file"
        test "$found" = true || return 1
    done
}
