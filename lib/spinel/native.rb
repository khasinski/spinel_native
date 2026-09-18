# frozen_string_literal: true

# Spinel::Native -- compile individual Ruby methods to a native extension with
# the Spinel AOT compiler, from inside a running CRuby program.
#
#   module Physics
#     extend Spinel::Native
#
#     native def dot(a, b)
#       s = 0.0
#       i = 0
#       while i < a.length
#         s += a[i] * b[i]
#         i += 1
#       end
#       s
#     end
#   end
#
# The method keeps running as plain Ruby until it is first called; the
# argument types of that first call seed Spinel's type inference, the kernel
# is compiled into a CRuby extension (cached on disk), and the method is
# re-bound to the compiled entry. If anything fails the pure-Ruby definition
# stays in place, so the program is never worse off than without the gem.
#
# A module can also keep state inside the kernel between calls:
#
#   module Index
#     extend Spinel::Native
#     native_state { @docs = [] }
#     native "(Array[String]) -> Integer"
#     def load(docs) = (@docs = docs).length
#     native "(Integer) -> String"
#     def doc(i) = @docs[i]
#   end
#
# Such a module is compiled as a whole when its body ends (all its native
# methods must declare signatures), and the Ruby definitions run against the
# module's own ivars, initialised by the same block.
#
# SPINEL_NATIVE=off     never compile, run the Ruby definitions
# SPINEL_NATIVE=verify  run both and raise Spinel::Native::Mismatch on divergence
# SPINEL_NATIVE=strict  a compile failure raises instead of falling back

require "rbconfig"
require "digest"
require "fileutils"
require "prism"

require_relative "native/version"
require_relative "native/types"
require_relative "native/source"
require_relative "native/builder"
require_relative "native/registry"

module Spinel
  module Native
    class Error < StandardError; end
    class CompileError < Error; end
    class TypeError < Error; end
    class Mismatch < Error; end

    class << self
      # :on (default), :off, :verify, :strict
      def mode
        @mode ||= (ENV["SPINEL_NATIVE"] || "on").to_sym
      end
      attr_writer :mode

      def verbose?
        ENV["SPINEL_NATIVE_VERBOSE"] == "1"
      end

      def log(msg)
        warn("[spinel-native] #{msg}") if verbose?
      end

      # Compile every native method of +mod+ whose parameter types are known
      # (from a signature or an earlier call). Useful at boot to pay the
      # compile cost up front and surface errors early.
      def compile!(mod)
        registry_of(mod).compile_known!
      end

      # The registry behind a module that has `extend Spinel::Native`.
      def registry_of(mod)
        mod.instance_variable_get(:@__spinel_native) or
          raise Error, "#{mod} does not extend Spinel::Native"
      end

      def extended(base)
        base.instance_variable_set(:@__spinel_native, Registry.new(base))
        base.singleton_class.prepend(Hooks)
      end
    end

    # Records which `def` ran last so `native def x` knows what it marked.
    module Hooks
      def method_added(name)
        @__spinel_native&.defined(:instance, name)
        super
      end

      def singleton_method_added(name)
        @__spinel_native&.defined(:singleton, name)
        super
      end
    end

    # native_state { @items = []; @sum = 0 }
    #
    # Module-level state that lives inside the compiled kernel across calls
    # (and, for the Ruby fallback, in the module's own ivars). A stateful
    # module is compiled as a whole when its body ends, so every native
    # method in it needs a declared signature.
    def native_state(&block)
      raise ArgumentError, "native_state needs a block" unless block
      @__spinel_native.state(block)
    end

    # native def foo(a, b) ... end          types sampled from the first call
    # native "(Array[Float], Integer) -> Float"; def foo(a, b) ... end
    #                                         types declared, compiled on first call
    def native(arg = nil)
      registry = @__spinel_native
      case arg
      when Symbol then registry.mark(arg)
      when String then registry.pending_signature = Types.parse_signature(arg)
      when nil    then raise ArgumentError, "native: expected `native def ...` or `native \"(...) -> ...\"`"
      else raise ArgumentError, "native: unexpected #{arg.inspect}"
      end
      arg
    end

    # Emit extra top-level source into the compiled kernel, ahead of the marked
    # methods: constants, `Struct.new` state aggregates, and plain helper defs
    # the native methods call. Only `native` methods are pulled from their
    # source files; everything else a kernel needs must be declared here.
    #
    #   native_prelude <<~RUBY
    #     WIDTH = 320
    #     St = Struct.new(:buf, :n)
    #   RUBY
    def native_prelude(source)
      @__spinel_native.add_prelude(source)
      source
    end

    # native_entries :render, :load_map
    #
    # In a stateful kernel, name the methods that are called from Ruby (exported
    # across the extension boundary). Every other native method stays internal
    # to the kernel -- reachable only from native code -- so its parameter and
    # return types need not be boundary types. Without this, every native method
    # is an entry and must have boundary-crossable signatures.
    def native_entries(*names)
      @__spinel_native.set_entries(names)
      names
    end
  end
end
