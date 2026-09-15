# frozen_string_literal: true

module Spinel
  module Native
    # One per module that `extend Spinel::Native`. Tracks the methods marked
    # `native`, keeps their pure-Ruby definitions, and swaps the compiled
    # entries in once their parameter types are known.
    class Registry
      Entry = Struct.new(:name, :kind, :pure, :source, :types, :compiled, :module_function, keyword_init: true)

      attr_accessor :pending_signature
      attr_reader :entries, :prelude

      def initialize(owner)
        @owner = owner
        @entries = {}
        @prelude = []
        @last_def = nil
        @installing = false
        @state = nil
        @disabled = false
      end

      def stateful?
        !@state.nil?
      end

      # `native_state { ... }`: run the block on the module so the Ruby
      # definitions start from the same state, keep its source for the
      # kernel, and arm a compile of the whole module for when its body ends.
      def state(block)
        raise Error, "#{@owner}: native_state declared twice" if @state
        @state = Source.of_state_block(block)
        @owner.instance_exec(&block)
        owner = @owner
        tp = TracePoint.new(:end) do |ev|
          next unless ev.self.equal?(owner)
          tp.disable
          compile_stateful
        end
        @end_hook = tp
        tp.enable
      end

      # Extra top-level source (constants, Structs, plain helper defs) emitted
      # into the kernel module ahead of the marked methods. The kernel is
      # otherwise exactly the set of `native` methods, so anything they
      # reference by name -- a SCREEN_WIDTH constant, a state Struct, a helper
      # that is not itself an exported entry -- has to be declared here.
      def add_prelude(source)
        @prelude << source.to_s
      end

      # Called from the method_added hooks.
      def defined(kind, name)
        return if @installing
        @last_def = [kind, name]
        return unless @pending_signature
        sig = @pending_signature
        @pending_signature = nil
        mark(name, sig)
      end

      # `native def name` (types nil: sampled from the first call) or a
      # signature-declared entry.
      def mark(name, types = nil)
        kind = @last_def && @last_def[1] == name ? @last_def[0] : :instance
        pure = kind == :singleton ? @owner.method(name) : @owner.instance_method(name)
        entry = Entry.new(name: name, kind: kind, pure: pure, source: Source.of_method(pure), types: types,
                          # in a module, `native def x` is also callable as Mod.x (it never uses self)
                          module_function: kind == :instance && @owner.instance_of?(Module))
        if types && pure.arity != types.length
          raise TypeError, "#{name}: signature has #{types.length} parameter(s), the method takes #{pure.arity}"
        end
        @entries[name] = entry
        install(entry) { |args, this| dispatch(entry, args, this) }
        entry
      end

      def compile_known!
        return compile_stateful ? @entries.values : [] if stateful?
        known = @entries.values.select { |e| e.types && !e.compiled }
        compile(known) unless known.empty?
        known
      end

      # The pure definition, bound like the original call.
      def pure_call(entry, args, this)
        entry.kind == :singleton ? entry.pure.call(*args) : entry.pure.bind_call(this, *args)
      end

      private

      # First call of a not-yet-compiled entry: settle its types, compile the
      # kernel, then either forward or (verify mode) keep comparing.
      def dispatch(entry, args, this)
        return pure_call(entry, args, this) if Native.mode == :off || @disabled
        if stateful?
          # A module without a closing `end` event (Module.new) compiles here instead.
          compile_stateful unless entry.compiled
          return pure_call(entry, args, this) unless entry.compiled
          return native_call(entry, args, this)
        end
        unless entry.compiled
          entry.types ||= args.map { |a| Types.of_value(a) }
          compile(@entries.values.select { |e| e.types && !e.compiled })
        end
        return pure_call(entry, args, this) unless entry.compiled
        native_call(entry, args, this)
      rescue Native::TypeError, CompileError => e
        raise if Native.mode == :strict
        warn "[spinel-native] #{@owner}##{entry.name}: staying on Ruby (#{e.message.lines.first.strip})"
        entry.types = nil
        install(entry) { |a, t| pure_call(entry, a, t) }
        pure_call(entry, args, this)
      end

      # A stateful module is one kernel with one state, so it is compiled in
      # full, once: every native method must carry a declared signature. Runs
      # when the module body ends, or at the first call if that never fires.
      # Returns true when the module is now native.
      def compile_stateful
        @end_hook&.disable
        return false if @disabled || Native.mode == :off
        return true if @entries.values.all?(&:compiled) && !@entries.empty?
        untyped = @entries.values.reject(&:types).map(&:name)
        unless untyped.empty?
          raise Native::TypeError, "#{@owner} keeps state, so every native method needs a signature; missing: #{untyped.join(', ')}"
        end
        compile(@entries.values)
        true
      rescue Native::TypeError, CompileError => e
        raise if Native.mode == :strict
        warn "[spinel-native] #{@owner}: staying on Ruby (#{e.message.lines.first.strip})"
        @disabled = true
        @entries.each_value { |entry| install(entry) { |a, t| pure_call(entry, a, t) } }
        false
      end

      def native_call(entry, args, this)
        got = entry.compiled.public_send(entry.name, *args)
        if Native.mode == :verify
          want = pure_call(entry, args, this)
          unless want == got || (want.is_a?(Float) && got.is_a?(Float) && want.nan? && got.nan?)
            raise Mismatch, "#{@owner}##{entry.name}(#{args.map(&:inspect).join(', ')}): ruby=#{want.inspect} native=#{got.inspect}"
          end
        end
        got
      end

      # Every marked method goes into the kernel (they may call each other);
      # the ones with known types are exported.
      def compile(exports)
        body = (@prelude + @entries.values.map(&:source)).join("\n\n")
        builder = Builder.new(body, exports.to_h { |e| [e.name, e.types] }, state: @state)
        result = builder.build
        mod = Object.const_get(result.module_name)
        exports.each do |e|
          e.compiled = mod
          if Native.mode == :verify
            install(e) { |args, this| native_call(e, args, this) }
          else
            install(e) { |args, _this| mod.public_send(e.name, *args) }
          end
        end
        Native.log("#{@owner}: #{exports.map { |e| "#{e.name}(#{e.types.map { |t| Types.to_s(t) }.join(', ')})" }.join(', ')} " \
                   "#{result.cached ? 'loaded from cache' : 'compiled'} in #{result.seconds.round(2)}s (#{result.dir})")
      end

      def install(entry, &body)
        @installing = true
        target = entry.kind == :singleton ? @owner.singleton_class : @owner
        redefine(target, entry.name) { |*args| body.call(args, self) }
        redefine(@owner.singleton_class, entry.name) { |*args| body.call(args, self) } if entry.module_function
      ensure
        @installing = false
      end

      # define_method over an existing definition warns under -w; drop it first.
      def redefine(target, name, &impl)
        target.send(:remove_method, name) if target.method_defined?(name, false) || target.private_method_defined?(name, false)
        target.send(:define_method, name, &impl)
      end
    end
  end
end
