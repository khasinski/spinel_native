# frozen_string_literal: true

require_relative "lib/spinel/native/version"

Gem::Specification.new do |s|
  s.name = "spinel_native"
  s.version = Spinel::Native::VERSION
  s.summary = "Compile individual Ruby methods to native code with the Spinel AOT compiler"
  s.description = "Mark a hot method with `native def`; on first call it is compiled by Spinel " \
                  "into a CRuby extension and rebound, with the Ruby definition kept as fallback and oracle."
  s.authors = ["Chris Hasiński"]
  s.email = ["krzysztof.hasinski@gmail.com"]
  s.license = "MIT"
  s.homepage = "https://github.com/khasinski/spinel_native"
  s.files = Dir["lib/**/*.rb", "README.md"]
  s.required_ruby_version = ">= 3.4"
  s.add_dependency "prism"
end
