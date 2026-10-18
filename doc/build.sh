#!/usr/bin/env bash
# Renders the asciidoc documents to doc/build/.
# Asciidoctor and Rouge are installed into tools/gems on first run (needs Ruby).
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

export GEM_HOME="$ROOT/tools/gems"
export GEM_PATH="$GEM_HOME"
export PATH="$GEM_HOME/bin:$PATH"

for g in asciidoctor rouge; do
  if ! gem list -i "^$g\$" >/dev/null; then
    echo "Installing $g into tools/gems ..."
    gem install --no-document "$g"
  fi
done

# Pictures and animations that the documents use, from passthrough blocks.
mkdir -p build && rm -rf build/visuals && cp -R visuals build/visuals

for f in litmus.adoc implementation.adoc; do
  [ -f "$f" ] && asciidoctor --failure-level WARN -r ./litmus-weave.rb -D build "$f" && echo "Wrote doc/build/${f%.adoc}.html"
done
true
