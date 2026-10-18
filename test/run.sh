#!/usr/bin/env bash
# The golden tests and the self-hosting test of Litmus.
#   test/run.sh cases LITMUS   tangles, checks and queries every case in test/cases
#   test/run.sh self LITMUS    tangles the book, builds Litmus from the result, and tangles again
set -u
mode=${1:?usage: test/run.sh cases|self LITMUS}
litmus=$(cd "$(dirname "${2:?usage: test/run.sh cases|self LITMUS}")" && pwd)/$(basename "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# expect_same NAME ACTUAL EXPECTED: two files or trees must be equal.
expect_same() {
  if ! diff -r -x .DS_Store "$2" "$3" > "$work/diff" 2>&1; then
    fail "$1" "differs from the expected result"
    sed 's/^/    /' "$work/diff" | head -20
  fi
}

# Runs the command of an init case in the sandbox, with Litmus reachable under the
# name the command uses: on the PATH, or at a relative path such as tools/litmus.
run_init() {
  local sandbox=$1 cmd=$2 first=${2%% *}
  rm -rf "$work/bin" && mkdir -p "$work/bin"
  if [[ $first == */* ]]; then
    mkdir -p "$sandbox/$(dirname "$first")"
    ln -s "$litmus" "$sandbox/$first"
  else
    ln -s "$litmus" "$work/bin/$first"
  fi
  (cd "$sandbox" && PATH="$work/bin:$PATH" sh -c "$cmd") > "$work/stdout" 2> "$work/stderr"
  local code=$?
  if [[ $first == */* ]]; then
    rm "$sandbox/$first"
    (cd "$sandbox" && rmdir -p "$(dirname "$first")" 2> /dev/null)
  fi
  return $code
}

# A case with a `cmd` file is an init case. The others are tangle cases.
init_case() {
  local dir=$1 name=$2 sandbox=$work/sandbox cmd
  rm -rf "$sandbox" && mkdir -p "$sandbox"
  [ -d "$dir/before" ] && cp -R "$dir/before/." "$sandbox/"
  cmd=$(cat "$dir/cmd")
  run_init "$sandbox" "$cmd" || fail "$name" "init failed: $(cat "$work/stderr")"
  expect_same "$name (what init prints)" "$work/stdout" "$( [ -f "$dir/expected.out" ] && echo "$dir/expected.out" || echo /dev/null )"
  expect_same "$name (the files)" "$sandbox" "$dir/expected"
  # I4: the second run changes nothing.
  run_init "$sandbox" "$cmd"
  [ -s "$work/stdout" ] && fail "$name" "the second init printed: $(cat "$work/stdout")"
  expect_same "$name (the files after a second run)" "$sandbox" "$dir/expected"
}

tangle_case() {
  local dir=$1 name=$2 out=$work/out args expected want_exit=0 code
  rm -rf "$out" && mkdir -p "$out"
  [ -d "$dir/before" ] && cp -R "$dir/before/." "$out/"
  [ -f "$dir/exit" ] && want_exit=$(cat "$dir/exit")
  args=$(cat "$dir/args")
  # 1. Tangle, and compare the files, the map and what is said.
  (cd "$dir" && "$litmus" tangle -o "$out" $args) > "$work/stdout" 2> "$work/stderr"
  code=$?
  [ "$code" -eq "$want_exit" ] || fail "$name" "tangle exited $code, not $want_exit"
  expected=$dir/expected
  if [ ! -d "$expected" ]; then
    mkdir -p "$work/empty" && expected=$work/empty
  fi
  expect_same "$name (the files)" "$out" "$expected"
  expect_same "$name (what tangle says)" "$work/stderr" "$( [ -f "$dir/expected.err" ] && echo "$dir/expected.err" || echo /dev/null )"
  [ "$want_exit" -eq 0 ] || return
  # T4: the second tangle writes nothing.
  (cd "$dir" && "$litmus" tangle -o "$out" $args) > "$work/stdout" 2> /dev/null
  [ -s "$work/stdout" ] && fail "$name" "the second tangle wrote: $(cat "$work/stdout")"

  # 2. Check the result.
  local documents=${args//--force/}
  (cd "$dir" && "$litmus" check -o "$out" $documents) > /dev/null 2> "$work/stderr" || fail "$name" "check failed: $(cat "$work/stderr")"

  # 3. Change the first byte of the first file that has any, and check must say where.
  local file origin
  file=$(awk -F'\t' '$1 == "file" { file = $2 } $1 != "file" && file != "" && !seen && FILENAME != "" { print file; seen = 1 }' "$out/.litmus/map")
  if [ -n "$file" ]; then
    origin=$(awk -F'\t' -v want="$file" '$1 == "file" { on = ($2 == want); next } on && !done { print $3 ":" $4; done = 1 }' "$out/.litmus/map")
    printf 'X' | dd of="$out/$file" bs=1 count=1 conv=notrunc 2> /dev/null
    (cd "$dir" && "$litmus" check -o "$out" $documents) > /dev/null 2> "$work/stderr"
    [ $? -eq 1 ] || fail "$name" "check passed on a changed file"
    grep -q -F "$origin" "$work/stderr" || fail "$name" "check did not name $origin: $(cat "$work/stderr")"
  fi

  # 4. Where: the first and last line of every run.
  local file_name=""
  while IFS=$'\t' read -r first second third fourth fifth sixth; do
    [ "$first" = "litmus map 1" ] && continue
    if [ "$first" = file ]; then
      file_name=$second
      continue
    fi
    local excerpt=$sixth
    [ "$excerpt" = ":file:" ] && excerpt="file root"
    local last=$((first + second - 1)) doc_last=$((fourth + second - 1))
    [ "$("$litmus" where -o "$out" "$file_name:$first")" = "$third:$fourth ($excerpt)" ] || fail "$name" "where $file_name:$first"
    [ "$("$litmus" where -o "$out" "$file_name:$last")" = "$third:$doc_last ($excerpt)" ] || fail "$name" "where $file_name:$last"
  done < "$out/.litmus/map"
}

cases() {
  local dir name count=0
  for dir in "$root"/test/cases/*/; do
    dir=${dir%/}
    name=$(basename "$dir")
    count=$((count + 1))
    if [ -f "$dir/cmd" ]; then init_case "$dir" "$name"; else tangle_case "$dir" "$name"; fi
  done
  echo "cases: $count run"
  speed
}

# Tangling 100,000 lines of code is timed, and the time is reported.
speed() {
  local big=$work/big
  mkdir -p "$big"
  awk 'BEGIN {
    print "… :file: big.txt\n----"
    for (i = 1; i <= 1000; i++) print "… part " i
    print "----\n"
    for (i = 1; i <= 1000; i++) {
      print "… part " i " :file: big.txt\n----"
      for (j = 1; j <= 100; j++) print "    line " j " of part " i
      print "----\n"
    }
  }' > "$big/big.adoc"
  local start end
  start=$(date +%s)
  (cd "$big" && "$litmus" tangle -o out big.adoc) > /dev/null
  end=$(date +%s)
  local lines
  lines=$(wc -l < "$big/out/big.txt")
  echo "speed: tangled $lines lines in about $((end - start)) s (whole seconds)"
  TIMEFORMAT='speed: %R s of wall time for the same tangle, second run'
  time (cd "$big" && "$litmus" tangle -o out2 big.adoc) > /dev/null
}

# The fixed point: the book tangles to the repository, a Litmus built from that tangles it again.
self() {
  local book=doc/implementation.adoc one=$work/one two=$work/two
  (cd "$root" && "$litmus" tangle -o "$one" "$book") || fail self "the book does not tangle"
  compare_with_repo self-one "$one"
  (cd "$one" && "$root/tools/zig/zig" build test && "$root/tools/zig/zig" build) || fail self "the tangled sources do not build and pass their tests"
  (cd "$root" && "$one/zig-out/bin/litmus" tangle -o "$two" "$book") || fail self "the second Litmus does not tangle the book"
  compare_with_repo self-two "$two"
  expect_same "self (the two tangles)" "$one/.litmus" "$two/.litmus"
}

# Every file in the map of the tangle at $2 must equal the repository's file.
compare_with_repo() {
  local path
  while IFS=$'\t' read -r first path _; do
    [ "$first" = file ] || continue
    cmp -s "$2/$path" "$root/$path" || fail "$1" "$path differs from the repository"
  done < "$2/.litmus/map"
}

case $mode in
  cases) cases ;;
  self) self ;;
  *) echo "usage: test/run.sh cases|self LITMUS"; exit 2 ;;
esac
if [ "$failures" -gt 0 ]; then
  echo "$failures failures"
  exit 1
fi
echo "$mode: ok"
