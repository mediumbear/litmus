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

# A case with an `edit` directory is an untangle case. The documents are tangled into the
# output, or the output starts as `before`. Then the files of `edit` are copied over the
# output, those named in `remove` are removed, and untangle has to give the documents
# in `expected`. Options for untangle go in `options`.
untangle_case() {
  local dir=$1 name=$2 sandbox=$work/sandbox out=$work/out args options="" want_exit=0 code path
  rm -rf "$sandbox" "$out" && mkdir -p "$sandbox" "$out"
  cp -R "$dir/." "$sandbox/"
  (cd "$sandbox" && rm -rf edit expected before remove expected.out expected.err args exit options)
  [ -f "$dir/exit" ] && want_exit=$(cat "$dir/exit")
  [ -f "$dir/options" ] && options=$(cat "$dir/options")
  args=$(cat "$dir/args")
  if [ -d "$dir/before" ]; then
    cp -R "$dir/before/." "$out/"
  else
    (cd "$sandbox" && "$litmus" tangle -o "$out" $args) > /dev/null 2>&1 || fail "$name" "the documents do not tangle"
  fi
  cp -R "$dir/edit/." "$out/"
  [ -f "$dir/remove" ] && while read -r path; do rm -f "$out/$path"; done < "$dir/remove"
  (cd "$sandbox" && "$litmus" untangle -o "$out" $options $args) > "$work/stdout" 2> "$work/stderr"
  code=$?
  [ "$code" -eq "$want_exit" ] || fail "$name" "untangle exited $code, not $want_exit"
  expect_same "$name (the documents)" "$sandbox" "$dir/expected"
  expect_same "$name (what untangle prints)" "$work/stdout" "$( [ -f "$dir/expected.out" ] && echo "$dir/expected.out" || echo /dev/null )"
  expect_same "$name (what untangle says)" "$work/stderr" "$( [ -f "$dir/expected.err" ] && echo "$dir/expected.err" || echo /dev/null )"
  [ "$want_exit" -eq 0 ] || return
  # The documents tangle to the files, and a second untangle has nothing to do. A file that
  # was removed stays missing.
  [ -f "$dir/remove" ] || (cd "$sandbox" && "$litmus" check -o "$out" $args) > /dev/null 2> "$work/stderr" || fail "$name" "check failed after untangle: $(cat "$work/stderr")"
  (cd "$sandbox" && "$litmus" untangle -o "$out" $options $args) > "$work/stdout" 2> /dev/null
  [ "$(head -n 1 "$work/stdout")" = "nothing to untangle" ] || fail "$name" "the second untangle said: $(cat "$work/stdout")"
}

# A case with a `cmd` file runs that command: init, adopt, or a few commands in a row.
# The others are tangle cases.
init_case() {
  local dir=$1 name=$2 sandbox=$work/sandbox cmd
  rm -rf "$sandbox" && mkdir -p "$sandbox"
  [ -d "$dir/before" ] && cp -R "$dir/before/." "$sandbox/"
  cmd=$(cat "$dir/cmd")
  run_init "$sandbox" "$cmd" || fail "$name" "init failed: $(cat "$work/stderr")"
  expect_same "$name (what init prints)" "$work/stdout" "$( [ -f "$dir/expected.out" ] && echo "$dir/expected.out" || echo /dev/null )"
  expect_same "$name (the files)" "$sandbox" "$dir/expected"
  # I4: a second init changes nothing. Other commands run once.
  case " $cmd " in
    *" init "*) ;;
    *) return ;;
  esac
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
    if [ -f "$dir/cmd" ]; then
      init_case "$dir" "$name"
    elif [ -d "$dir/edit" ]; then
      untangle_case "$dir" "$name"
    else
      tangle_case "$dir" "$name"
    fi
  done
  echo "cases: $count run"
  watch_tests
  speed
}

# Waits until the log has at least $3 lines that contain $2, or fails after ten seconds.
wait_for() {
  local log=$1 pattern=$2 want=${3:-1} i
  for i in $(seq 1 200); do
    [ "$(grep -c -F -e "$pattern" "$log")" -ge "$want" ] && return 0
    sleep 0.05
  done
  return 1
}

