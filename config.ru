# Start home_timeline polling
require_relative "service"
require_relative "app"

# HACK: The web app must be already started and accept "GET /webhook" when
# Service.setup is called
Thread.start {
  sleep 1
  begin
    Net::HTTP.get_response(URI(ENV["TWITTER_EVENT_STREAM_BASE_URL"]))
  rescue
  end
  Service.setup
}

# Start web app
use Rack::Deflater
run App
