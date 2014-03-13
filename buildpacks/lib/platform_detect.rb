require 'rbconfig'

module PlatformDetect
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

  def self.platform=(value)
    @@platform = value
  end

  def self.platform_name
    platform.to_s
  end
end