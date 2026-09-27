require_relative "app"

Process.setproctitle("file_server")
run FileServerApp.new
