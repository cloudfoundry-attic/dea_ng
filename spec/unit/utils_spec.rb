# coding: UTF-8

require 'spec_helper'

describe Dea do
  describe '.local_ip' do
    it 'returns an ip address to use' do
      expect(Dea.local_ip).to match(/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/)
    end
  end

  describe '.grab_ephemeral_port' do
    it 'returns a valid port' do
      expect(Dea.grab_ephemeral_port).to be_between(0, 65535).inclusive
    end
  end
end
