module Library

  # REQUIRED METHODS (CALLED BY DRIVER)

  def lib_build(env)
    bindir=env.build.bindir
    binname=env.run.binname
    compiler=env.build.compiler
    srcfile=env.build.srcfile
    cmd="cd #{env.build._root} && #{compiler} #{srcfile} -o #{bindir}/#{binname}"
    ext(cmd,{:msg=>"Build failed, see #{logfile}"})
  end

  def lib_build_post(env,output)
    File.join(env.run.build,env.build.bindir)
  end

  def lib_build_prep(env)
    FileUtils.mkdir_p(env.build._root)
    FileUtils.cp(File.join(env.build.srcdir,env.build.srcfile),env.build._root)
    FileUtils.mkdir_p(File.join(env.build._root,env.build.bindir))
  end

  def lib_outfiles(env,path)
    nil
  end

  def lib_outfiles_ex(env,path)
    [[path,'out']]
  end

  def lib_data(env)
    f="data.tgz"
    cmd="cp ex/data.tgz ."
    md5='d49037f1ef796b8a7ca3906e713fc33b'
    unless File.exists?(f) and hash_matches(f,md5)
      logd "Getting data: #{cmd}"
      output,status=ext(cmd,{:msg=>"Failed to get data, see #{logfile}"})
      die "Data archive #{f} has incorrect md5 hash" unless hash_matches(f,md5)
    end
    logd "Data archive #{f} ready"
    cmd="tar xvzf #{f}"
    logd "Extracting data: #{cmd}"
    output,status=ext(cmd,{:msg=>"Data extract failed, see #{logfile}"})
    logd "Data extract complete"
  end

  def lib_run(env,rundir)
    bin=env.run.binname
    run=env.run.runcmd
    sleep=env.run.sleep
    tasks=env.run.tasks
    cmd="cd #{rundir} && #{run} #{tasks} #{bin} >stdout 2>&1 && sleep #{sleep}"
    IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
    File.join(rundir,'stdout')
  end

  def lib_run_post(env,runkit)
    stdout=runkit
    (job_check(stdout,"SUCCESS"))?(true):(false)
  end

  def lib_run_prep(env,rundir)
    binname=env.run.binname
    conffile=env.run.conffile
    FileUtils.cp(File.join('builds',env.build._result,binname),rundir)
    FileUtils.chmod(0755,File.join(rundir,binname))
    a=env.run.a
    b=env.run.b
    n=env.run.n
    confstr="&config a=#{a} b=#{b} n=#{n} /\n"
    conffile=File.join(rundir,env.run.conffile)
    File.open(conffile,'w') { |f| f.write(confstr) }
    rundir
  end

  def lib_queue_del_cmd(env)
    nil
  end

  def lib_suite_post(env)
    logi "[ default post action ]"
  end

  def lib_suite_post_ex(env)
    logi "[ custom post action ]"
  end

  def lib_suite_prep(env)
    logi "[ default prep action ]"
  end

  def lib_suite_prep_ex(env)
    logi "[ custom prep action ]"
  end

  # CUSTOM METHODS (NOT CALLED BY DRIVER)

end
