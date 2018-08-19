require "json"
require "net/http"
require "simple_oauth"

class ServiceError < StandardError; end

class Service
  class << self
    private :new

    def setup
      aa_consumer_key = ENV["TWITTER_EVENT_STREAM_CONSUMER_KEY"]
      aa_consumer_secret = ENV["TWITTER_EVENT_STREAM_CONSUMER_SECRET"]

      @users = {}
      ENV.each { |k, v|
        next unless k.start_with?("TWITTER_EVENT_STREAM_USER_")
        obj = JSON.parse(v, symbolize_names: true)
        @users[obj.fetch(:user_id)] = new(
          consumer_key: aa_consumer_key,
          consumer_secret: aa_consumer_secret,
          **obj,
        )

        # TODO: Add to the webhook if needed
      }
    end

    def oauth_echo(asp, vca)
      if asp != "https://api.twitter.com/1.1/account/verify_credentials.json"
        raise ServiceError, "invalid OAuth Echo parameters"
      end

      uri = URI.parse(asp)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http|
        res = http.get(uri.path, { "Authorization" => vca })
        raise ServiceError, "OAuth Echo failed" if res.code != "200"
        content = JSON.parse(res.body)
        get(content["id"])
      }
    end

    def feed_webhook(json)
      hash = JSON.parse(json)
      if user_id = hash["for_user_id"]
        service = get(user_id)
        service.feed_webhook(hash)
      else
        warn "FIXME\n#{hash}"
      end
    end

    private

    def get(user_id)
      @users[user_id] or
        raise ServiceError, "unauthenticated user: #{user_id}"
    end
  end

  attr_reader :user_id

  def initialize(user_id:,
                 requests_per_window:,
                 consumer_key:,
                 consumer_secret:,
                 token:,
                 token_secret:,
                 rest_consumer_key: consumer_key,
                 rest_consumer_secret: consumer_secret,
                 rest_token: token,
                 rest_token_secret: token_secret)
    @user_id = user_id
    @requests_per_window = Integer(requests_per_window)
    @aa_oauth = {
      consumer_key: consumer_key,
      consumer_secret: consumer_secret,
      token: token,
      token_secret: token_secret,
    }
    @rest_oauth = {
      consumer_key: rest_consumer_key,
      consumer_secret: rest_consumer_secret,
      token: rest_token,
      token_secret: rest_token_secret,
    }
    @listeners = {}
    @backfill = []
    start_polling
  end

  def subscribe(count, &block)
    @listeners[block] = block
    emit_backfill(count)
    block
  end

  def unsubscribe(tag)
    @listeners.delete(tag)
  end

  def feed_webhook(hash)
    hash.each do |key, value|
      next if key == "for_user_id"
      emit(key, value)
    end
  end

  def twitter_get(path, params)
    path += "?" + params.map { |k, v| "#{k}=#{v}" }.join("&") if !params.empty?
    uri = URI.parse("https://api.twitter.com#{path}")
    auth = SimpleOAuth::Header.new(:get, uri.to_s, {}, @rest_oauth).to_s

    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http|
      res = http.get(path, { "Authorization" => auth })
      if res.code != "200"
        # pp res.each_header.to_h
        raise ServiceError, "API request failed: path=#{path} body=#{res.body}"
      end
      JSON.parse(res.body)
    }
  end

  private

  def emit(event, object)
    # TODO: backfill
    @backfill.shift if @backfill.size == 100
    @backfill << [event, object]
    @listeners.each { |_, block| block.call(event, object) }
  end

  def emit_system(message)
    emit("twitter_event_stream_message", message)
  end

  def emit_backfill(count)
    @backfill.last(count).each { |event, object| emit(event, object) }
  end

  def start_polling
    @polling_thread = Thread.start {
      request_interval = 15.0 * 60 / @requests_per_window

      begin
        last_max = nil
        while true
          t = Time.now
          opts = { "count" => 200, "since_id" => last_max ? last_max - 1 : 1 }
          ret = twitter_get("/1.1/statuses/home_timeline.json", opts)

          unless ret.empty?
            if last_max
              if last_max != ret.last["id"]
                emit_system("possible stalled tweets " \
                            "#{last_max}+1...#{ret.last["id"]}")
              else
                ret.pop
              end
            end

            unless ret.empty?
              emit("twitter_event_stream_home_timeline", ret)
              last_max = ret.first["id"]
            end
          end

          sleep -(Time.now - t) % request_interval
        end
      rescue => e
        warn "polling_thread (#{user_id}) uncaught exception: " \
          "#{e.class} (#{e.message})"
        warn e.backtrace
        warn "polling_thread (#{user_id}) restarting in #{request_interval}s"
        sleep request_interval
        retry
      end
    }
  end
end
