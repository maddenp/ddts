#!/usr/bin/env ruby

require 'fileutils'

class NamelistHandler

  attr_reader :dst,:ok,:src

  def initialize(src)
    @dst=@src=src
    @written=false
    if @ok=File.readable?(@src)
      text=''
      File.open(@src,'r') { |f| text=f.read }
      # Remove comments.
      if text.respond_to?(:lines)
        text=text.lines.inject('') { |x,e| x+nocomment(e) }
      else # this ruby is ancient
        text=text.inject('') { |x,e| x+nocomment(e) }
      end
      # Mask quoted strings (note mask order: sq -> dq).
      sqstrings,sqtoken=mask(text,"'.*?'","__'__")
      dqstrings,dqtoken=mask(text,'".*?"','__"__')
      # Remove newlines.
      text.delete!("\n")
      # Remove extraneous spaces.
      text=text.split.join(' ')
      # Remove whitespace around equal signs and commas.
      text.gsub!(/ *([=,]) */,'\1')
      # Add final namelist-terminating slash if not present.
      text+='/' unless text[/.$/]=='/'
      # Create a hash for namelist names.
      @namelists={}
      # Iterate over namelists in the text string.
      text.scan(/(&\S+\s*\/)|(&\S+\s+.*?\/)/) do |nl|
        # String.scan() returns an array: Keep the non-nil match.
        nl=(nl.first.nil?)?(nl.last):(nl.first)
        # Remove the namelist-terminating / from the namelist string.
        nl.sub!(/\/$/,'')
        # Extract the namelist name from the namelist string.
        nlname=nl.sub(/&(\S+)\s*.*/,'\1')
        # Create a hash for this namelist's key-value pairs.
        @namelists[nlname]={}
        # Extract the list of key-value pairs from the namelist string.
        kvpairs=nl.sub(Regexp.new('&'+nlname+'(.*)'),'\1')
        # Mask "key=" strings with tokens.
        keqstrings,ketoken=mask(kvpairs,'[^\s,=]+?=','__=__')
        # Iterate over values in the key-value pairs string.
        kvpairs.split(ketoken).each do |val|
          # Strip leading/trailing whitespace and, potentially, a trailing comma
          # from the value string and, if what's left isnt' blank...
          unless (val=val.strip.sub(/,$/,''))=~/^\s*$/
            # ...unmask quoted strings (note unmask order: dq -> sq).
            while val.include?(dqtoken) do val.sub!(dqtoken,dqstrings.pop) end
            while val.include?(sqtoken) do val.sub!(sqtoken,sqstrings.pop) end
            # Add to the namelist has matching key and vlaue.
            @namelists[nlname][keqstrings.pop.delete('=')]=val
          end
        end
      end
    end
  end

  def keys(namelist)
    # A sorted list of the keys (namelist variables) present in the namelist
    # with the supplied name.
    @namelists[namelist].keys.sort
  end

  def lookup(namelist,key)
    # Return the value corresponding to the supplied namelist and key (variable)
    # if found, otherwise nil.
    if nk=find(namelist,key) then return @namelists[nk[0]][nk[1]] end
    nil
  end

  def set(namelist,key,value)
    # Set the supplied namelist:key to value, if namelist:key already exists.
    # Since Fortran namelist and variable names are case-insensitive, but Ruby
    # hashes are not, set n and k to the actual hash keys corresponding to the
    # supplied namelist and key. If n and k are found & set, set the value and
    # return it. Otherwise, return nil.
    n,k=find(namelist,key)
    unless n==nil or k==nil
      return @namelists[n][k]=value
    end
    nil
  end

  def set!(namelist,key,value)
    # See the comment in set() re: case-insensitivity requirements. Set
    # namelist:key=value, creating the namelist and/or key as necessary. An
    # initial call to set() handles the case there namelist and key already
    # exist.
    unless r=set(namelist,key,value)
      unless n=find_namelist(namelist)
        n=namelist
        @namelists[n]={}
      end
      return @namelists[n][key]=value
    end
    r
  end

  def to_s
    # Print out the internal hash-of-hashes representing the namelist file's
    # contents. This should produce a valid namelist, minus comments and with
    # simple formatting.
    s=''
    @namelists.sort.each do |n|
      s << "&#{n[0]}\n"
      @namelists[n[0]].sort.each { |k| s << "  #{k[0]}=#{k[1]}\n" }
      s << "/\n"
    end
    s
  end

  def write(dst=nil)
    # Use src as dst if the latter is not provided. Make a backup of dst unless
    # one already exists. The backup is only made once in the object's lifetime
    # so multiple calls to write() will maintain the backup in the state it was
    # in when the object was created.
    @dst=dst||@src
    if File.readable?(@dst) and not @written
      FileUtils.cp(@dst,@dst+'.original')
    end
    write!(@dst)
  end

  def write!(dst=nil)
    @dst=dst||@src
    File.open(@dst,'w') { |f| f.puts(self.to_s) }
    @written=true
  end

  private

  def find(namelist,key)
    # Return the actual namelist and hash keys corresponding to the supplied
    # strings, which are matched case-insensitively.
    if n=find_namelist(namelist)
      if k=find_key_in_namelist(n,key)
        return [n,k]
      end
    end
    nil
  end

  def find_key_in_namelist(namelist,key)
    # Return the actual hash key corresponding to the supplied namelist
    # and key. Note that namelist must case-sensitively match the actual
    # namelist hash key, so should have already been processed by
    # find_namelist(). Compare upcase'ed strings to match Fortran's case-
    # insensitivity.
    @namelists[namelist].each do |kv|
      return kv[0] if kv[0].to_s.upcase==key.to_s.upcase
    end
    nil
  end

  def find_namelist(namelist)
    # Return the actual hash key corresponding to the supplied namelist name.
    # Compare upcase'ed strings to match Fortran's case-insensitivity.
    @namelists.keys.each do |n|
      return n if n.to_s.upcase==namelist.to_s.upcase
    end
    nil
  end

  def mask(text,pattern,token)
    strings=text.scan(Regexp.new(pattern))
    strings.each { |x| text.sub!(x,token) }
    strings.reverse!
    [strings,token]
  end

  def nocomment(s,qc=nil)
    # Only look for a comment if the string contains a '!'
    if bi=s.index('!')
      # Get the index of the first quote character if we know it, or the
      # index of either the first ' or the first ".
      if qci=(qc)?(s.index(qc)):(s.index(/[\'\"]/))
        # Find out what the quote character actually is.
        qc=s[qci,1]
        # We're done if: there's no quote character; the quote character
        # is to the right of the '!' (i.e. the quote character is part
        # of the comment); or if there's an even number of quote characters
        # to the left of the '!' (i.e. the '!' isn't in a quoted string).
        if qci and qci<bi and s[qci..bi].count(qc).divmod(2)[1].eql?(1)
          # Otherwise, the '!' must be *inside* a quoted string, so get
          # the index of the next quote character to the right of the
          # '!', which *may* terminate the quoted string.
          qcri=s.index(qc,bi)
          # The characters from the start of the string up through the
          # (possibly) terminating quote character we just found are not
          # part of a comment, so we'll return them... plus the non-
          # comment portion of whatever lies to the right of that quote
          # character, which we recurse to find. We know what quote
          # character we're using now and so send it on.
          return s[0..qcri]+nocomment(s[qcri+1,s.size],qc)
        end
      end
      # If there was no quote character, there's no quoted string, so the
      # first '!' must be the start of a comment. Strip and return.
      return s.gsub(/\s*!.*$/,'')
    end
    # If there was no '!', there's no comment, so return the unmodified string.
    s
  end

end

# A three-argument command-line invocation returns the value of the given key
# from the given namelist in the given namelist file, if it exists. The four-
# argument version sets the given namelist:key=value triplet, creating a new
# namelist and/or key, if necessary. If $embedded is set (e.g. by a JRuby Embed
# Core container), a new NamelistHandler object will be instantiated with the
# string value in $embedded as the namelist filename and returned with no
# further action.

if (__FILE__==$0)
  if $embedded
    NamelistHandler.new($embedded)
  else
    args=ARGV.size
    if args==3 or args==4
      nlfile=ARGV[0]
      namelist=ARGV[1]
      key=ARGV[2]
      if File.readable?(nlfile)
        n=NamelistHandler.new(nlfile)
        if args==3 # do a lookup
          v=n.lookup(namelist,key)
          exit 1 if v.nil?
          puts v
        else
          value=ARGV[3]
          n.set!(namelist,key,value)
          n.write!
        end
      end
    else
      puts "\nusage: #{$0} file namelist key [value]\n\n"
      exit 1
    end
  end
end

# paul.a.madden@noaa.gov
