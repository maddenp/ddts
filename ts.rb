require 'digest/md5'
require 'fileutils'
require 'find'
require 'logger'
require 'ostruct'
require 'profiles'
require 'thread'
require 'time'
require 'yaml'

module Common

  def buildsdir() "conf/builds" end
  def runsdir()   "conf/runs"   end
  def suitesdir() "conf/suites" end

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

    r1=runs.delete_at(0)
    r1_name=r1.name
    r1_files=r1.files.reverse
    r1_bases=r1_files.collect { |a,b| b }.sort
    runs.each do |r2|
      r2_name=r2.name
      r2_files=r2.files.reverse
      r2_bases=r2_files.collect { |a,b| b }.sort
      logd "Comparing #{r1_name} to #{r2_name}"
      m="(#{r1_name} vs #{r2_name})"
      unless r1_bases==r2_bases
        logd "File list matching FAILED #{m}, lists are:"
        logd "#{r1_name} files: #{r1_bases.join(' ')}"
        logd "#{r2_name} files: #{r2_bases.join(' ')}"
        die "File list matching FAILED #{m}"
      end
      r1_stack=r1_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      r2_stack=r2_files.sort { |a,b| a[1]<=>b[1] }.collect { |a,b| File.join(a,b) }
      until r1_stack.empty?
        f1=r1_stack.pop
        f2=r2_stack.pop
        fb=File.basename(f1)
        unless FileUtils.cmp(f1,f2)
          logd "Comparing #{fb}: FAILED #{m}"
          die "Comparison failed #{m}"
        end
        logd "Comparing #{fb}: OK #{m}"
      end
      logd "Comparing #{r1_name} to #{r2_name}: OK"
    end
    logd_flush
  end

  def die(msg=nil)

    # Flush any messages accumulated in the 'delayed' logger, report a FATAL-
    # level message, and raise an Interrupt, to be caught by the top-level
    # TS object. If the 'immediate' logger has not been initialized (indicating
    # that the test suite has died very early), simply print the message and
    # exit.

    if @ilog.nil?
      puts "\n#{msg}\n\n"
      exit 1
    end
    logd_flush
    @ilog.fatal("#{@pre}: #{msg}") unless msg.nil?
    ($!)?(raise):(exit 1)
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

  def logi(msg)

    # A convenience wrapper that logs INFO-level messages to the 'immediate'
    # logger, to appear both on stdout and in the log file.

    @ilog.info "#{@pre}: #{msg}"
  end

  def logw(msg)

    # A convenience wrapper that logs WARN-level messages to the 'immediate'
    # logger, to appear both on stdout and in the log file.

    @ilog.warn "#{@pre}: WARNING! #{msg}"
    @ilog.warned=true
  end

  def parse(file)

    # Instantiate a Ruby object from a YAML config file.

    file=File.expand_path(file)
    o=begin
        YAML.load(File.open(valid_file(file)))
      rescue Exception=>x
        logd x.message
        logd "* Backtrace:"
        x.backtrace.each { |e| logd e }
        die 'Error parsing YAML from '+file
      end
    unless @dlog.nil?
      c=File.basename(file)
      logd "Read config #{c}:"
      die "Config '#{c}' is invalid" unless o
      pp(o).each { |e| logd e }
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

    # Handle a tagged YAML value according to the rule(s) defined for its type
    # id. If an untagged value instantiated as a Ruby String, wrap it in quotes.

    if s.respond_to?(:type_id)
      if (s.type_id=='unquoted')
        s=s.value
      else
        die "Unhandled YAML tag: #{s.type_id}"
      end
    elsif s.is_a?(String)
      s="'#{s}'"
    end
    s
  end

  def specget(file,descendant=nil,specs=nil)

    # Parse YAML spec from file, potentially using recursion to merge the
    # current spec onto a specified ancestor. Keep track of spec files already
    # processed to avoid graph cycles.

    specs=[] if specs.nil?
    die "Circular dependency detected for #{file}" if specs.include?(file)
    specs << file
    me=parse(file)
    ancestor=me['extends']
    me=specget("#{File.dirname(file)}/#{ancestor}",me,specs) if ancestor
    me=specmerge(me,descendant) unless descendant.nil?
    me
  end

  def specmerge(me,descendant)

    # Merge two specs together, allowing descendant's settings to take
    # precedence. Top-level key-value pairs are set directly; arrays are
    # appended; nested hashes are handled via recursion.

    me={} if me.nil?
    descendant={} if descendant.nil?
    descendant.each do |k,v|
      if v.is_a?(Hash)
        me[k]=specmerge(me[k],v)
      elsif v.is_a?(Array)
        me[k]=(me[k].nil?)?(v):(me[k]+v)
      else
        me[k]=v
      end
    end
    me
  end

  def threadmon(threads)

    # Loop over the supplied array of threads, removing each from the array and
    # joining it as it finishes. Sleep briefly between iterations. Joining each
    # thread allows exceptions to percolate up to be handled by the top-level TS
    # object.

    until threads.empty?
      threads.each do |e|
        unless e.alive?
          threads.delete(e)
          e.join
        end
      end
      sleep 1
    end
  end

  def valid_dir(dir)

    # Return the supplied dir if it exists -- otherwise die.

    dir=File.expand_path(dir)
    die "Directory #{dir} not found" unless File.directory?(dir)
    dir
  end

  def valid_file(file)

    # Return the supplied file if it exists -- otherwise die.

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
    @ts.instance_variables.each { |v| eval "#{v}=@ts.#{v[1..-1]}" }
    @dlog=XlogBuffer.new(@ilog)
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
    @ts.instance_variables.each { |v| eval "#{v}=@ts.#{v[1..-1]}" }
    @dlog=XlogBuffer.new(@ilog)
    @pre="Run #{@r}"
    @runmaster.synchronize do
      @runlocks[@r]=Mutex.new unless @runlocks.has_key?(@r)
    end
    @runlocks[@r].synchronize do
      break if @runs.has_key?(@r)
      @runspec=specget("#{runsdir}/#{@r}")
      self.extend(Object.const_get(@runspec['profile']))
      @runspec['name']=@r
      unless @bline=@runspec['baseline'] # Yes: =, not ==
        die "Config incomplete: No baseline name specified"
      end
      buildrun=build
      prep_data
      logi "Started"
      @rundir=File.join(Dir.pwd,"runs","#{@r}.#{@uniq}")
      FileUtils.mkdir_p(@rundir)
      logd "* Output from run prep:"
      @rundir=lib_prep_job(@rundir,@runspec)
      logd_flush
      logd "* Output from run:"
      stdout=lib_run_job(@rundir,@runspec,@activeruns)
      die "FAILED -- see #{@ilog.file}" if stdout.nil?
      jobcheck(stdout)
      runpair=OpenStruct.new
      runpair.name=@r
      runpair.files=lib_outfiles(@rundir)
      @runs[@r]=runpair
      (@genbaseline)?(baseline_reg):(baseline_comp)
      logd_flush
      logi "Completed"
    end
    @result=@runs[@r]
  end

  def jobdel

    # Delete a run's job from the batch system.

    logd "Deleting job #{@runspec['jobid']}"
    cmd="#{lib_queue_del_cmd(@runspec)} #{@runspec['jobid']} 2>&1"
    IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
    logd_flush
  end

  private

  def baseline_comp

    # Compare this run's output files to its baseline.

    if @bline=='none'
      logd "Baseline comparison for #{@r} disabled, skipping"
    else
      suitebase=File.join(@topdir,'baseline',@suite)
      if File.directory?(suitebase)
        blinepath=File.join(suitebase,@bline)
        if File.directory?(blinepath)
          logi "Comparing to baseline #{@bline}"
          blinepair=OpenStruct.new
          blinepair.name='baseline'
          blinepair.files=lib_outfiles(blinepath)
          comp([@runs[@r],blinepair])
          logi "Baseline comparison OK"
        else
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
      @baselinemaster.synchronize do
        @baselinesrcs[@bline]=@runs[@r] unless @baselinesrcs.has_key?(@bline)
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

    b=@runspec['build']
    buildspec=parse("#{buildsdir}/#{b}")
    buildspec['buildroot']=File.join(FileUtils.pwd,"builds")
    buildspec['retainbuilds']=@retainbuilds
    @runspec['buildspec']=buildspec
    @buildmaster.synchronize do
      @buildlocks[b]=Mutex.new unless @buildlocks.has_key?(b)
    end
    @buildlocks[b].synchronize do
      break if @builds.has_key?(b)
      logi "Build #{b} started"
      logd "* Output from build #{b} prep:"
      lib_build_prep(buildspec)
      logd_flush
      cmd="#{lib_build_cmd(buildspec)} 2>&1"
      logd "* Output from build #{b}:"
      logd "Executing build command: #{cmd}"
      output=[]
      IO.popen(cmd) { |io| io.readlines.each { |e| output << e } }
      output.each { |e| logd "#{e}" }
      die "FAILED -- see #{@ilog.file}" unless $?.exitstatus==0
      @builds[b]=lib_build_post(buildspec,output)
      logi "Build #{b} completed"
      logd_flush
    end
    @runspec['buildrun']=@builds[b]
  end

  def get_data

    # Obtain the test suite's canned data set, whose md5 checksum has previously
    # been computed via the system 'md5sum' utility and recorded as the 'md5'
    # variable here. If a data archive file is already present and hashes to the
    # expected value, we're done.

    f='data.tgz'
    cmd,md5=lib_dataspecs
    cmd+=" 2>&1"
    unless File.exists?(f) and hash_matches(f,md5)
      logd "Getting data: #{cmd}"
      IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
      stat=$?.exitstatus
      die "Failed to get data" unless stat==0
      unless hash_matches(f,md5)
        die "Data archive #{f} has incorrect md5 hash"
      end
    end
    logd "Data archive #{f} ready"
    f
  end

  def hash_matches(file,hash)

    # Do they match?

    Digest::MD5.hexdigest(File.read(file))==hash
  end

  def jobcheck(stdout)

    # The job is assumed to have completed successfully if the string specified
    # in the regular expression below is found in its stdout.

    re=Regexp.new(lib_re_str_success)
    File.open(stdout,'r') do |io|
      io.readlines.each { |e| return if re.match(e) }
    end
    die "FAILED -- see #{stdout}"
  end

  def prep_data

    # Extract the test suite's canned data set. A global mutex protects this
    # operation so that only one run may perform the export and extraction.

    @runmaster.synchronize do
      return if @ts.havedata
      logd "* Preparing data for all test-suite runs..."
      f=get_data
      cmd="tar xvzf #{f} 2>&1"
      logd "Extracting data: #{cmd}"
      IO.popen(cmd) { |io| io.readlines.each { |e| logd "#{e}" } }
      stat=$?.exitstatus
      die "Data extract FAILED -- see #{@ilog.file}" unless stat==0
      logd "Data extract complete"
      logd_flush
      @ts.havedata=true
    end
  end

