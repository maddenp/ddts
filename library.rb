module Library

  def lib_build_cmd(buildspec)
    bindir=buildspec['bindir']
    binname=buildspec['binname']
    builddir=File.join(buildspec['buildroot'],buildspec['builddir'])
    compiler=buildspec['compiler']
    srcfile=buildspec['srcfile']
    cmd="cd #{builddir} && #{compiler} #{srcfile} -o #{bindir}/#{binname}"
  end

  def lib_build_post(buildspec,output)
    File.join(buildspec['builddir'],buildspec['bindir'])
  end

  def lib_build_prep(buildspec)
    dir=File.join(buildspec['buildroot'],buildspec['builddir'])
    FileUtils.mkdir_p(dir)
    FileUtils.cp(File.join(buildspec['srcdir'],buildspec['srcfile']),dir)
    FileUtils.mkdir(File.join(dir,buildspec['bindir']))
  end

  def lib_dataspecs
    ['cp ex/data.tgz .','d49037f1ef796b8a7ca3906e713fc33b']
  end

  def lib_outfiles(path)
    nil
  end

  def lib_outfiles_ex(path)
    [[path,'out']]
  end

  def lib_prep_job(rundir,runspec)
    binname=runspec['binname']
    conffile=runspec['conffile']
    FileUtils.cp(File.join('builds',runspec['buildrun'],binname),rundir)
    FileUtils.chmod(0755,File.join(rundir,binname))
    a=runspec['a']
    b=runspec['b']
    n=runspec['n']
    confstr="&config a=#{a} b=#{b} n=#{n} /\n"
    conffile=File.join(rundir,runspec['conffile'])
    File.open(conffile,'w') { |f| f.write(confstr) }
    rundir
  end

  def lib_re_str_success
    'SUCCESS'
  end

  def lib_run_job(rundir,runspec,activeruns)
    bin=runspec['binname']
    run=runspec['runcmd']
    sleep=runspec['sleep']
    tasks=runspec['tasks']
    cmd="cd #{rundir} && #{run} #{tasks} #{bin} >stdout 2>&1 && sleep #{sleep}"
    IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
    File.join(rundir,'stdout')
  end

end
