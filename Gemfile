source "https://rubygems.org", cooldown: 7

ruby "4.0.10"

gem "rack", "~> 3.1"
gem "rackup", "~> 2.2"
gem "webrick", "~> 1.9"
gem "dotenv", "~> 3.1"

# Ruby 4.0 no longer lets bundle exec load the bundled minitest/rake unless listed here.
group :test do
  gem "minitest"
  gem "rake"
end
