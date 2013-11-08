# coding: UTF-8

require "spec_helper"
require "dea/resource_manager"
require "dea/bootstrap"

require "dea/staging/staging_task_registry"
require "dea/staging/staging_task"

require "dea/starting/instance_registry"
require "dea/starting/instance"

describe Dea::ResourceManager do
  let(:memory_mb) { 600 }
  let(:memory_overcommit_factor) { 4 }
  let(:disk_mb) { 4000 }
  let(:disk_overcommit_factor) { 2 }
  let(:max_instances) { 2 }
  let(:nominal_memory_capacity) { memory_mb * memory_overcommit_factor }
  let(:nominal_disk_capacity) { disk_mb * disk_overcommit_factor }

  let(:bootstrap) { Dea::Bootstrap.new }
  let(:instance_registry) { Dea::InstanceRegistry.new }
  let(:staging_registry) { Dea::StagingTaskRegistry.new }

  let(:manager) do
    Dea::ResourceManager.new(instance_registry, staging_registry, {
      "memory_mb" => memory_mb,
      "memory_overcommit_factor" => memory_overcommit_factor,
      "disk_mb" => disk_mb,
      "disk_overcommit_factor" => disk_overcommit_factor,
      "max_instances" => max_instances
    })
  end

  describe "#remaining_memory" do
    context "when no instances or staging tasks are registered" do
      it "returns the full memory capacity" do
        manager.remaining_memory.should eql(memory_mb * memory_overcommit_factor)
      end
    end

    context "when instances are registered" do
      before do
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1 }).tap { |i| i.state = "BORN" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 2 }).tap { |i| i.state = "STARTING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 4 }).tap { |i| i.state = "RUNNING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 8 }).tap { |i| i.state = "STOPPING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 16 }).tap { |i| i.state = "STOPPED" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 32 }).tap { |i| i.state = "CRASHED" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 64 }).tap { |i| i.state = "DELETED" })

        staging_registry.register(Dea::StagingTask.new(bootstrap, nil, StagingMessage.new({}), []))
      end

      it "returns the correct remaining memory" do
        manager.remaining_memory.should eql(nominal_memory_capacity - (1 + 2 + 4 + 8 + 1024))
      end
    end
  end

  describe "#remaining_disk" do
    context "when no instances are registered" do
      let(:reserved_instance_disk) { 0 }
      let(:reserved_staging_disk) { 0 }

      it "returns the full disk capacity" do
        manager.remaining_disk.should eql(nominal_disk_capacity)
      end
    end

    context "when instances are registered" do
      before do
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 1 }).tap { |i| i.state = "BORN" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 2 }).tap { |i| i.state = "STARTING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 4 }).tap { |i| i.state = "RUNNING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 8 }).tap { |i| i.state = "STOPPING" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 16 }).tap { |i| i.state = "STOPPED" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 32 }).tap { |i| i.state = "CRASHED" })
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 64 }).tap { |i| i.state = "DELETED" })

        staging_registry.register(Dea::StagingTask.new(bootstrap, nil, StagingMessage.new({}), []))
      end

      it "returns the correct remaining disk" do
        manager.remaining_disk.should eql(nominal_disk_capacity - (1 + 2 + 4 + 8 + 32 + 2048))
      end
    end
  end

  describe "remaining_instances" do
    context "where no instance is registered" do
      it "returns the max_instances" do
        manager.remaining_instances.should eql(2)
      end
    end

    context "when a regular instance is added" do
      before do
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => {}))
      end
      it "returns 1" do
        manager.remaining_instances.should eql(1)
      end
    end

    context "when a instance in DELETED state is added" do
      before do
        instance_registry.register(Dea::Instance.new(bootstrap, "limits" => {}).tap { |i| i.state = "DELETED" })
      end
      it "returns two, which unchanged." do
        manager.remaining_instances.should eql(2)
      end
    end
  end

  describe "app_id_to_count" do
    before do
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "a").tap { |i| i.state = "BORN" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "b").tap { |i| i.state = "STARTING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "b").tap { |i| i.state = "STARTING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "c").tap { |i| i.state = "RUNNING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "c").tap { |i| i.state = "RUNNING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "c").tap { |i| i.state = "RUNNING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "d").tap { |i| i.state = "STOPPING" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "e").tap { |i| i.state = "STOPPED" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "f").tap { |i| i.state = "CRASHED" })
      instance_registry.register(Dea::Instance.new(bootstrap, "application_id" => "g").tap { |i| i.state = "DELETED" })
    end

    it "should return all registered instances regardless of state" do
      manager.app_id_to_count.should == {
        "a" => 1,
        "b" => 2,
        "c" => 3,
        "d" => 1,
        "e" => 1,
        "f" => 1,
        "g" => 1,
      }
    end
  end

  describe "number_reservable" do
    let(:memory_mb) { 600 }
    let(:memory_overcommit_factor) { 1 }
    let(:disk_mb) { 4000 }
    let(:disk_overcommit_factor) { 1 }
    let(:max_instances) { 5 }

    context "when there is not enough memory to reserve any" do
      it "is 0" do
        manager.number_reservable(10_000, 1).should == 0
      end
    end

    context "when there is not enough disk to reserve any" do
      it "is 0" do
        manager.number_reservable(1, 10_000).should == 0
      end
    end

    context "when there are enough resources for a single reservation" do
      it "is 1" do
        manager.number_reservable(500, 3000).should == 1
      end
    end

    context "when there are enough memory and disk" do
      it "is limited by max_instances" do
        manager.number_reservable(1, 1).should == 5
      end
    end

    context "when there are enough resources for many reservations" do
      it "is correct" do
        manager.number_reservable(200, 1500).should == 2
        manager.number_reservable(200, 1000).should == 3
      end
    end

    context "when too many instances are registered" do
      before do
        5.times do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }))
        end
      end

      it "cannot reserve because of too many resvered instances" do
        manager.number_reservable(1, 1).should == 0
      end
    end

    context "when 0 resources are requested" do
      it "returns 0" do
        manager.number_reservable(0, 0).should == 0
      end
    end
  end

  describe "get_constrained_resource" do
    context "when this is no sufficient memory" do
      it "identifies memory" do
        manager.get_constrained_resource(nominal_memory_capacity + 1, 1).should == "memory"
      end
    end
    
    context "when there is no sufficient disk available" do
      it "identifies disk" do
        manager.get_constrained_resource(1, nominal_disk_capacity + 1).should == "disk"
      end
    end

    context "when there is no sufficient instance available" do
      let(:max_instances) { 0 }
      it "identifies instance" do
        manager.get_constrained_resource(1, 1).should == "instance"
      end
    end
  end

  describe "available_memory_ratio" do
    before do
      instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 512 }).tap { |i| i.state = "RUNNING" })
      staging_registry.register(Dea::StagingTask.new(bootstrap, nil, StagingMessage.new({}), []))
    end

    it "is the ratio of available memory to total memory" do
      manager.available_memory_ratio.should == 1 - (512.0 + 1024.0) / nominal_memory_capacity
    end
  end

  describe "available_disk_ratio" do
    before do
      instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "disk" => 512 }).tap { |i| i.state = "RUNNING" })
      staging_registry.register(Dea::StagingTask.new(bootstrap, nil, StagingMessage.new({}), []))
    end

    it "is the ratio of available disk to total disk" do
      manager.available_disk_ratio.should == 1 - (512.0 + 2048.0) / nominal_disk_capacity
    end
  end

  describe "check if there are available resources" do
    before do
      instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 512, "disk" => 1024 }).tap { |i| i.state = "RUNNING" })
      staging_registry.register(Dea::StagingTask.new(bootstrap, nil, StagingMessage.new({}), []))

      @remaining_memory = nominal_memory_capacity - 512 - 1024
      @remaining_disk = nominal_disk_capacity - 1024 - 2048
    end

    describe "could_reserve?" do
      context "when the given amounts of memory and disk are available (including extra 'headroom' memory)" do
        it "can reserve" do
          manager.could_reserve?(@remaining_memory - 1, @remaining_disk - 1).should be_true
        end
      end

      context "when too much memory is being used" do
        it "can't reserve" do
          manager.could_reserve?(@remaining_memory + 1, 1).should be_false
        end
      end

      context "when too much disk is being used" do
        it "can't reserve" do
          manager.could_reserve?(1, @remaining_disk + 1).should be_false
        end
      end

      context "when too many instances are registered" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }))
        end

        it "can't reserve because of too many reserved instances" do
          manager.could_reserve?(1, 1).should be_false
        end
      end

      context "when an instance in DELETED state is registered to bring the total number of instances to its maximum limit" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }).tap { |i| i.state = "DELETED" })
        end

        it "allows to reserve" do
          manager.could_reserve?(1, 1).should be_true
        end
      end

      context "when an instance in STOPPED state is registered" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }).tap { |i| i.state = "STOPPED" })
        end

        it "doesn't allow to reserve" do
          manager.could_reserve?(1, 1).should be_false
        end
      end

      context "when too many instances are registered" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }))
        end

        it "can't reserve because of too many reserved instances" do
          manager.could_reserve?(1, 1).should be_false
        end
      end

      context "when an instance in DELETED state is registered to bring the total number of instances to its maximum limit" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }).tap { |i| i.state = "DELETED" })
        end

        it "allows to reserve" do
          manager.could_reserve?(1, 1).should be_true
        end
      end

      context "when an instance in STOPPED state is registered" do
        before do
          instance_registry.register(Dea::Instance.new(bootstrap, "limits" => { "mem" => 1, "disk" => 1 }).tap { |i| i.state = "STOPPED" })
        end

        it "doesn't allow to reserve" do
          manager.could_reserve?(1, 1).should be_false
        end
      end
    end

    describe "could_reserve_memory?" do
      context "with enough memory" do
        it "can reserve memory" do
          manager.could_reserve_memory?(@remaining_memory).should be_true
        end
      end

      context "when too much memory is being used" do
        it "can't reserve" do
          manager.could_reserve_memory?(@remaining_memory + 1).should be_false
        end
      end
    end

    describe "could_reserve_disk?" do
      context "with enough disk" do
        it "can reserve disk" do
          manager.could_reserve_disk?(@remaining_disk).should be_true
        end
      end

      context "when too much disk is being used" do
        it "can't reserve" do
          manager.could_reserve_disk?(@remaining_disk + 1).should be_false
        end
      end
    end

    describe "could_reserve_instance?" do
      context "with enough instances" do
        it "can reserve instance" do
          manager.could_reserve_instance?.should be_true
        end
      end

      context "when there is no instance available" do
        let(:max_instances) { 0 }
        it "can't reserve" do
          manager.could_reserve_instance?.should be_false
        end
      end
    end
  end
end
