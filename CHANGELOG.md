# Changelog

## 0.2.0 (2026-09-16)

- `native_state { ... }`: module state kept inside the compiled kernel
  across calls. A stateful module is compiled as a whole when its body ends
  and needs a signature on every native method; the block also initialises
  the Ruby definitions' ivars.
- `native_prelude`: constants, Structs and helper defs emitted into the
  kernel ahead of the native methods.

## 0.1.0 (2026-09-15)

First release on RubyGems.

- `native def` marks a method; its first call samples the argument types,
  compiles the kernel with `spinel --ext cruby`, and rebinds the method.
- `native "(T, ...) -> R"` declares the types instead; `Spinel::Native.compile!`
  builds at boot.
- `SPINEL_NATIVE=off|verify|strict` modes; the Ruby definition stays as
  fallback and oracle.
