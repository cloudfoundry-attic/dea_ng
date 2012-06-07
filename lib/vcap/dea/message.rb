require 'yajl'

module VCAP
  module Dea
  end
end

class VCAP::Dea::Message
  class << self
    def decode_received(nats, subject, raw_msg, reply_to)
      dec_json = Yajl::Parser.parse(raw_msg)
      new(nats, subject,
          :reply_to => reply_to,
          :details  => dec_json)
    end
  end

  attr_accessor :subject, :details

  def initialize(nats, subj = nil, opts={})
    @nats     = nats
    @subject  = subj
    @reply_to = opts[:reply_to]
    @details  = opts[:details]
  end

  def respond(subj, details)
    @subject = subj
    @details = details
    send
  end

  def send
    encoded_message = Yajl::Encoder.encode(@details)
    @nats.publish(subject, encoded_message)

    self
  end

  def reply(details={})
    return unless @reply_to
    msg = self.class.new(@nats, @reply_to, :details => details)
    msg.send

    self
  end
end
