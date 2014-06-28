unless $DDTSHOME=ENV["DDTSHOME"]
  puts "DDTSHOME not found in environment."
  exit 1
end

$DDTSHOME=File.expand_path($DDTSHOME)
$DDTSAPP=(d=ENV["DDTSAPP"])?(d):(File.join($DDTSHOME,"app"))
$DDTSOUT=(d=ENV["DDTSOUT"])?(d):(File.join($DDTSAPP))

$:.push($DDTSHOME).push($DDTSAPP)

require "defaults"
require "digest/md5"
require "fileutils"
require "find"
require "logger"
require "nl"
require "ostruct"
require "set"
require "thread"
require "time"
require "yaml"

module Utility

  def app_dir

    $DDTSAPP

  end

  def die(msg=nil)

    # Flush any messages accumulated in the 'delayed' logger, report a FATAL-
    # level message, and raise an Interrupt, to be caught by the top-level
    # TS object. If the 'immediate' logger has not been initialized (indicating
    # that the test suite has died very early), simply print the message and
    # exit.

    if @ts.ilog.nil?
      puts "\n#{msg}\n\n"
      exit 1
    end
    logd_flush
    @ts.ilog.fatal("#{@pre}: #{msg}") unless msg.nil?
    raise DDTSException

  end

  def ext(cmd,props={})

    # Execute a system command in a subshell, collecting stdout and stderr. If
    # property :die is true, die on a nonzero subshell exit status, printing the
    # message keyed by property :msg, if any. If property :out is true, write
    # the collected stdout/stderr to the delayed log.

    d=(props.has_key?(:die))?(props[:die]):(true)
    m=(props.has_key?(:msg))?(props[:msg]):("")
    o=(props.has_key?(:out))?(props[:out]):(true)
    output=[]
    IO.popen("#{cmd} 2>&1") { |io| io.read.each_line { |x| output.push(x) } }
    status=$?.exitstatus
    if o
      logd "* Output from #{cmd} (status code=#{status}):"
      logd "---- 8< ----"
      output.each { |e| logd e }
      logd "---- >8 ----"
    end
    die(m) if d and status!=0
    [output,status]

  end

  def hash_matches(file,hash)

    # Do they match?

    Digest::MD5.file(file)==hash

  end

  def home_dir

    $DDTSHOME

  end

  def invoke(std,key,*args)

    env=args.first
    section=env.marshal_dump[key]
    alt=section.marshal_dump[std]
    method(alt||std.to_s).call(*args)

  end

  def job_activate(jobid,run)

    # Add jobid:run to the active-jobs hash, so that the job can be killed if
    # the test suite halts.

    @activemaster.synchronize { @activejobs[jobid]=run }

  end

  def job_check(stdout,restr)

    # Report whether the job's stdout file contains a line matching the supplied
    # string (converted to a regular expression).

    re=Regexp.new(restr)
    die "Run failed: Could not find #{stdout}" unless File.exist?(stdout)
    File.open(stdout,"r") do |io|
      io.readlines.each { |e| return true if re.match(e) }
    end
    false

  end

  def job_deactivate(jobid)

    # Remove jobid:run from the active-jobs hash.

    @activemaster.synchronize { @activejobs.delete(jobid) }

  end

  def logd(msg)

    # A convenience wrapper that logs DEBUG-level messages to the 'delayed'
    # logger, to appear later in the log file in a contiguous block. If the
    # delayed logger has not been initialized, write directly to stdout.

    s="#{@pre}: #{msg}"
    (@dlog)?(@dlog.debug s):(puts s)

  end

  def logfile

    @ts.ilog.file

  end

  def logi(msg)

    # A convenience wrapper that logs INFO-level messages to the 'immediate'
    # logger, to appear both on stdout and in the log file.

    @ts.ilog.info "#{@pre}: #{msg}"

  end

  def logw(msg)

    # A convenience wrapper that logs WARN-level messages to the 'immediate'
    # logger, to appear both on stdout and in the log file.

    @ts.ilog.warn "#{@pre}: WARNING! #{msg}"
    @ts.ilog.warned=true

  end

  def tmp_dir

    # The path to a temporary directory, which will be removed by the 'clean'
    # command.

    File.join($DDTSOUT,"tmp")

  end

  def valid_dir(dir)

    # Return the supplied dir if it exists (otherwise die).

    dir=File.expand_path(dir)
    die "Directory #{dir} not found" unless File.directory?(dir)
    dir

  end

  def valid_file(file)

    # Return the supplied file if it exists (otherwise die).

    file=File.expand_path(file)
    die "File #{file} not found" unless File.exists?(file)
    file

  end

end # module Utility

