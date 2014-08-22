class EgressRulesMapper

  attr_reader :rules, :container_handle

  def initialize(rules, container_handle)
    @rules            = rules
    @container_handle = container_handle
  end

  def map_to_warden_rules
    logging_rules = []
    normal_rules = []

    rules.each do |rule|
      protocol  = warden_protocol_from_string(rule['protocol'])
      rule_args = rule_args_for_protocol(protocol, rule)

      rule_args.each do |args|
        req = ::Warden::Protocol::NetOutRequest.new(args)
        rule['log'] ? logging_rules << req : normal_rules << req
      end
    end

    normal_rules | logging_rules
  end

  private

  def warden_protocol_from_string(protocol_str)
    case protocol_str
      when 'tcp'
        ::Warden::Protocol::NetOutRequest::Protocol::TCP
      when 'udp'
        ::Warden::Protocol::NetOutRequest::Protocol::UDP
      when 'icmp'
        ::Warden::Protocol::NetOutRequest::Protocol::ICMP
      when 'all'
        ::Warden::Protocol::NetOutRequest::Protocol::ALL
      else
        raise ArgumentError.new("Invalid protocol in egress rule: #{protocol_str}")
    end
  end

  def warden_port_or_range_from_string(port_str)
    if port_str.include?('-')
      { port_range: port_str.sub('-', ':') }
    else
      { port: port_str.to_i }
    end
  end

  def rule_args_for_protocol(protocol, rule)
    base_args = {
      handle:   container_handle,
      protocol: protocol,
      network:  rule['destination'],
    }

    base_args[:log] = true if rule['log']

    results = []

    case protocol
      when ::Warden::Protocol::NetOutRequest::Protocol::TCP, ::Warden::Protocol::NetOutRequest::Protocol::UDP
        if rule['ports']
          port_entries = port_entries(rule['ports'])
          port_entries.each do |p|
            results << base_args.merge(warden_port_or_range_from_string(p))
          end
        else
          results << base_args.dup
        end

      when ::Warden::Protocol::NetOutRequest::Protocol::ICMP
        results << base_args.merge(
          {
            icmp_type: rule['type'],
            icmp_code: rule['code']
          })
      when ::Warden::Protocol::NetOutRequest::Protocol::ALL
        results << base_args
    end

    results
  end

  def port_entries(port_str)
    return [] if port_str.nil?
    port_str.split(',')
  end

end
