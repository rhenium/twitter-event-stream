require "json"
require "net/http"
require "simple_oauth"

module OAuthHelpers
  class HTTPRequestError < StandardError
    attr_reader :res

    def initialize(uri, res)
      super("HTTP request failed: path=#{uri.request_uri} code=#{res.code} " \
            "body=#{res.body}")
      @res = res
    end
  end

  module_function

  private def http_req_connect(uri_string)
    uri = URI.parse(uri_string)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http|
      res = yield(http, uri.request_uri)
      raise HTTPRequestError.new(uri, res) if res.code !~ /\A2\d\d\z/
      res.body
    }
  end

  def http_get(auth, uri_string, method: :get)
    http_req_connect(uri_string) { |http, path|
      http.send(method, path, { "Authorization" => auth })
    }
  end

  def http_post(auth, uri_string, body)
    http_req_connect(uri_string) { |http, path|
      http.post(path, body, { "Authorization" => auth })
    }
  end

  def bearer_request_token(oauth)
    ck, cs = oauth[:consumer_key], oauth[:consumer_secret]
    body = http_post("Basic #{["#{ck}:#{cs}"].pack("m0")}",
                     "https://api.twitter.com/oauth2/token",
                     "grant_type=client_credentials")
    hash = JSON.parse(body, symbolize_names: true)
    hash[:access_token]
  end

  def bearer_get(token, path)
    http_get("Bearer #{token}", "https://api.twitter.com#{path}")
  end

  def user_get(oauth, path, params = {})
    path += "?" + params.map { |k, v| "#{k}=#{v}" }.join("&") if !params.empty?
    uri_string = "https://api.twitter.com#{path}"
    auth = SimpleOAuth::Header.new(:get, uri_string, {}, oauth).to_s
    http_get(auth, uri_string)
  end

  def user_delete(oauth, path, params = {})
    path += "?" + params.map { |k, v| "#{k}=#{v}" }.join("&") if !params.empty?
    uri_string = "https://api.twitter.com#{path}"
    auth = SimpleOAuth::Header.new(:delete, uri_string, {}, oauth).to_s
    http_get(auth, uri_string, method: :delete)
  end

  def user_post(oauth, path, params = {})
    body = params.map { |k, v| "#{k}=#{v}" }.join("&")
    uri_string = "https://api.twitter.com#{path}"
    auth = SimpleOAuth::Header.new(:post, uri_string, params, oauth).to_s
    http_post(auth, uri_string, body)
  end
end
