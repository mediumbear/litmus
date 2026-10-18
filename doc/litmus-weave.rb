# A small Asciidoctor extension for reading Litmus documents.
#
# - A document command above a code block (a paragraph like `… name :file: path`)
#   becomes a small, grey label with the file name in bold, and an anchor.
# - An excerpt command inside a labeled block links to the excerpt it stands for.
# - The label links back to the command that uses the excerpt.
# - Characters that Rouge cannot lex are not painted as errors.
# - Mermaid is loaded when a page has a diagram.

require 'asciidoctor'
require 'asciidoctor/extensions'
require 'cgi'

module LitmusWeave
  ELLIPSIS = "…"
  Label = Struct.new(:name, :file, :executable, :id, :listing)

  class Tree < Asciidoctor::Extensions::Treeprocessor
    @@listings = {}

    def self.listings
      @@listings
    end

    def process(doc)
      @@listings = {}
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
        @@listings[n] = { file: label.file, first_id: first_id }
        parent = para.parent
        index = parent.blocks.index(para)
        parent.blocks[index] = Asciidoctor::Block.new(parent, :pass, source: label_html(label, first_id), content_model: :raw)
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

    def process(doc, output)
      listings = Tree.listings
      pattern = /(<div class="listingblock[^"]*\blm-(\d+)\b[^"]*">\s*<div class="content">\s*<pre[^>]*>(?:<code[^>]*>)?)(.*?)((?:<\/code>)?<\/pre>)/m
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
      head = STYLE + SPY
      # Diagrams written as `<pre class="mermaid">` in a passthrough block are drawn in the
      # browser by Mermaid.
      if output.include?('class="mermaid"')
        head += <<~HTML
          <style>pre.mermaid { background: none; border: none; text-align: center; }</style>
          <script type="module">
          import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs';
          mermaid.initialize({ startOnLoad: true, theme: 'neutral' });
          </script>
        HTML
      end
      output.sub('</head>', head + '</head>')
    end
  end
end

Asciidoctor::Extensions.register do
  treeprocessor LitmusWeave::Tree
  postprocessor LitmusWeave::Post
end
