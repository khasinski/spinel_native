# frozen_string_literal: true

module Spinel
  module Native
    # One per module that `extend Spinel::Native`. Tracks the methods marked
    # `native`, keeps their pure-Ruby definitions, and swaps the compiled
    # entries in once their parameter types are known.
    class Registry
      Entry = Struct.new(:name, :kind, :pure, :source, :types, :compiled, :module_function, keyword_init: true)

      attr_accessor :pending_signature
      attr_reader :entries

      def initialize(owner)
        @owner = owner
        @entries = {}
        @last_def = nil
        @installing = false
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
        return pure_call(entry, args, this) if Native.mode == :off
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
        body = @entries.values.map(&:source).join("\n\n")
        builder = Builder.new(body, exports.to_h { |e| [e.name, e.types] })
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
