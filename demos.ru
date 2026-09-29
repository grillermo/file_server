require "dotenv/load"
require_relative "lib/demo_app"

Process.setproctitle("file_server-demos")
run DemoApp.new
