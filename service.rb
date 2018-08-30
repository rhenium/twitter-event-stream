require "json"
require_relative "oauth"

class ServiceError < StandardError; end

class Service
  class << self
    private :new

    def setup
      consumer_key = ENV["TWITTER_EVENT_STREAM_CONSUMER_KEY"]
      consumer_secret = ENV["TWITTER_EVENT_STREAM_CONSUMER_SECRET"]

      user_objs = []
      ENV.each { |k, v|
        next unless k.start_with?("TWITTER_EVENT_STREAM_USER_")
        user_objs << JSON.parse(v, symbolize_names: true)
      }

      # We assume the webapp is already started at this point: the CRC requires
      # GET /webhook to respond
      app_url = ENV["TWITTER_EVENT_STREAM_BASE_URL"]
      aa_env_name = ENV["TWITTER_EVENT_STREAM_ENV_NAME"]
      setup_webhook(app_url, aa_env_name, consumer_key, consumer_secret,
                    user_objs)

      @users = {}
      user_objs.each { |obj|
        @users[obj.fetch(:user_id)] = new(
          user_id: obj.fetch(:user_id),
          requests_per_window: obj.fetch(:requests_per_window),
          rest_oauth: {
            consumer_key: obj.fetch(:rest_consumer_key) {
              consumer_key },
            consumer_secret: obj.fetch(:rest_consumer_secret) {
              consumer_secret },
            token: obj.fetch(:rest_token) {
              obj.fetch(:token) },
            token_secret: obj.fetch(:rest_token_secret) {
              obj.fetch(:token_secret) }
          },
        )
      }
    end

    private def setup_webhook(app_url, env_name, consumer_key, consumer_secret,
                              user_objs)
      oauth = proc { |n|
        {
          consumer_key: consumer_key,
          consumer_secret: consumer_secret,
          token: user_objs.dig(n, :token),
          token_secret: user_objs.dig(n, :token_secret),
        }
      }

      if user_objs.empty?
        warn "setup_webhook: no users configured. cannot setup webhook"
        return
      end

      warn "setup_webhook: get existing webhook URL(s)"
      app_token = OAuthHelpers.bearer_request_token(oauth[0])
      body = OAuthHelpers.bearer_get(app_token,
                                     "/1.1/account_activity/all/webhooks.json")
      obj = JSON.parse(body, symbolize_names: true)
      env = obj.dig(:environments).find { |v| v[:environment_name] == env_name }

      warn "setup_webhook: clear existing webhook URL(s)"
      env[:webhooks].each do |webhook|
        warn "setup_webhook: delete id=#{webhook[:id]}: #{webhook[:url]}"
        path = "/1.1/account_activity/all/#{env_name}/webhooks/" \
          "#{webhook[:id]}.json"
        OAuthHelpers.user_delete(oauth[0], path)
      end

      warn "setup_webhook: register a webhook URL"
      webhook_url = app_url + (app_url.end_with?("/") ? "" : "/") + "webhook"
      path = "/1.1/account_activity/all/#{env_name}/webhooks.json?url=" +
        CGI.escape(webhook_url)
      webhook = OAuthHelpers.user_post(oauth[0], path)
      warn "setup_webhook: => #{webhook}"

      warn "setup_webhook: add subscriptions"
      user_objs.each_with_index { |_, n|
        warn "setup_webhook: add subscription for " \
          "user_id=#{user_objs.dig(n, :user_id)}"
        path = "/1.1/account_activity/all/#{env_name}/subscriptions.json"
        OAuthHelpers.user_post(oauth[n], path)
      }
    rescue => e
      warn "setup_webhook: uncaught exception: #{e.class} (#{e.message})"
      warn e.backtrace
    end

    def oauth_echo(asp, vca)
      if asp != "https://api.twitter.com/1.1/account/verify_credentials.json"
        raise ServiceError, "invalid OAuth Echo parameters"
      end

      begin
        body = OAuthHelpers.http_get(vca, asp)
        content = JSON.parse(body, symbolize_names: true)
        get(content[:id])
      rescue OAuthHelpers::HTTPRequestError
        raise ServiceError, "OAuth Echo failed"
      end
    end

    def feed_webhook(json)
      hash = JSON.parse(json)
      if user_id = hash["for_user_id"]
        service = get(Integer(user_id))
        service.feed_webhook(hash)
      else
        warn "FIXME\n#{hash}"
      end
    end

    private

    def get(user_id)
      defined?(@users) and @users[user_id] or
        raise ServiceError, "unauthenticated user: #{user_id}"
    end
  end

  attr_reader :user_id

  def initialize(user_id:,
                 requests_per_window:,
                 rest_oauth:)
    @user_id = user_id
    @requests_per_window = Integer(requests_per_window)
    @rest_oauth = rest_oauth
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
    JSON.parse(OAuthHelpers.user_get(@rest_oauth, path, params))
  rescue OAuthHelpers::HTTPRequestError => e
    # pp e.res.each_header.to_h
    raise ServiceError, "API request failed: path=#{path} body=#{e.res.body}"
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