module Common

  include Utility

  # Definition directories

  def defsdir()    File.join($DDTSAPP,"defs")   end
  def build_defs() File.join(defsdir,"builds")  end
  def run_defs()   File.join(defsdir,"runs")    end
  def suite_defs() File.join(defsdir,"suites")  end

  # Runtime directories

  def builds_dir() File.join($DDTSOUT,"builds") end
  def logs_dir()   File.join($DDTSOUT,"logs")   end
  def runs_dir()   File.join($DDTSOUT,"runs")   end

  # Various methods

  def ancestry(file,chain=nil)

    # Return an array containing the ancestry of the given definition file
    # (including the file itself), determined by following the chain of
    # 'ddts_extends' properties.

    dir,base=File.split(file)
    chain=[] if chain.nil?
    chain << base
    me=parse(file)
    ancestor=me["ddts_extends"]
    ancestry(File.join(dir,ancestor),chain) if ancestor
    chain

  end

  def comp(runs,env,continue=false)

    # Compare the output files for a set of runs (a 'run' may be a baseline).
    # Each element in the passed-in array is an OpenStruct object with
    # .name and .files members. The .name member specifies the name of the
    # run for display/logging purposes. The .files member contains a filenames
    # array-of-arrays, each element of which is composed of a prefix path and
    # a suffix path which, together, form the absolute path of each filename.
    # (This prefix/suffix split allows for flexibility in the directory
    # hierarchy of a baseline, as well as specificity in identifying the output
    # files of a model run.) The first element of the passed-in array is treated
    # as a master, and each other element in compared to it. Success means that
    # each set of output files is identical in name, number and content.

    ok=true # hope for the best
    r1=runs.shift
    r1_name=r1.name
    r1_files=r1.files
    r1_bases=r1_files.collect { |a,b| b }.sort
    runs.each do |r2|
      r2_name=r2.name
      r2_files=r2.files
      r2_bases=r2_files.collect { |a,b| b }.sort
      logd "Comparing #{r1_name} to #{r2_name}"
      m="(#{r1_name} vs #{r2_name})"
      unless r1_bases==r2_bases
        logd "File list matching failed #{m}, lists are:"
        logd "#{r1_name} files: #{r1_bases.join(' ')}"
        logd "#{r2_name} files: #{r2_bases.join(' ')}"
        begin
          ok=false
          die "File list matching failed #{m}, see #{logfile}"
        rescue Exception=>x
          unless x.is_a?(DDTSException) and continue
            logd_flush
            raise x
          end
        end
      end
      s1=r1_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      s2=r2_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      until s1.empty?
        f1=s1.shift
        f2=s2.shift
        fb=File.basename(f1)
        c=(x=env.lib_comp)?(x.to_sym):(nil)
        match=(c)?(send(c,env,f1,f2)):(FileUtils.compare_file(f1,f2))
        ok=false unless match
        logd "Comparing #{fb}: #{(match)?('OK'):('failed')} #{m}"
      end
      if ok
        logd "Comparing #{r1_name} to #{r2_name}: OK"
      else
        begin
          die "Comparison failed #{m}, see #{logfile}"
        rescue Exception=>x
          unless x.is_a?(DDTSException) and continue
            logd_flush
            raise x
          end
        end
      end
    end
    logd_flush
    ok

  end

  def convert_h2o(h)

    # Convert a (possibly nested) hash into an OpenStruct instance.

    o=OpenStruct.new
    h.each do |k,v|
      eval("o.#{k}="+((v.is_a?(Hash))?("convert_h2o(v)"):("v")))
    end
    o

  end

  def convert_o2h(o)

    # Convert a (possibly nested) OpenStruct instance into a hash.

    h=Hash.new
    o.marshal_dump.each do |k,v|
      h[k.to_s]=((v.is_a?(OpenStruct))?(convert_o2h(v)):(v))
    end
    h

  end

  def loadenv(file,descendant=nil,specs=nil)

    logd "Loading env from #{file}"
    convert_h2o(loadspec(file))

  end

  def loadspec(file,quiet=false,descendant=nil,specs=nil)

    # Parse YAML spec from file, potentially using recursion to merge the
    # current spec onto a specified ancestor. Keep track of spec files already
    # processed to avoid graph cycles.

    specs=[] if specs.nil?
    die "Circular dependency detected for #{file}" if specs.include?(file)
    specs << file
    me=parse(file,quiet)
    die "No valid definition found in '#{file}'" unless me
    ancestor=me["ddts_extends"]
    if ancestor
      me=loadspec(File.join(File.dirname(file),ancestor),quiet,me,specs)
    end
    me=mergespec(me,descendant) unless descendant.nil?
    me

  end

  def logd_flush

    @dlog.flush if @dlog

  end

  def mergespec(me,descendant)

    # Merge two specs together, allowing descendant's settings to take
    # precedence. Top-level key-value pairs are set directly; arrays are
    # appended; nested hashes are handled via recursion.

    me={} if me.nil?
    descendant={} if descendant.nil?
    descendant.each do |k,v|
      if v.is_a?(YAML_Delete)
        me.delete(k)
      elsif v.is_a?(YAML_Replace)
        me[k]=v.obj
      elsif v.is_a?(Hash)
        unless v.is_a?(Hash)
          die "Cannot merge Hash '#{me[k]}' with #{v.class} '#{v}'"
        end
        me[k]=mergespec(me[k],v)
      elsif v.is_a?(Array)
        unless v.is_a?(Array)
          die "Cannot merge Array '#{me[k]}' with #{v.class} '#{v}'"
        end
        me[k]=(me[k].nil?)?(v):(me[k]+v)
        me[k].each do |e|
          if e.is_a?(YAML_Delete)
            me[k].delete(e.obj)
            me[k].delete(e)
          end
        end
      else
        me[k]=v
      end
    end
    me

  end

  def parse(file,quiet=false)

    # Instantiate a Ruby object from a YAML definition file.

    file=File.expand_path(file)
    o=nil
    begin
      o=YAML.load(File.open(valid_file(file)))
    rescue Exception=>x
      logd x.message
      x.backtrace.each { |e| logd e }
      die "Error parsing YAML from "+file
    end
    if @dlog and not quiet
      c=File.basename(file)
      logd "Read definition '#{c}':"
      die "Definition '#{c}' is invalid" unless o
      pp(o).each_line { |e| logd e }
    end
    o

  end

  def pp(o,level=0,indent=true,quote=true)

    # Pretty-print. Sorting provides diff-comparable output.

    def a_or_h(o)
      o.is_a?(Array)||o.is_a?(Hash)
    end

    def ppsort(o)
      o.sort_by do |e|
        if e.is_a?(Hash)
          e.keys.first
        elsif e.is_a?(YAML_Delete)
          e.obj
        else
          e
        end
      end
    end

    s=""
    if o.is_a?(Array)
      ppsort(o).each do |e|
        s+="  "*level+"- "
        s+=pp(e,level,(a_or_h(e))?(false):(true),false)
      end
    elsif o.is_a?(Hash)
      ppsort(o).each do |k,v|
        s+="  "*level if indent
        s+=k+((a_or_h(v))?(":\n"):(": "))+pp(v,level+1,true)
      end
    else
      s+=(quote)?("#{quote_string(o)}\n"):("#{o}\n")
    end
    s

  end

  def quote_string(s)

    # Wrap values instantiated as Ruby Strings in quotes, except for those
    # tagged '!unquoted'.

    if s.is_a?(YAML_Unquoted)
      s="#{s}"
    elsif s.is_a?(String)
      s="'#{s}'"
    end
    s

  end

  def threadmon(threads,continue=false)

    # Initially, each thread is assumed to be live. Loop over the live threads,
    # discarding each as it finishes. Consider threads that raised exceptions
    # (indicated by nil status) to be failures. Join each thread if either (a)
    # it did not raise an exception, or (b) we are running in 'fail early' mode
    # (i.e. 'ddts_continue' is false).

    live=[].replace(threads)
    failures=0
    until live.empty?
      live.each do |e|
        unless e.alive?
          live.delete(e)
          failures+=1 if e.status.nil?
          begin
            e.join
          rescue Exception=>x
            raise x unless x.is_a?(DDTSException) and continue
          end
        end
      end
      sleep 1
    end
    failures

  end

