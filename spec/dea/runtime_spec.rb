# coding: UTF-8

require "spec_helper"

require "dea/runtime"

describe Dea::Runtime do
  describe "validating the executable path" do
    it "should work when the basename of the executable is specified" do
      config = { "executable" => "printf" }
      runtime = Dea::Runtime.new(config)

      runtime.validate_executable
      runtime.executable.should == "/usr/bin/printf"
    end
    it "should work when an absolute path to the executable is specified" do
      config = { "executable" => "/usr/bin/printf" }
      runtime = Dea::Runtime.new(config)

      runtime.validate_executable
      runtime.executable.should == "/usr/bin/printf"
    end

    it "should raise when the executable cannot be found" do
      config = { "executable" => "printf_whats_going_on" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_executable
      end.to raise_error
    end
  end

  describe "validating the version" do
    it "should work when the actual version matches the version regexp" do
      config = { "executable" => "/usr/bin/printf", "version" => "1\.2\.[1-5]", "version_flag" => "1.2.3\n" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_version
      end.to_not raise_error
    end

    it "should raise when the actual version doesn't match the version regexp" do
      config = { "executable" => "/usr/bin/printf", "version" => "1\.2\.[1-5]", "version_flag" => "1.2.6\n" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_version
      end.to raise_error(/version mismatch/i)
    end

    it "should raise when the process exits with non-zero status" do
      config = { "executable" => "/usr/bin/printf", "version" => "1\.2\.[1-5]", "version_flag" => "" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_version
      end.to raise_error(/non-zero status/i)
    end
  end

  describe "validating the additional checks" do
    it "should work when not specified" do
      config = { "executable" => "/bin/sh -c ''" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_additional_checks
      end.to_not raise_error
    end

    it "should work when the additional checks pass" do
      config = { "executable" => "/bin/sh", "additional_checks" => "-c 'echo true'" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_additional_checks
      end.to_not raise_error
    end

    it "should raise when the additional checks fail" do
      config = { "executable" => "/bin/sh", "additional_checks" => "-c 'echo false'" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_additional_checks
      end.to raise_error(/additional checks failed/i)
    end

    it "should raise when the process exits with non-zero status" do
      config = { "executable" => "/bin/sh", "additional_checks" => "-c 'exit 1'" }
      runtime = Dea::Runtime.new(config)

      expect do
        runtime.validate_additional_checks
      end.to raise_error(/non-zero status/i)
    end
  end
end
