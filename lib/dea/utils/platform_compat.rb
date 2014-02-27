require 'rbconfig'

module PlatformCompat
  WINDOWS_SIGNALS = %W[TERM INT SIGTERM SIGINT].freeze

  def self.detect_platform
    (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/) ? :Windows : :Linux
  end

  @@platform = detect_platform

  def self.windows?
    @@platform == :Windows
  end

  def self.linux?
    @@platform == :Linux
  end

  def self.platform
    @@platform
  end

  def self.platform_name
    platform.to_s
  end
  
  def self.get_platform_class(klass)
    # Find the start of the actual class name (i.e. after module names)
    idx = klass.name.rindex("::")
    idx = idx ? idx + 2 : 0
    
    # Build the platform class name
    # Module::Foobar -> Module::LinuxFoobar
    platformClassName = klass.name.insert(idx, PlatformCompat.platform_name)
    begin
      platformClass = eval(platformClassName)
    rescue NameError
      raise StandardError.new("Unable to get platform class for class '#{klass.name}'. The platform class '#{platformClassName}' does not exist.")
    end
    
    platformClass
  end

  def self.signal_supported?(signal)
    if windows?
      WINDOWS_SIGNALS.include?(signal)
    else
      true
    end
  end

  def self.to_env(envs)
    envs.map do |(key, value)|
      if windows?
        %Q{$env:%s='%s'\n} % [key, value]
      else
        %Q{export %s="%s";\n} % [key, value.to_s.gsub('"', '\"')]
      end

    end.join
  end
end

class Class
  def abstract_method(*methods)
    methods.each do |m|
      define_method(m) do |*args|
        raise "Abstract method not implemented"
      end
    end
  end

  def include_platform_compat
    klass = self

    klass.class_eval %Q{
     def self.new(*args)
       platformClass = PlatformCompat.get_platform_class(#{klass})
       object = platformClass.allocate
       object.send :initialize, *args
       object
     end
   }
  end
end

module FileUtils
  def self.cp_a(src, dest)
    if PlatformCompat.windows?
      FileUtils.cp_r(src, dest, :preserve => true)
    else
      # recursively (-r) while not following symlinks (-P) and preserving dir structure (-p)
      # this is why we use system copy not FileUtil
      system "cp -a #{src} #{dest}"
    end
  end
end
