require 'spec_helper'
require 'dea/utils/egress_rules_mapper'

describe EgressRulesMapper do

  let(:container_handle) { 'somehandle' }

  let(:tcp_rule) { { 'protocol' => 'tcp', 'ports' => '80', 'destination' => '198.41.191.47/1', 'log' => true } }
  let(:expected_tcp_rule) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:   container_handle,
      protocol: ::Warden::Protocol::NetOutRequest::Protocol::TCP,
      port:     80,
      network:  '198.41.191.47/1',
      log: true,
    })
  end

  let(:tcp_rule_range) { { 'protocol' => 'tcp', 'ports' => '80-90', 'destination' => '198.41.191.47/1', 'log' => false } }
  let(:expected_tcp_rule_range) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:     container_handle,
      protocol:   ::Warden::Protocol::NetOutRequest::Protocol::TCP,
      port_range: '80:90',
      network:    '198.41.191.47/1',
    })
  end

  let(:tcp_rule_without_port) { { 'protocol' => 'tcp', 'destination' => '198.41.191.47/1' } }
  let(:expected_tcp_rule_without_port) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:   container_handle,
      protocol: ::Warden::Protocol::NetOutRequest::Protocol::TCP,
      network:  '198.41.191.47/1',
    })
  end

  let(:tcp_rule_port_list) { { 'protocol' => 'tcp', 'ports' => '50,60', 'destination' => '198.41.191.47/1' } }
  let(:expected_tcp_rule_port_list_1) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:   container_handle,
      protocol: ::Warden::Protocol::NetOutRequest::Protocol::TCP,
      port:     50,
      network:  '198.41.191.47/1',
    })
  end
  let(:expected_tcp_rule_port_list_2) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:   container_handle,
      protocol: ::Warden::Protocol::NetOutRequest::Protocol::TCP,
      port:     60,
      network:  '198.41.191.47/1',
    })
  end

  let(:udp_rule) { { 'protocol' => 'udp', 'ports' => '80', 'destination' => '198.41.191.47/1',  } }
  let(:expected_udp_rule) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:   container_handle,
      protocol: ::Warden::Protocol::NetOutRequest::Protocol::UDP,
      port:     80,
      network:  '198.41.191.47/1',
    })
  end

  let(:udp_rule_range) { { 'protocol' => 'udp', 'ports' => '80-90', 'destination' => '198.41.191.47/1' } }
  let(:expected_udp_rule_range) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:     container_handle,
      protocol:   ::Warden::Protocol::NetOutRequest::Protocol::UDP,
      port_range: '80:90',
      network:    '198.41.191.47/1',
    })
  end

  let(:icmp_rule) { { 'protocol' => 'icmp', 'type' => 1, 'code' => 2, 'destination' => '198.41.191.47/1' } }
  let(:expected_icmp_rule) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:    container_handle,
      protocol:  ::Warden::Protocol::NetOutRequest::Protocol::ICMP,
      icmp_type: 1,
      icmp_code: 2,
      network:   '198.41.191.47/1',
    })
  end

  let(:all_rule) { {'protocol' => 'all', 'destination' => '198.41.191.47/1', 'log' => true } }
  let(:expected_all_rule) do
    ::Warden::Protocol::NetOutRequest.new({
      handle:    container_handle,
      protocol:  ::Warden::Protocol::NetOutRequest::Protocol::ALL,
      network:   '198.41.191.47/1',
      log: true,
    })
  end

  let(:rules) do
    [
      tcp_rule,
      tcp_rule_range,
      tcp_rule_without_port,
      tcp_rule_port_list,
      udp_rule,
      udp_rule_range,
      icmp_rule,
      all_rule
    ]
  end

  subject { described_class.new(rules, container_handle) }

  describe '#map_to_warden_rules' do
    it 'maps hash rules to warden client rules with log enabled last' do
      warden_rules = subject.map_to_warden_rules

      expect(warden_rules[0..-3]).to match_array([
        expected_tcp_rule_range,
        expected_tcp_rule_without_port,
        expected_tcp_rule_port_list_1,
        expected_tcp_rule_port_list_2,
        expected_udp_rule,
        expected_udp_rule_range,
        expected_icmp_rule,
      ])

      expect(warden_rules[-2..-1]).to match_array([
        expected_tcp_rule,
        expected_all_rule,
      ])
    end

    context 'when a bad protocol is provided' do
      let(:bad_rule) { { 'protocol' => 'gre', 'destination' => '198.41.191.47/1' } }
      let(:rules) { [bad_rule] }

      it 'raises an error' do
        expect { subject.map_to_warden_rules }.to raise_error(ArgumentError, /invalid protocol in egress rule: gre/i)
      end
    end

    context 'when icmp specific rules are provided and the protocol is not icmp' do
      let(:tcp_rule_with_icmp_data) { { 'protocol' => 'tcp', 'destination' => '198.41.191.47/1', 'type' => 8, 'code' => 0 } }
      let(:rules) { [tcp_rule_with_icmp_data] }

      it 'ignores the type and code' do
        warden_rules = subject.map_to_warden_rules

        expect(warden_rules).to match_array([
          ::Warden::Protocol::NetOutRequest.new({
            handle:   container_handle,
            protocol: ::Warden::Protocol::NetOutRequest::Protocol::TCP,
            network:  '198.41.191.47/1',
          })
        ])
      end
    end
  end
end
