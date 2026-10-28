# A small Asciidoctor extension for reading Litmus documents.
#
# - A document command above a code block (a paragraph like `… name :file: path`)
#   becomes a small, grey label with the file name in bold, and an anchor.
# - An excerpt command inside a labeled block links to the excerpt it stands for.
# - The label links back to the command that uses the excerpt.
# - Characters that Rouge cannot lex are not painted as errors.
# - Mermaid is loaded when a page has a diagram.
# - With LITMUS_LIVE set, the pages are live (V3): each block knows where it starts, and a
#   script sends selections to `litmus watch --live` and opens tangled files.
# - With the attribute `litmus-split`, each chapter gets a page of its own.

require 'asciidoctor'
require 'asciidoctor/extensions'
require 'cgi'
require 'json'
require 'pathname'

module LitmusWeave
  ELLIPSIS = "…"
  Label = Struct.new(:name, :file, :executable, :id, :listing)

  # V3: the directory that live pages name documents from, or nil when the pages are not live.
  def self.live_root
    root = ENV['LITMUS_LIVE']
    root && !root.empty? ? root : nil
  end

  # Line numbers are only kept while parsing when the document asks for them.
  class Lines < Asciidoctor::Extensions::Preprocessor
    def process(doc, reader)
      doc.sourcemap = true if LitmusWeave.live_root
      reader
    end
  end

  class Tree < Asciidoctor::Extensions::Treeprocessor
    @@listings = {}
    @@live = nil

    def self.listings
      @@listings
    end

    def self.live
      @@live
    end

    def process(doc)
      @@listings = {}
      @@live = nil
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
        @@listings[n] = { file: label.file, name: label.name, first_id: first_id }
        parent = para.parent
        index = parent.blocks.index(para)
        parent.blocks[index] = Asciidoctor::Block.new(parent, :pass, source: label_html(label, first_id), content_model: :raw)
      end
      mark_sources(doc, labels) if LitmusWeave.live_root
      doc
    end

    # V3: each block that has a wrapper of its own gets a role `lm-at-K`, and the table says
    # where block K starts: its document, as a path from LITMUS_LIVE, and its line. A labeled
    # listing also has its excerpt and file.
    MARKED = %i[paragraph listing literal ulist olist dlist colist table admonition example sidebar quote verse open image section].freeze

    def mark_sources(doc, labels)
      root = Pathname.new(LitmusWeave.live_root)
      labeled = {}
      labels.each { |_, label| labeled[label.listing] = label }
      paths = []
      path_index = {}
      blocks = []
      doc.find_by { |b| MARKED.include?(b.context) }.each do |block|
        at = block.source_location
        next unless at && at.file
        path = Pathname.new(File.expand_path(at.file)).relative_path_from(root).to_s rescue next
        index = (path_index[path] ||= (paths << path).size - 1)
        entry = [index, at.lineno]
        if (label = labeled[block])
          entry += [label.name, label.file]
        end
        block.add_role("lm-at-#{blocks.size}")
        blocks << entry
      end
      @@live = { paths: paths, blocks: blocks }
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

    def label_html(label, first_id)
      name = label.name ? "#{CGI.escapeHTML(label.name)} " : ''
      exe = label.executable ? ' :executable:' : ''
      back = ''
      if label.name && first_id[[label.file, label.name]] == label.id
        back = %( <a class="lm-back" href="#u-#{label.id}" title="Go to where this is used">&#8617;</a>)
      end
      %(<div class="litmus-label" id="#{label.id}">#{ELLIPSIS} #{name}:file: <strong>#{CGI.escapeHTML(label.file)}</strong>#{exe}#{back}</div>)
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
      return finish(output, theme) unless pages
      outdir = doc.attr('outdir') || File.dirname(doc.attr('outfile'))
      pages.drop(1).each { |name, html| File.write(File.join(outdir, name), finish(html, theme)) }
      finish(pages[0][1], theme)
    end

    def finish(output, theme)
      head = STYLE + SPY
      if (table = Tree.live)
        head += %(<script>window.LITMUS_LIVE = #{JSON.generate(table).gsub('</', '<\\/')};</script>\n) + LIVE
      end
      # Diagrams written as `<pre class="mermaid">` in a passthrough block are drawn in the
      # browser by Mermaid.
      if output.include?('class="mermaid"')
        head += <<~HTML
          <style>pre.mermaid { background: none; border: none; text-align: center; }</style>
          <script type="module">
          import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs';
          mermaid.initialize({ startOnLoad: true, theme: '#{theme}' });
          </script>
        HTML
      end
      output.sub('</head>', head + '</head>')
    end

    # V3, E3, E6: the script of live pages. It sends what the reader selects to watch, opens a
    # label's file when its name is clicked, and reloads the page when watch says the pages
    # were woven again.
    LIVE = <<~'HTML'
      <style>
      #lm-ask { position: absolute; z-index: 30; display: none; font: 12px system-ui, sans-serif; padding: 4px 10px;
        border: 1px solid #a5b4fc; border-radius: 12px; background: #4f46e5; color: #fff; cursor: pointer;
        box-shadow: 0 2px 6px rgba(0,0,0,.2); }
      #lm-toast { position: fixed; bottom: 16px; right: 16px; z-index: 30; max-width: 40em; font: 12px system-ui, sans-serif;
        padding: 6px 12px; border-radius: 6px; background: #111827; color: #f9fafb; opacity: 0; transition: opacity .3s;
        pointer-events: none; }
      #lm-toast.lm-show { opacity: .92; }
      .litmus-label strong.lm-open { cursor: pointer; text-decoration: underline dotted; }
      .litmus-label strong.lm-open:hover { color: #1d4ed8; }
      </style>
      <script>
      document.addEventListener('DOMContentLoaded', function () {
        var live = window.LITMUS_LIVE;
        if (!live) return;
        var toast = document.createElement('div');
        toast.id = 'lm-toast';
        document.body.appendChild(toast);
        var hide;
        function say(text) {
          toast.textContent = text;
          toast.classList.add('lm-show');
          clearTimeout(hide);
          hide = setTimeout(function () { toast.classList.remove('lm-show'); }, 3500);
        }
        function post(path, body) {
          return fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
            .then(function (r) { return r.text().then(function (t) { return { ok: r.ok, text: t }; }); })
            .catch(function () { return { ok: false, text: 'litmus watch --live is not running' }; });
        }
        function blockOf(node) {
          var el = node.nodeType === 1 ? node : node.parentElement;
          while (el && el !== document.body) {
            var m = el.className && typeof el.className === 'string' && el.className.match(/\blm-at-(\d+)\b/);
            if (m) return { el: el, k: +m[1] };
            el = el.parentElement;
          }
          return null;
        }
        function sections(el) {
          var titles = [];
          for (var s = el.closest('[class^="sect"]'); s; s = s.parentElement && s.parentElement.closest('[class^="sect"]')) {
            var h = s.querySelector(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6');
            if (h) titles.unshift(h.textContent.trim());
          }
          return titles;
        }
        // The line of a point in a code block, counted from its first line of code.
        function codeLine(pre, container, offset) {
          var r = document.createRange();
          r.setStart(pre, 0);
          r.setEnd(container, offset);
          return (r.toString().match(/\n/g) || []).length;
        }
        function selection() {
          var sel = window.getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
          var range = sel.getRangeAt(0);
          var first = blockOf(range.startContainer), last = blockOf(range.endContainer);
          if (!first || !last) return null;
          var a = live.blocks[first.k], b = live.blocks[last.k];
          var s = { doc: live.paths[a[0]], line: a[1], last_doc: live.paths[b[0]], last_line: b[1],
            sections: sections(first.el), text: sel.toString() };
          var pre = first.k === last.k && first.el.querySelector('pre');
          if (pre && pre.contains(range.startContainer) && pre.contains(range.endContainer)) {
            s.code_first = codeLine(pre, range.startContainer, range.startOffset);
            s.code_last = codeLine(pre, range.endContainer, range.endOffset);
            if (s.code_last > s.code_first && /\n$/.test(s.text)) s.code_last -= 1;
            if (a[2]) s.excerpt = a[2];
            if (a[3]) s.file = a[3];
          }
          return s;
        }
        var ask = document.createElement('button');
        ask.id = 'lm-ask';
        ask.type = 'button';
        ask.textContent = 'Send to agent';
        ask.title = 'Write this selection to .litmus/selection, for the next prompt';
        document.body.appendChild(ask);
        var pending = null;
        ask.addEventListener('mousedown', function (e) { e.preventDefault(); });
        ask.addEventListener('click', function () {
          if (!pending) return;
          post('/litmus/selection', pending).then(function (r) { say(r.ok ? 'Sent: ' + r.text : r.text); });
          ask.style.display = 'none';
        });
        document.addEventListener('mouseup', function () {
          setTimeout(function () {
            pending = selection();
            if (!pending) { ask.style.display = 'none'; return; }
            var rects = window.getSelection().getRangeAt(0).getClientRects();
            var r = rects[rects.length - 1];
            ask.style.left = (r.right + window.scrollX + 6) + 'px';
            ask.style.top = (r.bottom + window.scrollY + 4) + 'px';
            ask.style.display = 'block';
          }, 0);
        });
        // E6: the file name of a label opens the tangled file at the block's first line.
        document.querySelectorAll('.litmus-label strong').forEach(function (strong) {
          // The block is the label's next sibling that has a line of its own; its parents,
          // such as the section, have lines too, so blockOf would find those.
          var next = strong.closest('.litmus-label').nextElementSibling, m = null;
          while (next && !(m = (next.className || '').match(/\blm-at-(\d+)\b/))) next = next.nextElementSibling;
          if (!m) return;
          var at = live.blocks[+m[1]];
          strong.classList.add('lm-open');
          strong.title = 'Open the tangled file here';
          strong.addEventListener('click', function () {
            post('/litmus/open', { doc: live.paths[at[0]], line: at[1] }).then(function (r) { say(r.ok ? 'Opened ' + r.text : r.text); });
          });
        });
        // E2: reload when the pages were woven again, and keep the place.
        var key = 'lm-scroll:' + location.pathname;
        try {
          var y = sessionStorage.getItem(key);
          if (y !== null) { sessionStorage.removeItem(key); window.scrollTo(0, +y); }
        } catch (e) {}
        var version = null;
        setInterval(function () {
          fetch('/litmus/version', { cache: 'no-store' }).then(function (r) { return r.text(); }).then(function (v) {
            if (version === null) version = v;
            else if (v !== version) {
              try { sessionStorage.setItem(key, String(window.scrollY)); } catch (e) {}
              location.reload();
            }
          }).catch(function () {});
        }, 1000);
      });
      </script>
    HTML

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
  preprocessor LitmusWeave::Lines
  treeprocessor LitmusWeave::Tree
  postprocessor LitmusWeave::Post
end
