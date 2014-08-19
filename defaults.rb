module Library

  def lib_build(env,prepkit)
    true
  end

  def lib_build_post(env,buildkit)
    true
  end

  def lib_build_prep(env)
    true
  end
 
  def lib_data(env)
    true
  end

  def lib_outfiles(env,path)
    []
  end

  def lib_run(env,prepkit)
    true
  end

  def lib_run_check(env,postkit)
    true
  end

  def lib_run_post(env,runkit)
    true
  end

  def lib_run_prep(env)
    true
  end

  def lib_queue_del_cmd(env)
    true
  end

  def lib_suite_post(env)
    true
  end

  def lib_suite_prep(env)
    true
  end

end
