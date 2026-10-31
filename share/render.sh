#!/usr/bin/env bash
# Renders a Litmus document to HTML that opens from file://, with no network.
#   render.sh DOCUMENT [ASCIIDOCTOR OPTION...]
# The pages go to build/ beside the document, with the widget kit and the libraries they
# use in build/assets/. Installed by `litmus setup` into the home of Litmus ($LITMUS_HOME, or
# ~/.litmus). The first run installs Asciidoctor and Rouge into cache/gems and downloads the
# libraries into cache/vendor, each checked against its SHA-256; later runs use the cache.
set -euo pipefail

home="${LITMUS_HOME:-$HOME/.litmus}"
doc="${1:?usage: render.sh DOCUMENT [ASCIIDOCTOR OPTION...]}"
shift
[ -f "$doc" ] || { echo "render.sh: $doc: no such document" >&2; exit 1; }
docdir="$(cd "$(dirname "$doc")" && pwd)"
out="$docdir/build"
cache="$home/cache"
mkdir -p "$cache/vendor" "$out/assets/kit" "$out/assets/vendor"

# The libraries, pinned: name, URL, SHA-256. Each is a classic script, so pages run from file://.
vendor=(
  "mermaid.min.js https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js 581ed7d74bd9048d0e3a91363927d72ef22942d7722546b27f7cc29e35390eb8"
  "dagre.min.js https://cdn.jsdelivr.net/npm/@dagrejs/dagre@3.1.1/dist/dagre.min.js 3152d214941a5df3a3d4c079dfa338c3cd7a6c0d4c1b4c3a2fdb6bba6f6facf9"
  "konva.min.js https://cdn.jsdelivr.net/npm/konva@10.7.1/konva.min.js 46bea57e1c6009ac237745df395498cd6dbc0a4d164584c1fcbff6471335be5c"
  "three.min.js https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js f34446bf875b5fb0dcd93819ffe1d9e182d46634ee855f5d904c6c4ac7cdbc95"
  "OrbitControls.js https://cdn.jsdelivr.net/npm/three@0.147.0/examples/js/controls/OrbitControls.js b4c6e53f98538535b11fd6655627d47fb5877b3ad972568bff0a7026c4b6d5c4"
)

sha256() { if command -v shasum > /dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -c1-64; }

for entry in "${vendor[@]}"; do
  read -r name url sum <<< "$entry"
  file="$cache/vendor/$name"
  [ -f "$file" ] && [ "$(sha256 "$file")" = "$sum" ] && continue
  echo "render.sh: downloading $name (once)" >&2
  curl -fsSL -o "$file.part" "$url" || { rm -f "$file.part"; echo "render.sh: could not download $url" >&2; exit 1; }
  if [ "$(sha256 "$file.part")" != "$sum" ]; then
    rm -f "$file.part"
    echo "render.sh: $name does not have the pinned SHA-256; nothing was used" >&2
    exit 1
  fi
  mv "$file.part" "$file"
done

# Asciidoctor and Rouge, in the cache. Ruby's own gems stay visible: since Ruby 4, libraries
# such as logger are gems.
command -v gem > /dev/null || { echo "render.sh: needs Ruby (gem) to render" >&2; exit 1; }
ruby_gems="$(env -u GEM_HOME -u GEM_PATH gem env gempath)"
export GEM_HOME="$cache/gems"
export GEM_PATH="$GEM_HOME:$ruby_gems"
export PATH="$GEM_HOME/bin:$PATH"
for g in asciidoctor rouge; do
  if ! gem list -i "^$g\$" > /dev/null; then
    echo "render.sh: installing $g into $GEM_HOME (once)" >&2
    gem install --no-document --silent "$g" > /dev/null
  fi
done

# Render. Problems go to a log; only the first few are shown.
log="$out/render.log"
if ! asciidoctor --failure-level WARN -r "$home/weave/litmus-weave.rb" -a litmus-assets=assets \
    -a source-highlighter=rouge -D "$out" "$@" "$doc" > "$log" 2>&1; then
  echo "render.sh: asciidoctor failed; the first lines of $log:" >&2
  head -n 5 "$log" >&2
  exit 1
fi

# The kit, the libraries the pages name, and the document's own pictures.
cp "$home"/kit/*.js "$out/assets/kit/"
for entry in "${vendor[@]}"; do
  read -r name _ _ <<< "$entry"
  if grep -l -F "assets/vendor/$name" "$out"/*.html > /dev/null 2>&1; then cp "$cache/vendor/$name" "$out/assets/vendor/"; fi
done
for extra in visuals images; do
  [ -d "$docdir/$extra" ] && rm -rf "$out/$extra" && cp -R "$docdir/$extra" "$out/$extra"
done

stem="$(basename "${doc%.*}")"
for page in "$out/$stem".html "$out/$stem"-*.html; do
  [ -f "$page" ] && echo "wrote $page"
done
true
