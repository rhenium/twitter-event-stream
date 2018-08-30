twitter-event-stream
====================

Description
-----------

twitter-event-stream provides an HTTP long polling endpoint that works in a
similar way to the deprecated User Streams API[1]. It uses the REST API and
the Account Activity API.

It is no easy work to update a Twitter client application built on top of the
User Streams API. Even worse, the Account Activity API which pretends to be
the replacement cannot be used directly by a mobile Twitter client.
twitter-event-stream allows such applications to continue to work with the
minimal amount of changes.

[1] https://twittercommunity.com/t/details-and-what-to-expect-from-the-api-deprecations-this-week-on-august-16-2018/110746

Setup
-----

Configuration
~~~~~~~~~~~~~

 - You have to gain access to (the premium version of) the Account Activity
   API, and create a "dev environment". The "dev environment name", the base
   url where twitter-event-stream is deployed, the whitelisted consumer key,
   and the consumer secret are specified by environment variables.

     TWITTER_EVENT_STREAM_BASE_URL=<base url>
     TWITTER_EVENT_STREAM_ENV_NAME=<dev environment name>
     TWITTER_EVENT_STREAM_CONSUMER_KEY=<consumer key>
     TWITTER_EVENT_STREAM_CONSUMER_SECRET=<consumer secret>

   WARNING: twitter-event-stream assumes your dev environment allows only one
   webhook URL (which is the case for sandbox (free) plan) and removes all the
   existing webhook URL(s) on startup.

   NOTE: Subscription are limited to a maximum of 15 users per application in
   the sandbox plan. Because there is no way to clear subscriptions without
   having the access token of every subscribing user, it is not possible for
   twitter-event-stream to do that. It may be necessary to re-create the dev
   environment manually on developer.twitter.com after removing and adding
   another user to twitter-event-stream.

 - Credentials used for fetching home_timeline are stored in environment
   variables named `TWITTER_EVENT_STREAM_USER_<tag>`. `<tag>` may be any
   text.

     TWITTER_EVENT_STREAM_USER_ABC=<value>

   `<value>` is a JSON encoding of the following object:

     {
       "user_id": <user's numerical id>,
       "requests_per_window": 15,
       "token": <access token>,
       "token_secret": <access token secret>
     }
     # Increase requests_per_window if your application is granted the
     # permission to make more requests per 15 minutes window.

   If you need to use a different consumer key pair for the REST API requests,
   add the following to the JSON object. The token may be read-only.

     {
       "rest_consumer_key": <consumer key>,
       "rest_consumer_secret": <consumer secret>,
       "rest_token": <access token>,
       "rest_token_secret": <access token secret>,
     }

   NOTE: `setup-oauth.rb` included in this distribution might be useful to
   do 3-legged OAuth and make the JSON object.

Deployment
~~~~~~~~~~

 - Ruby and Bundler are the prerequisites.

 - Install dependencies by `bundle install`, and then run
   `bundle exec puma -e production -p $PORT`.

   * The quickest way to deploy twitter-event-stream would be to use Heroku.
     Click the link and fill forms: https://heroku.com/deploy

Usage
-----

twitter-event-stream opens two endpoints for a client:

 - /1.1/user.json

   The message format is almost identical to the User streams' message format.
   However, due to the limitation of the Account Activity API, direct messages
   and some of the event types are not supported.

 - /stream

   Sends events and home_timeline tweets in the server-sent events format
   (text/event-stream). Events have the structure:

     event: <event>\r\n
     data: <payload>\r\n\r\n

   `<event>` will be one of the event types received by the webhook:

   * `favorite_events` (for example; see Twitter's documentation[2])

       event: favorite_events\r\n
       data: [{"id":"...","favorited_status":{...}}]\r\n\r\n

   Or, one of the following event types defined by twitter-event-stream:

   * `twitter_event_stream_home_timeline`

     New items in the home timeline. `<payload>` is an array of Tweet object.

       event: twitter_event_stream_home_timeline\r\n
       data: [{"id":...,"text":"..."},...]\r\n\r\n

   * `twitter_event_stream_message`

     A message from twitter-event-stream, such as error reporting. `<payload>`
     is a String.

       event: twitter_event_stream_message\r\n
       data: "Message"\r\n\r\n

   Note that comment events are also sent every 30 seconds to keep the HTTP
   connection open:

     :\r\n\r\n


twitter-event-stream uses "OAuth Echo"[3] to authenticate a client, meaning
an application must provide the following HTTP headers:

 - `x-auth-service-provider`

    Must be set to
    "https://api.twitter.com/1.1/account/verify_credentials.json".

 - `x-verify-credentials-authorization`

    The content of the Authorization HTTP header that the client would
    normally send when calling the account/verify_credentials API.

[2] https://developer.twitter.com/en/docs/basics/authentication/overview/oauth-echo.html
[3] https://developer.twitter.com/en/docs/accounts-and-users/subscribe-account-activity/guides/account-activity-data-objects

License
-------

twitter-event-stream is licensed under the MIT license. See COPYING.
