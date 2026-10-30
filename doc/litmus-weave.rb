# A small Asciidoctor extension for reading Litmus documents.
#
# - A document command above a code block (a paragraph like `… name :file: path`)
#   becomes a small, grey label with the file name in bold, and an anchor.
# - An excerpt command inside a labeled block links to the excerpt it stands for.
# - The label links back to the command that uses the excerpt.
# - Characters that Rouge cannot lex are not painted as errors.
# - Mermaid is loaded when a page has a diagram, from `litmus-assets` when that is set (V4).
# - With the attribute `litmus-split`, each chapter gets a page of its own.
# - Lines a diff changed are highlighted, and their sections marked in the table of contents (V3).
# - Scripts on the page can light lines of a labeled listing: LitmusLines.light (V5).

require 'asciidoctor'
require 'asciidoctor/extensions'
require 'cgi'

module LitmusWeave
  ELLIPSIS = "…"
  Label = Struct.new(:name, :file, :executable, :id, :listing)

  # V3: the line numbers of ranges such as `3..7;12`.
  def self.lines_of(ranges)
    ranges.to_s.split(';').flat_map do |part|
      a, b = part.strip.split('..', 2)
      next [] unless a && a =~ /\A\d+\z/
      b && b =~ /\A\d+\z/ ? (a.to_i..b.to_i).to_a : [a.to_i]
    end
  end

  class Tree < Asciidoctor::Extensions::Treeprocessor
    @@listings = {}
    @@changed_sections = []

    def self.listings
      @@listings
    end

    def self.changed_sections
      @@changed_sections
    end

    def process(doc)
      @@listings = {}
      @@changed_sections = []
      nodes = doc.find_by { |b| b.context == :paragraph || b.context == :listing }
      labels = []
      pending = nil
      nodes.each do |node|
        if node.context == :paragraph
          label = parse_label(node)
          if label
            label.listing = nil
            pending = [node, label]
          else
            pending = nil
          end
        else
          if pending
            pending[1].listing = node
            labels << pending
          end
          pending = nil
        end
      end

      slugs = Hash.new(0)
      first_id = {}
      labels.each do |_, label|
        base = 'x-' + "#{label.file}/#{label.name}".gsub(/[^A-Za-z0-9]+/, '-')
        slugs[base] += 1
        label.id = slugs[base] == 1 ? base : "#{base}-#{slugs[base]}"
        first_id[[label.file, label.name]] ||= label.id
      end

      labels.each_with_index do |(para, label), n|
        label.listing.add_role("lm-#{n}")
        changed = label.listing.attr('litmus-changed')
        removed = label.listing.attr('litmus-removed')
        @@listings[n] = { file: label.file, name: label.name, first_id: first_id, changed: changed, removed: removed }
        if changed || removed
          node = label.listing.parent
          while node && node.context != :document
            @@changed_sections << node.id if node.context == :section && node.id
            node = node.parent
          end
        end
        parent = para.parent
        index = parent.blocks.index(para)
        parent.blocks[index] = Asciidoctor::Block.new(parent, :pass, source: label_html(label, first_id, changed, removed), content_model: :raw)
      end
      doc
    end

    def parse_label(node)
      return nil unless node.lines.size == 1
      line = node.lines[0]
      return nil unless line.start_with?("#{ELLIPSIS} ")
      text = line[2..]
      at = text.index(/(?:\A|\s):file:(?:\s|\z)/)
      return nil unless at
      name = text[0...at].strip
      rest = text[at..].sub(/\A\s*:file:\s*/, '')
      executable = rest.include?(':executable:')
      file = rest.sub(/\s*:executable:.*/, '').strip
      Label.new(name.empty? ? nil : name, file, executable)
    end

    def label_html(label, first_id, changed = nil, removed = nil)
      name = label.name ? "#{CGI.escapeHTML(label.name)} " : ''
      exe = label.executable ? ' :executable:' : ''
      back = ''
      if label.name && first_id[[label.file, label.name]] == label.id
        back = %( <a class="lm-back" href="#u-#{label.id}" title="Go to where this is used">&#8617;</a>)
      end
      badges = ''
      count = LitmusWeave.lines_of(changed).size
      badges << %( <span class="lm-badge lm-badge-changed">changed #{count}</span>) if count > 0
      badges << %( <span class="lm-badge lm-badge-removed">removed #{CGI.escapeHTML(removed.to_s)}</span>) if removed
      %(<div class="litmus-label" id="#{label.id}">#{ELLIPSIS} #{name}:file: <strong>#{CGI.escapeHTML(label.file)}</strong>#{exe}#{badges}#{back}</div>)
    end
  end

  class Post < Asciidoctor::Extensions::Postprocessor
    STYLE = <<~CSS
      <style>
      .litmus-label { font-size: .75em; color: #6b7280; margin: 1.2em 0 .2em; }
      .litmus-label strong { color: #374151; }
      .litmus-label a, a.lm-ref { text-decoration: none; }
      .litmus-label:target { background: #fef9c3; }
      a.lm-ref { color: #1d4ed8; }
      a.lm-ref:hover { text-decoration: underline; }
      .lm-badge { display: inline-block; margin-left: .5em; padding: 0 .45em; border-radius: 3px; font-size: .9em; font-weight: 600; }
      .lm-badge-changed { background: #fef3c7; color: #92400e; }
      .lm-badge-removed { background: #fee2e2; color: #991b1b; }
      .listingblock pre { position: relative; }
      .lm-line { position: absolute; left: 0; pointer-events: none; }
      .lm-hl-changed { background: rgba(250, 204, 21, .22); box-shadow: inset 3px 0 0 #eab308; }
      .lm-hl-lit { background: rgba(59, 130, 246, .22); box-shadow: inset 3px 0 0 #2563eb; transition: top .2s; }
      .rouge .err { background: none !important; color: inherit !important; border: none !important; }
      </style>
    CSS

    # Marks the section being read in the table of contents, keeps it in view, and has a
    # button that brings the table of contents to the section being read.
    SPY = <<~HTML
      <style>
      #toc a.lm-current { background: #e0e7ff; color: #1e3a8a; font-weight: 600; border-radius: 3px; }
      #lm-sync { position: fixed; top: 8px; left: 8px; z-index: 20; font: 12px system-ui, sans-serif; padding: 3px 9px;
        border: 1px solid #c7d2fe; border-radius: 12px; background: #eef2ff; color: #3730a3; cursor: pointer; opacity: .9; }
      #lm-sync:hover { background: #e0e7ff; opacity: 1; }
      #toc a.lm-flash { animation: lm-flash 1.2s; }
      @keyframes lm-flash { 0%, 60% { background: #fde68a; } 100% { background: #e0e7ff; } }
      </style>
      <script>
      document.addEventListener('DOMContentLoaded', function () {
        var toc = document.getElementById('toc');
        if (!toc) return;
        var links = {};
        toc.querySelectorAll('a[href^="#"]').forEach(function (a) { links[a.getAttribute('href').slice(1)] = a; });
        var heads = [];
        document.querySelectorAll('#content h2[id], #content h3[id], #content h4[id]').forEach(function (h) { if (links[h.id]) heads.push(h); });
        if (!heads.length) return;
        var current = null, ticking = false;
        function find() {
          var found = heads[0];
          for (var i = 0; i < heads.length; i++) { if (heads[i].getBoundingClientRect().top <= 90) found = heads[i]; else break; }
          return found;
        }
        function reveal(link, centre) {
          var box = toc.getBoundingClientRect(), r = link.getBoundingClientRect();
          if (centre || r.top < box.top + 30 || r.bottom > box.bottom - 30) {
            toc.scrollTop += r.top - box.top - box.height / 2;
          }
        }
        function update() {
          ticking = false;
          var h = find();
          if (h === current) return;
          if (current) links[current.id].classList.remove('lm-current');
          current = h;
          links[h.id].classList.add('lm-current');
          reveal(links[h.id], false);
        }
        window.addEventListener('scroll', function () { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
        var b = document.createElement('button');
        b.id = 'lm-sync'; b.type = 'button'; b.textContent = '\u2316 sync'; b.title = 'Show this section in the table of contents';
        b.onclick = function () {
          update();
          if (!current) return;
          var a = links[current.id];
          reveal(a, true);
          a.classList.remove('lm-flash'); void a.offsetWidth; a.classList.add('lm-flash');
        };
        document.body.appendChild(b);
        // Beside the table of contents, wherever its edge is; at the left edge when the table
        // of contents is not a column.
        function place() {
          var box = toc.getBoundingClientRect();
          var column = getComputedStyle(toc).position === 'fixed';
          b.style.left = (column ? box.right + 12 : 8) + 'px';
        }
        place();
        window.addEventListener('resize', place);
        window.addEventListener('load', place);
        update();
        reveal(links[current.id], true);
      });
      </script>
    HTML

    # V1: the `key: value` lines of the `## Settings` section of the document's style file.
    def settings(doc)
      style = doc.attr('litmus-style')
      return {} unless style
      path = File.join(doc.attr('docdir') || '.', style)
      return {} unless File.exist?(path)
      result = {}
      inside = false
      File.readlines(path, chomp: true).each do |line|
        if line.start_with?('## ')
          inside = line.strip == '## Settings'
        elsif inside && (m = line.match(/\A\s*([\w-]+)\s*:\s*(.*?)\s*\z/))
          result[m[1]] = m[2]
        end
      end
      result
    end

    def process(doc, output)
      listings = Tree.listings
      # A listing with a block title has the title before its content.
      pattern = /(<div class="listingblock[^"]*\blm-(\d+)\b[^"]*">\s*(?:<div class="title">.*?<\/div>\s*)?<div class="content">\s*<pre[^>]*>(?:<code[^>]*>)?)(.*?)((?:<\/code>)?<\/pre>)/m
      output = output.gsub(pattern) do
        head, n, code, tail = $1, $2.to_i, $3, $4
        info = listings[n]
        data = %( data-lm-file="#{CGI.escapeHTML(info[:file])}" data-lm-name="#{CGI.escapeHTML(info[:name] || '')}")
        data << %( data-lm-changed="#{CGI.escapeHTML(info[:changed])}") if info[:changed]
        head = head.sub(/\A<div class="listingblock[^"]*"/) { |m| m + data }
        lines = code.split("\n", -1).map do |line|
          plain = line.gsub(/<[^>]+>/, '')
          if (m = plain.match(/\A(\s*)#{ELLIPSIS} (.*\S)\s*\z/))
            target = info[:first_id][[info[:file], CGI.unescapeHTML(m[2]).strip]]
            if target
              %(#{m[1]}<a class="lm-ref" id="u-#{target}" href="##{target}">#{ELLIPSIS} #{m[2]}</a>)
            else
              line
            end
          else
            line
          end
        end
        head + lines.join("\n") + tail
      end
      theme = (settings(doc)['mermaid-theme'] || 'neutral').gsub(/[^a-z-]/, '')
      pages = split(doc, output)
      assets = doc.attr('litmus-assets')
      return finish(output, theme, assets) unless pages
      outdir = doc.attr('outdir') || File.dirname(doc.attr('outfile'))
      pages.drop(1).each { |name, html| File.write(File.join(outdir, name), finish(html, theme, assets)) }
      finish(pages[0][1], theme, assets)
    end

    # V5: finds a labeled listing by "NAME" or "FILE NAME", and lights lines of it. V3: lights
    # the lines a diff changed. The lights are boxes laid over the listing, so that the
    # highlighting of the code is left as it is; they are laid again when the fonts or the
    # width change.
    LINES = <<~HTML
      <script>
      window.LitmusLines = (function () {
        var painted = [];
        function numbers(ranges) {
          var out = [];
          String(ranges || '').split(';').forEach(function (part) {
            var ab = part.trim().split('..'), a = parseInt(ab[0], 10), b = ab.length > 1 ? parseInt(ab[1], 10) : a;
            if (!isNaN(a) && !isNaN(b)) for (var i = a; i <= b; i++) out.push(i);
          });
          return out;
        }
        function find(key) {
          key = String(key).trim();
          var nodes = document.querySelectorAll('.listingblock[data-lm-name]');
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i], name = n.getAttribute('data-lm-name'), file = n.getAttribute('data-lm-file');
            if (key === name || key === file + ' ' + name || (name === '' && key === file)) return n;
          }
          return null;
        }
        // The top and bottom of each line of the code, relative to the listing's box. A line
        // that wraps is as tall as all its rows.
        function rows(pre, code) {
          var starts = [], walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT), node, fresh = true;
          while ((node = walker.nextNode())) {
            for (var i = 0; i < node.data.length; i++) {
              if (fresh) { starts.push([node, i]); fresh = false; }
              if (node.data[i] === '\\n') fresh = true;
            }
          }
          var outer = pre.getBoundingClientRect(), box = code.getBoundingClientRect(), base = pre.scrollTop - outer.top;
          var tops = starts.map(function (s) {
            var r = document.createRange();
            r.setStart(s[0], s[1]);
            r.setEnd(s[0], s[1] + 1);
            var rects = r.getClientRects();
            return rects.length ? rects[0].top + base : null;
          });
          var step = box.height / Math.max(starts.length, 1);
          for (var i = 0; i < tops.length; i++) if (tops[i] === null) tops[i] = i ? tops[i - 1] + step : box.top + base;
          return tops.map(function (top, i) { return { top: top, bottom: i + 1 < tops.length ? tops[i + 1] : box.bottom + base }; });
        }
        function paint(entry) {
          var pre = entry.block.querySelector('pre');
          if (!pre) return;
          entry.boxes.forEach(function (d) { d.remove(); });
          entry.boxes = [];
          var lines = rows(pre, pre.querySelector('code') || pre);
          entry.lines.forEach(function (n) {
            var line = lines[n - 1];
            if (!line) return;
            var d = document.createElement('div');
            d.className = 'lm-line ' + entry.cls;
            d.style.top = line.top + 'px';
            d.style.height = (line.bottom - line.top) + 'px';
            d.style.width = pre.scrollWidth + 'px';
            pre.appendChild(d);
            entry.boxes.push(d);
          });
        }
        function add(block, ranges, cls) {
          var entry = { block: block, lines: numbers(ranges), cls: cls, boxes: [] };
          painted.push(entry);
          paint(entry);
          return entry;
        }
        function clear() {
          painted = painted.filter(function (e) {
            if (e.cls !== 'lm-hl-lit') return true;
            e.boxes.forEach(function (d) { d.remove(); });
            return false;
          });
        }
        function light(key, ranges) {
          clear();
          var block = key && find(key);
          if (block) add(block, ranges, 'lm-hl-lit');
          return block;
        }
        function repaint() { painted.forEach(paint); }
        document.addEventListener('DOMContentLoaded', function () {
          document.querySelectorAll('.listingblock[data-lm-changed]').forEach(function (b) {
            add(b, b.getAttribute('data-lm-changed'), 'lm-hl-changed');
          });
        });
        window.addEventListener('load', repaint);
        window.addEventListener('resize', repaint);
        return { light: light, clear: clear, find: find, numbers: numbers };
      })();
      </script>
    HTML

    def finish(output, theme, assets = nil)
      head = STYLE + SPY
      head += LINES if output.include?('data-lm-name=')
      sections = Tree.changed_sections.uniq
      head += changed_toc(sections) unless sections.empty?
      # Diagrams written as `<pre class="mermaid">` in a passthrough block are drawn in the
      # browser by Mermaid: from the page's own assets when it has them (V4), else from a CDN.
      if output.include?('class="mermaid"')
        head += %(<style>pre.mermaid { background: none; border: none; text-align: center; }</style>\n)
        if assets
          src = CGI.escapeHTML(File.join(assets, 'vendor', 'mermaid.min.js'))
          head += <<~HTML
            <script src="#{src}"></script>
            <script>mermaid.initialize({ startOnLoad: true, theme: '#{theme}' });</script>
          HTML
        else
          head += <<~HTML
            <script type="module">
            import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs';
            mermaid.initialize({ startOnLoad: true, theme: '#{theme}' });
            </script>
          HTML
        end
      end
      output.sub('</head>', head + '</head>')
    end

    # V3: marks the sections that hold changed lines in the table of contents, and adds a
    # button beside the sync button that shows only them.
    def changed_toc(ids)
      list = ids.map { |id| %("#{id.gsub(/[^A-Za-z0-9_-]/, '')}") }.join(',')
      <<~HTML
        <style>
        #toc a.lm-has-changed::after { content: ' \\25CF'; color: #eab308; font-size: .8em; }
        #toc.lm-only-changed li:not(.lm-has-changed) { display: none; }
        #lm-only { position: fixed; top: 8px; z-index: 20; font: 12px system-ui, sans-serif; padding: 3px 9px;
          border: 1px solid #fde68a; border-radius: 12px; background: #fefce8; color: #854d0e; cursor: pointer; opacity: .9; }
        #lm-only.on { background: #fde68a; }
        </style>
        <script>
        document.addEventListener('DOMContentLoaded', function () {
          var toc = document.getElementById('toc');
          if (!toc) return;
          var ids = [#{list}];
          toc.querySelectorAll('a[href*="#"]').forEach(function (a) {
            var id = a.getAttribute('href').split('#')[1];
            if (ids.indexOf(id) < 0) return;
            a.classList.add('lm-has-changed');
            for (var li = a.closest('li'); li; li = li.parentElement && li.parentElement.closest('li')) li.classList.add('lm-has-changed');
          });
          var b = document.createElement('button');
          b.id = 'lm-only'; b.type = 'button'; b.textContent = '\u25CF changed only'; b.title = 'Show only the sections a change touched';
          b.onclick = function () { b.classList.toggle('on'); toc.classList.toggle('lm-only-changed'); };
          document.body.appendChild(b);
          function place() {
            var sync = document.getElementById('lm-sync');
            var left = sync ? sync.getBoundingClientRect().right + 6 : 8;
            b.style.left = left + 'px';
          }
          place();
          window.addEventListener('resize', place);
          window.addEventListener('load', place);
        });
        </script>
      HTML
    end

    PAGES = <<~CSS
      <style>
      .lm-pages { display: flex; justify-content: space-between; gap: 1em; margin: 3em 0 1em; padding-top: 1em;
        border-top: 1px solid #e5e7eb; font-size: .9em; }
      .lm-pages a { text-decoration: none; }
      .lm-pages .lm-next { margin-left: auto; text-align: right; }
      </style>
    CSS

    # V2: the pages of a split document, as [name, html] pairs with the main page first, or nil
    # when the document is not split. Each page is the whole document with the content of one
    # chapter, so the header, the table of contents and the footer are on every page.
    def split(doc, output)
      return nil unless doc.attr?('litmus-split') && doc.attr?('outfile')
      open = output.index('<div id="content">')
      return nil unless open
      open += '<div id="content">'.length
      ends = ['<div id="footnotes">', '<div id="footer">', '</body>'].filter_map { |m| output.index(m, open) }
      return nil if ends.empty?
      close = output.rindex('</div>', ends.min)
      return nil unless close && close >= open
      body = output[open...close]

      # A chapter starts at its level-1 section, or at the part title before it.
      starts = []
      part = nil
      body.scan(/<h1 id="[^"]*" class="sect0[^"]*">|<div class="sect1">/) do
        at = $~.begin(0)
        if $~[0].start_with?('<h1')
          part ||= at
        else
          starts << (part || at)
          part = nil
        end
      end
      return nil if starts.empty?

      base = File.basename(doc.attr('outfile'), '.*')
      pages = [{ name: File.basename(doc.attr('outfile')), body: body[0...starts[0]], title: doc.doctitle(sanitize: true) || base }]
      starts.each_with_index do |at, i|
        slice = body[at...(starts[i + 1] || body.size)]
        h2 = slice.match(/<h2 id="([^"]+)"[^>]*>(.*?)<\/h2>/m)
        id = h2 ? h2[1] : "chapter-#{i + 1}"
        title = h2 ? CGI.unescapeHTML(h2[2].gsub(/<[^>]+>/, '')).strip : id
        pages << { name: "#{base}-#{id.sub(/\A_+/, '')}.html", body: slice, title: title }
      end

      owner = {}
      pages.each { |page| page[:body].scan(/\sid="([^"]+)"/) { owner[$1] ||= page[:name] } }

      head = output[0...open].sub('</head>', PAGES + '</head>')
      tail = output[close..]
      pages.each_with_index.map do |page, i|
        nav = +''
        if i > 0
          prev = pages[i - 1]
          nav << %(<a class="lm-prev" href="#{prev[:name]}">&#8592; #{CGI.escapeHTML(prev[:title])}</a>)
        end
        if (nxt = pages[i + 1])
          nav << %(<a class="lm-next" href="#{nxt[:name]}">#{CGI.escapeHTML(nxt[:title])} &#8594;</a>)
        end
        top = i.zero? ? head : head.sub(/<title>(.*?)<\/title>/m) { "<title>#{CGI.escapeHTML(page[:title])} | #{$1}</title>" }
        # A page keeps the footnotes it refers to.
        foot = tail.gsub(/<div class="footnote" id="_footnotedef_(\d+)">.*?<\/div>\n?/m) do |m|
          page[:body].include?(%(href="#_footnotedef_#{$1}")) ? m : ''
        end
        foot = foot.sub(/<div id="footnotes">\s*<hr>\s*<\/div>\n?/, '')
        html = top + page[:body] + %(<nav class="lm-pages">#{nav}</nav>\n) + foot
        # A link to an anchor on another page goes to that page.
        html = html.gsub(/href="#([^"]+)"/) do
          target = owner[$1]
          target && target != page[:name] ? %(href="#{target}##{$1}") : $~[0]
        end
        [page[:name], html]
      end
    end
  end
end

Asciidoctor::Extensions.register do
  treeprocessor LitmusWeave::Tree
  postprocessor LitmusWeave::Post
end
