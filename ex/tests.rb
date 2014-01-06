require 'fileutils'

def die(msg)
  puts msg
  exit 1
end

def exe(desc,suite,*expected)
  expected.map! { |e| Regexp::escape(e) }
  print "Testing: #{desc}"+" "*(40-desc.length)
  ddts=File.join("..","ddts")
  cmd="DDTSOUT=#{$OUT} #{ddts} #{suite} 2>&1"
  out=`#{cmd}`.split("\n")
  expected.each do |string|
    if out.grep(/.*#{string}.*/).empty? 
      puts "FAILED"
      puts "\nCommand was:\n\n#{cmd}"
      die "\nOutput was:\n\n#{out.join("\n")}"
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
  "ALL TESTS PASSED"
  )

# ex_suite_fail executes the single ex_fail run, which is expected to fail.

exe("ex_suite_fail","ex_suite_fail",
  "Run ex_fail: Run failed",
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
  "ex_baseline already exists",
  "Test suite 'ex_suite' FAILED"
  )

# Execute ex_suite again and verify against baseline.

exe("ex_suite use-baseline","use-baseline #{baseline} ex_suite",
  "Run ex_1: Baseline comparison OK",
  "Comparison: ex_1, ex_1_alt, ex_2, ex_4: OK",
  "ALL TESTS PASSED"
  )

# ex_suite_1p_1f executes two runs in one group, where one fails. The successful
# run has nothing to compare to, so comparison is skipped.

exe("ex_suite_1p_1f","ex_suite_1p_1f",
  "Group stats: 1 of 2 runs failed, skipping comparison",
  "Suite stats: Failure in 1 of 1 group(s)",
  "Failure in 1 of 1 group(s)"
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
  "Run ex_4_bad: Comparison failed (ex_4_bad vs baseline ex_baseline)",
  "Test suite 'ex_suite_mismatch_stop' FAILED"
  )

# Same as previous test, but without baseline comparison, so that the suite
# fails on run-vs-run comparison.

exe("ex_suite_mismatch_stop (no baseline)","ex_suite_mismatch_stop",
  "Comparison: Comparison failed (ex_2 vs ex_4_bad)",
  "Test suite 'ex_suite_mismatch_stop' FAILED"
  )

# Same as previous test, but 'continue' is true so that the suite completes.

exe("ex_suite_mismatch_continue","ex_suite_mismatch_continue",
  "Comparison failed (ex_2 vs ex_4_bad)",
  "Suite stats: Failure in 1 of 2 group(s)",
  "0 of 4 TEST(S) FAILED"
  )

# Remove output directory.

FileUtils.rm_rf($OUT)
