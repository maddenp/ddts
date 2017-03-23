DDTS
====
[![Build Status](https://travis-ci.org/maddenp/ddts.svg?branch=master)](https://travis-ci.org/maddenp/ddts)

A Ruby-Based Dependency-Driven Test System
### Notes

See the README for general test-suite driver usage; for information on the build, run and suite definition files; for a description of the library methods; and for other configuration and use information.

DDTS provides a system for composing test suites whose overall activity is driven by simple YAML definition files. The most general definition type is the _suite_, which defines one or more groups of runs whose output is expected to be identical. Each named run in these groups corresponds to a _run_ definition specifying runtime parameters for the code under test. Each run definition depends in turn on a _build_ definition specifying how binaries should be obtained. Run definitions are assumed to express different configurations of the tested code, e.g. running on different numbers of MPI tasks, or enabling different sets of optional features.

The system ensures the minimum necessary activity. For example, only one build is made on behalf of any number of run definitions sharing the same build type; only one run from an output-identical set contributes its output to a baseline, when one is being generated; and only the builds and runs necessary to satisfy the top-level suite definition are performed. The code leverages concurrency for faster results, and tries to respect end users by confining verbose activity traces to a log file and printing only comparatively terse progress messages to the console.

The system is adapted to a specific tested code and runtime platform by providing implementations of a set of methods in _library.rb_.

A simple example implementation (numerical integration using the trapezoid rule) is provided in the _ex_ directory, along with definition files and a full set of definitions in _ex/library.rb_ (a graph image showing the ancestry relationships between the run definitions can be found in _ex/rundefs.png_). In a Bourne-family shell, run `DDTSAPP=ex ddts ex_suite` to run the example suite. GNU `tar` and an MPI installation providing `mpif90` and `mpirun` on your path are required.

DDTS is currently testing with JRuby Complete 9.1.5.0. Other versions may or may not work.

See the README for detailed information on configuring DDTS.