end # class Run

class TS

  include Common

  attr_accessor :activeruns,:baselinemaster,:baselinesrcs,:buildlocks,
  :buildmaster,:builds,:dlog,:genbaseline,:havedata,:ilog,:loglock,:pre,
  :retainbuilds,:runlocks,:runmaster,:runs,:suite,:topdir,:uniq

  def initialize(cmd,rest)

    # The test-suite class. Provide a number of instance variables used
    # throughout the test suite, then branch to the appropriate method.

    @activeruns=[]
    @baselinemaster=Mutex.new
    @baselinesrcs={}
    @buildlocks={}
    @buildmaster=Mutex.new
    @builds={}
    @genbaseline=false
    @havedata=false
    @loglock=Mutex.new
    @pre='ts'
    @runlocks={}
    @runmaster=Mutex.new
    @runs={}
    @retainbuilds=false # use builds from last test-suite run (generally unsound)
    @topdir=FileUtils.pwd
    @uniq=Time.now.to_i
    (cmd.nil?)?(dosuite):(dispatch(cmd,rest))
  end

  def baseline(args=nil)

    # If 'baseline' was supplied as the command-line argument, make sure no
    # baseline already exists; set the baseline-generation flag; and call
    # dosuite() with the supplied suite name, or 'standard' by default.

    suite=args[0]||'standard'
    d="baseline/#{suite}"
    die "Directory '#{d}' for suite '#{suite}' exists" if File.exists?(d)
    @genbaseline=true
    dosuite(suite)
  end

  def baseline_gen

    # Generate a baseline. For each set of runs sharing a common value for the
    # 'baseline' key in their configs, copy the output of one run (the one that
    # managed to insert its result data in the baseline-sources array first) to
    # the subdirectory of baseline/<suite> named by that common 'baseline' key.

    @baselinesrcs.each do |r,src|
      logi "Creating #{r} baseline..."
      dst="#{@topdir}/baseline/#{@suite}/#{r}"
      src.files.each do |p1,p2|
        fullpath=File.join(p1,p2)
        minipath=p2
        logd "Copying #{fullpath} to baseline"
        FileUtils.mkdir_p("#{dst}/#{File.dirname(minipath)}")
        FileUtils.cp(fullpath,"#{dst}/#{minipath}")
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

    okargs=['baseline','clean','cleaner','help','show']
    suites=Dir.glob(File.join(suitesdir,"*")).map { |e| File.basename(e) }
    if okargs.include?(cmd)
      send(cmd,args)
    elsif suites.include?(cmd)
      dosuite(cmd)
    else
      help(args,1)
    end
  end

  def dosuite(suite=nil)

    # Perform a test suite. Essentially, this involves comparing against each
    # other the output of sets of runs declared in the suite definition to be
    # comparable. Use the optional suite name, if supplied, or the default name.
    # The bottom-level arrays in the YAML suite definition specify the names of
    # runs to compare together. Comparison objects are instantiated to perform
    # the necessary runs and compare their output. Each Comparison is run in a
    # thread, and the set of threads is monitored for completion. This program's
    # main thread of execution blocks on the call to threadmon() until all
    # Comparisons are complete, or until a thread aborts and raises and
    # exception, which is caught and handled here. A list of active Run objects
    # is collected so that, in the event of suite failure or interruption via
    # ctrl-c, commands can be issued to abort any queued jobs. A baseline is
    # generated if one was requested.

    @ilog=Xlog.new(@uniq,@loglock)
    @dlog=XlogBuffer.new(@ilog)
    @suite=suite||'standard'
    f="#{suitesdir}/#{@suite}"
    unless File.exists?(f)
      die "Suite '#{@suite}' not found"
    end
    logi "Running test suite '#{@suite}'"
    mkbuilds unless @retainbuilds
    threads=[]
    trap('INT') do
      logi "Interrupted"
      raise Interrupt
    end
    begin
      suitespec=specget(f)
      suitespec.delete('extends')
      suitespec.each do |k,v|
        threads << Thread.new { Comparison.new(v.sort.uniq,self) }
      end
      threadmon(threads)
    rescue Interrupt,Exception=>x
      threads.each { |e| e.kill }
      unless @activeruns.empty?
        logi "Stopping runs..."
        @activeruns.each { |e| e.jobdel }
      end
      logd x.message
      logd "* Backtrace:"
      x.backtrace.each { |e| logd e }
      logd_flush
      logi "Test suite '#{@suite}' FAILED"
      exit 1
    end
    baseline_gen if @genbaseline
    logd_flush
    msg="ALL TESTS PASSED"
    msg+=" -- but note WARNING(s) above!" if @ilog.warned
    logi msg
  end

  def help(args=nil,status=0)
    puts
    puts "usage: #{@pre} [suite]"
    puts "       #{@pre} baseline [suite]"
    puts "       #{@pre} clean"
    puts "       #{@pre} cleaner"
    puts "       #{@pre} help"
    puts "       #{@pre} show run|suite <name>"
    puts
    exit status
  end

  def mkbuilds

    # Create a 'builds' directory (potentially after removing an existing one)
    # to contain the objects created by the build-automation system.

    builds='builds'
    if File.directory?(builds)
      FileUtils.rm_rf(builds)
      @ilog.debug("Deleted existing '#{builds}'")
    end
    FileUtils.mkdir_p(builds)
    @ilog.debug("Created empty '#{builds}'")
  end

  def show(args)
    type=args[0]
    help(args,1) unless ['run','suite'].include?(type)
    name=args[1]
    die "No #{type} specified" unless name
    dir=(type=='run')?(runsdir):(suitesdir)
    file=File.join(dir,name)
    die "'#{name}' not found in #{dir}" unless File.exist?(file)
    spec=specget(file)
    puts
    puts "# #{ancestry(file).join(' < ')}"
    puts
    puts pp(spec,1)
    puts
  end

end # class TS

class Unquoted

  # Emulate the behavior of the YAML object tagged !unquoted.

  attr_reader :value

  def initialize(s)
    @value=s
  end

  def type_id
    'unquoted'
  end

end # class Unquoted

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

  def initialize(uniq,lock)
    @lock=lock
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
    @lock.synchronize do
      if m==:flush
        a[0].each do |e|
          @flog.send(e[0],e[1])
          @slog.send(e[0],e[1])
        end
      else
        @flog.send(m,a.first)
        @slog.send(m,a.first)
      end
    end
  end

end # class Xlog

class XlogBuffer

  # A wrapper around Xlog to buffer messages for batch output. The flush method
  # sends buffered messages to the primary ('immediate') logger, then resets the
  # buffer.

  def initialize(ilog)
    @ilog=ilog
    @buffer=[]
  end

  def flush
    @ilog.send(:flush,@buffer)
    @buffer=[]
  end

  def method_missing(m,*a)
    @buffer << [m,a[0].chomp]
  end

end # class XlogBuffer

# Command-line invocation:

if __FILE__==$0
  TS.new(ARGV[0],ARGV[1..-1])
end

# paul.a.madden@noaa.gov
