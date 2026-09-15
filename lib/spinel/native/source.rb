# frozen_string_literal: true

module Spinel
  module Native
    # Pulls the source text of a method back out of its file with Prism, and
    # rewrites its header to the `def self.name` form the kernel module uses.
    module Source
      module_function

      def of_method(meth)
        file, line = meth.source_location
        raise Error, "#{meth.name}: no source location (defined in C or eval?)" unless file && File.exist?(file)
        node = find_def(Prism.parse_file(file).value, meth.name, line)
        raise Error, "#{meth.name}: no `def` found at #{file}:#{line}" unless node
        as_module_function(node)
      end

      def find_def(node, name, line)
        return node if node.is_a?(Prism::DefNode) && node.name == name && node.location.start_line == line
        node.compact_child_nodes.each do |child|
          found = find_def(child, name, line)
          return found if found
        end
        nil
      end

      def as_module_function(node)
        raise Error, "#{node.name}: block parameters cannot cross the boundary" if node.parameters&.block
        text = node.slice
        text.sub(/\Adef\s+(self\s*\.\s*)?#{Regexp.escape(node.name.to_s)}/, "def self.#{node.name}")
      end
    end
  end
end