# Watch is started in a sandbox with a short interval, the files and documents are changed as
# a writer would change them, and each time the log has to say what happened (W1 to W5).
watch_tests() {
  local sandbox=$work/watch log=$work/watch.log pid
  rm -rf "$sandbox" && mkdir -p "$sandbox"
  printf '%s\n' '… :file: a.txt' '----' 'one' '… more' '----' '' '… more :file: a.txt' '----' 'two' '----' > "$sandbox/w.adoc"
  (cd "$sandbox" && "$litmus" watch --interval 50 w.adoc > "$log" 2>&1) &
  pid=$!

  # W1: sync runs at the start, and tangles.
  wait_for "$log" "wrote a.txt" 1 || fail watch "no tangle at the start: $(cat "$log")"
  [ "$(cat "$sandbox/a.txt")" = "$(printf 'one\ntwo')" ] || fail watch "a.txt is wrong at the start"

  # W4, W1: nothing is printed while nothing changes, and the files that watch wrote are not changes.
  local before
  before=$(wc -l < "$log")
  sleep 0.6
  [ "$(wc -l < "$log")" -eq "$before" ] || fail watch "watch printed while nothing changed: $(cat "$log")"

  # W1, W3: a tangled file is saved, and watch untangles.
  printf 'one\nTWO\n' > "$sandbox/a.txt"
  wait_for "$log" "changed: a.txt" 1 || fail watch "no run after a.txt changed: $(cat "$log")"
  wait_for "$log" "the files changed: untangling" 1 || fail watch "no untangle: $(cat "$log")"
  grep -q '^TWO$' "$sandbox/w.adoc" || fail watch "the change did not reach the document"

  # A document is saved, and watch tangles.
  sed 's/^one$/ONE/' "$sandbox/w.adoc" > "$sandbox/w.tmp" && mv "$sandbox/w.tmp" "$sandbox/w.adoc"
  wait_for "$log" "changed: w.adoc" 1 || fail watch "no run after w.adoc changed: $(cat "$log")"
  wait_for "$log" "the documents changed: tangling" 2 || fail watch "no tangle: $(cat "$log")"
  grep -q '^ONE$' "$sandbox/a.txt" || fail watch "the change did not reach the file"

  # W5: both sides changed in one quiet period. Watch says so, does nothing, and waits.
  local runs
  runs=$(grep -c '^\[' "$log")
  printf 'ONE\nTWO\nfile side\n' > "$sandbox/a.txt"
  sed 's/^ONE$/doc side/' "$sandbox/w.adoc" > "$sandbox/w.tmp" && mv "$sandbox/w.tmp" "$sandbox/w.adoc"
  wait_for "$log" "both sides changed" 1 || fail watch "no stop when both changed: $(cat "$log")"
  sleep 0.5
  [ "$(grep -c '^\[' "$log")" -eq $((runs + 1)) ] || fail watch "watch ran again by itself after it stopped"
  grep -q '^file side$' "$sandbox/a.txt" || fail watch "the file was touched after both sides changed"
  # The writer puts the file back, so only the document differs, and watch tangles.
  printf 'ONE\nTWO\n' > "$sandbox/a.txt"
  wait_for "$log" "the documents changed: tangling" 3 || fail watch "no recovery after the file was put back: $(cat "$log")"

  # W5: a document with an error is reported, and a fix brings watch on.
  cp "$sandbox/w.adoc" "$sandbox/good.adoc"
  printf '… :file: a.txt\n\n' >> "$sandbox/w.adoc"
  wait_for "$log" "C5" 1 || fail watch "no report of the error: $(cat "$log")"
  cp "$sandbox/good.adoc" "$sandbox/w.adoc"
  wait_for "$log" "in sync" 1 || fail watch "no run after the document was fixed: $(cat "$log")"

  # W2: an include added while watching is watched from then on.
  printf '… extra :file: b.txt\n----\nextra text\n----\n' > "$sandbox/more.adoc"
  printf '\n… :file: b.txt\n----\n… extra\n----\n\ninclude::more.adoc[]\n' >> "$sandbox/w.adoc"
  wait_for "$log" "wrote b.txt" 1 || fail watch "the new include was not tangled: $(cat "$log")"
  printf '… extra :file: b.txt\n----\nchanged extra\n----\n' > "$sandbox/more.adoc"
  wait_for "$log" "changed: more.adoc" 1 || fail watch "the included document is not watched: $(cat "$log")"
  [ "$(cat "$sandbox/b.txt")" = "changed extra" ] || fail watch "b.txt is wrong after more.adoc changed"

  kill "$pid" 2> /dev/null
  wait "$pid" 2> /dev/null
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
  # And untangling one changed line of it.
  awk 'NR == 50000 { print "    a changed line"; next } { print }' "$big/out/big.txt" > "$big/out/big.tmp" && mv "$big/out/big.tmp" "$big/out/big.txt"
  TIMEFORMAT='speed: %R s of wall time to untangle one changed line'
  time (cd "$big" && "$litmus" untangle -o out big.adoc) > /dev/null
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
