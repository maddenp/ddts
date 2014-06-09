DDTS
====

A Ruby-Based Dependency-Driven Test System
### Notes

See the README for general test-suite driver usage; for information on the build, run and suite configuration files; for a description of the library methods; and for other configuration and use information.

DDTS provides a system for composing test suites whose overall activity is driven by simple YAML configuration files. The most general configuration type is the _suite_, which defines one or more sets of runs whose output is expected to be identical. Each named run in these sets corresponds to a _run_ configuration defining runtime parameters for the code under test. Each run configuration depends in turn on a _build_ configuration specifying how binaries should be obtained. Run configurations are assumed to express different configurations of the tested code, e.g. running on different numbers of MPI tasks, or enabling different sets of optional features.

The system ensures the minimum necessary activity. For example, only one build is made on behalf of any number of run configurations sharing the same build type; only one run from an output-identical set contributes its output to the baseline image, when one is being generated; and only the builds and runs necessary to satisfy the top-level suite configuration are performed. The code leverages concurrency for faster results, and tries to respect end users by confining verbose activity traces to a log file and printing only comparatively terse progress messages to the console.

The system is adapted to a specific tested code and runtime platform by providing implementations of a set of methods in library.rb.

A simple example implementation (numerical integration using the trapezoid rule) is provided in the ex directory, along with configuration files and a full set of definitions in ex/library.rb. In a Bourne-family shell, run `DDTSCONF=ex ddts ex_suite` to run the example suite. GNU `tar` and an MPI installation providing `mpif90` and `mpirun` are required.

JRuby Complete 1.7.2 or later is required. Place jruby-complete.jar in the test-suite directory before invoking `ddts`.

See the README for detailed information on configuring DDTS.
