#!/usr/bin/env ruby

#########################
# tmux get current layout
#########################

def window_layout(window)
  window =~ /\[layout (\S+)\]/
  $1
end

def current_window(windows)
  windows.find { |window|
    window.split(/\s+/)[1].end_with?('*')
  }
end

def windows
  `tmux list-windows`.lines.map(&:chomp)
end

def tmux_current_layout
  window = current_window(windows)
  window_layout(window)
end

#####################
# tmux layout classes
#####################

class LayoutString < Struct.new(:checksum, :layout)
  def visit(visitor)
    visitor.call(self)
    layout.visit(visitor)
  end

  def to_s
    "#{checksum},#{layout.to_s}"
  end
end

class Layout < Struct.new(:dims, :x, :y, :pane_id_or_nesting)
  def visit(visitor)
    visitor.call(self)
    pane_id_or_nesting.visit(visitor)
  end

  def checksum
    i =
      to_s.codepoints.inject(0) {|csum, codepoint|
        ((csum >> 1) + ((csum & 1) << 15) + codepoint) & 0xFFFF
      }
    "%x" % [i]
  end

  def to_s
    "#{dims},#{x},#{y}#{pane_id_or_nesting}"
  end
end

class PaneId < Struct.new(:pane_id)
  def visit(visitor)
    visitor.call(self)
  end

  def to_s
    ",#{pane_id}"
  end
end

class Nesting < Struct.new(:layouts)
  def visit(visitor)
    visitor.call(self)
    layouts.each do |layout|
      layout.visit(visitor)
    end
  end
end

class HorizontalNesting < Nesting
  def to_s
    "{#{layouts.map(&:to_s).join(",")}}"
  end
end

class VerticalNesting < Nesting
  def to_s
    "[#{layouts.map(&:to_s).join(",")}]"
  end
end

####################
# tmux layout parser
####################

require 'raabro'

# A Raabro PEG for parsing tmux layout strings
module TmuxLayout
  include Raabro

  def comma(i);        str(:comma, i, ",");        end
  def x(i);            str(:comma, i, "x");        end
  def open_curly(i);   str(:open_curly, i, "{");   end
  def close_curly(i);  str(:close_curly, i, "}");  end
  def open_square(i);  str(:open_square, i, "[");  end
  def close_square(i); str(:close_square, i, "]"); end
  def number(i);       rex(:number, i, /\d+/);     end
  def whitespace(i);   rex(:whitespace, i, /\n*/); end

  def checksum(i); rex(:checksum, i, /[a-f0-9]{4}/); end
  def dims(i)
    seq(:dims, i, :number, :x, :number)
  end

  def layout(i)
    seq(:layout, i, :dims, :comma, :number, :comma, :number, :comma_pane_id_or_nesting)
  end
  def comma_pane_id(i)
    seq(:comma_pane_id, i, :comma, :number)
  end

  def nesting(i)
    alt(:nesting, i, :horizontal_nesting, :vertical_nesting)
  end
  def horizontal_nesting(i)
    eseq(:horizontal_nesting, i, :open_curly, :layout, :comma, :close_curly)
  end
  def vertical_nesting(i)
    eseq(:vertical_nesting, i, :open_square, :layout, :comma, :close_square)
  end

  def comma_pane_id_or_nesting(i)
    alt(:comma_pane_id_or_nesting, i, :comma_pane_id, :nesting)
  end

  def layout_string(i)
    seq(:layout_string, i, :checksum, :comma, :layout, :whitespace)
  end

  def rewrite_comma_pane_id(t)
    _, pane_id = t.children
    PaneId.new(pane_id.string)
  end

  def rewrite_horizontal_nesting(t)
    _, *layouts_and_commas, _ = t.children
    layouts = layouts_and_commas.reject {|e| e.name == :comma}
    HorizontalNesting.new(layouts.map {|layout| rewrite(layout)})
  end

  def rewrite_vertical_nesting(t)
    _, *layouts_and_commas, _ = t.children
    layouts = layouts_and_commas.reject {|e| e.name == :comma}
    VerticalNesting.new(layouts.map {|layout| rewrite(layout)})
  end

  def rewrite_nesting(t)
    rewrite(t.children.first)
  end

  def rewrite_comma_pane_id_or_nesting(t)
    rewrite(t.children.first)
  end

  def rewrite_layout(t)
    dims, _, x, _, y, comma_pane_id_or_nesting = t.children

    Layout.new(dims.string, x.string, y.string, rewrite(comma_pane_id_or_nesting))
  end

  def rewrite_layout_string(t)
    checksum, _, layout = t.children

    LayoutString.new(checksum.string, rewrite(layout))
  end
