require "sinatra/base"
require "json"
require_relative "service"

class App < Sinatra::Base
  enable :logging
  set :consumer_key, ENV["TWITTER_EVENT_STREAM_CONSUMER_KEY"]
  set :consumer_secret, ENV["TWITTER_EVENT_STREAM_CONSUMER_SECRET"]

  helpers do
    def get_service
      asp = request.env["HTTP_X_AUTH_SERVICE_PROVIDER"]
      vca = request.env["HTTP_X_VERIFY_CREDENTIALS_AUTHORIZATION"]
      Service.oauth_echo(asp, vca)
    rescue ServiceError => e
      halt 403, "authentication failed"
    end
  end

  get "/stream" do
    content_type "text/event-stream"
    service = get_service
    logger.debug("/stream (#{service.user_id}): CONNECT!")

    # Heroku will kill the connection after 55 seconds of inactivity.
    # https://devcenter.heroku.com/articles/request-timeout#long-polling-and-streaming-responses
    queue = Thread::Queue.new
    th = Thread.start { sleep 15; loop { queue << ":\r\n\r\n"; sleep 30 } }
    tag = service.subscribe(params["count"].to_i) { |event, data|
      queue << "event: #{event}\r\ndata: #{JSON.generate(data)}\r\n\r\n"
    }

    stream(true) do |out|
      out.callback {
        logger.debug("/stream (#{service.user_id}): CLEANUP!")
        queue.close
        service.unsubscribe(tag)
        th.kill; th.join
      }
      loop { out << queue.pop }
    end
  end

  get "/1.1/user.json" do
    content_type :json
    service = get_service
    logger.debug("/1.1/user.json (#{service.user_id}): CONNECT!")

    friend_ids = service.twitter_get("/1.1/friends/ids.json",
                                     { "user_id" => service.user_id })

    queue = Thread::Queue.new
    queue << "#{JSON.generate({ "friends" => friend_ids["ids"] })}\r\n"

    th = Thread.start { sleep 15; loop { queue << "\r\n"; sleep 30 } }
    tag = service.subscribe(params["count"].to_i) { |event, data|
      case event
      when "twitter_event_stream_home_timeline"
        queue << data.map { |object| JSON.generate(object) }.join("\r\n")
      when "twitter_event_stream_message"
      when "tweet_create_events"
        queue << data.map { |object| JSON.generate(object) }.join("\r\n")
      when "favorite_events"
        queue << data.map { |object|
          JSON.generate({
            "event" => "favorite",
            "created_at" => object["created_at"],
            "source" => object["user"],
            "target" => object["favorited_status"]["user"],
            "target_object" => object["favorited_status"],
          })
        }.join("\r\n")
      when "follow_events", "block_events"
        queue << data.map { |object|
          JSON.generate({
            "event" => object["type"],
            "created_at" => Time.utc(Integer(object["created_timestamp"]))
              .strftime("%a %b %d %T %z %Y"),
            "source" => object["user"],
            "target" => object["favorited_status"]["user"],
            "target_object" => object["favorited_status"],
          })
        }.join("\r\n")
      when "mute_events"
        # Not supported
      when "direct_message_events", "direct_message_indicate_typing_events",
        "direct_message_mark_read_events"
        # Not supported
      when "tweet_delete_events"
        queue << data.map { |object|
          JSON.generate({
            "delete" => object
          })
        }.join("\r\n")
      else
        logger.info("/1.1/user.json (#{service.user_id}): " \
                    "unknown event: #{event}")
      end
    }

    stream(true) do |out|
      out.callback {
        logger.debug("/1.1/user.json (#{service.user_id}): CLEANUP!")
        queue.close
        service.unsubscribe(tag)
        th.kill; th.join
      }
      loop { out << queue.pop }
    end
  end

  get "/webhook" do
    content_type :json
    crc_token = params["crc_token"] or
      halt 400, "crc_token missing"
    mac = OpenSSL::HMAC.digest("sha256", settings.consumer_secret, crc_token)
    response_token = "sha256=#{[mac].pack("m0")}"
    JSON.generate({ "response_token" => response_token })
  end

  post "/webhook" do
    content_type :json
    body = request.body.read
    mac = OpenSSL::HMAC.digest("sha256", settings.consumer_secret, body)
    sig = "sha256=#{[mac].pack("m0")}"
    if request.env["HTTP_X_TWITTER_WEBHOOKS_SIGNATURE"] == sig
      Service.feed_webhook(body)
    else
      logger.info "x-twitter-webhooks-signature invalid"
    end
    JSON.generate({ "looks" => "ok" })
  end

  get "/" do
    <<~'EOF'
      <!DOCTYPE html>
      <meta charset=UTF-8>
      <meta name=viewport content="width=device-width,initial-scale=1">
      <title>twitter-event-stream</title>
      <style>
        div { max-width: 1200px; margin: 0 auto; }
      </style>
      <div>
        <h1>twitter-event-stream</h1>
        <a href="https://github.com/rhenium/twitter-event-stream">Source Code</a>
      </div>
    EOF
  end
end