end # module Common

class Comparison

  include Common

  attr_reader :comp_ok,:failruns,:totalruns

  def initialize(a,env,ts)

    # Receive an array of runs to be compared together, instantiate each in a
    # thread, then monitor threads for completion. Perform pairwise comparison
    # on the collected set of output specs (run names + file lists). Instance
    # variables from passed-in TS object are converted into instance variables
    # of this object.

    @env=env
    @ts=ts
    @env.suite=OpenStruct.new(@ts.env.marshal_dump)
    @dlog=XlogBuffer.new(ts.ilog)
    @pre="Comparison"
    @totalruns=a.size
    self.extend(Library)
    runs=[]
    threads=[]
    set=a.join(", ")
    a.each { |e| threads << Thread.new { runs << Run.new(e,@ts).result } }
    @failruns=threadmon(threads,@ts.env.suite.ddts_continue)
    @comp_ok=true # hope for the best
    return if @ts.env.suite.ddts_build_only
    if @totalruns-@failruns > 1
      runs.delete_if { |e| e.failed }
      set=runs.reduce([]) { |m,e| m.push(e.name) }.sort.join(", ")
      logi "#{set}: Checking..."
      sorted_runs=runs.sort { |r1,r2| r1.name <=> r2.name }
      @comp_ok=comp(sorted_runs,env,@ts.env.suite.ddts_continue)
      logi "#{set}: OK" if @comp_ok
    else
      unless @totalruns==1
        # Do not set @comp_ok to false here: The failure of this group will be
        # reflected in threadmon()'s return value.
        logi "Group stats: #{@failruns} of #{@totalruns} runs failed, "+
          "skipping comparison for group #{set}"
      end
    end

  end

end # class Comparison

class DDTSException < Exception

  # An exception to raise for internal purposes, and to allow real runtime
  # errors to be handled separately.

end

