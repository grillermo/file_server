#!/usr/bin/env ruby
# frozen_string_literal: true

require "dotenv/load"
require "net/http"
require "securerandom"
require "tempfile"
require "time"
require "uri"

BASE_URL = ENV.fetch("BASE_URL", "http://localhost:33333")
REGION = ENV.fetch("AWS_REGION")
BUCKET = ENV.fetch("AWS_S3_BUCKET")

def build_multipart_body(boundary, field_name:, filename:, content_type:, content:)
  [
    "--#{boundary}\r\n",
    %(Content-Disposition: form-data; name="#{field_name}"; filename="#{filename}"\r\n),
    "Content-Type: #{content_type}\r\n\r\n",
    content,
    "\r\n--#{boundary}--\r\n"
  ].join
end

uri = URI.join(BASE_URL, "/upload")
boundary = "RubyMultipart#{SecureRandom.hex(8)}"
filename = "test.rb"
content = "file_server upload test at #{Time.now.utc.iso8601}\n"

tempfile = File.open(filename)

body = build_multipart_body(
  boundary,
  field_name: "file",
  filename: filename,
  content_type: "text/plain",
  content: tempfile.read
)

request = Net::HTTP::Post.new(uri)
request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
request.body = body

response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
  http.request(request)
end

raise "Expected HTTP 200, got #{response.code}\n#{response.body}" unless response.code == "200"
raise "Expected text/plain response, got #{response['content-type'].inspect}" unless response["content-type"]&.start_with?("text/plain")

returned_url = response.body.strip
expected_prefix = "https://#{BUCKET}.s3.#{REGION}.amazonaws.com/"
raise "Expected S3 URL starting with #{expected_prefix.inspect}, got #{returned_url.inspect}" unless returned_url.start_with?(expected_prefix)

key = returned_url.delete_prefix(expected_prefix)
raise "Expected object key to include #{filename.inspect}, got #{key.inspect}" unless key.end_with?(filename)

puts "Upload succeeded"
puts "S3 URL: #{returned_url}"
