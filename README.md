# spinel_native

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

- `native def name(args)` marks a method. In a module it is also callable as
  `Mod.name` (it can never use `self`, so the distinction is moot). `native
  def self.name` works too, and so do instance methods of a class.
- `native "(Array[Float], Integer) -> Float"` on the line before a `def`
  declares the parameter types instead of sampling them. The return type is
  inferred by Spinel and only checked for shape.
- `Spinel::Native.compile!(Mod)` compiles every declared entry now, at boot,
  so compile errors surface before the first request.
- `SPINEL_NATIVE=off` runs the Ruby definitions only. `verify` runs both paths
  on every call and raises `Spinel::Native::Mismatch` when they disagree (the
  Ruby definition is the oracle). `strict` turns the silent fallback into a
  raised `CompileError` / `TypeError`. Same knob: `Spinel::Native.mode = :verify`.
- `SPINEL=/path/to/spinel` names the compiler (otherwise `spinel` on PATH),
  `SPINEL_NATIVE_CACHE` the build cache (default `~/.cache/spinel-native`),
  `SPINEL_NATIVE_VERBOSE=1` prints the commands and timings.

## Rules for a native method

- Parameters and the return value cross the boundary **by copy**. Supported
  types: `Integer` (64-bit), `Float`, `String`, `bool`, and `Array` of those.
  Mutating a parameter is refused at compile time; return the result instead.
- The body must not touch `self`, instance variables, or anything outside the
  module. Native methods may call each other; everything reachable must be
  `native` too, because the kernel is exactly the set of marked methods.
- A `raise` inside the kernel arrives in Ruby as the same exception class and
  message. Integer overflow raises `RangeError` where CRuby would promote to a
  Bignum, and a Bignum argument is a `RangeError` at the boundary.
- The kernel runs without the GVL, one call at a time per module.

## How it works

1. `Method#source_location` plus Prism pull the `def` back out of its file.
2. The marked methods become `def self.` methods of a synthetic module, with
   a `if __FILE__ == $0` driver that calls each exported entry once with a
   literal of its parameter types (`[0.0]`, `0`, `"x"`). Spinel infers from
   that call site and never runs the driver.
3. `spinel kernel.rb -c --ext cruby --ext-init ... --ext-entry Mod.a,Mod.b`
   emits the kernel C, a header contract, and a CRuby shim that converts
   `VALUE`s, releases the GVL, and re-raises kernel exceptions.
4. The C compiler from `RbConfig` links those with `libspinel_rt.a` into a
   bundle, keyed in the cache by the kernel source, the entries, the Spinel
   binary and the Ruby ABI. `require` loads it; the method is redefined to
   forward to the extension.

## Install

Spinel is not on RubyGems; build it from source once and point the gem at it:

```sh
git clone https://github.com/matz/spinel && cd spinel && make deps && make
export SPINEL=$PWD/bin/spinel
gem install spinel_native   # or: gem "spinel_native" in the Gemfile
```

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