class Run

  include Common

  attr_reader :result # because initialize()'s return value is the Run object

  def initialize(r,ts)

    def update_runs_completed(failed,files,name,result,incomplete=false)
      if incomplete
        o=:incomplete
      else
        h={:failed=>failed,:files=>files,:name=>name,:result=>result}
        o=OpenStruct.new(h)
      end
      @ts.runmaster.synchronize do
        @ts.runs_completed[name]=o
      end
    end

    # Define a few things.

    @r=r
    @ts=ts
    @activejobs=@ts.activejobs
    @activemaster=@ts.activemaster
    @dlog=XlogBuffer.new(@ts.ilog)
    @pre="Run #{@r}"

    # Create a lock for this run unless one already exists.

    @ts.runmaster.synchronize do
      @ts.runlocks[@r]=Mutex.new unless @ts.runlocks.has_key?(@r)
    end

    # Obtain the lock for this run and (maybe) perform it.

    @ts.runlocks[@r].synchronize do

      # If the run has already performed, break out of this block.

      break if @ts.runs_completed.has_key?(@r)

      # Otherwise, perform the run.

      @env=OpenStruct.new(@ts.env.marshal_dump) # private copy
      @env.run=loadenv(File.join(run_defs,@r))
      logd_flush
      self.extend(Library)
      @env.run.ddts_name=@r
      @bline=@env.run.ddts_baseline

      # Wait on required runs.

      if (require=@env.run.ddts_require)
        require=[require] unless require.is_a?(Array)
        suffix=(require.size==1)?(""):("(s)")
        logi "Waiting on required run#{suffix}: #{require.join(', ')}"
        @env.run.ddts_require_results={}
        until require.empty?
          @ts.runmaster.synchronize do
            require.each do |e|
              if (result=@ts.runs_completed[e] and result!=:incomplete)
                if result.failed
                  die "Run '#{@r}' depends on failed run '#{e}'"
                end
                @env.run.ddts_require_results[e]=result
                require.delete(e)
              end
            end
          end
          sleep 3
        end
      end

      # Create a default entry for this run in case the build fails and never
      # returns so that, e.g., post-suite statistics can determine the number of
      # runs that were attempted.

      update_runs_completed(nil,nil,@r,nil,true)

      # Perform the build required for this run.

      build

      if @env.suite.ddts_build_only

        # If this suite is only performing builds, set the run's result to the
        # symbol :build_only.

        @ts.runmaster.synchronize { @ts.runs_completed[@r]=:build_only }

      else

        # Otherwise, obtain the necessary data...

        @ts.runmaster.synchronize do
          unless @ts.havedata
            logd "* Preparing data for all test-suite runs..."
            invoke(:lib_data,:run,@env)
            logd_flush
            @ts.havedata=true
          end
        end

        # ...and perform the run.

        logi "Started"
        @rundir=File.join(runs_dir,"#{@r}.#{@ts.uniq}")
        FileUtils.mkdir_p(@rundir) unless Dir.exist?(@rundir)
        logd "* Output from run prep:"
        @rundir=invoke(:lib_run_prep,:run,@env,@rundir)
        logd_flush
        logd "* Output from run:"
        runkit=invoke(:lib_run,:run,@env,@rundir)
        postkit=invoke(:lib_run_post,:run,@env,runkit)
        success=invoke(:lib_run_check,:run,@env,postkit)
        files=invoke(:lib_outfiles,:run,@env,@rundir)

        # Record final result value.

        update_runs_completed(!success,files,@r,postkit)

        # If the run succeeded, (potentially) compare the run's output to its
        # baseline or register its output for inclusion in a newly-generated
        # baseline. Otherwise, report failure.

        if success

          if @ts.use_baseline_dir
            baseline_comp
          elsif @ts.gen_baseline_dir
            baseline_reg
          end
          logd_flush
          logi "Completed"
        else
          die "Run failed: See #{logfile}"
        end

      end
    end

    # Obtain the run results, whether or not the run was actually performed by
    # the current thread.

    @ts.runmaster.synchronize { @result=@ts.runs_completed[@r] }

  end

  def jobdel(jobid)

    # Delete a run's job from the batch system.

    logd "Deleting job #{jobid}"
    qdel=invoke(:lib_queue_del_cmd,:run,@env)
    cmd="#{qdel} #{jobid}"
    output,status=ext(cmd,{:die=>false})

  end

  private

  def baseline_comp

    # Compare this run's output files to its baseline.

    if @bline
      blinepath=File.join(@ts.use_baseline_dir,@bline)
      if Dir.exist?(blinepath)
        logi "Comparing to baseline #{@bline}"
        blinepair=OpenStruct.new
        blinepair.name="baseline #{@bline}"
        blinepair.files=invoke(:lib_outfiles,:run,@env,blinepath)
        comp([@ts.runs_completed[@r],blinepair],@env.run)
        logi "Baseline comparison OK"
      else
        if Dir.exist?(@ts.use_baseline_dir)
          logw "No baseline '#{@bline}' found, continuing..."
        end
      end
    else
      logd "No baseline specified for #{@r} disabled, skipping"
    end

  end

  def baseline_reg

    # Volunteer to contribute to the suite's baseline, on behalf of the set
    # of runs sharing a common baseline name, this run's output files. Only one
    # run of the set performs this operation, due to the mutex.

    if @bline
      @ts.baselinemaster.synchronize do
        unless @ts.baselinesrcs.has_key?(@bline)
          @ts.baselinesrcs[@bline]=@ts.runs_completed[@r]
        end
      end
    else
      logd "Baseline registration for #{@r} disabled, skipping"
    end

  end

  def build

    # Due to the pair of mutexes, only one Run thread (the first to arrive)
    # will perform the actual build; threads that gain subsequent access to the
    # critical region will break out of the synchronize block and return
    # immediately. The thread that performs the build does so in an external
    # shell after obtaining its build spec. It stores into a global hash the
    # information required by its dependent runs.

    def update_builds(build,failed,result)
      @ts.buildmaster.synchronize do
        x=OpenStruct.new({:failed=>failed,:result=>result})
        @env.suite.ddts_builds||={}
        @env.suite.ddts_builds[build]=x
        @ts.builds[build]=x
      end
    end

    b=@env.run.ddts_build
    @env.build=loadenv(File.join(build_defs,b))
    logd_flush
    @env.build.ddts_root=File.join(builds_dir,b)
    @ts.buildmaster.synchronize do
      @ts.buildlocks[b]=Mutex.new unless @ts.buildlocks.has_key?(b)
    end
    @ts.buildlocks[b].synchronize do
      unless @ts.builds.has_key?(b)
        update_builds(b,true,nil) # assume the worst
        logi "Build #{b} started"
        logd "* Output from build #{b} prep:"
        invoke(:lib_build_prep,:run,@env)
        logd_flush
        logd "* Output from build #{b}:"
        buildkit=invoke(:lib_build,:run,@env)
        logd_flush
        result=invoke(:lib_build_post,:run,@env,buildkit)
        update_builds(b,false,result)
        logi "Build #{b} completed"
      end
    end
    die "Required build unavailable" if @ts.builds[b].failed
    @ts.buildmaster.synchronize do
      x=@ts.builds[b]
      @env.build.ddts_result=(x.failed)?(:build_failed):(x.result)
    end

  end

  def mod_namelist_file(nlfile,nlenv)

    # Modify a namelist file with values supplied by a definition.

    nlspec=convert_o2h(nlenv)
    nlh=NamelistHandler.new(nlfile)
    nlspec.each do |nlk,nlv|
      nlv.each do |k,v|
        v=quote_string(v)
        nlh.set!(nlk,k,v)
        logd "Set namelist #{nlk}:#{k}=#{v}"
      end
    end
    nlh.write

  end

