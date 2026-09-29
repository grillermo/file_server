# frozen_string_literal: true

require "rack/mime"

# Streams a stored file instead of reading it into memory. WEBrick sends
# anything with to_path straight from disk; other servers use each. Lives on
# its own so the demos app can serve files without loading the main app.
class FileBody
  CHUNK_SIZE = 64 * 1024

  def self.headers(path)
    {
      "content-type" => Rack::Mime.mime_type(File.extname(path), "application/octet-stream"),
      "content-length" => File.size(path).to_s
    }
  end

  def initialize(path)
    @path = path
  end

  def to_path
    @path
  end

  def each
    File.open(@path, "rb") do |file|
      while (chunk = file.read(CHUNK_SIZE))
        yield chunk
      end
    end
  end
end
