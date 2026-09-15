# frozen_string_literal: true

require "open3"
require "shellwords"

module Spinel
  module Native
    # Turns a kernel (a module of `def self.` methods plus a witness driver)
    # into a loaded CRuby extension:
    #
    #   spinel kernel.rb -c --ext cruby --ext-init ... --ext-entry Mod.a,Mod.b
    #   cc -bundle kernel.c kernel_ext.c libspinel_rt.a
    #   require kernel.bundle
    #
    # Builds are cached under SPINEL_NATIVE_CACHE (default ~/.cache/spinel-native)
    # keyed by the kernel source, the exported entries, the spinel binary and
    # the Ruby ABI, so a repeated run of the same program compiles nothing.
    class Builder
      Result = Struct.new(:module_name, :bundle, :dir, :cached, :seconds)

      class << self
        def spinel_bin
          @spinel_bin ||= begin
            env = ENV["SPINEL"].to_s
            found = env.empty? ? which("spinel") : env
            raise Error, "spinel compiler not found: set SPINEL=/path/to/spinel or put it on PATH" if found.to_s.empty?
            File.realpath(found)
          end
        end

        # The runtime headers and archive ship beside the compiler: <root>/bin/spinel, <root>/lib.
        def runtime_dir
          @runtime_dir ||= begin
            env = ENV["SPINEL_HDR_DIR"].to_s
            candidates = [env, File.expand_path("../lib", File.dirname(spinel_bin)),
                          File.expand_path("lib", File.dirname(spinel_bin))]
            candidates.find { |d| !d.empty? && File.exist?(File.join(d, "spinel_rt.h")) } or
              raise Error, "spinel runtime (spinel_rt.h) not found next to #{spinel_bin}; set SPINEL_HDR_DIR"
          end
        end

        def cache_dir
          ENV["SPINEL_NATIVE_CACHE"] || File.join(ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache"), "spinel-native")
        end

        def which(cmd)
          ENV["PATH"].split(File::PATH_SEPARATOR).each do |d|
            p = File.join(d, cmd)
            return p if File.executable?(p) && !File.directory?(p)
          end
          nil
        end

        def fingerprint
          @fingerprint ||= begin
            st = File.stat(spinel_bin)
            Digest::SHA256.hexdigest([st.size, st.mtime.to_i, RUBY_VERSION, RUBY_PLATFORM, RbConfig::CONFIG["CC"]].join("|"))
          end
        end
      end

      # +body+ is the module body (the `def self.` methods), +entries+ maps the
      # exported names to their parameter types.
      def initialize(body, entries)
        @body = body
        @entries = entries
        digest = Digest::SHA256.hexdigest([self.class.fingerprint, body, entries.inspect].join("\0"))[0, 12]
        @module_name = "SpinelKernel#{digest}"
        @feature = "spinel_kernel_#{digest}"
        @dir = File.join(self.class.cache_dir, @feature)
      end

      attr_reader :module_name, :feature, :dir

      def kernel_source
        witness = @entries.map do |name, types|
          "  #{@module_name}.#{name}(#{types.map { |t| Types.witness(t) }.join(', ')})"
        end
        <<~RUBY
          module #{@module_name}
          #{@body.gsub(/^/, "  ")}
          end

          if __FILE__ == $0
          #{witness.join("\n")}
          end
        RUBY
      end

      def bundle
        File.join(@dir, "#{@feature}.#{RbConfig::CONFIG['DLEXT']}")
      end

      def build
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cached = File.exist?(bundle)
        unless cached
          FileUtils.mkdir_p(@dir)
          File.write(File.join(@dir, "kernel.rb"), kernel_source)
          run_spinel
          run_cc
        end
        require bundle
        Result.new(@module_name, bundle, @dir, cached, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
      end

      private

      def run_spinel
        entry_list = @entries.keys.map { |n| "#{@module_name}.#{n}" }.join(",")
        cmd = [self.class.spinel_bin, File.join(@dir, "kernel.rb"), "-c", "--no-line-map",
               "--ext", "cruby", "--ext-init", "spx_init_#{@feature}", "--ext-entry", entry_list,
               "-o", File.join(@dir, "#{@feature}.c")]
        sh(cmd, "spinel")
      end

      def run_cc
        cc = Shellwords.split(RbConfig::CONFIG["CC"] || "cc")
        shared = RUBY_PLATFORM.include?("darwin") ? %w[-bundle -Wl,-undefined,dynamic_lookup] : %w[-shared]
        cmd = [*cc, *shared, "-fPIC", "-O2", "-w",
               "-I#{RbConfig::CONFIG['rubyhdrdir']}", "-I#{RbConfig::CONFIG['rubyarchhdrdir']}",
               "-I#{self.class.runtime_dir}", "-I#{@dir}",
               File.join(@dir, "#{@feature}.c"), File.join(@dir, "#{@feature}_ext.c"),
               File.join(self.class.runtime_dir, "libspinel_rt.a"), "-lm", "-o", bundle]
        sh(cmd, "cc")
      end

      def sh(cmd, what)
        Native.log(cmd.join(" "))
        out, status = Open3.capture2e(*cmd)
        File.write(File.join(@dir, "#{what}.log"), out)
        return if status.success?
        FileUtils.rm_f(bundle)
        raise CompileError, "#{what} failed (exit #{status.exitstatus}) building #{@dir}:\n#{out}"
      end
    end
  end
end
