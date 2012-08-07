# coding: UTF-8

require "spec_helper"
require "dea/varz_collector"

describe Dea::VarzCollector do
  let(:bootstrap) do
    bootstrap = Dea::Bootstrap.new
    bootstrap.setup_instance_registry
    bootstrap.setup_resource_manager

    6.times do |ii|
      instance = Dea::Instance.new(bootstrap,
                                   "application_id" => ii,
                                   "runtime_name"   => "runtime#{ii % 2}",
                                   "framework_name" => "framework#{ii % 2}",
                                   "limits"         => {
                                     "disk" => ii,
                                     "mem"  => ii * 1024})
      if ii % 2 != 0
        instance.state = Dea::Instance::State::RUNNING
      else
        instance.state = Dea::Instance::State::STARTING
      end

      instance.stub(:used_memory_in_bytes).and_return(ii * 1024)
      instance.stub(:used_disk_in_bytes).and_return(ii)
      instance.stub(:computed_pcpu).and_return(ii)
      bootstrap.instance_registry.register(instance)
    end

    # Verify these aren't included in varz
    [:BORN, :STOPPED, :CRASHED, :DELETED].each_with_index do |state, ii|
      instance = Dea::Instance.new(bootstrap,
                                   "application_id" => ii,
                                   "runtime_name"   => "runtime#{ii % 2}",
                                   "framework_name" => "framework#{ii % 2}",
                                   "limits"         => {
                                     "disk" => ii,
                                     "mem"  => ii * 1024})
      instance.state = Dea::Instance::State.const_get(state)
      instance.stub(:used_memory_in_bytes).and_return(ii)
      instance.stub(:used_disk_in_bytes).and_return(ii)
      instance.stub(:computed_pcpu).and_return(ii)
      bootstrap.instance_registry.register(instance)
    end

    bootstrap
  end

  let(:collector) { Dea::VarzCollector.new(bootstrap) }

  describe "update" do
    before :each do
      VCAP::Component.instance_variable_set(:@varz, {})
      collector.update
    end

    it "should compute aggregate memory statistics" do
      mem_used = bootstrap.instance_registry  \
                          .select { |i| i.running? || i.starting? } \
                          .inject(0) { |a, i| a + i.used_memory_in_bytes }
      VCAP::Component.varz[:apps_used_memory].should == mem_used
    end

    it "should compute memory/disk/cpu statistics by framework" do
      summary = compute_summaries(bootstrap.instance_registry, :framework_name)
      VCAP::Component.varz[:frameworks].should == summary
    end

    it "should compute memory/disk/cpu statistics by runtime" do
      summary = compute_summaries(bootstrap.instance_registry, :runtime_name)
      VCAP::Component.varz[:runtimes].should == summary
    end

    it "should set the instance listing" do
      ids = bootstrap.instance_registry \
                     .select { |i| i.running? || i.starting? } \
                     .map(&:instance_id)
      varz_ids = VCAP::Component.varz[:running_apps].map { |x| x[:instance_id] }
      varz_ids.should == ids
    end
  end

  def compute_summaries(instances, group_by)
    summaries = Hash.new do |h, k|
      h[k] = {
        :used_memory     => 0,
        :reserved_memory => 0,
        :used_disk       => 0,
        :used_cpu        => 0,
      }
    end

    instances.select { |i| i.running? || i.starting? }.each do |i|
      summary = summaries[i.send(group_by)]
      summary[:used_memory]     += i.used_memory_in_bytes / 1024
      summary[:reserved_memory] += i.memory_limit_in_bytes / 1024
      summary[:used_disk]       += i.used_disk_in_bytes
      summary[:used_cpu]        += i.computed_pcpu
    end

    summaries
  end
end
