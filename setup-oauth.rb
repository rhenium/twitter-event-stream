require "json"
require_relative "oauth"

if ARGV.size != 2
  STDERR.puts "Usage: ruby setup-oauth.rb <consumer key> <consumer secret>"
  exit 1
end

oauth_opts = { consumer_key: ARGV[0], consumer_secret: ARGV[1] }

puts "#POST /oauth/request_token"
authorize_params = OAuthHelpers.user_post(oauth_opts, "/oauth/request_token",
                                          { "oauth_callback" => "oob" })
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
oauth_params = OAuthHelpers.user_post(oauth_opts, "/oauth/access_token",
                                      { "oauth_verifier" => pin })
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
