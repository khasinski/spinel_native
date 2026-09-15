# frozen_string_literal: true

# ruby -I lib examples/demo.rb
require "benchmark"
require "spinel/native"

module Physics
  extend Spinel::Native

  # Types are sampled from the first call.
  native def dot(a, b)
    s = 0.0
    i = 0
    while i < a.length
      s += a[i] * b[i]
      i += 1
    end
    s
  end

  # Or declared, so the kernel can be compiled before the first call.
  native "(Float, Float, Integer) -> Integer"
  def mandel(cr, ci, limit)
    zr = 0.0
    zi = 0.0
    n = 0
    while n < limit && zr * zr + zi * zi < 4.0
      t = zr * zr - zi * zi + cr
      zi = 2.0 * zr * zi + ci
      zr = t
      n += 1
    end
    n
  end

  # Native methods may call each other; everything reachable must be native too.
  native def mandel_row(ci, width, limit)
    out = []
    x = 0
    while x < width
      out << mandel(-2.0 + 3.0 * x / width, ci, limit)
      x += 1
    end
    out
  end
end

class Sieve
  extend Spinel::Native

  # Instance methods work too; they must not touch ivars or self.
  native def count_primes(n)
    flags = Array.new(n + 1, true)
    count = 0
    i = 2
    while i <= n
      if flags[i]
        count += 1
        j = i * i
        while j <= n
          flags[j] = false
          j += i
        end
      end
      i += 1
    end
    count
  end
end

a = Array.new(2_000_000) { |i| i * 0.5 }

Spinel::Native.mode = :off
t_ruby = Benchmark.realtime { 3.times { Physics.dot(a, a) } } / 3
p_ruby = Benchmark.realtime { Physics.mandel_row(0.1, 4000, 2000) }
s_ruby = Benchmark.realtime { Sieve.new.count_primes(5_000_000) }

Spinel::Native.mode = :on
Physics.dot(a, a) # first call compiles (or loads from cache)
Physics.mandel_row(0.1, 4, 10)
Sieve.new.count_primes(10)
t_nat = Benchmark.realtime { 3.times { Physics.dot(a, a) } } / 3
p_nat = Benchmark.realtime { Physics.mandel_row(0.1, 4000, 2000) }
s_nat = Benchmark.realtime { Sieve.new.count_primes(5_000_000) }

puts "dot(2M floats)       ruby %.3fs  native %.3fs  x%.1f" % [t_ruby, t_nat, t_ruby / t_nat]
puts "mandel_row(4000)     ruby %.3fs  native %.3fs  x%.1f" % [p_ruby, p_nat, p_ruby / p_nat]
puts "count_primes(5M)     ruby %.3fs  native %.3fs  x%.1f" % [s_ruby, s_nat, s_ruby / s_nat]
Spinel::Native.mode = :off
ruby_dot = Physics.dot(a, a)
Spinel::Native.mode = :on
puts "results agree: #{Physics.dot(a, a) == ruby_dot && Sieve.new.count_primes(100) == 25 && Physics.mandel(0.0, 0.0, 50) == 50}"