end # class Run

class TS

  include Common

  attr_accessor :activemaster,:activejobs,:baselinemaster,:baselinesrcs,
  :buildlocks,:buildmaster,:builds,:dlog,:env,:gen_baseline_dir,:havedata,:ilog,
  :pre,:runlocks,:runmaster,:runs_all,:runs_completed,:suite,:uniq,
  :use_baseline_dir

  def initialize(tsname,cmd,rest)

    # The test-suite class. Provide a number of instance variables used
    # throughout the test suite, then branch to the appropriate method.

    @activejobs={}
    @activemaster=Mutex.new
    @baselinemaster=Mutex.new
    @baselinesrcs={}
    @buildlocks={}
    @buildmaster=Mutex.new
    @builds={}
    @dlog=nil
    @env=OpenStruct.new
    @env.suite=OpenStruct.new
    @gen_baseline_dir=nil
    @havedata=false
    @ilog=nil
    @pre=tsname
    @runlocks={}
    @runmaster=Mutex.new
    @runs_all=SortedSet.new
    @runs_completed={}
    @suite=nil
    @ts=self
    @uniq=Time.now.to_i
    @use_baseline_dir=nil
    dispatch(cmd,rest)

  end

  def baseline_gen

    # Generate a baseline. For each set of runs sharing a common value for the
    # 'baseline' key in their definitions, copy the output of one run (the one
    # that managed to insert its result data in the baseline-sources array
    # first) to the subdirectory of baseline/<suite> named by that common
    # 'baseline' key.

    baselinesrcs.each do |r,src|
      logi "Creating #{r} baseline..."
      dst=File.join(gen_baseline_dir,r)
      src.files.each do |p1,p2|
        fullpath=File.join(p1,p2)
        minipath=p2
        logd "Copying #{fullpath} to baseline"
        dstdir=File.join(dst,File.dirname(minipath))
        FileUtils.mkdir_p(dstdir) unless Dir.exist?(dstdir)
        FileUtils.cp(fullpath,File.join(dst,minipath))
      end
      logd_flush
      logi "Creating #{r} baseline: OK"
    end

  end

  def build_init(run_or_runs)

    # If the builds directory does not exist, simply create it. Otherwise,
    # exctract the set of unique 'build' keys from the supplied run def(s)
    # and remove any build directories with the same names. NB: This assumes
    # that build directories are named identically to build definition names!

    logd "build_init:"
    logd "----"
    runs=(run_or_runs.respond_to?(:each))?(run_or_runs):([run_or_runs])
    builds=runs.reduce(Set.new) do |m,e|
      build_name=loadspec(File.join(run_defs,e),true)["ddts_build"]
      m.add(File.join(builds_dir,build_name))
      logd "----"
      m
    end
    if Dir.exist?(builds_dir)
      if not env.suite.ddts_retain_builds
        builds.each do |build|
          if Dir.exist?(build)
            FileUtils.rm_rf(build)
            logd "Deleted build '#{build}'"
          end
        end
      end
    else
      FileUtils.mkdir_p(builds_dir)
      logd "Created empty '#{builds_dir}'"
    end
    builds.each do |build|
      FileUtils.mkdir_p(build)
      logd "Created empty build directory '#{build}'"
    end
    logd_flush

  end

  def clean(args)

    # Clean up items created by the test suite. As well as those defined here,
    # remove any items specified by the caller.

    items=[builds_dir,logs_dir,runs_dir,tmp_dir]
    Dir.glob(File.join($DDTSOUT,"log.*")).each { |e| items << e }
    items.sort.each do |e|
      if File.exists?(e)
        puts "Deleting #{File.basename(e)}"
        FileUtils.rm_rf(e)
      end
    end

  end

  def dispatch(cmd,args)

    # If the given method is approved as a command-line action, call it with
    # the given arguments. If it is a suite name, run the suite. Otherwise, show
    # usage info and exit with error.

    cmd||="help"
    cmd.gsub!(/-/,"_")
    okargs=[
      "clean",
      "gen_baseline",
      "help",
      "make_app",
      "run",
      "show",
      "use_baseline",
      "version"
    ]
    suites=Dir.glob(File.join(suite_defs,"*")).map { |e| File.basename(e) }
    unless ["help","make_app","version"].include?(cmd)
      unless Dir.exist?($DDTSAPP)
        die "Application directory '#{$DDTSAPP}' not found"
      end
      begin
        require "library"
      rescue LoadError=>ex
        puts "NOTE: No library.rb found, using defaults.rb"
      end
    end
    if okargs.include?(cmd)
      send(cmd,args)
    elsif suites.include?(cmd)
      dosuite(cmd)
    else
      help(args,1)
    end

  end

  def dosuite(suite)

    # Perform the requsted test suite. Essentially, this involves comparing
    # against each other the output of sets of runs declared in the suite
    # definition to be comparable. The top-level arrays in the YAML suite
    # definition specify the names of runs to compare together. Comparison
    # objects are instantiated to perform the necessary runs and compare their
    # output. Each Comparison is run in a thread, and the set of threads is
    # monitored for completion. This program's main thread of execution blocks
    # on the call to threadmon() until all Comparisons are complete, or until a
    # thread aborts and raises an exception, which is caught and handled here. A
    # list of active jobs is maintained so that, in the event of suite failure
    # or interruption via ctrl-c, commands can be issued to abort them. A
    # baseline is generated if one was requested.

    @suite=suite
    setup
    f=File.join(suite_defs,suite)
    unless File.exists?(f)
      die "Suite '#{suite}' not found"
    end
    logi "Running test suite '#{suite}'"
    threads=[]
    begin
      logd "Loading suite spec #{f}"
      suitespec=loadspec(f)
      logd_flush
      suitespec.each do |k,v|
        # Assume that array values are run groups and move all scalar values
        # into env.suite, assuming that these are either reserved or user-
        # defined suite-level settings.
        eval "env.suite.#{k}=suitespec.delete(k)" unless v.is_a?(Array)
      end
      env.suite.ddts_totalruns=0
      env.suite.ddts_totalfailures=0
      env.suite.ddts_suitename=suite
      self.extend(Library)
      FileUtils.mkdir_p(tmp_dir)
      invoke(:lib_suite_prep,:suite,env)
      suitespec.each do |k,v|
        v.each { |x| runs_all.add(x) if x.is_a?(String) }
      end
      sanity_checks(gen_baseline_dir)
      build_init(runs_all)
      suitespec.each do |group,runs|
        runs.each do |run|
          if runs.count(run)>1
            die "Run '#{run}' is duplicated in group '#{group}'"
          end
        end
        group_hash=runs.reduce({}) do |m,e|
          (e.is_a?(Hash))?(m.merge(runs.delete(e))):(m)
        end
        group_env=OpenStruct.new(group_hash)
        if runs
          threads << Thread.new do
            comparison=Comparison.new(runs.sort.uniq,group_env,self)
            Thread.current[:comparison]=comparison
            raise DDTSException if Thread.current[:comparison].failruns > 0
          end
        else
          logi "Suite group #{group} empty, ignoring..."
        end
      end
      failgroups=threadmon(threads,env.suite.ddts_continue)
      if env.suite.ddts_continue
        threads.each do |e|
          env.suite.ddts_totalruns+=e[:comparison].totalruns
          env.suite.ddts_totalfailures+=e[:comparison].failruns
          failgroups+=1 unless e[:comparison].comp_ok
        end
        logi "Suite stats: Failure in #{failgroups} of #{threads.size} group(s)"
      end
    rescue Interrupt,DDTSException=>x
      threads.each { |e| e.kill if e.alive? }
      halt(x)
    rescue Exception=>x
      logi x.message
      x.backtrace.each { |e| logi e }
      exit 1
    end
    if gen_baseline_dir
      if failgroups>0
        logi "Skipping baseline generation due to #{failgroups} run failure(s)"
      else
        baseline_gen
      end
    end
    if failgroups>0
      msg="#{env.suite.ddts_totalfailures} of #{env.suite.ddts_totalruns} "+
        "TEST(S) FAILED"
    else
      msg="ALL TESTS PASSED"
      msg+=" -- but note WARNING(s) above!" if ilog.warned
    end
    logi msg
    env.suite.ddts_runs=runs_completed.reduce({}) do |m,(k,v)|
      if v==:build_only
        h={:failed=>false,:files=>[],:result=>nil}
      elsif v==:incomplete
        h={:failed=>true,:files=>[],:result=>nil}
      else
        h={:failed=>v.failed,:files=>v.files,:result=>v.result}
      end
      m[k]=OpenStruct.new(h)
      m
    end
    invoke(:lib_suite_post,:suite,env)

  end

  def gen_baseline(args=nil)

    # If 'gen-baseline' was supplied as the command-line argument, record the
    # specified baseline directory, then call dosuite with the suite name.

    help(args,1) unless args.size==2
    @gen_baseline_dir=args.shift
    help(args,1) if args.empty?
    dosuite(args[0])

  end

  def halt(x)

    # Terminate the test-suite run. First try to kill any submitted batch jobs
    # that are still active. Print some (hopefully helpful) diagnostic messages
    # and then exit.

    unless activejobs.nil? or activejobs.empty?
      logi "Stopping runs..."
      activemaster.synchronize do
        activejobs.each { |jobid,job| job.jobdel(jobid) }
      end
    end
    logd x.message
    logd "* Backtrace:"
    x.backtrace.each { |e| logd e }
    logd_flush
    pre=(suite.nil?)?("Run"):("Test suite '#{suite}'")
    logi "#{pre} FAILED"
    exit 1

  end

  def help(args=nil,status=0)

    puts
    puts "usage: #{pre} <suite>"
    puts "       #{pre} gen-baseline <directory> <suite>"
    puts "       #{pre} use-baseline <directory> <suite>"
    puts "       #{pre} clean"
    puts "       #{pre} make-app <path>"
    puts "       #{pre} help"
    puts "       #{pre} run [ gen-baseline <dir> ] <run>"
    puts "       #{pre} run [ use-baseline <dir> ] <run>"
    puts "       #{pre} show build <build>"
    puts "       #{pre} show run <run>"
    puts "       #{pre} show suite <suite>"
    puts "       #{pre} version"
    puts
    puts "See the README for more information."
    puts
    exit status

  end

  def make_app(args)
    help(args,1) if args.size>1
    approot=args.first||File.join(home_dir,"app")
    defs=File.join(approot,"defs")
    die "Directory '#{approot}' already exists" if File.exist?(approot)
    dirs=[approot]
    ["builds","runs","suites"].each { |dir| dirs.push(File.join(defs,dir)) }
    dirs.each do |dir|
      begin
        FileUtils.mkdir_p(dir)
      rescue
        die "Unable to create directory '#{dir}'"
      end
    end
    begin
      src=File.join(home_dir,"defaults.rb")
      dst=File.join(approot,"library.rb")
      FileUtils.cp(src,dst)
    rescue
      die "Unable to copy '#{src}' to '#{dst}'"
    end
    def write_definition(defs,sub,name,str)
      definition=File.join(defs,sub,name)
      begin
        File.open(definition,"w") { |f| f.write(str) }
      rescue
        die "Unable to write to '#{definition}'"
      end
    end
    write_definition(defs,"builds","build1","set: me")
    write_definition(defs,"runs","run1","ddts_build: build1\n")
    write_definition(defs,"suites","suite1","group1:\n  - run1\n")
    puts"\nCreated application skeletion in #{approot}\n\n"
  end

  def run(args=nil)

    # Handle the command-line "run" argument, to perform a single named run.

    help(args,1) unless args.size==1 or args.size==3
    help(args,1) unless args.size==1 or args.first=~/^(gen|use)-baseline$/
    run=args.pop
    runs_all.add(run)
    setup
    begin
      if args.first=="gen-baseline"
        args.shift
        @gen_baseline_dir=args.shift
      elsif args.first=="use-baseline"
        args.shift
        @use_baseline_dir=args.shift
        unless Dir.exist?(use_baseline_dir)
          die "Baseline directory #{use_baseline_dir} not found"
        end
      end
      sanity_checks(gen_baseline_dir)
    rescue Exception=>x
      exit 1
    end
    FileUtils.mkdir_p(tmp_dir)
    begin
      build_init(run)
      Run.new(run,self)
      baseline_gen if gen_baseline_dir
    rescue Interrupt,DDTSException=>x
      halt(x)
    rescue Exception=>x
      logi x.message
      x.backtrace.each { |e| logi e }
      exit 1
    end

  end

  def sanity_checks(check_baseline_conflicts=false)

    baseline_conflict=false
    unsatisfied_require=false

    builds_all=Dir.glob(File.join(build_defs,"*")).map { |e| File.basename(e) }

    runs_all.each do |run|

      spec=loadspec(File.join(run_defs,run),true)

      # If a baseline is being generated, check for any pre-existing baseline
      # directories that would potentially be clobbered if we continue.

      if check_baseline_conflicts and (b=spec["ddts_baseline"])
        if Dir.exist?(File.join(gen_baseline_dir,b))
          logi "ERROR: Run '#{run}' could overwrite baseline '#{b}'"
          baseline_conflict=true
        end
      end

      # Check that all run dependencies are satisfied by scheduled runs.

      unless (r=spec["ddts_require"])==nil
        r=[r] unless r.is_a?(Array)
        r.each do |e|
          unless runs_all.include?(e)
            logi "ERROR: Run '#{run}' depends on unscheduled run '#{e}'"
            unsatisfied_require=true
          end
        end
      end

      # Check that all runs have defined 'build'.

      unless build=spec["ddts_build"]
        die "Run '#{run}' not associated with any build, aborting..."
      end
      unless builds_all.include?(build)
        die "Run '#{run}' associated with unknown build '#{build}', aborting..."
      end

    end

    die "Aborting..." if baseline_conflict or unsatisfied_require

  end

  def setup

    # Perform common tasks needed for either full-suite or single-run
    # invocations.

    env.ddts_ilog=(@ilog=Xlog.new(logs_dir,uniq))
    env.ddts_dlog=(@dlog=XlogBuffer.new(ilog))
    trap("INT") do
      logi "Interrupted"
      raise Interrupt
    end

  end

  def show(args)

    # Pretty-print a fully composed run or suite definition.

    def get_dir(type)
      case
      when type=="build"
        unless Dir.exist?(d=build_defs)
          die "Build definitions directory '#{d}' not found"
        end
        d
      when type=="run"
        unless Dir.exist?(d=run_defs)
          die "Run definitions directory '#{d}' not found"
        end
        d
      when type=="suite"
        unless Dir.exist?(d=suite_defs)
          die "Suite definitions directory '#{d}' not found"
        end
        d
      else
        die "Unrecognized definition type '#{type}'"
      end
    end

    unless Dir.exist?(defsdir)
      die "Definition directory '#{defsdir}' not found"
    end
    type=args[0]
    name=args[1]
    if ["build","run","suite"].include?(type)
      die "No #{type} specified" unless name
      dir=get_dir(type)
      file=File.join(dir,name)
      die "'#{name}' not found in #{dir}" unless File.exist?(file)
      spec=loadspec(file)
      spec.delete("ddts_extends")
      puts
      puts "# #{ancestry(file).join(' < ')}"
      puts
      puts pp(spec)
      puts
    else
      help(args,1)
    end

  end

  def use_baseline(args=nil)

    # If 'use-baseline' was supplied as the command-line argument, record the
    # specified baseline directory, then set the suite name and call dosuite
    # with the suite name.

    help(args,1) unless args.size==2
    @use_baseline_dir=args.shift
    unless Dir.exist?(use_baseline_dir)
      die "Baseline directory #{use_baseline_dir} not found"
    end
    help(args,1) if args.empty?
    dosuite(args[0])

  end

  def version(args)

    puts "2.4"

  end

