require "openssl"

class HMACHelper
  attr_reader :key

  def initialize(key)
    raise ArgumentError, "key must not be nil" unless key
    @key = key
  end

  def create(str)
    hmac = OpenSSL::HMAC.new(@key, OpenSSL::Digest::SHA512.new)
    hmac.update(str)
    hmac.hexdigest
  end

  def compare(correct_hmac, str)
    generated_hmac = create(str)

    # Use constant_time_compare instead of simple '=='
    # to prevent possible timing attacks.
    # (http://codahale.com/a-lesson-in-timing-attacks/)
    constant_time_compare(correct_hmac, generated_hmac)
  end

  private

  def constant_time_compare(str1, str2)
    return false if str1.to_s.size != str2.to_s.size

    verified = true
    str1.to_s.bytes.zip(str2.to_s.bytes) do |expected_byte, given_byte|
      verified = false if expected_byte != given_byte
    end

    verified
  end
end
