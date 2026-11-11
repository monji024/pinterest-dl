# pinterest-dl

**Get direct image/video URLs from Pinterest, search pins, fetch board contents, and download media — as a Ruby library or a CLI.**

[![Gem Version](https://img.shields.io/gem/v/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![Gem Downloads](https://img.shields.io/gem/dt/pinterest-dl)](https://rubygems.org/gems/pinterest-dl)
[![CI](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml/badge.svg)](https://github.com/monji024/pinterest-dl/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-WTFPL-blue)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.0+-red)](https://www.ruby-lang.org/)

<img src="https://img.icons8.com/color/96/000000/pinterest--v1.png" width="80">

> **Note:** Users in some regions (e.g. Iran) may need a VPN or proxy (`--proxy`) to reach Pinterest.

Pinterest doesn't give you a clean, official API for getting a direct media URL out of a pin, walking a board, or downloading a batch of images. `pinterest-dl` does that: point it at a pin, a search query, or a board, and get back real `i.pinimg.com` / `v.pinimg.com` URLs — or save the files straight to disk.

## What it does

- Pulls the **direct image or video URL** out of a single pin page (including `pin.it` short links and country domains).
- **Searches** Pinterest and returns pin metadata (`id`, `pin_url`, `title`, `description`, `creator`, `image_url`, `video_url`), with automatic cursor pagination and duplicate detection.
- Fetches all pins from a **board** (or a specific board section).
- **Downloads** single files or parallel batches with live progress bars (percentage, bytes, speed, ETA), HTTP `Range` resume, bandwidth throttling, content-type/magic-byte verification, max file size limits, and automatic deduplication.
- Provides **isolated sessions** (`PinterestDL.session`) alongside global configuration, with domain-scoped `CookieJar` protection, cross-domain redirect guards, SSRF prevention, and automatic log redaction.
- Raises **specific, catchable exceptions** (`NotFoundError`, `ForbiddenError`, `RateLimitError`, `AuthenticationError`, `TimeoutError`, `SSRFError`, `FileTooLargeError`, `IncompleteDownloadError`, `InvalidMediaError`, ...) instead of returning `nil`.
- Ships a full-featured **CLI** (`pinterest-dl`) with `text`, `json`, `csv`, and `quiet` output modes.

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
PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/')
# => "https://i.pinimg.com/originals/aa/bb/cc/aabbcc...jpg"

# Direct video URL (raises PinterestDL::NotFoundError if the pin has no video)
PinterestDL.get_video_url('https://www.pinterest.com/pin/1234567890123456789/')
# => "https://v.pinimg.com/videos/mc/720p/aa/bb/cc/aabbcc....mp4"

# Download it
PinterestDL.download(
  PinterestDL.get_image_url('https://www.pinterest.com/pin/1234567890123456789/'),
  path: 'downloads/pin.jpg'
)
```

## Usage

### Isolated Sessions

Create independent sessions with their own cookies, timeouts, and settings without mutating global state:

```ruby
session = PinterestDL.session(
  cookies: File.expand_path('~/cookies.txt'),
  quality: :'1200x',
  concurrency: 6,
  max_speed: '2M'
)

pins = session.board('https://www.pinterest.com/username/board-name/', limit: 50)
report = session.download_batch(pins, dir: './downloads')
```

### Get image / video URLs

```ruby
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/')

# Pick a specific size bucket (:originals, :"1200x", :"736x", :"564x", :"474x", :"236x")
url = PinterestDL.get_image_url('https://www.pinterest.com/pin/example/', quality: :"736x")

url = PinterestDL.get_video_url('https://www.pinterest.com/pin/example/')

# Both at once
media = PinterestDL.get_media('https://www.pinterest.com/pin/example/')
# => { image_url: "https://i.pinimg.com/...", video_url: nil }
```

### Search & Boards

```ruby
results = PinterestDL.search('nature landscape', limit: 25)
video_pins = PinterestDL.search('motion graphics', limit: 20, type: :video)

images = PinterestDL.search_images('sunset', limit: 5)
videos = PinterestDL.search_videos('tutorial', limit: 3)

# Boards and board sections
pins = PinterestDL.board('https://www.pinterest.com/username/board-name/', limit: 100)
section_pins = PinterestDL.board('https://www.pinterest.com/username/board-name/section-slug/', limit: 50)
```

### Downloading

```ruby
# Single file with resume, max size, and speed limit
PinterestDL.download(
  'https://i.pinimg.com/originals/aa/bb/cc/img.jpg',
  path: 'out/img.jpg',
  resume: true,
  max_size: 100 * 1024 * 1024,
  max_speed: '1.5M'
)

# Batch download (returns a PinterestDL::DownloadReport, compatible with Hash access)
urls = PinterestDL.search_images('mountains', limit: 40)
report = PinterestDL.download_batch(
  urls,
  dir: './downloads',
  concurrency: 6,
  overwrite: false,
  resume: true,
  deduplicate: true,
  collision_strategy: :rename
)

puts "Downloaded: #{report.succeeded.size}, Failed: #{report.failed.size}, Bytes: #{report.bytes_downloaded}"
```

### Configuration

```ruby
PinterestDL.configure do |c|
  c.cookies             = File.expand_path('~/cookies.txt')
  c.open_timeout        = 10
  c.read_timeout        = 20
  c.write_timeout       = 20
  c.max_retries         = 3
  c.retry_wait          = 1.0
  c.max_retry_wait      = 30.0
  c.retry_jitter        = 0.25
  c.rate_limit_interval = 0.5
  c.concurrency         = 4
  c.overwrite           = true
  c.resume              = true
  c.deduplicate         = true
  c.collision_strategy  = :rename
  c.max_file_size       = 500 * 1024 * 1024
  c.max_speed           = nil
  c.verify_content_type = true
  c.proxy               = nil
  c.quality             = :originals
  c.max_cache_entries   = 256
end
```

### CLI

```bash
pinterest-dl image https://www.pinterest.com/pin/example/ -o pin.jpg
pinterest-dl video https://www.pinterest.com/pin/example/ -o pin.mp4 --max-speed 2M
pinterest-dl media https://www.pinterest.com/pin/example/ --json
pinterest-dl search "cyberpunk city" -n 50 -j 8 -o ./downloads
pinterest-dl board https://www.pinterest.com/username/board-name/ -n 100 -j 6 -s -o ./downloads
pinterest-dl board https://www.pinterest.com/username/board-name/ --videos-only -o ./videos
pinterest-dl search "cats" --images-only -n 30 --format json
pinterest-dl board https://www.pinterest.com/username/secret/ -c ~/cookies.txt --no-progress -o ./secret
```

## Development

```bash
bundle install
bundle exec rake test      # run the test suite
bundle exec rake coverage  # run tests with SimpleCov coverage
bundle exec rake rubocop   # lint
bundle exec rake           # test + rubocop
```

## License

WTFPL — [monji024](https://github.com/monji024)