end

#################
# layout building
#################

# Get the pane ids for the current panes, in order.
#
# layout - A Layout to extract pane ids from
#
# Returns: [pane id integers]
def get_pane_ids(layout)
  pane_ids = []
  visitor = ->(node) {
    if node.kind_of?(PaneId)
      pane_ids << node.pane_id
    end
  }
  layout.visit(visitor)
  pane_ids
end

# Divvy the total amount into count groups
#
# total - The total amount to divvy up
# count - The number of sums to get
#
# Returns an Array of `count` integers, totaling `total`
def get_sums(total, count)
  ([1]*total).group_by.with_index {|_, i| i % count}.values.map {|a| a.inject(0, &:+)}
end

def distribute_horizontally(y, width, height, pane_ids)
  widths = get_sums(width - (pane_ids.count-1), pane_ids.count)
  pane_ids.map.with_index {|pane_id, i|
    x = widths[0,i].inject(0, &:+) + i
    dim = "#{widths[i]}x#{height}"
    Layout.new(dim, x, y, PaneId.new(pane_id))
  }
end

def distribute_vertically(x, width, height, pane_ids)
  heights = get_sums(height - (pane_ids.count-1), pane_ids.count)
  pane_ids.map.with_index {|pane_id, i|
    y = heights[0,i].inject(0, &:+) + i
    dim = "#{width}x#{heights[i]}"
    Layout.new(dim, x, y, PaneId.new(pane_id))
  }
end

# Build the layout for a horizontal row of editors.
def build_editor_layout(width, height, pane_ids)
  if pane_ids.count == 1
    build_single_editor_layout(width, height, pane_ids.first)
  else
    build_multiple_editor_layout(width, height, pane_ids)
  end
end

# Build a layout containing a single pane.
def build_single_editor_layout(width, height, pane_id)
  Layout.new("#{width}x#{height}", 0, 0, PaneId.new(pane_id))
end

# Build a horizontal layout containing multiple panes
def build_multiple_editor_layout(width, height, pane_ids)
  editor_height = height / 2
  top_editor_pane_ids = pane_ids[0, pane_ids.count/2]
  bottom_editor_pane_ids = pane_ids[pane_ids.count/2..-1]
  top_editor_layouts = distribute_horizontally(0, width, editor_height, top_editor_pane_ids)
  bottom_editor_layouts = distribute_horizontally(editor_height+1, width, height-editor_height-1, bottom_editor_pane_ids)

  top_layout = top_editor_layouts.count == 1 ? top_editor_layouts.first : Layout.new("#{width}x#{editor_height}", 0, 0, HorizontalNesting.new(top_editor_layouts))
  bottom_layout = bottom_editor_layouts.count == 1 ? bottom_editor_layouts.first : Layout.new("#{width}x#{height-editor_height-1}", 0, editor_height+1, HorizontalNesting.new(bottom_editor_layouts))

  Layout.new("#{width}x#{height}", 0, 0, VerticalNesting.new([ top_layout, bottom_layout ]))
end

# Build a layout for a vertical column of consoles
def build_console_layout(x, width, height, pane_ids)
  console_layouts = distribute_vertically(x, width, height, pane_ids)
  Layout.new("#{width}x#{height}", x, 0,
    VerticalNesting.new(console_layouts))
end

# Determine how wide the console column should be
def determine_console_width(total_width)
  [[total_width / 4, 120].min, 80].max
end

# Build the coder layout for a certain number of editors
#
# editor_count - The number of editors on the left
#
# Returns a layout with `editor_count` editors on the left and the remaining
# panes on the right.
def coder_layout(editor_count)
  current_layout = TmuxLayout.parse(tmux_current_layout)
  layout = current_layout.layout
  pane_ids = get_pane_ids(layout)

  if pane_ids.count == 1
    return current_layout.to_s
  end

  total_dims = layout.dims
  total_width, total_height = total_dims.split('x').map(&:to_i)

  editor_pane_ids = pane_ids[0,editor_count]
  console_pane_ids = pane_ids[editor_count..-1]

  right_width = determine_console_width(total_width)
  left_width = total_width - right_width - 1

  layout =
    Layout.new(total_dims, 0, 0,
      HorizontalNesting.new(
        [
          build_editor_layout(left_width, total_height, editor_pane_ids),
          build_console_layout(left_width+1, right_width, total_height, console_pane_ids)
        ]
      ))
  LayoutString.new(layout.checksum, layout).to_s
end

if __FILE__ == $0
  puts coder_layout(ARGV[0].to_i)
end
