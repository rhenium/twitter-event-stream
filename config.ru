# Start home_timeline polling
require_relative "service"
Service.setup

# Start web app
require_relative "app"
run App
