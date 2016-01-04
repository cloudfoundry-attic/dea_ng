# coding: UTF-8

require "spec_helper"

require "dea/promise"

describe Dea::Promise do
  it "can deliver" do
    p = Dea::Promise.new do
      p.deliver("ok")
    end

    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([nil, "ok"])
  end

  it "can fail" do
    error = RuntimeError.new("error")

    p = Dea::Promise.new do
      p.fail(error)
    end

    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([error, nil])
  end

  it "can deliver without argument" do
    p = Dea::Promise.new do
      p.deliver
    end

    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([nil, nil])
  end

  it "cannot fail without argument" do
    p = Dea::Promise.new do
      p.fail
    end

    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([kind_of(ArgumentError), nil])
  end

  it "can chain" do
    p1 = Dea::Promise.new do
      p1.deliver("ok")
    end

    p2 = Dea::Promise.new do
      p2.deliver(p1.resolve)
    end

    expect do |b|
      Dea::Promise.resolve(p2, &b)
    end.to yield_with_args([nil, "ok"])
  end

  it "should yield itself" do
    p = Dea::Promise.new do |*args|
      expect(args).to eq([p])
      p.deliver
    end

    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([nil, nil])
  end

  it "should store the time it takes to execute" do
    time = Time.now
    Timecop.freeze(time)

    p = Dea::Promise.new do
      Timecop.travel(5)
      p.deliver
    end

    expect { |b|
      Dea::Promise.resolve(p, &b)
    }.to yield_control

    expect(p.elapsed_time).to be_within(0.01).of(5)
  end

  it "can run without resolve" do
    p = Dea::Promise.new do
      p.deliver("ok")
    end

    # Calling #run should start execution
    expect do
      p.run
    end.to change(p, :ran?)

    # Calling #resolve should work as expected
    expect do |b|
      Dea::Promise.resolve(p, &b)
    end.to yield_with_args([nil, "ok"])
  end

  context "run_in_parallel_and_join" do
    it "resolves all promises" do
      p1 = Dea::Promise.new do
        p1.deliver("ok")
      end

      p2 = Dea::Promise.new do
        p2.deliver("ok")
      end

      Fiber.new do
        Dea::Promise.run_in_parallel_and_join(p1, p2)
      end.resume

      expect(p1.result).to_not be_nil
      expect(p2.result).to_not be_nil
    end

    context "when a promise fails" do
      it "resolves all promises" do
        p1 = Dea::Promise.new do
          p1.fail("fail")
        end
        p2 = Dea::Promise.new do
          f = Fiber.current
          EM::add_timer(1) { f.resume }
          Fiber::yield
          p2.deliver("ok")
        end

        EM.run do
          Fiber.new do
            begin
              expect do
                Dea::Promise.run_in_parallel_and_join(p1, p2)
              end.to raise_error("fail")
            ensure
              EM.stop
            end
          end.resume
        end

        expect(p1.result).to_not be_nil
        expect(p2.result).to_not be_nil
      end

      it "raises one of the failures when multiple promises fail" do
        p1 = Dea::Promise.new do
          p1.fail("fail")
        end
        p2 = Dea::Promise.new do
          f = Fiber.current
          EM::add_timer(1) { f.resume }
          Fiber::yield
          p2.fail("fail")
        end

        EM.run do
          Fiber.new do
            begin
              expect do
                Dea::Promise.run_in_parallel_and_join(p1, p2)
              end.to raise_error("fail")
            ensure
              EM.stop
            end
          end.resume
        end

        expect(p1.result).to_not be_nil
        expect(p2.result).to_not be_nil
      end
    end

    context "run_serially" do
      it "resolves all promises" do
        p1 = Dea::Promise.new do
          p1.deliver("ok")
        end

        p2 = Dea::Promise.new do
          p2.deliver("ok")
        end

        Dea::Promise.run_serially(p1, p2)

        expect(p1.result).to_not be_nil
        expect(p2.result).to_not be_nil
      end

      it "resolves until the first failure" do
        p1 = Dea::Promise.new do
          p1.fail("fail")
        end

        p2 = Dea::Promise.new do
          p2.deliver("ok")
        end

        expect do
          Dea::Promise.run_serially(p1, p2)
        end.to raise_error("fail")

        expect(p1.result).to_not be_nil
        expect(p2.result).to be_nil
      end
    end
  end
end
