shared_examples :handles_registry_enumerations do

  let(:registry) do
    registry = nil
    with_event_machine do
      registry = described_class.new
      done
    end
    registry
  end

  before do
    @instance_id = 0
  end

  def make_instance(options = {})
    @instance_id += 1
    double(:instance, {
      consuming_memory?: true,
      consuming_disk?: true,
      instance_id: @instance_id,
      application_id: 123,
      task_id: @instance_id,
      instance_index: 0
    }.merge(options))
  end

  describe "reserved_memory_bytes" do
    subject { registry.reserved_memory_bytes }

    context "with no instances" do
      it { should == 0 }
    end

    context "with one instance" do
      before do
        registry.register(make_instance(:memory_limit_in_bytes => 12))
      end

      it { should == 12 }
    end

    context "with multiple instances" do
      before do
        registry.register(make_instance(:memory_limit_in_bytes => 12))
        registry.register(make_instance(:memory_limit_in_bytes => 34))
        registry.register(make_instance(:memory_limit_in_bytes => 56))
      end

      it { should == 102 }
    end
  end

  describe "used_memory_bytes" do
    subject { registry.used_memory_bytes }

    context "with no instances" do
      it { should == 0 }
    end

    context "with one instance" do
      before do
        registry.register(make_instance(:used_memory_in_bytes => 45))
      end

      it { should == 45 }
    end

    context "with multiple instances" do
      before do
        registry.register(make_instance(:used_memory_in_bytes => 45))
        registry.register(make_instance(:used_memory_in_bytes => 67))
        registry.register(make_instance(:used_memory_in_bytes => 89))
      end

      it { should == 201 }
    end
  end

  describe "reserved_disk_bytes" do
    subject { registry.reserved_disk_bytes }

    context "with no instances" do
      it { should == 0 }
    end

    context "with one instance" do
      before do
        registry.register(make_instance(:disk_limit_in_bytes => 67))
      end

      it { should == 67 }
    end

    context "with multple instances" do
      before do
        registry.register(make_instance(:disk_limit_in_bytes => 67))
        registry.register(make_instance(:disk_limit_in_bytes => 89))
        registry.register(make_instance(:disk_limit_in_bytes => 102))
      end

      it { should == 258 }
    end
  end
end