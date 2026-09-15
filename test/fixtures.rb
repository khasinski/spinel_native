# frozen_string_literal: true

module Fixtures
  module Calc
    extend Spinel::Native

    native def twice(n)
      n * 2
    end

    native def self.greet(who)
      "hi " + who
    end

    native def dot(a, b)
      s = 0.0
      i = 0
      while i < a.length
        s += a[i] * b[i]
        i += 1
      end
      s
    end

    native def doubled(xs)
      out = []
      xs.each { |x| out << x * 2 }
      out
    end

    native def checked_sqrt(x)
      raise ArgumentError, "negative input" if x < 0.0
      Math.sqrt(x)
    end
  end

  module Declared
    extend Spinel::Native

    native "(Integer) -> Integer"
    def fib(n)
      n < 2 ? n : fib(n - 1) + fib(n - 2)
    end
  end

  module Fallback
    extend Spinel::Native

    native def identity(h)
      h
    end

    native def strict_identity(h)
      h
    end
  end

  module Verified
    extend Spinel::Native

    native def triple(n)
      n * 3
    end
  end

  module Off
    extend Spinel::Native

    native def plus_one(n)
      n + 1
    end
  end
end
