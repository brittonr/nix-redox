#!/nix/system/profile/bin/bash
# Check symlinks, their real store contents, and native Snix root registration.
# Only roots owned by this test are touched; no store GC or root pruning runs.
set -eu
stage=$1
silo=/tmp/nixtamal-test/tamal/.silo/input
state=/tmp/nixtamal-test/first-generation-roots
case "$stage" in
    one) expected=nixtamal-archive-one ;;
    two) expected=nixtamal-archive-two ;;
    *) echo "unknown generation stage: $stage" >&2; exit 1 ;;
esac

archive_path=$(/bin/snix eval --raw --expr 'builtins.toString ((import /tmp/nixtamal-test/tamal { bootstrap-pkgs = {}; }).archive)')
git_path=$(/bin/snix eval --raw --expr 'builtins.toString ((import /tmp/nixtamal-test/tamal { bootstrap-pkgs = {}; }).git)')

linked_root() {
    local directory=$1 target=$2 link
    for link in "$directory"/*; do
        if test -L "$link" && test "$link" -ef "$target"; then
            printf '%s\n' "$link"
            return 0
        fi
    done
    echo "no root in $directory protects $target" >&2
    return 1
}

check_root() {
    local root=$1 target=$2 expected_value=$3 actual realized
    case "$target" in
        /nix/store/*) ;;
        *) echo "not a store path: $target" >&2; exit 1 ;;
    esac
    test -L "$root"
    test "$root" -ef "$target"
    test -f "$target/default.nix"
    actual=$(/bin/snix eval --raw --expr "import $root")
    test "$actual" = "$expected_value"
    # Verify NAR metadata and protection by the native indirect-root registry.
    realized=$(nix-store --realize "$target")
    test "$realized" = "$target"
    linked_root /nix/var/snix/gcroots "$target" > /dev/null
}

archive_root=$(linked_root "$silo/archive/milpa" "$archive_path")
git_root=$(linked_root "$silo/git/milpa" "$git_path")
check_root "$archive_root" "$archive_path" "$expected"
check_root "$git_root" "$git_path" nixtamal-git-pinned
test -L "$silo/archive/elotl"
test "$silo/archive/elotl" -ef "$archive_path"
test -L "$silo/git/elotl"
test "$silo/git/elotl" -ef "$git_path"

case "$stage" in
    one)
        printf '%s\n' "$archive_root" "$archive_path" "$git_root" "$git_path" > "$state"
        ;;
    two)
        {
            IFS= read -r first_archive_root
            IFS= read -r first_archive_path
            IFS= read -r first_git_root
            IFS= read -r first_git_path
        } < "$state"
        test "$first_archive_root" != "$archive_root"
        test "$first_archive_path" != "$archive_path"
        test "$first_git_path" = "$git_path"
        check_root "$first_archive_root" "$first_archive_path" nixtamal-archive-one
        check_root "$first_git_root" "$first_git_path" nixtamal-git-pinned
        ;;
esac
echo "validated $stage archive generation and pinned Git GC roots"
