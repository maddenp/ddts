# rubocop:disable Lint/UnusedMethodArgument

module Library

  # TODO: Comments are needed here to explain how these routines use information
  #       from the 'env' object and their arguments and how they satisfy return-
  #       value requirements. For now, please consult Section 5 in ../README
  #       when reading this code. Other sections of the README may be helpful,
  #       too.

  def lib_baseline_post(env, baseline_dir, baseline_files)
    baseline_files.each do |f|
      unless File.exist?(File.join(baseline_dir, f))
        die "ERROR: Baseline file '#{f}' not found!"
      end
    end
    FileUtils.touch(File.join(baseline_dir, 'non-baseline-file'))
    logi 'Baseline post function OK'
  end

  def lib_baseline_post_alt(env, baseline_dir, baseline_files)
    logi 'Alternate baseline post function called'
    lib_baseline_post(env, baseline_dir, baseline_files)
  end

  def lib_build(env, prepkit)
    bindir = env.build.bindir
    binname = env.run.binname
    compiler = env.build.compiler
    srcdir = env.build.ddts_root
    srcfile = env.build.srcfile
    cmd = "cd #{srcdir} && #{compiler} #{srcfile} -o #{bindir}/#{binname}"
    ext(cmd, msg: "Build failed, see #{logfile}")
  end

  def lib_build_post(env, buildkit)
    File.join(env.build.ddts_root, env.build.bindir, env.build.binname)
  end

  def lib_build_prep(env)
    if env.suite.crash or env.run.crash
      logi "Crashing for test purposes..."
      logd "CRASH SENTINEL"
      raise Exception
    end
    FileUtils.cp(File.join(app_dir, env.build.srcfile), env.build.ddts_root)
    FileUtils.mkdir_p(File.join(env.build.ddts_root, env.build.bindir))
  end

  def lib_comp_alt(env, f1, f2)
    logi "Comparing '#{f1}' to '#{f2}' with alternate comparator..."
    FileUtils.compare_file(f1, f2)
  end

  def lib_data(env)
    f = 'data.tgz'
    src = File.join(app_dir, f)
    dst = File.join(tmp_dir, f)
    cmd = "cp #{src} #{dst}"
    md5 = 'd49037f1ef796b8a7ca3906e713fc33b'
    unless File.exist?(dst) and hash_matches(dst, md5)
      logd "Getting data: #{cmd}"
      ext(cmd, msg: "Failed to get data, see #{logfile}")
      unless hash_matches(dst, md5)
        die "Data archive #{f} has incorrect md5 hash"
      end
    end
    logd "Data archive #{f} ready"
    cmd = "cd #{tmp_dir} && tar xvzf #{f}"
    logd "Extracting data: #{cmd}"
    ext(cmd, msg: "Data extract failed, see #{logfile}")
    logd 'Data extract complete'
  end

  def lib_outfiles_ex(env, path)
    expr = File.join(path, 'out[0-9]')
    Dir.glob(expr).map { |e| [path, File.basename(e)] }
  end

  def lib_run(env, prepkit)
    rundir = prepkit
    bin = env.run.binname
    run = env.run.runcmd
    sleep = env.run.sleep
    tasks = env.run.tasks
    if (message = env.run.message)
      logi message.is_a?(Array) ? message.join(' ') : message
    end
    cmd = "cd #{rundir} && #{run} #{tasks} #{bin} >stdout 2>&1 " \
          "&& sleep #{sleep}"
    logd "Running: #{cmd}"
    IO.popen(cmd) { |io| io.readlines.each { |e| logd e.to_s } }
    File.join(rundir, 'stdout')
  end

  def lib_run_nobuild(env, prepkit)
    true
  end

  def lib_run_check(env, postkit)
    stdout = postkit
    unless (lines = File.open(stdout).read) =~ /SUCCESS/
      lines.each_line { |line| logi line.chomp }
    end
    job_check(stdout, 'SUCCESS') ? env.run.ddts_root : nil
  end

  def lib_run_check_nobuild(env, postkit)
    true
  end

  def lib_run_post(env, runkit)
    runkit
  end

  def lib_run_post_nobuild(env, runkit)
    logi "No-build run OK"
  end

  def lib_run_prep(env)
    rundir = env.run.ddts_root
    binname = env.run.binname
    FileUtils.cp(env.build.ddts_result, rundir)
    FileUtils.chmod(0o755, File.join(rundir, binname))
    a = env.run.a
    b = env.run.b
    n = env.run.n || 0
    confstr = "&config a=#{a} b=#{b} n=#{n} /\n"
    conffile = File.join(rundir, env.run.conffile)
    File.open(conffile, 'w') { |f| f.write(confstr) }
    rundir
  end

  def lib_run_prep_nobuild(env)
    true
  end

  def lib_suite_post(env)
    logi '[ default post action ]'
  end

  def lib_suite_post_ex(env)
    buildfails = env.suite.ddts_builds.reduce(0) do |m, (_, v)|
      v.failed ? (m + 1) : m
    end
    logi "build fail rate = #{Float(buildfails) / env.suite.ddts_builds.size}"
    runfails = env.suite.ddts_runs.reduce(0) do |m, (_, v)|
      v.failed ? (m + 1) : m
    end
    logi "run fail rate = #{Float(runfails) / env.suite.ddts_runs.size}"
    logi '[ custom post action ]'
  end

  def lib_suite_prep(env)
    logi '[ default prep action ]'
  end

  def lib_suite_prep_ex(env)
    logi '[ custom prep action ]'
  end

end
