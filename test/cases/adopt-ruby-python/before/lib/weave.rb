# Labels for code blocks.
require 'cgi'

module Weave
  ELLIPSIS = "…"
  Label = Struct.new(:name, :file)

  # The line numbers of ranges such as `3..7;12`.
  def self.lines_of(ranges)
    ranges.to_s.split(';').flat_map do |part|
      a, b = part.strip.split('..', 2)
      b ? (a.to_i..b.to_i).to_a : [a.to_i]
    end
  end

  class Tree
    def process(doc)
      doc.find_by(context: :listing).each do |node|
        label = parse_label(node)
        next unless label

        node.id = label.name
      end
    end

    def parse_label(node)
      text = node.source.strip
      return nil unless text.start_with?(ELLIPSIS)

      name, file = text[2..].split(' :file: ', 2)
      Label.new(name, file)
    end

    def label_html(label)
      "<div class=\"label\">#{CGI.escapeHTML(label.name)}</div>"
    end

    def chapter_one(doc)
      doc.sections[0]
    end

    def chapter_two(doc)
      doc.sections[1]
    end

    def chapter_three(doc)
      doc.sections[2]
    end

    def chapter_four(doc)
      doc.sections[3]
    end

    def to_s
      "tree"
    end
  end

  class Post
    def process(doc, output)
      output.sub('</head>', "<style>.label{}</style></head>")
    end
  end
end

Weave.lines_of(ARGV[0])
