# frozen_string_literal: true

require "minitest/autorun"
require "spinel/native"
require_relative "fixtures"

class TypesTest < Minitest::Test
  T = Spinel::Native::Types

  def test_parse_signature
    assert_equal [[:array, :float], :int], T.parse_signature("(Array[Float], Integer) -> Float")
    assert_equal [], T.parse_signature("() -> bool")
  end

  def test_rejects_unsupported
    assert_raises(Spinel::Native::TypeError) { T.parse_signature("(Hash[String, Integer]) -> Integer") }
    assert_raises(Spinel::Native::TypeError) { T.parse_signature("(Array[Array[Integer]]) -> Integer") }
    assert_raises(Spinel::Native::TypeError) { T.of_value([]) }
    assert_raises(Spinel::Native::TypeError) { T.of_value([1, "a"]) }
    assert_raises(Spinel::Native::TypeError) { T.of_value(nil) }
  end

  def test_of_value_and_witness
    assert_equal [:array, :float], T.of_value([1.0, 2.0])
    assert_equal "[0.0]", T.witness([:array, :float])
    assert_equal '"x"', T.witness(:str)
  end
end

class SourceTest < Minitest::Test
  def test_extracts_def_as_module_function
    src = Spinel::Native::Source.of_method(Spinel::Native.registry_of(Fixtures::Calc).entries[:twice].pure)
    assert_match(/\Adef self\.twice\(n\)/, src)
    assert_match(/n \* 2/, src)
    assert_match(/end\z/, src)
  end

  def test_singleton_def_keeps_name
    src = Spinel::Native::Source.of_method(Spinel::Native.registry_of(Fixtures::Calc).entries[:greet].pure)
    assert_match(/\Adef self\.greet\(who\)/, src)
  end
end

class CompileTest < Minitest::Test
  def setup
    Spinel::Native.mode = :strict
  end

  def test_compiles_and_matches_ruby
    assert_equal 42, Fixtures::Calc.twice(21)
    assert_equal 42, Fixtures::Calc.twice(21)
    entry = Spinel::Native.registry_of(Fixtures::Calc).entries[:twice]
    refute_nil entry.compiled, "twice should be bound to a compiled kernel after the first call"
    assert_equal [:int], entry.types
  end

  def test_module_function_and_instance_forms
    o = Object.new.extend(Fixtures::Calc)
    assert_equal 6, o.twice(3)
    assert_equal "hi bob", Fixtures::Calc.greet("bob")
  end

  def test_arrays_cross_by_copy
    a = [1.0, 2.0, 3.0]
    assert_equal 14.0, Fixtures::Calc.dot(a, a)
    assert_equal [2, 4, 6], Fixtures::Calc.doubled([1, 2, 3])
    assert_equal [1.0, 2.0, 3.0], a, "the caller's array is untouched"
  end

  def test_kernel_raise_crosses_as_ruby_exception
    err = assert_raises(ArgumentError) { Fixtures::Calc.checked_sqrt(-1.0) }
    assert_match(/negative/, err.message)
    assert_equal 3.0, Fixtures::Calc.checked_sqrt(9.0)
  end

  def test_bignum_argument_is_a_range_error
    assert_raises(RangeError) { Fixtures::Calc.twice(2**70) }
  end

  def test_declared_signature_compiles_eagerly
    entries = Spinel::Native.compile!(Fixtures::Declared)
    assert_equal [:fib], entries.map(&:name)
    assert_equal 55, Fixtures::Declared.fib(10)
  end

  def test_unsupported_argument_falls_back_in_default_mode
    Spinel::Native.mode = :on
    out, err = capture_io { assert_equal({ a: 1 }, Fixtures::Fallback.identity({ a: 1 })) }
    assert_match(/staying on Ruby/, err)
    assert_equal "", out
    assert_nil Spinel::Native.registry_of(Fixtures::Fallback).entries[:identity].compiled
  end

  def test_unsupported_argument_raises_in_strict_mode
    assert_raises(Spinel::Native::TypeError) { Fixtures::Fallback.strict_identity({ a: 1 }) }
  end

  def test_verify_mode_runs_both_paths
    Spinel::Native.mode = :verify
    assert_equal 12, Fixtures::Verified.triple(4)
    assert_equal 0, Fixtures::Verified.triple(0)
  end

  def test_off_mode_never_compiles
    Spinel::Native.mode = :off
    assert_equal 5, Fixtures::Off.plus_one(4)
    assert_nil Spinel::Native.registry_of(Fixtures::Off).entries[:plus_one].compiled
  end
end

class StateTest < Minitest::Test
  def test_stateful_module_compiles_when_its_body_ends
    entries = Spinel::Native.registry_of(Fixtures::Counter).entries
    assert entries.values.all?(&:compiled), "Counter should be compiled without any call"
  end

  def test_state_persists_across_calls
    Spinel::Native.mode = :strict
    before = Fixtures::Counter.total
    Fixtures::Counter.add(5)
    Fixtures::Counter.add(7)
    assert_equal before + 12, Fixtures::Counter.total
    assert_equal [5, 7], Fixtures::Counter.seen.last(2)
  end

  def test_ruby_side_state_is_initialised_by_the_same_block
    reg = Spinel::Native.registry_of(Fixtures::Counter)
    total = reg.entries[:total]
    assert_kind_of Integer, reg.pure_call(total, [], Fixtures::Counter)
  end

  def test_verify_mode_keeps_both_states_in_step
    Spinel::Native.mode = :verify
    Fixtures::Counter.add(1)
    assert_equal Fixtures::Counter.total, Fixtures::Counter.total
  end

  def test_untyped_stateful_module_stays_on_ruby
    Spinel::Native.mode = :on
    # the warning was printed when the module body ended; the Ruby definitions still work
    assert_equal 1, Fixtures::Untyped.bump
    assert_equal 2, Fixtures::Untyped.bump
    assert_nil Spinel::Native.registry_of(Fixtures::Untyped).entries[:bump].compiled
  end
end

class PreludeTest < Minitest::Test
  def test_prelude_source_is_part_of_the_kernel
    Spinel::Native.mode = :strict
    assert_equal 31, Fixtures::WithPrelude.scaled(3)
    refute_nil Spinel::Native.registry_of(Fixtures::WithPrelude).entries[:scaled].compiled
  end
end

class NativeEntriesTest < Minitest::Test
  def test_only_named_methods_are_entries_and_internals_need_no_signature
    Spinel::Native.mode = :strict
    # run(2) = step(2)*2 = (2*3+1)*2 = 14; the module compiled although the
    # internal helper `step` carries no signature.
    assert_equal 14, Fixtures::Entried.run(2)
    reg = Spinel::Native.registry_of(Fixtures::Entried)
    refute_nil reg.entries[:run].compiled, "run is an exported entry"
  end
end

class ConcurrencyTest < Minitest::Test
  # Two Ruby threads calling a kernel at once must not deadlock (the shim's
  # mutex-then-release-GVL order did, before keep_gvl).
  def test_concurrent_calls_from_ruby_threads
    Spinel::Native.mode = :strict
    Fixtures::Calc.twice(1)
    results = 8.times.map { |i| Thread.new { 200.times.map { |j| Fixtures::Calc.twice(i * 1000 + j) } } }.map { |t| t.join(20) or flunk "deadlocked" }.map(&:value)
    assert_equal 8, results.size
    assert_equal (0...200).map { |j| (7 * 1000 + j) * 2 }, results.last
  end
end
