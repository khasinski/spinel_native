# Changelog

## 0.1.0

- `native def` marks a method; its first call samples the argument types,
  compiles the kernel with `spinel --ext cruby`, and rebinds the method.
- `native "(T, ...) -> R"` declares the types instead; `Spinel::Native.compile!`
  builds at boot.
- `SPINEL_NATIVE=off|verify|strict` modes; the Ruby definition stays as
  fallback and oracle.
