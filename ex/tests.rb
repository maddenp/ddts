require 'fileutils'

def die(msg)
  puts msg
  exit 1
end

def exe(desc,suite,*expected)

  # Arguments are:
  #
  #   1. desc, a short description of the test to print on the console
  #   2. suite, the full set of arguments to ddts
  #   3.-? One or more strings expected to be found in the suite's output
  #
  # The 'expected' strings are escaped, so regexp characters will be
  # treated literally.

  expected.map! { |e| [e,Regexp::escape(e)] }
  print "Testing: #{desc}"+" "*(78-desc.length)
  ddts=File.join("..","ddts")
  cmd="DDTSAPP=. DDTSOUT=#{$OUT} #{ddts} #{suite} 2>&1"
  out=`#{cmd}`.split("\n")
  expected.each do |pair|
    string=pair.first
    re_str=pair.last
    if out.grep(/.*#{re_str}.*/).empty?
      puts "FAILED\n"
      puts "\nCommand was:\n\n#{cmd}"
      puts "\nExpected to see:\n\n#{string}"
      die "\nIn output:\n\n#{out.join("\n")}"
    end
  end
  puts "ok"
end

# Set some variables.

$OUT="tests_out"
baseline=File.join($OUT,"baseline")
sentinel=File.join($OUT,"builds","ex_build","sentinel")

# Create a directory for test detritus.

FileUtils.mkdir_p($OUT)

# Delete any existing baseline.

FileUtils.rm_rf(baseline)

# ex_suite_single executes the single ex_4 run, which is expected to pass.

exe("ex_suite_single","ex_suite_single",
  "Run ex_4: Completed",
  "ALL TESTS PASSED",
  "build fail rate = 0.0"
  )

# ex_suite_fail executes the single ex_fail run, which is expected to fail.

exe("ex_suite_fail","ex_suite_fail",
  "Run ex_fail: ERROR: Run failed",
  "Test suite 'ex_suite_fail' FAILED"
  )

# ex_suite_build_only uses the suite-level 'build_only' setting to perform only
# the required build, without performing any runs.

exe("ex_suite_build_only","ex_suite_build_only",
  "Build ex_build completed",
  "ALL TESTS PASSED"
  )

# ex_suite_retain_builds uses the suite-level 'retain_builds' setting to avoid
# deleting existing builds. Create a sentinel file in the build directory, run
# the suite, then check that the sentinel is still there to prove that the old
# build was not deleted.

FileUtils.touch(sentinel)
die "Sentinel file '#{sentinel}' was not created" unless File.exist?(sentinel)
exe("ex_suite_retain_builds","ex_suite_retain_builds",
  "Comparison: ex_1, ex_1_alt, ex_2, ex_4: OK",
  "ALL TESTS PASSED"
  )
die "Sentinel file '#{sentinel}' missing!" unless File.exist?(sentinel)

# ex_suite executes four runs -- also create a baseline here.

exe("ex_suite (gen baseline pass)","gen-baseline #{baseline} ex_suite",
  "Creating ex_baseline baseline: OK",
  "ALL TESTS PASSED"
  )

# Retry baseline creation -- it should fail.

exe("ex_suite (gen baseline fail)","gen-baseline #{baseline} ex_suite",
  "Run 'ex_1' could overwrite baseline 'ex_baseline'",
  "Test suite 'ex_suite' FAILED"
  )

# Execute ex_suite again and verify against baseline.

exe("ex_suite use-baseline","use-baseline #{baseline} ex_suite",
  "Run ex_1: Baseline comparison OK",
  "with alternate comparator",
  "Comparison: ex_1, ex_1_alt, ex_2, ex_4: OK",
  "ALL TESTS PASSED"
  )

# ex_suite_1p_1f executes two runs in one group, where one fails. The successful
# run has nothing to compare to, so comparison is skipped.

exe("ex_suite_1p_1f","ex_suite_1p_1f",
  "Group stats: 1 of 2 runs failed, skipping comparison",
  "Suite stats: Failure in 1 of 1 group(s)",
  "Failure in 1 of 1 group(s)",
  "run fail rate = 0.5"
  )

# ex_suite_2p_1f executes three runs in one group, where one fails. The two
# successful runs are compared.

exe("ex_suite_2p_1f","ex_suite_2p_1f",
  "Comparison: ex_1, ex_2: OK",
  "Suite stats: Failure in 1 of 1 group(s)",
  "1 of 3 TEST(S) FAILED"
  )

# ex_suite_3p_1f executes four runs, two in each of two groups. One run fails.
# Comparison is skipped in the group with the failed run, and an alternate
# comparator is used for the other group.

exe("ex_suite_3p_1f","ex_suite_3p_1f",
  "Group stats: 1 of 2 runs failed, skipping comparison",
  "alternate comparator",
  "Comparison: ex_1, ex_2: OK",
  "Suite stats: Failure in 1 of 2 group(s)",
  "1 of 4 TEST(S) FAILED"
  )

# ex_suite_mismatch_stop contains a run that produces output different from the
# other runs', so that comparison fails. Here, 'continue' is false and a
# baseline is used, so the suite fails on baseline comparison of the oddball
# run.

die "Cannot find 'baseline'" unless File.exist?(baseline)
exe("ex_suite_mismatch_stop (with baseline)","use-baseline #{baseline} ex_suite_mismatch_stop",
  "Run ex_4_bad: ERROR: Comparison failed (ex_4_bad vs baseline ex_baseline)",
  "Test suite 'ex_suite_mismatch_stop' FAILED"
  )

# Same as previous test, but without baseline comparison, so that the suite
# fails on run-vs-run comparison.

exe("ex_suite_mismatch_stop (no baseline)","ex_suite_mismatch_stop",
  "Comparison: ERROR: Comparison failed (ex_2 vs ex_4_bad)",
  "Test suite 'ex_suite_mismatch_stop' FAILED"
  )

# Same as previous test, but 'continue' is true so that the suite completes.

exe("ex_suite_mismatch_continue","ex_suite_mismatch_continue",
  "ERROR: Comparison failed (ex_2 vs ex_4_bad)",
  "Suite stats: Failure in 1 of 2 group(s)",
  "0 of 4 TEST(S) FAILED"
  )

# Remove baseline

FileUtils.rm_rf(baseline)

# Single run, generate baseline

exe("ex_1 gen baseline","run gen-baseline #{baseline} ex_1",
  "Run ex_1: Completed",
  "Creating ex_baseline baseline: OK"
  )

# Single run, generate baseline (fail due to conflict)

exe("ex_1 gen baseline (conflict)","run gen-baseline #{baseline} ex_1",
  "Run 'ex_1' could overwrite baseline 'ex_baseline'",
  "Aborting..."
  )

# Single run, use baseline

exe("ex_1 use baseline","run use-baseline #{baseline} ex_1",
  "Comparing to baseline ex_baseline",
  "Baseline comparison OK"
  )

# Single run with unsatisfied 'require'.

exe("ex_2_require_scalar fail","run ex_2_require_scalar",
  "Run 'ex_2_require_scalar' depends on unscheduled run 'ex_1'",
  "Aborting..."
  )

# Suite with satisfied 'require', scalar version

exe("ex_suite_require_pass_1","ex_suite_require_pass_1",
  "Waiting on required run: ex_1",
  "Run ex_2_require_scalar: Completed",
  "ALL TESTS PASSED"
  )

# Suite with satisfied 'require', array version

exe("ex_suite_require_pass_2","ex_suite_require_pass_2",
  "Waiting on required run: ex_1",
  "Run ex_2_require_array: Completed",
  "ALL TESTS PASSED"
  )

# Suite with unsatisfied 'require' (unscheduled run)

exe("ex_suite_require fail_1 (unscheduled run)","ex_suite_require_fail_1",
  "Run 'ex_2_require_array' depends on unscheduled run 'ex_1'",
  "Test suite 'ex_suite_require_fail_1' FAILED"
  )

# Suite with unsatisfied 'require' (failed run)

exe("ex_suite_require fail_2 (failed run)","ex_suite_require_fail_2",
  "Run 'ex_2_require_fail' depends on failed run 'ex_fail'",
  "2 of 2 TEST(S) FAILED"
  )

# Suite with a failed build, no continue

exe("ex_suite_build_fail","ex_suite_build_fail",
  "Build ex_build_fail started",
  "Build failed",
  "Test suite 'ex_suite_build_fail' FAILED"
  )

# Suite with a failed build, with continue

exe("ex_suite_build_fail_continue","ex_suite_build_fail_continue",
  "Build ex_build_fail started",
  "Build failed",
  "1 of 2 TEST(S) FAILED",
  "build fail rate = 0.5",
  "run fail rate = 0.5"
  )

# Run with no build specified

exe("ex_no_build","run ex_no_build",
  "ERROR: Run 'ex_no_build' not associated with any build"
  )

# Run with non-existent build specified

exe("ex_bad_build","run ex_bad_build",
  "ERROR: Run 'ex_bad_build' associated with missing or abstract build 'no_such_build'"
  )

# Test !replace yaml tag

exe("ex_1_alt !replace test","run ex_1_alt",
  ": Running case ex_1_alt"
  )

# Test !delete yaml tag (hash)

exe("ex_1_no_n !delete test (no n parameter)","run ex_1_no_n",
  "Configuration parameter 'n' must be > 0"
  )

# Test !delete yaml tag (array)

exe("ex_1_no_case !delete test (no 'case' in message)","run ex_1_no_case",
  "Running ex_1 now",
  )

# Override run test

exe("ex_1 with override","run ex_1/sleep=0,message='Sleeping 0'",
  "ex_1_v1: Sleeping 0",
  "ex_1_v1: Completed"
  )

# Override suite test

exe("ex_suite_override (ex_1 overridden two ways)","ex_suite_override",
  "Sleeping 0",
  "Sleeping 1",
  "Comparison: ex_1_v1, ex_1_v2: OK",
  "ALL TESTS PASSED"
  )

# Remove output directory.

FileUtils.rm_rf($OUT)
