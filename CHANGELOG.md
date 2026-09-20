# Changelog

## 0.3.1 (2026-09-20)

- Run the kernel with the GVL held. The CRuby shim Spinel emits locks its
  mutex under the GVL and then releases the GVL for the call, which deadlocks
  on the second concurrent call from another Ruby thread (Puma under load).
  Until the shim is fixed upstream, spinel_native rewrites the call site so
  the kernel runs under the GVL; kernels no longer overlap other Ruby threads.
- The build cache key includes the spinel_native version.

## 0.3.0 (2026-09-18)

- `native_entries :a, :b`: in a stateful kernel, name the methods called from
  Ruby (exported across the extension boundary). Every other native method
  stays internal to the kernel, so its parameters and return value need not be
  boundary types and it needs no signature -- letting a real stateful renderer
  keep poly-typed helpers behind a small typed surface. A non-entry method
  called from Ruby runs its Ruby definition on the module's Ruby-side ivars,
  not the kernel state; treat it as private to the kernel.

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
