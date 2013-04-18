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
      args.should == [p]
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

    p.elapsed_time.should be_within(0.001).of(5)
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
end
