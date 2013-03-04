require 'spec_helper'

describe Buildpacks::Config, :type => :buildpack do
  describe '#from_file' do
    it 'should symbolize keys for service bindings' do
      svc = {
        'label' => 'hello',
        'tags'  => ['tag1', 'tag2'],
        'name'  => 'my_test_svc',
        'credentials' => {
          'hostname' => 'localhost',
          'port'     => 12345,
          'password' => 'sekret',
          'name'     => 'test',
        },
        'options' => {},
        'plan' => 'free',
        'plan_option' => 'zazzle',
      }

      svc_expected = {
        :label => 'hello',
        :tags  => ['tag1', 'tag2'],
        :name  => 'my_test_svc',
        :credentials => {
          :hostname => 'localhost',
          :port     => 12345,
          :password => 'sekret',
          :name     => 'test',
        },
        :options => {},
        :plan => 'free',
        :plan_option => 'zazzle',
      }

      config = {
        'source_dir'  => 'test',
        'dest_dir'    => 'test',
        'environment' => {
          'resources' => {
            'memory'  => 128,
            'disk'    => 2048,
            'fds'     => 1024,
          },
          'services'  => [svc],
        }
      }

      tf = Tempfile.new('test_config')
      begin
        Buildpacks::Config.to_file(config, tf.path)
        parsed_cfg = Buildpacks::Config.from_file(tf.path)
      ensure
        tf.close
        tf.unlink
      end

      parsed_cfg[:environment][:services][0].should == svc_expected
    end
  end
end
