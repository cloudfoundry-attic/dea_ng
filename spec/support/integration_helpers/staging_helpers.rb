require "net/http"
require "securerandom"
require 'uri'
require 'socket'
require 'httpclient'

module StagingHelpers
  def get_stager_id
    nats.with_nats do
      NATS.subscribe("dea.advertise", :do_not_track_subscription => true) do |msg|
        stager_id = Yajl::Parser.parse(msg)["id"] if msg
        NATS.stop
        return stager_id
      end
    end
  end

  def log_url(response)
    log_url = response['task_streaming_log_url']
    return nil unless log_url

    @@resolved ||= {}

    uri = URI.parse(log_url)
    @@resolved[uri.host] ||= Dea.local_ip
    uri.host = @@resolved[uri.host]
    uri.to_s
  end

  def perform_stage_request(message)
    message["task_id"] ||= SecureRandom.uuid

    got_first_response = false
    got_second_response = false

    log = ""
    completion_response = nil

    stager_id = get_stager_id
    nats.make_blocking_request("staging.#{stager_id}.start", message, 2) do |response_index, response|
      case response_index
      when 0
        got_first_response = true

        stream_update_log(log_url(response)) do |chunk|
          print chunk
          log << chunk
        end

      when 1
        got_second_response = true
        completion_response = response

      else
        raise "got unknown response index: #{response_index}"
      end
    end

    expect(got_first_response).to be true
    expect(got_second_response).to be true

    return completion_response, log
  end

  def stream_update_log(log_url)
    offset = 0

    catch(:log_completed) do
      while true
        begin
          stream_url(log_url + "&tail&tail_offset=#{offset}") do |out|
            offset += out.size
            yield out
          end
        rescue Timeout::Error
          puts "Timed out waiting for logs"
        end
      end
    end
  end

  def stream_url(url, &blk)
    uri = URI.parse(url)

    client = HTTPClient.new
    client.ssl_config.verify_mode = nil if uri.scheme == "https"
    response = client.get(url)
    case response.status
      when 200
        blk.call(response.content)
      when 404
        throw(:log_completed)
      else
        raise "Bad response from streaming log: #{response.code}: #{response.body}"
    end
  end
end