end # class TS

# Special YAML handling. See JRuby's lib/ruby/shared/psych/coder.rb.

class YAML_Delete

  # To delete inherited keys/values.

  attr_accessor :obj

  def init_with(coder)
    @obj=coder.send(coder.type)
  end

end # class YAML_Delete

YAML.add_tag("!delete",YAML_Delete)

class YAML_Replace

  # To to suppress Array/Hash merging.

  attr_accessor :obj

  def init_with(coder)
    @obj=coder.send(coder.type)
  end

end # class YAML_Replace

YAML.add_tag("!replace",YAML_Replace)

class YAML_Unquoted

  # To suppress quoting Strings e.g. for Fortran namelist values.

  def initialize(v)
    @v=v
  end

  def init_with(coder)
    @v=coder.scalar
  end

  def to_s
    @v
  end

end # class YAML_Unquoted

YAML.add_tag("!unquoted",YAML_Unquoted)

# Logging

class Xlog

  # An extension to Ruby's Logger library, providing simultaneous writes to both
  # a screen logger and a file logger. The screen logger is configured to only
  # display messages with priority INFO and higher, and so is relatively terse.
  # The file logger accepts *all* messages: from priority DEBUG and up. Messages
  # logged to file are preceded by a timestamp and the priority-level string.
  # method_missing() passes calls to Logger methods like info(), debug(), etc.
  # directly on to the underlying Logger objects. It intercepts the flush() call
  # and sends the contents of the supplied array of priority-level / message
  # pairs on to the screen and file loggers. A mutex protects access to the file
  # and screen loggers so that buffered messages can be output in contiguous
  # blocks. NB: method_missing() should be a prime suspect in any runtime
  # mischief traceable to this class: Analyze its arguments carefully.

  attr_accessor :warned
  attr_reader :file

  def initialize(dir,uniq)

    # File logger

    FileUtils.mkdir_p(dir)
    @file=File.join(dir,"log.#{uniq}")
    FileUtils.rm_f(@file)
    @flog=Logger.new(@file)
    @flog.level=Logger::DEBUG
    @flog.formatter=proc do |s,t,p,m|
      timestr="#{t.year}-#{t.month}-#{t.day} #{t.hour}:#{t.min}:#{t.sec}"
      "#{timestr} [#{s}] #{m}\n"
    end

    # Screen logger

    @slog=Logger.new(STDOUT)
    @slog.level=Logger::INFO
    @slog.formatter=proc { |s,t,p,m| "#{m}\n" }
    @warned=false

  end

  def method_missing(m,*a)

    if m==:flush
      @flog.debug("\n#{a.first}")
    else
      @flog.send(m,"\n\n  #{a.first}\n")
      @slog.send(m,a.first)
    end

  end

end # class Xlog

class XlogBuffer

  # A wrapper around Xlog to buffer messages for batch output. The flush method
  # sends buffered messages to the primary ('immediate') logger, then resets the
  # buffer.

  def initialize(ilog)

    @ilog=ilog
    reset

  end

  def flush

    @ilog.flush(@buffer)
    reset

  end

  def method_missing(m,*a)

    @buffer+="  #{a[0].chomp}\n"

  end

  def reset

    @buffer="\n"

  end

end # class XlogBuffer

# Command-line invocation:

if __FILE__==$0
  TS.new(ARGV[0],ARGV[1],ARGV[2..-1])
end

# paul.a.madden@noaa.gov
