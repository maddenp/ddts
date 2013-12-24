DDTS
====

A Ruby-Based Dependency-Driven Test Suite system

### Notes

See _README_ for general test-suite driver usage (or run `ddts help`); for information on the build, run and suite configuration files; and for a description of the _library.rb_ and _profiles.rb_ files.

DDTS provides a system for composing test suites whose overall activity is driven by simple YAML configuration files. The most general configuration type is the _suite_, which defines one or more sets of runs whose output is expected to be identical. Each named run in these sets corresponds to a _run_ configuration defining runtime parameters for the code under test. Each run configuration depends in turn on a _build_ configuration specifying how binaries should be obtained. Run configurations are assumed to express different configurations of the tested code, e.g. running on different numbers of MPI tasks, or enabling different sets of optional features.

The system ensures the minimum necessary activity. For example, only one build is made on behalf of any number of run configurations sharing the same build type; only one run from an output-identical set contributes its output to the baseline image, when one is being generated; and only the builds and runs necessary to satisfy the top-level suite configuration are performed. The code leverages concurrency for faster results, and tries to respect end users by confining verbose activity traces to a log file and printing only comparatively terse progress messages to the console.

The system is adapted to a specific tested code and runtime platform by providing implementations of a set of required methods in _library.rb_. Modules in _profiles.rb_ may be used to alias default method names to preferred implementations, for platform portability: The core driver always calls the default method names, but these may be redirected to alternatives.

A simple example implementation (numerical integration using the trapezoid rule) is provided in the _ex_ directory, along with configuration files and a full set of definitions in _library.rb_ and _profiles.rb_. Run `DDTSCONF=ex ddts ex_suite` to run the example suite. GNU `tar` and an MPI installation providing `mpif90` and `mpirun` are required.

JRuby Complete 1.7.2 or later is required. Place _jruby-complete.jar_ in the test-suite directory before invoking `ddts`.

See the _README_ for detailed information on configuring DDTS.

### License

The contents of this repository are released under the [Apache 2.0](http://www.apache.org/licenses/LICENSE-2.0) license. See the LICENSE file for details.
