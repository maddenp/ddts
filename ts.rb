require 'digest/md5'
require 'fileutils'
require 'find'
require 'logger'
require 'nl'
require 'ostruct'
require 'profiles'
require 'thread'
require 'time'
require 'yaml'

module Common

  def confdir()   'conf'                      end
  def buildsdir() File.join(confdir,'builds') end
  def runsdir()   File.join(confdir,'runs')   end
  def suitesdir() File.join(confdir,'suites') end

  def ancestry(file,chain=nil)

    # Return an array containing the ancestry of the given configuration file
    # (including the file itself), determined by following the chain of
    # 'extends' properties.

    dir,base=File.split(file)
    chain=[] if chain.nil?
    chain << base
    me=parse(file)
    ancestor=me['extends']
    ancestry(File.join(dir,ancestor),chain) if ancestor
    chain
  end

  def comp(runs)

    # Compare the output files for a set of runs (a 'run' may be a baseline
    # image). Each element in the passed-in array is an OpenStruct object with
    # .name and .files members. The .name member specifies the name of the
    # run for display/logging purposes. The .files member contains a filenames
    # array-of-arrays, each element of which is composed of a prefix path and
    # a suffix path which, together, form the absolute path of each filename.
    # (This prefix/suffix split allows for flexibility in the directory
    # hierarchy of a baseline, as well as specificity in identifying the output
    # files of a model run.) The first element of the passed-in array is treated
    # as a master, and each other element in compared to it. Success means that
    # each set of output files is identical in name, number and content.

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
        logd "File list matching FAILED #{m}, lists are:"
        logd "#{r1_name} files: #{r1_bases.join(' ')}"
        logd "#{r2_name} files: #{r2_bases.join(' ')}"
        die "File list matching FAILED #{m}"
      end
      s1=r1_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      s2=r2_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      until s1.empty?
        f1=s1.shift
        f2=s2.shift
        fb=File.basename(f1)
        unless FileUtils.compare_file(f1,f2)
          logd "Comparing #{fb}: FAILED #{m}"
          die "Comparison failed #{m}"
        end
        logd "Comparing #{fb}: OK #{m}"
      end
      logd "Comparing #{r1_name} to #{r2_name}: OK"
    end
    logd_flush
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
    raise
  end

  def ext(cmd,props={})

    # Execute a system command in a subshell, collecting a merged stdout and
    # stderr. If property :die is true, die on a nonzero subshell exit status,
    # printing the message keyed by property :msg, if any. If property :out is
    # true, write the collected stdout/stderr to the delayed log.

    d=(props.has_key?(:die))?(props[:die]):(true)
    m=(props.has_key?(:msg))?(props[:msg]):("")
    o=(props.has_key?(:out))?(props[:out]):(true)
    output=%x{#{cmd} 2>&1}.split("\n")
    status=$?
    if o
      logd "* Output from: #{cmd}"
      logd "* Status code: #{status}"
      logd "---- 8< ----"
      output.each { |e| logd e }
      logd "---- >8 ----"
    end
    die(m) if d and status!=0
    [output,status]
  end

  def job_activate(jobid,run)

    # Add jobid:run to the active-jobs hash, so that the job can be killed if
    # the test suite halts.

    @activemaster.synchronize { @activejobs[jobid]=run }
  end

  def job_deactivate(jobid)

    # Remove jobid:run from the active-jobs hash.

    @activemaster.synchronize { @activejobs.delete(jobid) }
  end

  def loadenv(file,descendant=nil,specs=nil)
    convert_h2o(loadspec(file))
  end

  def loadspec(file,descendant=nil,specs=nil)

    # Parse YAML spec from file, potentially using recursion to merge the
    # current spec onto a specified ancestor. Keep track of spec files already
    # processed to avoid graph cycles.

    specs=[] if specs.nil?
    die "Circular dependency detected for #{file}" if specs.include?(file)
    specs << file
    me=parse(file)
    ancestor=me['extends']
    me=loadspec(File.join(File.dirname(file),ancestor),me,specs) if ancestor
    me=mergespec(me,descendant) unless descendant.nil?
    me
  end

  def logd(msg)

    # A convenience wrapper that logs DEBUG-level messages to the 'delayed'
    # logger, to appear later in the log file in a contiguous block. If the
    # delayed logger has not been initialized, write directly to stdout.

    s="#{@pre}: #{msg}"
    (@dlog)?(@dlog.debug s):(puts s)
  end

  def logd_flush
    @dlog.flush if @dlog
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

  def mergespec(me,descendant)

    # Merge two specs together, allowing descendant's settings to take
    # precedence. Top-level key-value pairs are set directly; arrays are
    # appended; nested hashes are handled via recursion.

    me={} if me.nil?
    descendant={} if descendant.nil?
    descendant.each do |k,v|
      if v.is_a?(Hash)
        me[k]=mergespec(me[k],v)
      elsif v.is_a?(Array)
        me[k]=(me[k].nil?)?(v):(me[k]+v)
      else
        me[k]=v
      end
    end
    me
  end

  def parse(file)

    # Instantiate a Ruby object from a YAML config file.

    file=File.expand_path(file)
    o=nil
    begin
      o=YAML.load(File.open(valid_file(file)))
    rescue Exception=>x
      logd x.message
      logd "* Backtrace:"
      x.backtrace.each { |e| logd e }
      die 'Error parsing YAML from '+file
    end
    unless @dlog.nil?
      c=File.basename(file)
      logd "Read config '#{c}':"
      die "Config '#{c}' is invalid" unless o
      pp(o).each_line { |e| logd e }
      logd_flush
    end
    o
  end

  def pp(o,d=0)

    # Pretty-print. Sorting provides diff-comparable output. Handles hashes or
    # arrays. Hashes may contain hashes or arrays, but arrays are expected to
    # contain scalars. (The latter limitation can be removed, but there's no
    # need at present.)

    s=""
    o.sort.each do |k,v|
      s+="  "*d+k
      ha=v.is_a?(Hash)||v.is_a?(Array)
      s+=(o.is_a?(Hash))?(": "+((ha)?("\n"+pp(v,d+1)):("#{quote(v)}\n"))):("\n")
    end
    s
  end

  def quote(s)

    # Wrap values instantiated as Ruby Strings in quotes, except for those
    # tagged '!unquoted'.

    if s.is_a?(Unquoted)
      s="#{s}"
    elsif s.is_a?(String)
      s="'#{s}'"
    end
    s
  end

  def threadmon(threads)

    # Loop over the supplied array of threads, removing each from the array and
    # joining it as it finishes. Sleep briefly between iterations. Joining each
    # thread allows exceptions to percolate up to be handled by the top-level TS
    # object.

    until threads.empty?
      threads.delete_if { |e| (e.alive?)?(false):(e.join;true) }
      sleep 5
    end
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

end # module Common

class Comparison

  include Common

  def initialize(a,ts)

    # Receive an array of runs to be compared together, instantiate each in a
    # separate thread, then monitor the threads for completion. Perform pairwise
    # comparison on the collected set of output specs (run names + file lists).
    # Instance variables from passed-in TS object are converted into instance
    # variables of this object.

    @ts=ts
    @dlog=XlogBuffer.new(ts.ilog)
    @pre="Comparison"
    threads=[]
    runs=[]
    a.each { |e| threads << Thread.new { runs << Run.new(e,ts).result } }
    threadmon(threads)
    s=a.join(', ')
    unless runs.size==1
      logi "#{s}: Checking..."
      comp(runs.sort { |r1,r2| r1.name <=> r2.name })
      logi "#{s}: OK"
    end
  end

end # class Comparison

class Run

  include Common

  attr_reader :result # because initialize()'s return value is the Run object

  def initialize(r,ts)

    # Set up instance variables, including instance references to the exposed
    # instance variables of the passed-in TS object. Due to the pair of mutex
    # locks, only one thread (the first to arrive) will perform the actual run;
    # threads that gain subsequent access to the critical region will break out
    # of the synchronize block and return immediately. The thread that performs
    # the run obtains its run spec, the build it needs and the canned data set.
    # It copies the run-scripts directory created by the build, modifies the
    # queuetime and runtime configuration files, runs and checks for the success
    # of the job, and either registers to create a baseline or (potentially) has
    # its output compared against the baseline. It stores into a global hash a
    # result value comprised of its name and its output files.

    @r=r
    @ts=ts
    @activejobs=@ts.activejobs
    @activemaster=@ts.activemaster
    @dlog=XlogBuffer.new(@ts.ilog)
    @pre="Run #{@r}"
    @ts.runmaster.synchronize do
      @ts.runlocks[@r]=Mutex.new unless @ts.runlocks.has_key?(@r)
    end
    @ts.runlocks[@r].synchronize do
      break if @ts.runs.has_key?(@r)
      @env=OpenStruct.new({:run=>loadenv(File.join(runsdir,@r))})
      self.extend(Object.const_get(@env.run.profile))
      @env.run.name=@r
      unless (@bline=@env.run.baseline)
        die "Config incomplete: No baseline name specified"
      end
      build
      @ts.runmaster.synchronize do
        unless @ts.havedata
          logd "* Preparing data for all test-suite runs..."
          lib_prep_data(@env)
          logd_flush
          @ts.havedata=true
        end
      end
      logi "Started"
      @rundir=File.join(Dir.pwd,"runs","#{@r}.#{@ts.uniq}")
      FileUtils.mkdir_p(@rundir) unless Dir.exist?(@rundir)
      logd "* Output from run prep:"
      @rundir=lib_prep_job(@env,@rundir)
      logd_flush
      logd "* Output from run:"
      stdout=lib_run_job(@env,@rundir)
      die "FAILED: See #{logfile}" if stdout.nil?
      jobcheck(stdout)
      runpair=OpenStruct.new
      runpair.name=@r
      runpair.files=lib_outfiles(@env,@rundir)
      @ts.runmaster.synchronize { @ts.runs[@r]=runpair }
      (@ts.genbaseline)?(baseline_reg):(baseline_comp)
      logd_flush
      logi "Completed"
    end
    @ts.runmaster.synchronize { @result=@ts.runs[@r] }
  end

  def jobdel(jobid)

    # Delete a run's job from the batch system.

    logd "Deleting job #{jobid}"
    cmd="#{lib_queue_del_cmd(@env)} #{jobid}"
    output,status=ext(cmd,{:die=>false})
  end

  private

  def baseline_comp

    # Compare this run's output files to its baseline.

    if @bline=='none'
      logd "Baseline comparison for #{@r} disabled, skipping"
    else
      blinetop=File.join(@ts.topdir,'baseline')
      blinepath=File.join(blinetop,@bline)
      if Dir.exist?(blinepath)
        logi "Comparing to baseline #{@bline}"
        blinepair=OpenStruct.new
        blinepair.name="baseline #{@bline}"
        blinepair.files=lib_outfiles(@env,blinepath)
        comp([@ts.runs[@r],blinepair])
        logi "Baseline comparison OK"
      else
        if Dir.exist?(blinetop)
          logw "No baseline '#{@bline}' found, continuing..."
        end
      end
    end
  end

  def baseline_reg

    # Volunteer to contribute to the suite's baseline, on behalf of the set
    # of runs sharing a common baseline name, this run's output files. Only one
    # run of the set performs this operation, due to the mutex.

    if @bline=='none'
      logd "Baseline registration for #{@r} disabled, skipping"
    else
      @ts.baselinemaster.synchronize do
        unless @ts.baselinesrcs.has_key?(@bline)
          @ts.baselinesrcs[@bline]=@ts.runs[@r]
        end
      end
    end
  end

  def build

    # Due to the pair of mutex locks, only one Run thread (the first to arrive)
    # will perform the actual build; threads that gain subsequent access to the
    # critical region will break out of the synchronize block and return
    # immediately. The thread that performs the build does so in an external
    # shell after obtaining its build spec. It stores into a global hash the
    # path to the directory containing the build's run scripts.

    b=@env.run.build
    @env.build=loadenv(File.join(buildsdir,b))
    @env.build.root=File.join(FileUtils.pwd,"builds")
    @ts.buildmaster.synchronize do
      @ts.buildlocks[b]=Mutex.new unless @ts.buildlocks.has_key?(b)
    end
    @ts.buildlocks[b].synchronize do
      unless @ts.builds.has_key?(b)
        logi "Build #{b} started"
        logd "* Output from build #{b} prep:"
        lib_build_prep(@env)
        logd_flush
        logd "* Output from build #{b}:"
        build_output=lib_build(@env)
        logd_flush
        @ts.buildmaster.synchronize do
          @ts.builds[b]=lib_build_post(@env,build_output)
        end
        logi "Build #{b} completed"
        logd_flush
      end
    end
    @ts.buildmaster.synchronize { @env.build.runfiles=@ts.builds[b] }
  end

  def hash_matches(file,hash)

    # Do they match?

    Digest::MD5.file(file)==hash
  end

  def jobcheck(stdout)

    # The job is assumed to have completed successfully if the string specified
    # in the regular expression below is found in its stdout.

    re=Regexp.new(lib_re_str_success(@env))
    die "FAILED: Could not find #{stdout}" unless File.exist?(stdout)
    File.open(stdout,'r') do |io|
      io.readlines.each { |e| return if re.match(e) }
    end
    die "FAILED: See #{stdout}"
  end

  def mod_namelist_file(nlfile,nlenv)

    # Modify a namelist file with values supplied by a config.

    nlspec=convert_o2h(nlenv)
    nlh=NamelistHandler.new(nlfile)
    nlspec.each do |nlk,nlv|
      nlv.each do |k,v|
        v=quote(v)
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
  :buildlocks,:buildmaster,:builds,:dlog,:genbaseline,:havedata,:ilog,:pre,
  :runlocks,:runmaster,:runs,:suite,:topdir,:uniq

  def initialize(tsname,cmd,rest)

    # The test-suite class. Provide a number of instance variables used
    # throughout the test suite, then branch to the appropriate method.

    @activemaster=Mutex.new
    @activejobs={}
    @baselinemaster=Mutex.new
    @baselinesrcs={}
    @buildlocks={}
    @buildmaster=Mutex.new
    @builds={}
    @dlog=nil
    @genbaseline=false
    @havedata=false
    @ilog=nil
    @pre=tsname
    @runlocks={}
    @runmaster=Mutex.new
    @retainbuilds=false # use existing builds (generally unsound)
    @runs={}
    @suite=nil
    @topdir=FileUtils.pwd
    @ts=self
    @uniq=Time.now.to_i
    dispatch(cmd,rest)
  end

  def avoid_baseline_conflicts(suitespec)

    # Examine each run the suite plans to execute, report any pre-existing
    # baseline-image directories that would potentially be clobbered if we
    # continue, then die.

    conflicts=[]
    suitespec.each do |group,runs|
      runs.each do |run|
        if (b=loadspec(File.join(runsdir,run))['baseline'])
          unless b=='none'
            d=File.join(@ts.topdir,'baseline',b)
            conflicts.push(b) if Dir.exist?(d)
          end
        end
      end
    end
    unless conflicts.empty?
      logi "Baseline conflicts:"
      conflicts.sort.uniq.each { |e| logi "  #{e} already exists" }
      die "Aborting..."
    end
  end

  def baseline(args=nil)

    # If 'baseline' was supplied as the command-line argument, record the fact
    # that baseline generation has been requested, then call dosuite() with the
    # supplied suite name.

    help(args,1) if args.empty?
    @genbaseline=true
    dosuite(args[0])
  end

  def baseline_gen

    # Generate a baseline. For each set of runs sharing a common value for the
    # 'baseline' key in their configs, copy the output of one run (the one that
    # managed to insert its result data in the baseline-sources array first) to
    # the subdirectory of baseline/<suite> named by that common 'baseline' key.

    @baselinesrcs.each do |r,src|
      logi "Creating #{r} baseline..."
      dst=File.join(@topdir,"baseline",r)
      src.files.each do |p1,p2|
        fullpath=File.join(p1,p2)
        minipath=p2
        logd "Copying #{fullpath} to baseline"
        dstdir=File.join(dst,File.dirname(minipath))
        FileUtils.mkdir_p(dstdir) unless Dir.exist?(dstdir)
        FileUtils.cp(fullpath,File.join(dst,minipath))
      end
      logi "Creating #{r} baseline: OK"
    end
  end

  def clean(extras=nil)

    # Clean up items created by the test suite. As well as those defined here,
    # remove any items specified by the caller.

    items=['builds','data','runs']
    Dir.glob("log.*").each { |e| items << e }
    extras.each { |e| items << e } unless extras.nil?
    items.sort.each do |e|
      if File.exists?(e)
        puts "Deleting #{e}"
        FileUtils.rm_rf(e)
      end
    end
  end

  def cleaner(args=nil)

    # Cleaner than clean: Delete the items defined in 'clean', plus these.
    # 'args' is ignored.

    clean(['baseline','data.tgz'])
  end

  def dispatch(cmd,args)

    # If the given method is approved as a command-line action, call it with
    # the given arguments. If it is a suite name, run the suite. Otherwise, show
    # usage info and exit with error.

    okargs=['baseline','clean','cleaner','help','run','show']
    suites=Dir.glob(File.join(suitesdir,"*")).map { |e| File.basename(e) }
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

    setup
    @suite=suite
    f=File.join(suitesdir,@suite)
    unless File.exists?(f)
      die "Suite '#{@suite}' not found"
    end
    logi "Running test suite '#{@suite}'"
    threads=[]
    begin
      suitespec=loadspec(f)
      suitespec.delete('extends')
      avoid_baseline_conflicts(suitespec) if @genbaseline
      mkbuilds
      suitespec.each do |group,runs|
        if runs
          threads << Thread.new { Comparison.new(runs.sort.uniq,self) }
        else
          logi "Suite group #{group} empty, ignoring..."
        end
      end
      threadmon(threads)
    rescue Interrupt,Exception=>x
      threads.each { |e| e.kill }
      halt(x)
    end
    baseline_gen if @genbaseline
    logd_flush
    msg="ALL TESTS PASSED"
    msg+=" -- but note WARNING(s) above!" if @ilog.warned
    logi msg
  end

  def halt(x)

    # Terminate the test-suite run. First try to kill any submitted batch jobs
    # that are still active. Print some (hopefully helpful) diagnostic messages
    # and then exit.

    unless @activejobs.nil? or @activejobs.empty?
      logi "Stopping runs..."
      @activemaster.synchronize do
        @activejobs.each do |jobid,job|
          job.jobdel(jobid) if job.respond_to?(:jobdel)
        end
      end
    end
    logd x.message
    logd "* Backtrace:"
    x.backtrace.each { |e| logd e }
    logd_flush
    pre=(@suite.nil?)?("Run"):("Test suite '#{@suite}'")
    logi "#{pre} FAILED"
    exit 1
  end

  def help(args=nil,status=0)
    puts
    puts "usage: #{@pre} <suite>"
    puts "       #{@pre} baseline <suite>"
    puts "       #{@pre} clean"
    puts "       #{@pre} cleaner"
    puts "       #{@pre} help"
    puts "       #{@pre} run <run>"
    puts "       #{@pre} show run <run>"
    puts "       #{@pre} show runs"
    puts "       #{@pre} show suite <suite>"
    puts "       #{@pre} show suites"
    puts
    puts "See the README for more information."
    puts
    exit status
  end

  def mkbuilds

    # Create a 'builds' directory (potentially after removing an existing one)
    # to contain the objects created by the build-automation system.

    builds='builds'
    if Dir.exist?(builds) and not @retainbuilds
      FileUtils.rm_rf(builds)
      @ilog.debug("Deleted existing '#{builds}'")
    end
    unless Dir.exist?(builds)
      FileUtils.mkdir_p(builds)
      @ilog.debug("Created empty '#{builds}'")
    end
  end

  def run(args=nil)

    # Handle the command-line "run" argument, to perform a single named run.

    die "No run name specified" if args.empty?
    setup
    begin
      mkbuilds
      Run.new(args[0],self)
    rescue Interrupt,Exception=>x
      halt(x)
    end
  end

  def setup

    # Perform common tasks needed for either full-suite or single-run
    # invocations.

    @ilog=Xlog.new(@uniq)
    @dlog=XlogBuffer.new(@ilog)
    trap('INT') do
      logi "Interrupted"
      raise Interrupt
    end
  end

  def show(args)

    # Pretty-print a fully composed run or suite configuration.

    type=args[0]
    name=args[1]
    if ['run','suite'].include?(type)
      die "No #{type} specified" unless name
      dir=(type=='run')?(runsdir):(suitesdir)
      file=File.join(dir,name)
      die "'#{name}' not found in #{dir}" unless File.exist?(file)
      spec=loadspec(file)
      spec.delete("extends")
      puts
      puts "# #{ancestry(file).join(' < ')}"
      puts
      puts pp(spec)
      puts
    elsif ['runs','suites'].include?(type)
      dir=(type=='runs')?(runsdir):(suitesdir)
      puts
      puts "Available #{type}:"
      puts
      Dir.glob("#{dir}/*").sort.each { |item| puts "  #{File.basename(item)}" }
      puts
    else
      help(args,1)
    end
  end

end # class TS

class Unquoted

  # An alternative to String for namelist values that must not be quoted.

  def initialize(v) @v=v end
  def init_with(coder) @v=coder.scalar end
  def to_s() @v end

end # class Unquoted

YAML.add_tag('!unquoted',Unquoted)

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

  def initialize(uniq)
    # File logger
    @file="log.#{uniq}"
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
