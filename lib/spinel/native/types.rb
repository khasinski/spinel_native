# frozen_string_literal: true

module Spinel
  module Native
    # The types that cross the extension boundary (by copy), and how a Ruby
    # value maps onto them. A type is one of:
    #   :int, :float, :str, :bool, [:array, :int|:float|:str]
    module Types
      module_function

      NAMES = {
        "Integer" => :int, "Float" => :float, "String" => :str,
        "bool" => :bool, "true" => :bool, "false" => :bool,
      }.freeze

      # "(Array[Float], Integer) -> Float" => [[:array, :float], :int]
      # The return type is inferred by Spinel and only checked for shape here.
      def parse_signature(sig)
        m = sig.strip.match(/\A\((.*)\)\s*->\s*(.+)\z/m)
        raise TypeError, "bad signature #{sig.inspect}, want \"(T1, T2) -> R\"" unless m
        params = split_top_level(m[1]).map { |t| parse_type(t) }
        parse_type(m[2])
        params
      end

      def parse_type(text)
        t = text.strip
        if (m = t.match(/\AArray\[(.+)\]\z/))
          elem = parse_type(m[1])
          raise TypeError, "nested arrays cannot cross the boundary: #{t}" if elem.is_a?(Array)
          return [:array, elem]
        end
        NAMES.fetch(t) { raise TypeError, "unsupported type #{t.inspect} (supported: Integer, Float, String, bool, Array[...])" }
      end

      def split_top_level(text)
        out, depth, cur = [], 0, +""
        text.each_char do |ch|
          case ch
          when "[" then depth += 1; cur << ch
          when "]" then depth -= 1; cur << ch
          when "," then depth.zero? ? (out << cur; cur = +"") : cur << ch
          else cur << ch
          end
        end
        out << cur unless cur.strip.empty?
        out.map(&:strip)
      end

      # The boundary type of a live Ruby value, or raise TypeError.
      def of_value(v)
        case v
        when Integer then :int
        when Float then :float
        when String then :str
        when true, false then :bool
        when Array
          raise TypeError, "cannot infer the element type of an empty array (declare a signature)" if v.empty?
          elem = of_value(v.first)
          raise TypeError, "nested arrays cannot cross the boundary" if elem.is_a?(Array)
          unless v.all? { |e| of_value(e) == elem }
            raise TypeError, "mixed-type array cannot cross the boundary"
          end
          [:array, elem]
        else
          raise TypeError, "#{v.class} cannot cross the boundary (Integer, Float, String, bool, Array of those)"
        end
      end

      # A Ruby literal of the type, used as the witness call that seeds
      # Spinel's whole-program inference for an exported entry.
      def witness(type)
        case type
        in :int then "0"
        in :float then "0.0"
        in :str then '"x"'
        in :bool then "true"
        in [:array, elem] then "[#{witness(elem)}]"
        end
      end

      def to_s(type)
        case type
        in :int then "Integer"
        in :float then "Float"
        in :str then "String"
        in :bool then "bool"
        in [:array, elem] then "Array[#{to_s(elem)}]"
        end
      end
    end
  end
end
