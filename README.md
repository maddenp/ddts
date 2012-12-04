ddts
====

A Ruby-Based Dependency-Driven Test Suite system

### Notes

Please see _README_ for general test-suite driver usage (or run `ts help`); _README.conf_ for information on the build, run and suite configuration files; and _README.library_ for a description of the _library.rb_ and _profiles.rb_ files.

This code provides a system for composing test suites whose overall activity is driven by simple configuration files (in the _conf_ directory). The most abstract configuration type is the _suite_, which defines one or more sets of runs whose output is expected to be identical. Each named run in these sets corresponds to a _run_ configuration defining runtime parameters for the tested code. Each run configuration depends in turn on a _build_ configuration specifying how binaries should be obtained. Run configurations are assumed to express different configurations of the tested code, e.g. running on different numbers of MPI tasks, or enabling different sets of optional features.

The system ensures the minimum necessary activity. For example, only one build is made on behalf of any number of run configurations sharing the same build type; only one run from an output-identical set contributes its output to the baseline image (when one is being generated); and only the builds and runs necessary to satisfy the top-level suite configuration are performed. The code uses concurrency where possible, and tries to respect end uses by confining verbose blow-by-blow activity traces to a log file and printing only terse progress messages to the console.

The system is adapted to a specific tested code and runtime platform by providing implementations of a set of required methods in _library.rb_. Modules in _profiles.rb_ allow one to override default method names for platform portability: While the test-suite driver code will always call the default method names, these may be aliased to alternatives.

A simple example code (numerical integration using the trapezoid rule) is provided in the _ex_ directory, along with configuration files and a full set of definitions in _library.rb_ and _profiles.rb_. Run `ts` to run the example suite. Requirements: GNU `tar` and an MPI installation providing `mpif90` and `mpirun`.

Ruby 1.9.x is required. It has mainly been used under JRuby.

### License

The contents of this repository are released under the [Apache 2.0](http://www.apache.org/licenses/LICENSE-2.0) license. See the LICENSE file for details.
