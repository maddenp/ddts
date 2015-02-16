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
require "ostruct"
require "set"
require "thread"
require "time"
require "yaml"

begin
  require "library"
rescue LoadError=>ex
  puts "NOTE: No library.rb found, using defaults.rb"
end

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
      puts "\nERROR: #{msg}\n\n"
      exit 1
    end
    logd_flush
    @ts.ilog.fatal("#{@pre}: ERROR: #{msg}") unless msg.nil?
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
    die "Run failed, could not find #{stdout}" unless File.exist?(stdout)
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

  def logi_block(level,msg_block)

    # Like logi, but takes an array of strings and logs them as a contiguous
    # block in the log file.

    msg_block=msg_block.map { |msg| "#{@pre}: #{msg}" }
    @ts.ilog.logi_block(level,msg_block)

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

  def ancestry(dir,name,chain=nil)

    # Return an array containing the ancestry of the given definition (including
    # the definition itself), by following the chain of 'ddts_extends' keys.

    name,override,hash=destruct(name)
    (chain||=[]).push(name)
    me=parse(find_def(dir,name,true))
    ancestor=me["ddts_extends"]
    ancestry(dir,ancestor,chain) if ancestor
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

  def destruct(s)

    name,sep,override=s.partition('/')
    list=override.dup
    return [s,"",{}] if name.empty? or not list.include?('=')
    hash={}
    until list.empty?
      arr='((!replace\s+)?\[[^\[\]]*?\])'
      del='!delete'
      qsd='("[^\"]*")'
      qss='(\'[^\']*\')'
      unq='!unquoted\s+[^,\'\"\[\]]+'
      val='[^!,\'\"\[\]]+[^,\'\"\[\]]*'
      re=/\s*[\w:]+\s*=\s*(#{del}|#{unq}|#{val}|#{qss}|#{qsd}|#{arr})/
      x,first,list=list.partition(re)
      return [s,"",{}] unless x=~/^,?$/
      k,x,v=first.strip.partition(/\s*=\s*/)
      v=YAML.load(v)
      if k.include?(":") and (a=k.split(/\s*:\s*/))
        g=(hash[a[0]]||={})
        g.merge!(a[1...-1].reverse.reduce({a[-1]=>v}) { |m,e| m={e=>m} })
      else
        hash[k]=v
      end
    end
    [name,override,hash]

  end

  def destruct_build(b)

    name,override,hash=destruct(b)
    if override.empty?
      unique_name=name
    else
      unique_name="#{name}_#{Digest::MD5.hexdigest(override)}"
    end
    [name,override,hash,unique_name]

  end

  def fatal_backtrace(backtrace,message=nil)
    if message
      backtrace.push("")
      backtrace.push(message)
    end
    logi_block(:fatal,backtrace)
    exit 1
  end

  def find_def(dir,name,abstract_ok)

    # Look for a definition file first in the directory corresponding to the
    # definition type, then in its 'abstract' subdirectory.

    def_file=File.join(dir,name)
    return def_file if File.exist?(def_file)
    def_file=File.join(dir,"abstract",name)
    die "No definition '#{name}' found in #{dir}" unless File.exist?(def_file)
    die "Definition '#{name}' is abstract" unless abstract_ok
    def_file
  end

  def load_def(dir,_def,abstract_ok,quiet=false,descendant=nil,seen=[])

    # Parse YAML definition from file, potentially using recursion to merge the
    # current definition onto a specified ancestor. Keep track of definition
    # files already processed to avoid graph cycles.

    name,override,hash=destruct(_def)
    die "Circular dependency detected for '#{name}'" if seen.include?(name)
    seen.push(name)
    me=parse(find_def(dir,name,abstract_ok),quiet)
    die "No valid definition found for '#{name}'" unless me
    ancestor=me["ddts_extends"]
    me=load_def(dir,ancestor,true,quiet,me,seen) if ancestor
    if ancestor and not quiet
      logd ""
      logd "Final composed definition for #{_def}:"
      logd ""
      pp(me).each_line { |e| logd e }
    end
    me=merge_def(me,descendant) if descendant
    final=merge_def(me,hash)
    final

  end

  def load_env(dir,name)

    convert_h2o(load_def(dir,name,false))

  end

  def logd_flush

    @dlog.flush if @dlog

  end

  def merge_def(me,descendant)

    # Merge two definitions together, allowing descendant's settings to take
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
        me[k]=merge_def(me[k],v)
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
      die "Cannot parse YAML from "+file
    end
    if @dlog and not quiet
      c=File.basename(file)
      logd ""
      logd "Read definition '#{c}':"
      logd ""
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
      o.each do |e|
        next if e.is_a?(YAML_Delete)
        s+="  "*level+"- "
        s+=pp(e,level,(a_or_h(e))?(false):(true),false)
      end
    elsif o.is_a?(Hash)
      ppsort(o).each do |k,v|
        next if v.is_a?(YAML_Delete)
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
  include Library

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
  include Library

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
    @pre="Run #{@r}"
    @dlog=XlogBuffer.new(@ts.ilog)
    name,override,hash=destruct(@r)
    unless override.empty?
      @ts.runmaster.synchronize do
        @@variant_run={} unless defined?(@@variant_run)
        @@variant_run[name]||=0
        @r="#{name}_v#{@@variant_run[name]+=1}"
      end
      @pre="Run #{@r}"
      logi "Assigning name '#{@r}' to run '#{r}'"
    end
    @activejobs=@ts.activejobs
    @activemaster=@ts.activemaster

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
      @env.run=load_env(run_defs,r)
      logd_flush
      @env.run.ddts_name=@r
      unless override.empty?
        @env.run.ddts_basename=name
        @env.run.ddts_override=override
      end
      @bline=@env.run.ddts_baseline

      # Wait on required runs.

      if (req=@env.run.ddts_require)
        req=[req] unless req.is_a?(Array)
        suffix=(req.size==1)?(""):("(s)")
        logi "Waiting on required run#{suffix}: #{req.join(', ')}"
        @env.run.ddts_require_results={}
        until req.empty?
          @ts.runmaster.synchronize do
            req.each do |e|
              if (result=@ts.runs_completed[e] and result!=:incomplete)
                if result.failed
                  die "Run '#{@r}' depends on failed run '#{e}'"
                end
                @env.run.ddts_require_results[e]=result
                req.delete(e)
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
        rundir=@env.run.ddts_root=File.join(runs_dir,"#{@r}.#{@ts.timestamp}")
        FileUtils.mkdir_p(rundir) unless Dir.exist?(rundir)
        logd "* Output from run prep:"
        prepkit=invoke(:lib_run_prep,:run,@env)
        logd_flush
        logd "* Output from run:"
        runkit=invoke(:lib_run,:run,@env,prepkit)
        postkit=invoke(:lib_run_post,:run,@env,runkit)
        output_path=invoke(:lib_run_check,:run,@env,postkit)
        success=(output_path)?(true):(false)
        files=(success)?(invoke(:lib_outfiles,:run,@env,output_path)):([])
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
          die "Run failed, see #{logfile}"
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
      logd "No baseline specified for #{@r}, skipping comparison"
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
    # shell after obtaining its build definition. It stores into a global hash
    # the information required by its dependent runs.

    def update_builds(build,failed,result)
      @ts.buildmaster.synchronize do
        x=OpenStruct.new({:failed=>failed,:result=>result})
        @env.suite.ddts_builds||={}
        @env.suite.ddts_builds[build]=x
        @ts.builds[build]=x
      end
    end

    build=@env.run.ddts_build
    @env.build=load_env(build_defs,build)
    logd_flush
    name,override,hash,unique_name=destruct_build(build)
    unless unique_name==name
      logi "Assigning name '#{unique_name}' to build '#{build}'"
    end
    @env.build.ddts_root=File.join(builds_dir,unique_name)
    @ts.buildmaster.synchronize do
      @ts.buildlocks[build]=Mutex.new unless @ts.buildlocks.has_key?(build)
    end
    @ts.buildlocks[build].synchronize do
      unless @ts.builds.has_key?(build)
        update_builds(build,true,nil) # assume the worst
        logi "Build #{unique_name} started"
        logd "* Output from build #{unique_name} prep:"
        prepkit=invoke(:lib_build_prep,:run,@env)
        logd_flush
        logd "* Output from build #{unique_name}:"
        buildkit=invoke(:lib_build,:run,@env,prepkit)
        logd_flush
        result=invoke(:lib_build_post,:run,@env,buildkit)
        update_builds(build,false,result)
        logi "Build #{unique_name} completed"
      end
    end
    die "Required build unavailable" if @ts.builds[build].failed
    @ts.buildmaster.synchronize do
      x=@ts.builds[build]
      @env.build.ddts_result=(x.failed)?(:build_failed):(x.result)
    end

  end

end # class Run

class TS

  include Common
  include Library

  attr_accessor :activemaster,:activejobs,:baselinemaster,:baselinesrcs,
  :buildlocks,:buildmaster,:builds,:dlog,:env,:gen_baseline_dir,:havedata,:ilog,
  :pre,:runlocks,:runmaster,:runs_all,:runs_completed,:suite,:timestamp,
  :use_baseline_dir

  def initialize(invoked_as,args)

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
    @pre=invoked_as
    @runlocks={}
    @runmaster=Mutex.new
    @runs_all=SortedSet.new
    @runs_completed={}
    @suite=nil
    @timestamp=Time.now.to_i
    @ts=self
    @use_baseline_dir=nil
    dispatch(args)

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
    # exctract the set of unique 'build' keys from the given run definition(s)
    # and remove any build directories with the same names. NB: This assumes
    # that build directories are named identically to build definition names!

    logd "build_init:"
    logd "----"
    runs=(run_or_runs.respond_to?(:each))?(run_or_runs):([run_or_runs])
    builds=runs.reduce(Set.new) do |m,e|
      build_name=load_def(run_defs,e,false,true)["ddts_build"]
      name,override,hash,unique_name=destruct_build(build_name)
      unless unique_name==name
        logd "Mapping build '#{build_name}' to '#{unique_name}'"
      end
      m.add(File.join(builds_dir,unique_name))
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

  def dispatch(args)

    # If the given method is approved as a command-line action, call it with
    # the given arguments. If it is a suite name, run the suite. Otherwise, show
    # usage info and exit with error.

    suite=args.join(" ")
    cmd=(x=args.shift)?(x):("help")
    cmd=cmd.gsub(/-/,"_")
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
    end
    if okargs.include?(cmd)
      send(cmd,args)
    else
      dosuite(suite)
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
    name,override,hash=destruct(suite)
    unless File.exists?(File.join(suite_defs,name))
      die "Suite '#{name}' not found"
    end
    logi "Running test suite '#{suite}'"
    threads=[]
    begin
      logd "Loading suite definition '#{suite}'"
      suitedef=load_def(suite_defs,suite,false)
      logd_flush
      suitedef.each do |k,v|
        # Assume that array values are run groups and move all scalar values
        # into env.suite, assuming that these are either reserved or user-
        # defined suite-level settings.
        eval "env.suite.#{k}=suitedef.delete(k)" unless v.is_a?(Array)
      end
      env.suite.ddts_totalruns=0
      env.suite.ddts_totalfailures=0
      env.suite.ddts_suitename=suite
      FileUtils.mkdir_p(tmp_dir)
      invoke(:lib_suite_prep,:suite,env)
      suitedef.each do |k,v|
        v.each { |x| runs_all.add(x) if x.is_a?(String) }
      end
      sanity_checks(gen_baseline_dir)
      build_init(runs_all)
      suitedef.each do |group,runs|
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
      fatal_backtrace(x.backtrace,x.message)
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

    help(args,1) if args.size < 2
    gen_baseline_common(args)
    dosuite(args.join(" "))

  end

  def gen_baseline_common(args)
    @gen_baseline_dir=args.shift
    logd "Using gen-baseline directory '#{@gen_baseline_dir}'"
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
    puts "       #{pre} make-app [path]"
    puts "       #{pre} help"
    puts "       #{pre} run [ gen-baseline <dir> ] <run>"
    puts "       #{pre} run [ use-baseline <dir> ] <run>"
    puts "       #{pre} show build <build>"
    puts "       #{pre} show builds"
    puts "       #{pre} show run <run>"
    puts "       #{pre} show runs"
    puts "       #{pre} show suite <suite>"
    puts "       #{pre} show suites"
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
    write_definition(defs,"builds","build1","set: me\n")
    write_definition(defs,"runs","run1","ddts_build: build1\n")
    write_definition(defs,"suites","suite1","group1:\n  - run1\n")
    puts"\nCreated application skeletion in #{approot}\n\n"
  end

  def run(args=nil)

    # Handle the command-line "run" argument, to perform a single named run.

    setup
    begin
      if args.first=="gen-baseline"
        args.shift
        gen_baseline_common(args)
      elsif args.first=="use-baseline"
        args.shift
        use_baseline_common(args)
      end
      run=args.join(" ")
      runs_all.add(run)
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
      fatal_backtrace(x.backtrace,x.message)
    end

  end

  def sanity_checks(check_baseline_conflicts=false)

    baseline_conflict=false
    unsatisfied_require=false

    builds_all=Dir.glob(File.join(build_defs,"*")).map { |e| File.basename(e) }

    runs_all.each do |run|

      rundef=load_def(run_defs,run,false,true)

      # If a baseline is being generated, check for any pre-existing baseline
      # directories that would potentially be clobbered if we continue.

      if check_baseline_conflicts and (b=rundef["ddts_baseline"])
        if Dir.exist?(File.join(gen_baseline_dir,b))
          logi "ERROR: Run '#{run}' could overwrite baseline '#{b}'"
          baseline_conflict=true
        end
      end

      # Check that all run dependencies are satisfied by scheduled runs.

      unless (r=rundef["ddts_require"])==nil
        r=[r] unless r.is_a?(Array)
        r.each do |e|
          unless runs_all.include?(e)
            logi "ERROR: Run '#{run}' depends on unscheduled run '#{e}'"
            unsatisfied_require=true
          end
        end
      end

      # Check that all runs have defined 'build'.

      unless name=rundef["ddts_build"]
        die "Run '#{run}' not associated with any build"
      end
      name,override,hash=destruct(name)
      unless builds_all.include?(name)
        die "Run '#{run}' associated with missing or abstract build '#{name}'"
      end

    end

    die "Aborting..." if baseline_conflict or unsatisfied_require

  end

  def setup

    # Perform common tasks needed for either full-suite or single-run
    # invocations.

    env.ddts_ilog=(@ilog=Xlog.new(logs_dir,timestamp))
    env.ddts_dlog=(@dlog=XlogBuffer.new(ilog))
    logi "Invocation timestamp is #{timestamp}"
    trap("INT") do
      logi "Interrupted"
      raise Interrupt
    end

  end

  def show(args)

    # Pretty-print a fully composed run or suite definition.

    def get_dir(type)
      case
      when type=~/build[s]?/
        unless Dir.exist?(d=build_defs)
          die "Build definitions directory '#{d}' not found"
        end
        d
      when type=~/run[s]?/
        unless Dir.exist?(d=run_defs)
          die "Run definitions directory '#{d}' not found"
        end
        d
      when type=~/suite[s]?/
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
    name=args[1..-1].join(" ")
    if ["build","run","suite"].include?(type)
      die "No #{type} specified" unless name and not name.empty?
      dir=get_dir(type)
      _def=load_def(dir,name,true,true)
      _def.delete("ddts_extends")
      puts
      puts "# #{ancestry(dir,name).join(' < ')}"
      puts
      puts pp(_def)
      puts
    elsif ["builds","runs","suites"].include?(type)
      dir=get_dir(type)
      defns=Dir.glob(File.join(dir,"*")).reject { |x| File.directory?(x) }
      if defns.empty?
        puts
        puts "No #{type} defined"
        puts
      else
        puts
        puts "Available #{type}:"
        puts
        defns.sort.each { |e| puts "  #{File.basename(e)}" }
        puts
      end
    else
      help(args,1)
    end

  end

  def use_baseline(args=nil)

    # If 'use-baseline' was supplied as the command-line argument, record the
    # specified baseline directory, then set the suite name and call dosuite
    # with the suite name.

    help(args,1) if  args.size < 2
    use_baseline_common(args)
    dosuite(args.join(" "))

  end

  def use_baseline_common(args)
    @use_baseline_dir=args.shift
    unless Dir.exist?(use_baseline_dir)
      die "Baseline directory #{use_baseline_dir} not found"
    end
    logd "Using use-baseline directory '#{use_baseline_dir}'"
  end

  def version(args)

    puts "3.4"

  end

end # class TS

# Special YAML handling. See JRuby's lib/ruby/shared/psych/coder.rb.

class YAML_Delete

  # To delete inherited keys/values.

  attr_accessor :obj

  def init_with(coder)
    @obj=coder.send(coder.type)
  end

  def to_s
    "!delete #{obj}"
  end

end # class YAML_Delete

YAML.add_tag("!delete",YAML_Delete)

class YAML_Replace

  # To to suppress Array/Hash merging.

  attr_accessor :obj

  def init_with(coder)
    @obj=coder.send(coder.type)
  end

  def to_s
    "!replace #{obj}"
  end

end # class YAML_Replace

YAML.add_tag("!replace",YAML_Replace)

class YAML_Unquoted

  # To suppress quoting Strings e.g. for Fortran namelist values.

  include Comparable

  def initialize(v)
    @v=v
  end

  def init_with(coder)
    @v=coder.scalar
  end

  def to_s
    @v
  end

  def <=>(o)
    "#{self}"<=>"#{o}"
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
  # pairs on to the screen and file loggers

  attr_accessor :warned
  attr_reader   :file

  def initialize(dir,timestamp)

    # File logger

    FileUtils.mkdir_p(dir)
    @file=File.join(dir,"log.#{timestamp}")
    if File.exist?(@file)
      puts "\nERROR: Log file '#{@file}' already exists, aborting...\n\n"
      exit 1
    end
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

  def logi_block(level,msg_block)
    formatted=msg_block.map { |msg| "  #{msg}" }.join("\n")
    @flog.send(level,"\n\n#{formatted}\n")
    msg_block.each { |msg| @slog.send(level,msg) }
  end

  def method_missing(m,*a)
    msg=a.first
    if m==:flush
      @flog.debug("\n\n#{msg}")
    else
      @flog.send(m,"\n\n  #{msg}\n")
      @slog.send(m,msg)
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
    @ilog.flush(@buffer) unless @buffer.empty?
    reset
  end

  def method_missing(m,*a)
    @buffer+="  #{a[0].chomp}\n"
  end

  def reset
    @buffer=""
  end

end # class XlogBuffer

# Command-line invocation:

if __FILE__==$0
  TS.new(ARGV[0],ARGV[1..-1])
end

# paul.a.madden@noaa.gov
