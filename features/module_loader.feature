Feature: Dynamic module loading lifecycle
  As a library user
  I want to compile, register, load, execute, and release Elixir modules at runtime
  So that I can dynamically extend my application with new behaviour

  Background:
    Given the module loader is running

  Scenario: Load and execute a module
    When I load the module
    Then the module should be loaded
    When I execute add with a=3 and b=4
    Then the result should be 7

  Scenario: Release a loaded module
    When I load the module
    When I release the module
    Then the module should not be loaded
