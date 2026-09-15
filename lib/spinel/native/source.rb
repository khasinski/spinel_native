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

      # The body of the `native_state { ... }` block at the block's source location.
      def of_state_block(block)
        file, line = block.source_location
        raise Error, "native_state: no source location" unless file && File.exist?(file)
        call = find_state_call(Prism.parse_file(file).value, line)
        raise Error, "native_state: no `native_state { ... }` found at #{file}:#{line}" unless call
        body = call.block.body
        body ? body.slice : ""
      end

      def find_state_call(node, line)
        if node.is_a?(Prism::CallNode) && node.name == :native_state &&
           node.block.is_a?(Prism::BlockNode) && node.location.start_line == line
          return node
        end
        node.compact_child_nodes.each do |child|
          found = find_state_call(child, line)
          return found if found
        end
        nil
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
