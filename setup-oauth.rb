require "json"
require "net/http"
require "simple_oauth"

if ARGV.size != 2
  STDERR.puts "Usage: ruby setup-oauth.rb <consumer key> <consumer secret>"
  exit 1
end

def oauth_post(path, params, oauth)
  body = params.map { |k, v| "#{k}=#{v}" }.join("&")

  uri = URI.parse("https://api.twitter.com#{path}")
  auth = SimpleOAuth::Header.new(:post, uri.to_s, params, oauth).to_s

  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http|
    res = http.post(path, body, { "Authorization" => auth })
    if res.code != "200"
      raise "request failed: path=#{path} code=#{res.code} body=#{res.body}"
    end
    res.body
  }
end


oauth_opts = { consumer_key: ARGV[0], consumer_secret: ARGV[1] }

puts "#POST /oauth/request_token"
authorize_params = oauth_post("/oauth/request_token",
                              { "oauth_callback" => "oob" }, oauth_opts)
extracted = authorize_params.split("&").map { |v| v.split("=") }.to_h
oauth_opts[:token] = extracted["oauth_token"]
oauth_opts[:token_secret] = extracted["oauth_token_secret"]
puts "#=> #{authorize_params}"
puts

puts "Visit https://api.twitter.com/oauth/authorize?oauth_token=" \
  "#{extracted["oauth_token"]}"
print "Input PIN code: "
pin = STDIN.gets.chomp
puts

puts "#POST /oauth/access_token"
oauth_params = oauth_post("/oauth/access_token",
                          { "oauth_verifier" => pin }, oauth_opts)
puts "#=> #{oauth_params}"
puts

extracted = oauth_params.split("&").map { |v| v.split("=") }.to_h
user_id = extracted["oauth_token"].split("-")[0].to_i
obj = {
  user_id: user_id,
  requests_per_window: 15,
  token: extracted["oauth_token"],
  token_secret: extracted["oauth_token_secret"],
  rest_consumer_key: oauth_opts[:consumer_key],
  rest_consumer_secret: oauth_opts[:consumer_secret],
  rest_token: extracted["oauth_token"],
  rest_token_secret: extracted["oauth_token_secret"],
}
puts "TWITTER_EVENT_STREAM_USER_#{user_id}='#{JSON.generate(obj)}'"
