# coding: UTF-8

require "uri"

class URICleaner

  def self.clean(uri)
    uri.kind_of?(Array) ? clean_array(uri) : clean_uri(uri)
  end

  private

  def self.clean_array(uri_list)
    uri_list.map { |uri| clean_uri(uri) }
  end

  def self.clean_uri(u)
    uri = u.is_a?(URI) ? u.dup : URI.parse(u)
    uri.password = nil if uri.password
    uri.user = nil if uri.user
    uri.to_s
  rescue => e
    "<<uri parse error>>"
  end

end
