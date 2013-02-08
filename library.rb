module Library

  # REQUIRED METHODS (CALLED BY DRIVER)

  def lib_build(env)
    bindir=env.build.bindir
    binname=env.run.binname
    builddir=File.join(env.build.root,env.build.builddir)
    compiler=env.build.compiler
    srcfile=env.build.srcfile
    cmd="cd #{builddir} && #{compiler} #{srcfile} -o #{bindir}/#{binname}"
    ext(cmd,{:msg=>"Build failed"})
  end

  def lib_build_post(env,output)
    File.join(env.build.builddir,env.build.bindir)
  end

  def lib_build_prep(env)
    dir=File.join(env.build.root,env.build.builddir)
    FileUtils.mkdir_p(dir)
    FileUtils.cp(File.join(env.build.srcdir,env.build.srcfile),dir)
    FileUtils.mkdir(File.join(dir,env.build.bindir))
  end

  def lib_dataspecs(env)
    ['cp ex/data.tgz .','d49037f1ef796b8a7ca3906e713fc33b']
  end

  def lib_outfiles(env,path)
    nil
  end

  def lib_outfiles_ex(env,path)
    [[path,'out']]
  end

  def lib_prep_job(env,rundir)
    binname=env.run.binname
    conffile=env.run.conffile
    FileUtils.cp(File.join('builds',env.build.runfiles,binname),rundir)
    FileUtils.chmod(0755,File.join(rundir,binname))
    a=env.run.a
    b=env.run.b
    n=env.run.c
    confstr="&config a=#{a} b=#{b} n=#{n} /\n"
    conffile=File.join(rundir,env.run.conffile)
    File.open(conffile,'w') { |f| f.write(confstr) }
    rundir
  end

  def lib_queue_del_cmd(env)
    nil
  end

  def lib_re_str_success(env)
    'SUCCESS'
  end

  def lib_run_job(env,rundir)
    bin=env.run.binname
    run=env.run.runcmd
    sleep=env.run.sleep
    tasks=env.run.tasks
    cmd="cd #{rundir} && #{run} #{tasks} #{bin} >stdout 2>&1 && sleep #{sleep}"
    IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
    File.join(rundir,'stdout')
  end

  # CUSTOM METHODS (NOT CALLED BY DRIVER)

end
