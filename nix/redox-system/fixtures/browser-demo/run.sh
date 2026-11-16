#!/nix/system/profile/bin/bash
set -eEuo pipefail
source /etc/browser-demo/common.sh
current=initial-state
fail() {
    local status=$?
    trap - ERR
    printf 'FUNC_TEST:%s:FAIL:exit-%s\n' "$current" "$status"
    printf '%s\n' 'FUNC_TESTS_COMPLETE'
    exit "$status"
}
trap fail ERR
pass() { printf 'FUNC_TEST:%s:PASS\n' "$current"; }

fresh_build() {
    local input=$1 expression path actual
    expression=$(build_expression "$input")
    path=$(output_path "$input")
    test ! -e "$path"
    "$SNIX" build --expr "$expression"
    test -f "$path"
    actual=$(< "$path")
    test "$actual" = "$input"
    # Verify bytes including the final newline, not only command substitution.
    test "$(wc -c < "$path")" -eq "$((${#input} + 1))"
    printf 'REDOX_BROWSER_DEMO_BUILD:%s:%s\n' "$input" "$path"
}

case "${1:-all}" in
    build)
        # Interactive, user-selected declared-input build. Repeated input is
        # deliberately rejected here: this command promises a *fresh* build.
        fresh_build "${2:?usage: run.sh build alphanumeric-input}"
        exit 0
        ;;
    all) ;;
    *) printf '%s\n' 'usage: run.sh [all | build alphanumeric-input]' >&2; exit 2;;
esac

printf '%s\n' 'FUNC_TESTS_START'
/nix/system/profile/bin/bash "$FIXTURES/ready.sh" --check-only
pass
mkdir -p /var/lib/browser-demo
RESULTS=/var/lib/browser-demo
cp "$MANIFEST" "$RESULTS/initial-manifest.json"

current=offline-eval
test "$("$SNIX" eval --raw --expr 'builtins.concatStringsSep "-" [ "offline" "snix" "42" ]')" = offline-snix-42
pass

current=cache-package-absent
profile_absent
"$SNIX" search ripgrep --cache-path /nix/cache
"$SNIX" show ripgrep --cache-path /nix/cache
nix_assert 'builtins.hasAttr "ripgrep" (builtins.fromJSON (builtins.readFile /nix/cache/packages.json)).packages'
pass

current=offline-install-execute
"$SNIX" install ripgrep --recursive --cache-path /nix/cache
nix_assert 'builtins.hasAttr "ripgrep" (builtins.fromJSON (builtins.readFile /nix/var/snix/profiles/default/manifest.json)).packages'
# Explicit user-profile path: a system or store executable cannot fake success.
"$PROFILE/bin/rg" --version
"$PROFILE/bin/rg" --fixed-strings --line-regexp REDOX_BROWSER_RIPGREP_SAMPLE "$FIXTURES/sample.txt" > "$RESULTS/rg-output"
test "$(< "$RESULTS/rg-output")" = REDOX_BROWSER_RIPGREP_SAMPLE
"$SNIX" profile list
pass

current=offline-remove
"$SNIX" remove ripgrep
profile_absent
"$SNIX" profile list
pass

current=fresh-build-first
fresh_build first
first_path=$(output_path first)
pass
current=fresh-build-second
fresh_build second
second_path=$(output_path second)
test "$first_path" != "$second_path"
pass

current=local-rebuild
cp "$FIXTURES/after.nix" /etc/redox-system/configuration.nix
"$SNIX" system rebuild --local > "$RESULTS/rebuild.log" 2>&1
cat "$RESULTS/rebuild.log"
test "$(< /etc/hostname)" = browser-demo-changed
nix_assert 'let m = builtins.fromJSON (builtins.readFile /etc/redox-system/manifest.json);
  old = builtins.fromJSON (builtins.readFile /var/lib/browser-demo/initial-manifest.json);
  in m.generation.id == 2 && m.system.hostname == "browser-demo-changed" &&
    m.packages == old.packages && !m.configuration.networking.enabled'
cp "$MANIFEST" "$RESULTS/rebuilt-manifest.json"
pass

current=generation-state
"$SNIX" system generations > "$RESULTS/generations-before-rollback.txt"
cat "$RESULTS/generations-before-rollback.txt"
generation_listing "$RESULTS/generations-before-rollback.txt" 2 1 2
nix_assert 'let read = p: builtins.fromJSON (builtins.readFile p);
  a = read /etc/redox-system/generations/1/manifest.json;
  b = read /etc/redox-system/generations/2/manifest.json;
  in a.generation.id == 1 && a.system.hostname == "browser-demo" &&
    b.generation.id == 2 && b.system.hostname == "browser-demo-changed"'
pass

current=actual-rollback
# Exercise the rollback command, not switch-generation or another rebuild.
"$SNIX" system rollback --generation 1 > "$RESULTS/rollback.log" 2>&1
cat "$RESULTS/rollback.log"
test "$(< /etc/hostname)" = browser-demo
nix_assert 'let read = p: builtins.fromJSON (builtins.readFile p);
  m = read /etc/redox-system/manifest.json;
  saved = read /etc/redox-system/generations/3/manifest.json;
  old = read /var/lib/browser-demo/initial-manifest.json;
  in m.generation.id == 3 &&
    m.system == old.system && m.configuration == old.configuration &&
    m.packages == old.packages && saved == m'
"$SNIX" system generations > "$RESULTS/generations-after-rollback.txt"
cat "$RESULTS/generations-after-rollback.txt"
generation_listing "$RESULTS/generations-after-rollback.txt" 3 1 2 3
cp "$MANIFEST" "$RESULTS/rolled-back-manifest.json"
pass

current=final-package-state
profile_absent
# Activation can change the source coordinates under /etc; verify the outputs
# actually built before switching generations, not a newly evaluated derivation.
test "$(< "$first_path")" = first
test "$(< "$second_path")" = second
pass
printf '%s\n' 'FUNC_TESTS_COMPLETE'
