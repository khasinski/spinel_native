# spinel_native

[![Gem Version](https://badge.fury.io/rb/spinel_native.svg)](https://rubygems.org/gems/spinel_native)
[![CI](https://github.com/khasinski/spinel_native/actions/workflows/ci.yml/badge.svg)](https://github.com/khasinski/spinel_native/actions/workflows/ci.yml)

Compile a single Ruby method to native code with the
[Spinel](https://github.com/matz/spinel) AOT compiler, from inside a running
CRuby program. Mark the hot method, keep everything else on CRuby.

```ruby
require "spinel/native"

module Physics
  extend Spinel::Native

  native def dot(a, b)
    s = 0.0
    i = 0
    while i < a.length
      s += a[i] * b[i]
      i += 1
    end
    s
  end
end

Physics.dot(xs, ys)   # first call: compile + rebind (about 1s, cached on disk)
Physics.dot(xs, ys)   # native
```

That is the whole interface: `native def`. The method stays plain Ruby until
its first call. The argument types of that call seed Spinel's whole-program
type inference, the kernel is compiled into a CRuby extension, and the method
is rebound to the compiled entry. If anything goes wrong the Ruby definition
stays in place and a warning says why.

## Interface

### Mark a method

`native def` is the whole DSL. Types are sampled from the first call.

```ruby
module Physics
  extend Spinel::Native

  native def dot(a, b)
    s = 0.0
    i = 0
    while i < a.length
      s += a[i] * b[i]
      i += 1
    end
    s
  end
end

Physics.dot([1.0, 2.0], [3.0, 4.0])   # => 11.0, compiled on this call
```

In a module the method is also callable as `Physics.dot`, since a native
method never uses `self`. Singleton and instance forms work the same way:

```ruby
module Text
  extend Spinel::Native

  native def self.count_vowels(s)
    n = 0
    s.each_char { |c| n += 1 if "aeiou".include?(c) }
    n
  end
end

class Sieve
  extend Spinel::Native

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

Text.count_vowels("spinel")      # => 2
Sieve.new.count_primes(100)      # => 25
```

Native methods may call each other; everything reachable must be `native`
too, because the kernel is exactly the set of marked methods:

```ruby
module Fractal
  extend Spinel::Native

  native def mandel(cr, ci, limit)
    zr = zi = 0.0
    n = 0
    while n < limit && zr * zr + zi * zi < 4.0
      zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
      n += 1
    end
    n
  end

  native def row(ci, width, limit)
    (0...width).map { |x| mandel(-2.0 + 3.0 * x / width, ci, limit) }
  end
end
```

### Declare the types

A signature on the line before the `def` replaces sampling. The return
type is inferred by Spinel and only checked for shape.

```ruby
module Stats
  extend Spinel::Native

  native "(Array[Float]) -> Float"
  def mean(xs)
    xs.sum / xs.length
  end
end
```

Declared entries can be compiled at boot, so a compile error surfaces
before the first request rather than in the middle of one:

```ruby
Spinel::Native.compile!(Stats)
```

### Keep state between calls

`native_state` gives the module state that lives inside the compiled kernel,
so a large input can be copied in once and queried many times:

```ruby
module Index
  extend Spinel::Native

  native_state do
    @docs = []
  end

  native "(Array[String]) -> Integer"
  def load(docs)
    @docs = docs
    docs.length
  end

  native "(String) -> Array[Integer]"
  def find(word)
    hits = []
    i = 0
    while i < @docs.length
      hits << i if @docs[i].include?(word)
      i += 1
    end
    hits
  end
end

Index.load(corpus)      # copied across once
Index.find("spinel")    # no copy, just the answer
```

A stateful module is one kernel with one state, so it is compiled as a
whole the moment its body ends; there is nothing to call first. Every native
method in it therefore needs a declared signature, and a missing one is
reported when the module closes. The block also runs on the module itself,
so the Ruby definitions (used by `off`, `verify`, and the fallback) start
from the same state. State is per process, not per object: a stateful
module is a singleton, and a forked worker gets its own copy.

### Extra kernel source

Only `native` methods are pulled out of the source file. Constants, `Struct`
definitions, and helpers the kernel needs but that are not entries go in a
`native_prelude`:

```ruby
module Raster
  extend Spinel::Native

  native_prelude <<~RUBY
    WIDTH = 320
    Point = Struct.new(:x, :y)

    def self.clamp(v, lo, hi)
      v < lo ? lo : (v > hi ? hi : v)
    end
  RUBY

  native def pixel(x, y)
    clamp(y, 0, 239) * WIDTH + clamp(x, 0, WIDTH - 1)
  end
end
```

### Choose the entry methods

A stateful module is compiled as one kernel, and by default every native method
is an entry that Ruby can call -- so every one needs a boundary-crossable
signature. `native_entries` names the few methods actually called from Ruby; the
rest stay internal to the kernel, reachable only from other native methods.
Internal methods need no signature and their parameters and return value need
not be boundary types (they may be poly and get boxed) -- which is what lets a
real, mutually-recursive kernel expose a small typed surface:

```ruby
module Renderer
  extend Spinel::Native

  native_state { @fb = Array.new(76800, 0) }
  native_entries :render          # the only method CRuby calls

  native "(Integer, Integer, Float) -> Array[Integer]"
  def render(px, py, angle)
    draw_walls(px, py, angle)     # internal; no signature required
    @fb
  end

  native def draw_walls(px, py, angle) # stays inside the kernel
    # ...
    0
  end
end
```

### Modes

The Ruby definition is always kept. Which path runs is a process-wide
switch, settable from code or from the environment:

```ruby
Spinel::Native.mode = :on       # default: compile on first call, fall back on failure
Spinel::Native.mode = :off      # never compile, run the Ruby definitions
Spinel::Native.mode = :verify   # run both, raise Spinel::Native::Mismatch if they differ
Spinel::Native.mode = :strict   # a compile or type failure raises instead of falling back
```

```sh
SPINEL_NATIVE=verify ruby app.rb     # the Ruby definition is the oracle
SPINEL_NATIVE=off    ruby app.rb     # e.g. in a debugger
```

### Environment

```sh
SPINEL=/path/to/spinel/bin/spinel   # the compiler; otherwise `spinel` on PATH
SPINEL_HDR_DIR=/path/to/lib         # runtime headers, if not next to the binary
SPINEL_NATIVE_CACHE=~/.cache/spinel-native   # where compiled kernels live
SPINEL_NATIVE_VERBOSE=1             # print the commands and timings
```

## Rules for a native method

- Parameters and the return value cross the boundary **by copy**. Supported
  types: `Integer` (64-bit), `Float`, `String`, `bool`, and `Array` of those.
  Mutating a parameter is refused at compile time; return the result instead.
- The body must not touch `self` or anything outside the module's `native`
  methods, its `native_prelude`, and its `native_state` ivars.
- A `raise` inside the kernel arrives in Ruby as the same exception class and
  message. Integer overflow raises `RangeError` where CRuby would promote to a
  Bignum, and a Bignum argument is a `RangeError` at the boundary.
- The kernel runs without the GVL, one call at a time per module, so
  `native_state` needs no locking of its own.

## How it works

1. `Method#source_location` plus Prism pull the `def` back out of its file.
2. The marked methods become `def self.` methods of a synthetic module, with
   a `if __FILE__ == $0` driver that calls each exported entry once with a
   literal of its parameter types (`[0.0]`, `0`, `"x"`). Spinel infers from
   that call site and never runs the driver.
3. `spinel kernel.rb -c --ext cruby --ext-init ... --ext-entry Mod.a,Mod.b`
   emits the kernel C, a header contract, and a CRuby shim that converts
   `VALUE`s, releases the GVL, and re-raises kernel exceptions.
4. The C compiler from `RbConfig` links those with the Spinel runtime into a
   shared object, keyed in the cache by the kernel source, the entries, the
   Spinel binary and the Ruby ABI. The runtime itself is compiled once per
   Spinel build with `-fPIC` (a couple of seconds), since the archive Spinel
   ships is meant for executables. On Linux the object exports only its
   `Init_*` symbol and binds the rest internally, because CRuby loads
   extensions `RTLD_GLOBAL` and two kernels would otherwise share one
   `sp_raise_cls`. `require` loads the object; the method is redefined to
   forward to the extension.

## Install

The gem is on RubyGems:

```sh
gem install spinel_native
```

or in a Gemfile:

```ruby
gem "spinel_native"
```

The gem needs the Spinel compiler at run time, and Spinel is not on RubyGems.
Build it from source once and point the gem at the binary, either through
`SPINEL` or by putting `spinel` on `PATH`:

```sh
git clone https://github.com/matz/spinel && cd spinel && make deps && make
export SPINEL=$PWD/bin/spinel
```

The runtime headers and sources are found next to the binary. If Spinel
was installed elsewhere, `SPINEL_HDR_DIR` names the directory with
`spinel_rt.h`.

## Running the example

```sh
git clone https://github.com/khasinski/spinel_native && cd spinel_native
ruby -I lib examples/demo.rb
bundle exec rake test
```

On an M-series Mac with CRuby master the demo prints roughly:

```
dot(2M floats)       ruby 0.136s  native 0.016s  x8.4
mandel_row(4000)     ruby 0.517s  native 0.013s  x39.6
count_primes(5M)     ruby 0.645s  native 0.072s  x9.0
```

## Status

A proof of concept. Not yet done: shipping the compiled kernel inside a gem
(Spinel's own `spin ext` covers that path), zero-copy numeric buffers, keyword
and block parameters, Hash parameters, and `--int-overflow=promote` parity.
