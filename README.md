
# pinterest-dl
**Get direct image/video URLs from Pinterest, search pins, fetch board contents, and download media — as a Ruby library or a CLI.**

[![Gem Version](https://img.shields.io/gem/v/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)  
[![Gem Downloads](https://img.shields.io/gem/dt/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)  
[![License](https://img.shields.io/badge/License-WTFPL-blue)](LICENSE)  
[![Ruby](https://img.shields.io/badge/Ruby-2.7+-red)](https://www.ruby-lang.org/)  
<img src="https://img.icons8.com/color/96/000000/pinterest--v1.png" width="80">

---

> **Note:** Users in some regions (e.g. Iran) may need a fu*king VPN to reach Pinterest.  
> (Yeah, because even in 2026 Pinterest still gives you the middle finger on clean APIs.)

Pinterest doesn't give you a clean, official API for getting a direct media URL out of a pin, walking a board, or downloading a batch of images. `pinterest-dl` does that: point it at a pin, a search query, or a board, and get back real `i.pinimg.com` / `v.pinimg.com` URLs — or the fucking files themselves, already saved to disk.

## What it does

- Pulls the **direct image or video URL** out of a single pin page.  
- **Searches** Pinterest and returns pin metadata (id, url, title, description, creator, image/video URL), with pagination.  
- Fetches all pins from a **board** (or a specific board section).  
- **Downloads** a URL — or a whole batch of them — straight to disk, with progress reporting and per-file error handling.  
- Supports **authenticated requests** via cookies, for boards/pins that require a logged-in session.  
- Raises **specific, catchable exceptions** (`NotFoundError`, `RateLimitError`, `NetworkError`, ...) instead of returning `nil` or printing to stdout.  
- Ships a **CLI** (`pinterest-dl`) for one-off use from the shell.

## Installation

```bash
gem install pinterest-dl
```

Or add it to your Gemfile:

```ruby
gem 'pinterest-dl'
```

## Quick start

```ruby
require 'pinterest-dl'
# Direct image URL
PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/') # => "https://i.pinimg.com/originals/aa/bb/cc/aabbcc...jpg"
# Direct video URL (raises PinterestDL::NotFoundError if the pin has no video)
PinterestDL.get_video_url('https://www.pinterest.com/pin/1234567890123456789/') # => "https://v.pinimg.com/videos/mc/720p/aa/bb/cc/aabbcc....mp4"
# Download it
PinterestDL.download(
  PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/'),
  path: 'downloads/pin.jpg'
)
```

## Usage

### Get image / video URLs

```ruby
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/') # Pick a specific size bucket
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/', quality: :"474x") # quality can be :originals, :"736x", :"474x", :"236x"
url = PinterestDL.get_video_url('https://www.pinterest.com/pin/example/')
# Both at once
media = PinterestDL.get_media('https://www.pinterest.com/pin/example/') # => { image_url: "https://i.pinimg.com/...", video_url: nil }
```

### Search

```ruby
# Search for pins with a specific query
results = PinterestDL.search('nature landscape', limit: 10) # => [{ id: "...", pin_url: "...", title: "...", description: "...", creator: "...", image_url: "...", video_url: nil }, ...]
# Fetch more than one page of results (25 pins/page from Pinterest)
results = PinterestDL.search('nature landscape', limit: 100, pages: 10)
# Get only image URLs from search results
images = PinterestDL.search_images('sunset', limit: 5) # => ["https://i.pinimg.com/originals/...", ...]
# Get only video URLs from search results
videos = PinterestDL.search_videos('tutorial', limit: 3) # => ["https://v.pinimg.com/videos/...", ...]
# Get search results as a JSON string
json_results = PinterestDL.search_json('anime art', limit: 20)
```

### Boards & sections

```ruby
# All pins on a board
pins = PinterestDL.board('https://www.pinterest.com/username/board-name/', limit: 50)
# A specific section within a board
pins = PinterestDL.board('https://www.pinterest.com/username/board-name/section-slug/', limit: 50)
```

### Downloading

```ruby
# Single file
PinterestDL.download('https://i.pinimg.com/originals/aa/bb/cc/img.jpg', path: 'out/img.jpg')
# Batch download (returns { succeeded: [...], failed: [{ url:, error: }, ...] })
urls = PinterestDL.search_images('mountains', limit: 20)
result = PinterestDL.download_batch(urls, dir: './downloads')
# With progress reporting
bar = PinterestDL::ProgressBar.new(total: urls.size)
PinterestDL.download_batch(urls, dir: './downloads') do |done, total, url|
  bar.update(done)
end
```

### Cookies / authenticated sessions

Some boards and pins require a logged-in session to view. Pass your browser's Pinterest cookies through global configuration:

```ruby
PinterestDL.configure do |c|
  c.cookies    = 'sessionid=...; csrftoken=...' # yeah, steal your own fucking session if you have to
  c.user_agent = 'Mozilla/5.0 ...' # optional override
end
```

### Other configuration

```ruby
PinterestDL.configure do |c|
  c.open_timeout        = 10   # seconds, connection open timeout
  c.read_timeout         = 20   # seconds, response read timeout
  c.max_retries          = 3    # retries on transient network failures
  c.retry_wait           = 1.0  # base seconds between retries (backs off linearly)
  c.rate_limit_interval   = 0.5  # minimum seconds between outgoing requests
  c.quality               = :originals # default image quality for get_image_url
  c.logger.level          = Logger::INFO # library uses this Logger instead of puts
end
```

### Error handling

Every method raises a subclass of `PinterestDL::Error` instead of returning `nil` or printing to the console:

```ruby
begin
  PinterestDL.get_image_url('https://www.pinterest.com/pin/does-not-exist/')
rescue PinterestDL::NotFoundError
  # pin/board/search had nothing to extract
rescue PinterestDL::RateLimitError => e
  # Pinterest throttled us; e.retry_after may hold a hint
rescue PinterestDL::AuthenticationError
  # the resource needs c.cookies to be set
rescue PinterestDL::NetworkError => e
  # DNS/timeout/connection-level failure; e.cause_error has the original exception
rescue PinterestDL::InvalidURLError
  # the given string isn't a Pinterest pin/board URL
rescue PinterestDL::Error
  # catch-all for anything above
end
```

### CLI

```bash
pinterest-dl image https://www.pinterest.com/pin/example/
pinterest-dl image https://www.pinterest.com/pin/example/ -o pin.jpg
pinterest-dl video https://www.pinterest.com/pin/example/ -o pin.mp4
pinterest-dl search "cyberpunk city" -n 20
pinterest-dl search "cyberpunk city" -n 20 -o ./downloads
pinterest-dl board https://www.pinterest.com/username/board-name/ -n 50 -o ./downloads
pinterest-dl --help
```

Flags: `-o/--output`, `-n/--limit`, `-q/--quality`, `-c/--cookies`, `-v/--verbose`.


## Development

```bash
bundle install
bundle exec rake test     # run the test suite
bundle exec rake rubocop  # lint
bundle exec rake          # both (default task)
```

## Links

- [RubyGems](https://rubygems.org/gems/pinterest-dl)
- [GitHub](https://github.com/monji024/pinterest-dl)
- [Changelog](CHANGELOG.md)
- [Issue tracker](https://github.com/monji024/pinterest-dl/issues)

## License

WTFPL © [monji024](https://github.com/monji024)
